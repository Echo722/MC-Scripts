-- ChannelFit core: render-settings checks, dry-run measurement, classification
-- and export. No UI code here; MC_ChannelFit.lua draws the window.
-- Loaded with dofile(), returns a module table. Nothing touches `reaper` at
-- load time, so the offline tests can run it against a stub.
-- MC Scripts

local M = {}

M.VERSION = "1.0"
M.SCRIPT_NAME = "MC ChannelFit"

--------------------------------------------------------------------------------
-- Config (dB)
--------------------------------------------------------------------------------
M.DEFAULTS = {
  mono_db      = -60,  -- S vs M energy at or below this counts as dual mono...
  mono_peak_db = -30,  -- ...if S peak vs M peak is also at or below this
  one_side_db  = -60,  -- quieter vs louder channel energy at or below this: one-sided
  gate_dbfs    = -70,  -- 10 ms windows whose louder channel RMS is below this are skipped
}
-- slider ranges; also used to clamp values read back from ExtState
M.LIMITS = {
  mono_db      = { -90, -20 },
  mono_peak_db = { -60, 0 },
  one_side_db  = { -90, -30 },
  gate_dbfs    = { -100, -40 },
}
M.CONFIG_KEYS = { "mono_db", "mono_peak_db", "one_side_db", "gate_dbfs" }
local WINDOW_SEC = 0.01

M.CONFIG = {}
for k, v in pairs(M.DEFAULTS) do M.CONFIG[k] = v end
local CONFIG = M.CONFIG

-- gmem layout: keep in sync with MC_ChannelFit_Meter.jsfx. Layout 2 keeps the
-- header and the 16-slot rows of layout 1 and fills row slots 11..15.
local G = {
  NAME = "MC_ChannelFit", LAYOUT = 2, MAX_SLOTS = 8388608,  -- 2^23
  TBL = 64, IN_STRIDE = 4, OUT_STRIDE = 16,
  TOKEN = 0, VERSION = 1, COUNT = 2, GATE = 3, WINDOW = 4,
  ACK = 8, SRATE = 9, INITS = 10, ERROR = 11, OUTSIDE = 12, JUMPS = 13,
}
-- offsets within one result row
local ROW = { samples = 0, windows = 1, gated = 2, eL = 3, eR = 4, eLR = 5, eS = 6,
              pL = 7, pR = 8, pM = 9, pS = 10,
              sL = 11, sR = 12, nG = 13, srate = 14, over = 15 }
M.ROW = ROW

-- Measurement completeness. A region is only judged when its row holds
-- (nearly) every sample its file should have; anything else is "unmeasured"
-- and exported as stereo.
local COVERAGE_MIN = 0.95      -- measured / expected samples, below: incomplete
local COVERAGE_MAX = 1.01      -- above (plus slack): the region was rendered twice
local COVERAGE_SLACK = 64      -- samples of rounding at both ends
local OVERSHOOT_MAX = 16384    -- samples after the region's end in its own file.
                               -- REAPER renders whole blocks, so up to one block
                               -- is normal padding; more means unmeasured audio
local OUTSIDE_TOL_PER_FILE = 8 -- samples outside every region, per rendered file
M.COVERAGE_MIN, M.COVERAGE_MAX, M.OVERSHOOT_MAX = COVERAGE_MIN, COVERAGE_MAX, OVERSHOOT_MAX

local MAX_REGIONS = 2000  -- keeps every loop short: this all runs on REAPER's UI thread
local METER_REL = "MC Scripts/ChannelFit/MC_ChannelFit_Meter.jsfx"  -- under Effects/
local ACTION_DRY_RUN = 43349  -- File: Dry run render project, using the most recent render settings
local ACTION_RENDER = 42230   -- File: Render project, using the most recent render settings, auto-close render dialog

-- RENDER_SETTINGS source bits other than "master mix"
local SRC_STEMS = 1 | 2
local SRC_MATRIX = 8
local SRC_RAZOR = 4096           -- razor edit areas (not in the API docs this script was written against)
local SRC_OTHER = 32 | 64 | 128 | SRC_RAZOR  -- selected items / items via master / tracks via master / razor

M.KINDS = { "mono", "stereo", "one_side", "silent", "unmeasured" }
M.LABEL = {
  mono = "双单声道", stereo = "真立体声", one_side = "单侧有声",
  silent = "静音", unmeasured = "未测到",
}
local LABEL = M.LABEL

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
-- Raise a message for the user. `detail` holds extra lines (raw settings).
local function fail(msg, detail) error({ msg = detail and (msg .. "\n\n" .. detail) or msg,
                                         short = msg, detail = detail }, 0) end
M.fail = fail

-- xpcall handler: keep our {msg} errors, wrap Lua errors with a traceback
function M.error_handler(e)
  if type(e) == "table" and e.msg then return e end
  return { msg = "脚本出错：" .. tostring(e), short = "脚本出错：" .. tostring(e),
           trace = debug.traceback() }
end

local function int(x) return math.tointeger(math.floor(x + 0.5)) end

local function db10(x) return x > 0 and 10 * math.log(x, 10) or -math.huge end
local function db20(x) return x > 0 and 20 * math.log(x, 10) or -math.huge end

function M.fmt_db(v)
  if v == nil then return "-" end
  if v == -math.huge then return "-inf" end
  if v == math.huge then return "+inf" end
  return string.format("%.1f", v)
end
local fmt_db = M.fmt_db

-- 0.42 -> "0.42 s", 75.3 -> "1:15.3"
function M.fmt_duration(sec)
  if sec < 60 then return string.format("%.2f s", sec) end
  local m = math.floor(sec / 60)
  return string.format("%d:%04.1f", m, sec - 60 * m)
end

local function proj_get(key) return reaper.GetSetProjectInfo(0, key, 0, false) end
local function proj_set(key, v) reaper.GetSetProjectInfo(0, key, v, true) end
local function proj_str(key)
  local _, s = reaper.GetSetProjectInfo_String(0, key, "", false)
  return s
end

-- Files the project would write with its current render settings.
local function render_targets()
  local t = {}
  for p in proj_str("RENDER_TARGETS"):gmatch("[^;]+") do t[#t + 1] = p end
  return t
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end
M.file_exists = file_exists

--------------------------------------------------------------------------------
-- Thresholds: clamp to the slider ranges, (de)serialize for ExtState
--------------------------------------------------------------------------------
function M.clamp_config(cfg)
  local out = {}
  for _, k in ipairs(M.CONFIG_KEYS) do
    local v, lim = tonumber(cfg[k]), M.LIMITS[k]
    if v == nil or v ~= v then v = M.DEFAULTS[k] end
    out[k] = math.max(lim[1], math.min(lim[2], v))
  end
  return out
end

-- "mono_db=-60;mono_peak_db=-30;..." in CONFIG_KEYS order
function M.serialize_config(cfg)
  local parts = {}
  for _, k in ipairs(M.CONFIG_KEYS) do parts[#parts + 1] = ("%s=%s"):format(k, cfg[k]) end
  return table.concat(parts, ";")
end

-- Unknown keys and garbage are ignored; missing keys fall back to defaults.
function M.parse_config(s)
  local cfg = {}
  for k, v in (s or ""):gmatch("([%w_]+)=([^;]*)") do
    if M.DEFAULTS[k] ~= nil then cfg[k] = tonumber(v) end
  end
  return M.clamp_config(cfg)
end

function M.set_config(cfg)
  local c = M.clamp_config(cfg)
  for k, v in pairs(c) do CONFIG[k] = v end
end

function M.config_is_default(cfg)
  for _, k in ipairs(M.CONFIG_KEYS) do
    if math.abs((cfg[k] or 0) - M.DEFAULTS[k]) > 1e-9 then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- Render settings snapshot / restore
--------------------------------------------------------------------------------
-- Everything the script changes; restore() puts it back even after an error.
local NUM_KEYS = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_CHANNELS", "RENDER_TAILFLAG" }
local KEY_NAME = {
  RENDER_SETTINGS = "渲染源", RENDER_BOUNDSFLAG = "渲染范围",
  RENDER_CHANNELS = "声道", RENDER_TAILFLAG = "渲染尾巴",
}

-- Regions are keyed by GUID so a restore still finds them if the project's
-- marker list changed; markers fall back to their enum index.
local function region_key(i, rm)
  local ok, has, guid = pcall(reaper.GetSetRegionOrMarkerInfo_String, 0, rm, "GUID", "", false)
  if ok and has and guid ~= "" then return guid end
  return "#" .. i
end

local function snapshot()
  local s = { num = {}, sel = {} }
  for _, k in ipairs(NUM_KEYS) do s.num[k] = proj_get(k) end
  for i = 0, reaper.GetNumRegionsOrMarkers(0) - 1 do
    local rm = reaper.GetRegionOrMarker(0, i, "")
    s.sel[region_key(i, rm)] = reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_UISEL")
  end
  return s
end
M.snapshot = snapshot

-- Writes every value back, each in its own pcall, then reads everything back.
-- Returns a list of leftovers (empty when the project is back as it was):
--   { what = "声道", want = 2, got = 1 }  or  { what = "Region 选择", count = n }
local function restore(s)
  local problems = {}
  for _, k in ipairs(NUM_KEYS) do
    local ok, err = pcall(proj_set, k, s.num[k])
    if not ok then problems[#problems + 1] = { what = KEY_NAME[k], err = tostring(err) } end
  end
  local sel_failed = 0
  local ok_n, n = pcall(reaper.GetNumRegionsOrMarkers, 0)
  for i = 0, (ok_n and n or 0) - 1 do
    local ok, err = pcall(function()
      local rm = reaper.GetRegionOrMarker(0, i, "")
      local want = s.sel[region_key(i, rm)]
      if want ~= nil then
        reaper.SetRegionOrMarkerInfo_Value(0, rm, "B_UISEL", want)
        if reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_UISEL") ~= want then error("read-back") end
      end
    end)
    if not ok then sel_failed = sel_failed + 1 end
  end
  -- read back: a set that "worked" but did not stick is a leftover too
  for _, k in ipairs(NUM_KEYS) do
    local ok, got = pcall(proj_get, k)
    if ok and got ~= s.num[k] then
      problems[#problems + 1] = { what = KEY_NAME[k], key = k, want = s.num[k], got = got }
    end
  end
  if not ok_n then problems[#problems + 1] = { what = "Region 选择", err = tostring(n) } end
  if sel_failed > 0 then problems[#problems + 1] = { what = "Region 选择", count = sel_failed } end
  return problems
end
M.restore = restore

-- Pure: one line per leftover, for the UI and the error popup.
function M.describe_leftovers(problems)
  local lines = {}
  for _, p in ipairs(problems or {}) do
    if p.key == "RENDER_CHANNELS" then
      lines[#lines + 1] = ("声道没能恢复：现在是 %d 声道，原来是 %d 声道（导出可能残留单声道）"):format(int(p.got), int(p.want))
    elseif p.key == "RENDER_BOUNDSFLAG" then
      lines[#lines + 1] = ("渲染范围没能恢复：现在是「%s」，原来是「%s」"):format(
        M.BOUNDS_NAME[int(p.got)] or tostring(p.got), M.BOUNDS_NAME[int(p.want)] or tostring(p.want))
    elseif p.count then
      lines[#lines + 1] = ("%d 个 Region 的选中状态没能恢复（选中的 Region 可能和原来不同）"):format(p.count)
    elseif p.got then
      lines[#lines + 1] = ("%s没能恢复：现在是 %s，原来是 %s"):format(p.what, tostring(p.got), tostring(p.want))
    else
      lines[#lines + 1] = ("%s没能恢复：%s"):format(p.what, p.err or "未知错误")
    end
  end
  return lines
end


--------------------------------------------------------------------------------
-- Regions
--------------------------------------------------------------------------------
local function all_regions()
  local list = {}
  for i = 0, reaper.GetNumRegionsOrMarkers(0) - 1 do
    local rm = reaper.GetRegionOrMarker(0, i, "")
    if reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_ISREGION") ~= 0 then
      local _, name = reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "", false)
      local _, guid = reaper.GetSetRegionOrMarkerInfo_String(0, rm, "GUID", "", false)
      list[#list + 1] = {
        enum = i,
        guid = guid,
        number = int(reaper.GetRegionOrMarkerInfo_Value(0, rm, "I_NUMBER")),
        name = name,
        start = reaper.GetRegionOrMarkerInfo_Value(0, rm, "D_STARTPOS"),
        stop = reaper.GetRegionOrMarkerInfo_Value(0, rm, "D_ENDPOS"),
        selected = reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_UISEL") ~= 0,
      }
    end
  end
  table.sort(list, function(a, b) return a.start < b.start end)
  return list
end

-- Regions that touch end-to-start are fine; any real overlap would put the
-- same audio into two files and make the measurement ambiguous.
local function find_overlaps(regions)
  local hits = {}
  for i = 2, #regions do
    local a, b = regions[i - 1], regions[i]
    if b.start < a.stop - 1e-9 then hits[#hits + 1] = { a, b } end
  end
  return hits
end

-- Select exactly the regions in `list` (every other region is deselected).
local function select_only(list)
  local want = {}
  for _, r in ipairs(list) do want[r.enum] = true end
  for i = 0, reaper.GetNumRegionsOrMarkers(0) - 1 do
    local rm = reaper.GetRegionOrMarker(0, i, "")
    if reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_ISREGION") ~= 0 then
      reaper.SetRegionOrMarkerInfo_Value(0, rm, "B_UISEL", want[i] and 1 or 0)
    end
  end
end

--------------------------------------------------------------------------------
-- Preflight: work out which regions the user's render settings would export
--------------------------------------------------------------------------------
local function matrix_tracks(number)
  local list, k = {}, 0
  while true do
    local tr = reaper.EnumRegionRenderMatrix(0, number, k)
    if not tr then break end
    list[#list + 1] = tr
    k = k + 1
  end
  return list
end

-- RENDER_BOUNDSFLAG values (REAPER API docs, GetSetProjectInfo)
local BOUNDS = { ALL_REGIONS = 3, SELECTED_REGIONS = 5 }
local BOUNDS_NAME = {
  [0] = "自定义时间范围", [1] = "整个工程", [2] = "时间选区", [3] = "所有 Region",
  [4] = "选中的媒体项", [5] = "选中的 Region", [6] = "所有标记", [7] = "选中的标记",
}
M.BOUNDS_NAME = BOUNDS_NAME

local function source_name(settings)
  if settings & SRC_RAZOR ~= 0 then return "Razor edit 区域" end
  if settings & SRC_MATRIX ~= 0 then return "Region 渲染矩阵" end
  if settings & 128 ~= 0 then return "选中的轨道（经 Master）" end
  if settings & 64 ~= 0 then return "选中的媒体项（经 Master）" end
  if settings & 32 ~= 0 then return "选中的媒体项" end
  local stems = settings & SRC_STEMS
  if stems == 1 then return "Master mix + 分轨" end
  if stems == 2 then return "仅分轨" end
  return "Master mix"
end
M.source_name = source_name

-- REAPER writes render-window changes into the project only on "Save
-- settings" or a render; while the window is open, scripts read older values.
local RENDER_DIALOG_TITLE = "Render to File"

function M.find_render_dialog()
  local h = reaper.JS_Window_FindTop(RENDER_DIALOG_TITLE, true)
  if h and reaper.JS_Window_IsVisible(h) then return h end
  return nil
end

local function render_dialog_open() return M.find_render_dialog() ~= nil end
M.render_dialog_open = render_dialog_open

-- The raw values preflight() worked from, appended to each of its errors.
local function settings_summary(settings, bounds, channels, tailflag)
  return table.concat({
    "脚本读到的工程渲染设置：",
    ("  RENDER_SETTINGS = %d（渲染源：%s）"):format(settings, source_name(settings)),
    ("  RENDER_BOUNDSFLAG = %d（%s）"):format(bounds, BOUNDS_NAME[bounds] or "未知"),
    ("  RENDER_CHANNELS = %d"):format(channels),
    ("  RENDER_TAILFLAG = %d"):format(tailflag),
    "",
    "这些是工程里已保存的渲染设置。渲染窗口里的改动要点「Save settings」或渲染一次"
      .. "才会写进工程，如果和渲染窗口里看到的不一样，请先保存再运行。",
  }, "\n")
end

local function preflight()
  local settings = int(proj_get("RENDER_SETTINGS"))
  local bounds = int(proj_get("RENDER_BOUNDSFLAG"))
  local channels = int(proj_get("RENDER_CHANNELS"))
  local tailflag = int(proj_get("RENDER_TAILFLAG"))
  local function pfail(msg)
    fail(msg, settings_summary(settings, bounds, channels, tailflag))
  end

  if render_dialog_open() then
    pfail("渲染窗口还开着。设置好后点「Save settings」并关闭渲染窗口，ChannelFit 会自动重新检测。")
  end

  local matrix = settings & SRC_MATRIX ~= 0
  -- razor edits restrict what gets rendered even next to the matrix: always refuse
  if settings & SRC_RAZOR ~= 0 then
    pfail("渲染源是 Razor edit 区域。ChannelFit 只处理 Master mix，或只勾了 Master 列的 Region 渲染矩阵。")
  end
  -- the matrix replaces the stems/items choice, so only check those without it
  if not matrix and settings & (SRC_STEMS | SRC_OTHER) ~= 0 then
    pfail("渲染源不是 Master mix 或 Region 渲染矩阵（而是分轨、选中的媒体项或轨道）。\n"
      .. "ChannelFit 只处理 Master mix，或只勾了 Master 列的 Region 渲染矩阵。")
  end
  if bounds ~= BOUNDS.ALL_REGIONS and bounds ~= BOUNDS.SELECTED_REGIONS then
    pfail("渲染范围不是「所有 Region」或「选中的 Region」。")
  end
  if channels ~= 2 then
    pfail(("渲染声道设置是 %d 声道。ChannelFit 只在设置为立体声（2 声道）时工作。"):format(channels))
  end

  local regions = all_regions()
  if #regions == 0 then pfail("工程里没有 Region。") end

  local only_selected = bounds == BOUNDS.SELECTED_REGIONS
  local master = reaper.GetMasterTrack(0)
  local targets = {}
  if matrix then
    if #matrix_tracks(0) > 0 then
      pfail("Region 渲染矩阵里用了「整个工程」这一行，ChannelFit 不支持。")
    end
    for _, r in ipairs(regions) do
      local tracks = matrix_tracks(r.number)
      for _, tr in ipairs(tracks) do
        if tr ~= master then
          pfail(("Region %d「%s」在渲染矩阵里勾了 Master 以外的轨道（分轨导出）。\n"
            .. "ChannelFit 只处理只勾 Master 的矩阵。"):format(r.number, r.name))
        end
      end
      if #tracks > 0 and (r.selected or not only_selected) then targets[#targets + 1] = r end
    end
  else
    for _, r in ipairs(regions) do
      if r.selected or not only_selected then targets[#targets + 1] = r end
    end
  end

  if #targets == 0 then
    pfail(only_selected and "按当前渲染设置没有要导出的 Region：没有选中 Region，或选中的 Region 在矩阵里没勾 Master。"
      or "按当前渲染设置没有要导出的 Region。")
  end
  if #targets > MAX_REGIONS then
    pfail(("要导出 %d 个 Region，超过上限 %d。"):format(#targets, MAX_REGIONS))
  end

  local overlaps = find_overlaps(targets)
  if #overlaps > 0 then
    local lines = {}
    for i, p in ipairs(overlaps) do
      if i > 10 then lines[#lines + 1] = ("……共 %d 处"):format(#overlaps) break end
      lines[#lines + 1] = ("  %d「%s」与 %d「%s」"):format(p[1].number, p[1].name, p[2].number, p[2].name)
    end
    pfail("以下 Region 时间上有重叠，ChannelFit 无法分开测量，已中止：\n" .. table.concat(lines, "\n"))
  end

  -- RENDER_TAILFLAG: &8 = all markers/regions, &32 = selected markers/regions
  local tail_on = tailflag & (only_selected and 32 or 8) ~= 0
  local tail_sec = tail_on and proj_get("RENDER_TAILMS") / 1000 or 0

  return {
    settings = settings, tailflag = tailflag, tail_on = tail_on, tail_sec = tail_sec,
    targets = targets, matrix = matrix,
  }
end
M.preflight = preflight

-- Settings that could make two passes come out different from one render.
-- What they do in REAPER has not been checked, so they only warn and the
-- export dialog asks for a confirmation. Not readable through the API (left
-- for testing in REAPER):
--   * forced mono/stereo on the Master cell of the region render matrix
--     (EnumRegionRenderMatrix lists tracks only; SetRegionRenderMatrix with
--     flag 2/4 on the Master did not change the rendered channels in a test)
--   * the "adjust mono media by -3 dB" render/normalize preference
-- Pure apart from reading the project: `read(key)` defaults to proj_get.
function M.consistency_warnings(plan, read)
  read = read or proj_get
  local w = {}
  local norm = int(read("RENDER_NORMALIZE"))
  if norm & 1 ~= 0 then
    w[#w + 1] = "渲染开了标准化。如果标准化是按整批文件一起算的（例如统一增益），分两遍导出后每遍单独计算，"
      .. "音量会和一次导出不同；逐个文件标准化不受影响。单声道文件的响度计算也可能和立体声不同。"
  end
  if norm & 64 ~= 0 then
    w[#w + 1] = "渲染开了砖墙限幅（brickwall limit），单声道和立体声文件的限幅结果可能不同。"
  end
  if plan.matrix then
    w[#w + 1] = "当前用的是 Region 渲染矩阵。ChannelFit 读不到矩阵里 Master 格子是否强制了单声道/立体声，"
      .. "导出时会改用 Master mix 加选中 Region 的方式，矩阵里的强制声道设置不会生效。"
  end
  if int(read("RENDER_SETTINGS")) & 2048 ~= 0 then
    w[#w + 1] = "渲染开了 2nd pass render，每一遍都会各自做两次渲染。"
  end
  return w
end

-- One-click fixes for the three checked settings. Pure: returns the project
-- key, the new value and the button label, or nil if `key` needs no fix.
function M.fix_for(key, raw)
  if key == "source" then
    return "RENDER_SETTINGS", raw.settings & ~(SRC_STEMS | SRC_OTHER), "改为 Master mix"
  elseif key == "bounds" then
    return "RENDER_BOUNDSFLAG", BOUNDS.ALL_REGIONS, "改为所有 Region"
  elseif key == "channels" then
    return "RENDER_CHANNELS", 2, "改为立体声"
  end
  return nil
end

local function read_raw()
  return { settings = int(proj_get("RENDER_SETTINGS")), bounds = int(proj_get("RENDER_BOUNDSFLAG")),
           channels = int(proj_get("RENDER_CHANNELS")) }
end

-- Status rows for the UI. Never throws: each row says whether that setting is
-- usable, and `plan` is the preflight() result when everything passes.
-- While the render window is open the project still holds the old values, so
-- the rows are only provisional and `waiting` is set instead of an error.
function M.check_settings()
  local raw = read_raw()
  local settings, bounds, channels = raw.settings, raw.bounds, raw.channels
  local matrix = settings & SRC_MATRIX ~= 0
  local src_ok = settings & SRC_RAZOR == 0 and (matrix or settings & (SRC_STEMS | SRC_OTHER) == 0)
  local st = {
    rows = {
      { key = "source", label = "渲染源", value = source_name(settings), ok = src_ok,
        hint = "需要 Master mix，或只勾 Master 列的 Region 渲染矩阵" },
      { key = "bounds", label = "渲染范围", value = BOUNDS_NAME[bounds] or ("未知（%d）"):format(bounds),
        ok = bounds == BOUNDS.ALL_REGIONS or bounds == BOUNDS.SELECTED_REGIONS,
        hint = "需要「所有 Region」或「选中的 Region」" },
      { key = "channels", label = "声道", value = channels == 2 and "立体声" or ("%d 声道"):format(channels),
        ok = channels == 2, hint = "需要立体声（2 声道）" },
    },
    raw = raw,
    dialog_open = render_dialog_open(),
  }
  for _, r in ipairs(st.rows) do
    if r.ok then
      r.hint = nil
    elseif not st.dialog_open then
      local _, _, label = M.fix_for(r.key, raw)
      r.fix = label
    end
  end
  if st.dialog_open then
    st.ok, st.waiting = false, true
    st.error = "渲染窗口已打开。设置好后点「Save settings」并关闭窗口，这里会自动重新检测。"
    return st
  end
  local ok, res = xpcall(preflight, M.error_handler)
  if ok then
    st.plan = res
  else
    st.error = res.short or res.msg
    st.detail = res.detail
  end
  st.ok = ok
  return st
end

--------------------------------------------------------------------------------
-- Render window: open it from the UI, compare settings before / after
--------------------------------------------------------------------------------
-- File: Render project to disk... (opens the render settings window)
local ACTION_RENDER_DIALOG = 40015

-- Brings an open render window to the front, otherwise opens it. If the
-- window turns out to be modal this call returns only once it is closed.
-- Returns "focused" or "opened".
function M.open_render_dialog()
  local h = M.find_render_dialog()
  if h then
    reaper.JS_Window_SetForeground(h)
    return "focused"
  end
  reaper.Main_OnCommand(ACTION_RENDER_DIALOG, 0)
  return "opened"
end

-- Everything the user might change in the render window that matters here.
function M.render_fingerprint()
  local fp = read_raw()
  fp.tailflag = int(proj_get("RENDER_TAILFLAG"))
  fp.pattern = proj_str("RENDER_PATTERN")
  fp.file = proj_str("RENDER_FILE")
  fp.format = proj_str("RENDER_FORMAT")
  return fp
end

local FP_FIELDS = {
  { "settings", "渲染源" }, { "bounds", "渲染范围" }, { "channels", "声道" },
  { "tailflag", "渲染尾巴" }, { "format", "格式" }, { "file", "输出目录" }, { "pattern", "文件名" },
}

-- Pure: names of the fields that differ between two fingerprints.
function M.diff_fingerprint(before, after)
  local changed = {}
  for _, f in ipairs(FP_FIELDS) do
    if before[f[1]] ~= after[f[1]] then changed[#changed + 1] = f[2] end
  end
  return changed
end

-- Pure: the log line shown once the render window has closed.
function M.render_dialog_closed_message(before, after)
  local changed = M.diff_fingerprint(before, after)
  if #changed == 0 then
    return "warn", "渲染窗口已关闭，渲染设置没有变化。如果刚才改过设置，可能没点「Save settings」。"
  end
  return "ok", "渲染窗口已关闭，已读取新的渲染设置（" .. table.concat(changed, "、") .. "）。"
end

-- Writes one fix from M.fix_for() into the project, as its own undo point.
function M.apply_fix(key)
  local pkey, value, label = M.fix_for(key, read_raw())
  if not pkey then return nil end
  reaper.Undo_BeginBlock2(0)
  proj_set(pkey, value)
  reaper.Undo_EndBlock2(0, M.SCRIPT_NAME .. "：" .. label, -1)
  return label
end

-- Things that change the rendered channels after the meter (which sits at the
-- end of the master FX chain): worth a warning, not a stop.
function M.master_warnings()
  local master = reaper.GetMasterTrack(0)
  local w = {}
  if reaper.GetToggleCommandState(40917) == 1 then
    w[#w + 1] = "Master 开着单声道（Mono）按钮：实际导出本来就是单声道，测量结果不代表导出结果。"
  end
  if math.abs(reaper.GetMediaTrackInfo_Value(master, "D_PAN")) > 1e-6
    or math.abs(reaper.GetMediaTrackInfo_Value(master, "D_WIDTH") - 1) > 1e-6 then
    w[#w + 1] = "Master 的声像或宽度不在默认值：测量点在 Master FX 之后、声像之前，结果可能有偏差。"
  end
  return w
end

-- Pure: RENDER_SETTINGS for one pass. Plain master mix: with the matrix bit
-- gone, leftover stems / items / razor bits (the matrix ignores them) would
-- otherwise take over as the source. restore() puts the user's value back.
function M.pass_settings(settings, dry)
  local s = settings & ~(SRC_MATRIX | SRC_STEMS | SRC_OTHER)
  if dry then s = s & ~2048 end  -- a 2nd render pass would feed the meter twice
  return s
end

-- Point the project's render settings at one pass: master mix of `list`.
local function configure_pass(plan, list, channels, dry)
  proj_set("RENDER_SETTINGS", M.pass_settings(plan.settings, dry))
  proj_set("RENDER_BOUNDSFLAG", 5)  -- selected project regions
  proj_set("RENDER_CHANNELS", channels)
  local tf = plan.tailflag & ~32
  if plan.tail_on then tf = tf | 32 end
  proj_set("RENDER_TAILFLAG", tf)
  select_only(list)
end

--------------------------------------------------------------------------------
-- Meter FX
--------------------------------------------------------------------------------
local function script_dir()
  return debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

-- JSFX only load from the Effects folder: copy the meter there if missing or stale.
local function install_meter()
  local src = read_all(script_dir() .. "MC_ChannelFit_Meter.jsfx")
  if not src then fail("找不到测量插件 MC_ChannelFit_Meter.jsfx，它应和本脚本放在同一文件夹。") end
  local dst = reaper.GetResourcePath() .. "/Effects/" .. METER_REL
  if read_all(dst) ~= src then
    reaper.RecursiveCreateDirectory(dst:match("^(.*)/"), 0)
    local f = io.open(dst, "wb")
    if not f then fail("无法写入 " .. dst) end
    f:write(src)
    f:close()
  end
end

local function add_meter()
  local master = reaper.GetMasterTrack(0)
  if reaper.GetMediaTrackInfo_Value(master, "I_FXEN") == 0 then
    fail("Master 的 FX 链被整体旁通了，测量插件无法工作。请先打开 Master FX 链再运行。")
  end
  local idx = reaper.TrackFX_AddByName(master, "JS:" .. METER_REL, false, -1)
  if idx < 0 then fail("无法在 Master 上加载测量插件 " .. METER_REL) end
  return reaper.TrackFX_GetFXGUID(master, idx)
end

local function remove_meter(guid)
  if not guid then return end
  local master = reaper.GetMasterTrack(0)
  for i = reaper.TrackFX_GetCount(master) - 1, 0, -1 do
    if reaper.TrackFX_GetFXGUID(master, i) == guid then reaper.TrackFX_Delete(master, i) end
  end
end
M.remove_meter = remove_meter

-- The dry run leaves its result window open; close the ones it just created.
local function top_windows()
  local arr = reaper.new_array({}, 1024)
  reaper.JS_Window_ArrayAllTop(arr)
  local set = {}
  for _, addr in ipairs(arr.table()) do set[addr] = true end
  return set
end

local function close_new_render_windows(before)
  for addr in pairs(top_windows()) do
    if not before[addr] then
      local h = reaper.JS_Window_HandleFromAddress(addr)
      -- render progress dialog: has the "Dry run" (40249) and file list (1041) controls
      if reaper.JS_Window_FindChildByID(h, 40249) and reaper.JS_Window_FindChildByID(h, 1041) then
        reaper.JS_WindowMessage_Post(h, "WM_COMMAND", 2, 0, 0, 0)  -- its Close button
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Measurement: one dry run, the meter sums each region into its own gmem row
--------------------------------------------------------------------------------
local function split_time(t)
  local whole = math.floor(t)
  return whole, t - whole
end

-- Runs the dry run (blocks REAPER until it finishes) and stores r.m on every
-- target. `state.meter` tracks the FX so cleanup can remove it after an error.
local function measure(plan, state)
  local targets = plan.targets
  local n = #targets
  local res = G.TBL + G.IN_STRIDE * n
  if res + n * G.OUT_STRIDE > G.MAX_SLOTS then
    fail("Region 太多，测量数据放不进共享内存（gmem）。")
  end

  -- disarm before the FX instance runs its first @init
  reaper.gmem_attach(G.NAME)
  reaper.gmem_write(G.TOKEN, 0)
  install_meter()
  state.meter = add_meter()

  for i, r in ipairs(targets) do
    local b = G.TBL + G.IN_STRIDE * (i - 1)
    local sw, sf = split_time(r.start)
    local ew, ef = split_time(r.stop + plan.tail_sec)
    reaper.gmem_write(b, sw)
    reaper.gmem_write(b + 1, sf)
    reaper.gmem_write(b + 2, ew)
    reaper.gmem_write(b + 3, ef)
  end
  reaper.gmem_write(G.VERSION, G.LAYOUT)
  reaper.gmem_write(G.COUNT, n)
  reaper.gmem_write(G.GATE, 10 ^ (CONFIG.gate_dbfs / 10))
  reaper.gmem_write(G.WINDOW, WINDOW_SEC)
  reaper.gmem_write(G.ERROR, 0)
  local token = math.random(1, 1 << 30)
  if token == reaper.gmem_read(G.ACK) then token = token + 1 end
  reaper.gmem_write(G.TOKEN, token)  -- arm last: the meter only reads the table once armed

  configure_pass(plan, targets, 2, true)
  local before = top_windows()
  reaper.Main_OnCommand(ACTION_DRY_RUN, 0)  -- blocks until the dry run has finished
  reaper.gmem_write(G.TOKEN, 0)
  close_new_render_windows(before)
  remove_meter(state.meter)
  state.meter = nil

  if reaper.gmem_read(G.ACK) ~= token then
    fail("测量插件没有收到数据：Dry run 可能被取消了，或 Master FX 没有运行。")
  end
  local err = int(reaper.gmem_read(G.ERROR))
  if err == 1 then fail("测量数据超出共享内存（gmem）容量，结果不完整，已中止。") end
  if err == 2 then fail("测量插件版本和脚本不一致，请重新安装 ChannelFit。") end
  if err ~= 0 then fail(("测量插件报告了未知错误 %d。"):format(err)) end

  local srate = reaper.gmem_read(G.SRATE)
  local rates = {}
  for i, r in ipairs(targets) do
    local o = res + (i - 1) * G.OUT_STRIDE
    local m = {}
    for k, off in pairs(ROW) do m[k] = reaper.gmem_read(o + off) end
    M.set_expected(m, r.stop + plan.tail_sec - r.start, srate)
    if m.srate > 0 then rates[m.srate] = true end
    r.m = m
  end
  local info = {
    srate = srate, files = int(reaper.gmem_read(G.INITS)),
    outside = int(reaper.gmem_read(G.OUTSIDE)), jumps = int(reaper.gmem_read(G.JUMPS)),
  }
  local n_rates = 0
  for _ in pairs(rates) do n_rates = n_rates + 1 end
  info.mixed_rates = n_rates > 1
  return info
end

-- Expected samples come from the rate the row was measured at (the meter
-- stores it), so a project rate change between files cannot shift coverage.
function M.set_expected(m, seconds, fallback_srate)
  local sr = (m.srate and m.srate > 0) and m.srate or fallback_srate
  m.expected = int(seconds * sr)
end

-- Pure: whether the dry-run counters point at a real problem. A few samples
-- outside every region per file are rounding at region edges; anything more,
-- or a position jump, means part of the render was not measured.
function M.run_warnings(info)
  local w = {}
  local tol = OUTSIDE_TOL_PER_FILE * math.max(1, info.files or 1)
  if (info.outside or 0) > tol then
    w[#w + 1] = ("Dry run 中有 %d 个采样不在任何 Region 里（每个文件允许 %d 个舍入误差），结果可能不完整。")
      :format(info.outside, OUTSIDE_TOL_PER_FILE)
  end
  if (info.jumps or 0) > 0 then
    w[#w + 1] = ("Dry run 中播放位置跳变 %d 次，跳变附近的音频可能没测到。"):format(info.jumps)
  end
  if info.mixed_rates then
    w[#w + 1] = "Dry run 期间采样率变过，各 Region 已按各自的采样率计算覆盖率。"
  end
  return w
end

--------------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------------
-- Fills r.kind ("mono" | "stereo" | "one_side" | "silent" | "unmeasured") and
-- the figures shown in the report. Only "mono" regions are exported as mono,
-- unless the user overrides a region. Uses M.CONFIG, so changing a threshold
-- and calling classify() again re-judges without a new dry run.
-- Pure: "ok", or why the row is not a complete measurement of its file.
function M.coverage(m)
  local exp = m.expected or 0
  if exp <= 0 or (m.samples or 0) <= 0 then return "none", 0 end
  local ratio = m.samples / exp
  if m.samples < COVERAGE_MIN * exp - COVERAGE_SLACK then return "short", ratio end
  if m.samples > COVERAGE_MAX * exp + COVERAGE_SLACK then return "excess", ratio end
  if (m.over or 0) > OVERSHOOT_MAX then return "overrun", ratio end
  return "ok", ratio
end

-- AC (DC-free) energies. A shared DC offset hides opposite-phase content:
-- L = d + s, R = d - s has S = s but M = d, and with d >> s the side energy
-- looks small next to M. Subtracting each channel's mean over the gated
-- windows (sum and count kept by the meter) leaves eL = eR = Σs², eLR = -Σs².
local function ac_energies(m)
  local n = m.nG or 0
  local eL, eR, eLR, eS = m.eL, m.eR, m.eLR, m.eS
  if n <= 0 or not m.sL then return eL, eR, eLR, eS, 0, 0 end
  local mL, mR = m.sL / n, m.sR / n
  local aL = math.max(0, eL - n * mL * mL)
  local aR = math.max(0, eR - n * mR * mR)
  local aLR = eLR - n * mL * mR
  local dS = (mL - mR) / 2
  local aS = math.max(0, eS - n * dS * dS)
  return aL, aR, aLR, aS, mL, mR
end

-- The report mentions DC only where it is a real share of the signal energy
-- (a short click has a small mean that changes nothing).
local DC_NOTE_SHARE = 0.01

local function classify(r)
  local m = r.m
  local eL, eR, eLR, eS, dcL, dcR = ac_energies(m)
  local eM = math.max(0, (eL + eR + 2 * eLR) / 4)
  r.corr = (eL > 0 and eR > 0) and math.max(-1, math.min(1, eLR / math.sqrt(eL * eR))) or nil
  r.side_db = (eM > 0) and db10(eS / eM) or ((eS > 0) and math.huge or nil)
  r.side_peak_db = (m.pM > 0) and db20(m.pS / m.pM) or nil
  r.balance_db = (eL > 0 and eR > 0) and db10(eL / eR) or nil
  r.peak_db = db20(math.max(m.pL, m.pR))
  local n, total = m.nG or 0, (m.eL or 0) + (m.eR or 0)
  r.dc = (n > 0 and total > 0 and n * (dcL * dcL + dcR * dcR) > DC_NOTE_SHARE * total) and { dcL, dcR } or nil
  r.side = nil
  r.coverage, r.coverage_ratio = M.coverage(m)

  if r.coverage ~= "ok" then
    r.kind = "unmeasured"
  elseif m.gated == 0 then
    r.kind = "silent"
  elseif math.max(eL, eR) <= 0 then
    r.kind = "stereo"  -- pure DC, nothing to compare
  elseif db10(math.min(eL, eR) / math.max(eL, eR)) <= CONFIG.one_side_db then
    r.kind = "one_side"
    r.side = (eL >= eR) and "L" or "R"
  elseif eM > 0 and db10(eS / eM) <= CONFIG.mono_db
    and (m.pS == 0 or db20(m.pS / m.pM) <= CONFIG.mono_peak_db) then
    r.kind = "mono"
  else
    r.kind = "stereo"
  end
end
M.classify = classify

local function note_for(r)
  if r.kind == "one_side" then
    return ("只有%s声道有声，默认保持立体声，请手动检查"):format(r.side == "L" and "左" or "右")
  elseif r.kind == "silent" then
    return "整段低于静音门限，保持立体声"
  elseif r.kind == "unmeasured" then
    local m = r.m
    if r.coverage == "excess" then
      return ("测到 %d 个采样，比应有的 %d 个多，可能重复渲染了，保持立体声"):format(int(m.samples), m.expected)
    elseif r.coverage == "overrun" then
      return ("Region 结束后还渲染了 %d 个采样没测到，保持立体声"):format(int(m.over))
    end
    return ("只测到 %d / %d 个采样（%.0f%%），保持立体声"):format(int(m.samples), m.expected,
      100 * (r.coverage_ratio or 0))
  elseif r.kind == "stereo" then
    if r.corr and r.corr < -0.9 then return "左右基本反相，导成单声道会互相抵消" end
    if r.balance_db and math.abs(r.balance_db) > 1 and r.side_db and r.side_db < -10 then
      return ("左右是同一个声音、音量差 %.1f dB（声像偏了）"):format(math.abs(r.balance_db))
    end
    if r.dc then return "有直流偏移，已扣除后判定" end
  elseif r.kind == "mono" and r.dc then
    return "有直流偏移，已扣除后判定"
  end
  return ""
end
M.note_for = note_for

--------------------------------------------------------------------------------
-- Export plan: what channel count each region gets
--------------------------------------------------------------------------------
-- r.override is nil (follow the verdict), 1 (force mono) or 2 (force stereo).
function M.export_channels(r)
  if r.override == 1 or r.override == 2 then return r.override end
  return r.kind == "mono" and 1 or 2
end

-- Splits targets into the two passes and counts verdicts / overrides.
function M.summarize(targets)
  local s = { total = #targets, mono = {}, rest = {}, kinds = {}, overridden = 0 }
  for _, k in ipairs(M.KINDS) do s.kinds[k] = 0 end
  for _, r in ipairs(targets) do
    if r.kind then s.kinds[r.kind] = s.kinds[r.kind] + 1 end
    if r.override then s.overridden = s.overridden + 1 end
    if M.export_channels(r) == 1 then s.mono[#s.mono + 1] = r else s.rest[#s.rest + 1] = r end
  end
  return s
end

-- Overrides survive a re-analysis for regions that still exist (matched by GUID).
function M.carry_overrides(old_targets, new_targets)
  local by_guid = {}
  for _, r in ipairs(old_targets or {}) do
    if r.override and r.guid and r.guid ~= "" then by_guid[r.guid] = r.override end
  end
  for _, r in ipairs(new_targets) do
    if r.guid and by_guid[r.guid] then r.override = by_guid[r.guid] end
  end
end

--------------------------------------------------------------------------------
-- Report (console text)
--------------------------------------------------------------------------------
-- The judging rules with the current thresholds, one line each (UI + report).
function M.rules_text()
  return {
    ("双单声道：S/M 能量 ≤ %g dB，且 S/M 峰值 ≤ %g dB"):format(CONFIG.mono_db, CONFIG.mono_peak_db),
    ("单侧有声：弱侧比强侧低 %g dB 以上"):format(-CONFIG.one_side_db),
    ("静音门限：%g dBFS，更安静的 10 ms 窗口不参与统计"):format(CONFIG.gate_dbfs),
    ("覆盖率低于 %d%% 判为未测到，按立体声导出"):format(math.floor(COVERAGE_MIN * 100 + 0.5)),
  }
end

-- Every measured figure of one region, one per line (UI tooltip).
function M.metrics_text(r)
  local lines = {
    ("S/M 能量：%s dB"):format(fmt_db(r.side_db)),
    ("S/M 峰值：%s dB"):format(fmt_db(r.side_peak_db)),
    ("相关度：%s"):format(r.corr and ("%.3f"):format(r.corr) or "-"),
    ("L/R 电平差：%s dB"):format(fmt_db(r.balance_db)),
    ("峰值：%s dBFS"):format(fmt_db(r.peak_db)),
  }
  if r.coverage_ratio then lines[#lines + 1] = ("覆盖率：%.1f%%"):format(100 * r.coverage_ratio) end
  return table.concat(lines, "\n")
end

function M.report(plan, info)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add(("%s %s：%d 个 Region"):format(M.SCRIPT_NAME, M.VERSION, #plan.targets))
  add("判定规则：" .. table.concat(M.rules_text(), "；"))
  add("")
  add(("%-4s %-28s %-8s %-6s %8s %8s %7s %8s  %s")
    :format("#", "Region", "判定", "导出", "S/M dB", "S峰 dB", "相关度", "L/R dB", "备注"))
  for _, r in ipairs(plan.targets) do
    local ch = M.export_channels(r) == 1 and "单声道" or "立体声"
    if r.override then ch = ch .. "*" end
    add(("%-4d %-28s %-8s %-6s %8s %8s %7s %8s  %s"):format(
      r.number, r.name, LABEL[r.kind], ch, fmt_db(r.side_db), fmt_db(r.side_peak_db),
      r.corr and ("%.3f"):format(r.corr) or "-", fmt_db(r.balance_db), note_for(r)))
  end
  local s = M.summarize(plan.targets)
  add("")
  add(("共 %d 个：导单声道 %d，导立体声 %d%s"):format(s.total, #s.mono, #s.rest,
    s.overridden > 0 and ("（其中 %d 个手动指定，标 *）"):format(s.overridden) or ""))
  if info then
    for _, w in ipairs(M.run_warnings(info)) do add("（" .. w .. "）") end
  end
  return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Undo grouping: every blocking step folds its project changes into one point
--------------------------------------------------------------------------------
local function with_undo(fn, ...)
  reaper.Undo_BeginBlock2(0)
  local res = table.pack(xpcall(fn, M.error_handler, ...))
  reaper.Undo_EndBlock2(0, M.SCRIPT_NAME, -1)
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

-- Identifies the analysed regions: if any of this changes, results are stale.
function M.signature(plan)
  local parts = { ("%.6f"):format(plan.tail_sec) }
  for _, r in ipairs(plan.targets) do
    parts[#parts + 1] = ("%s@%.6f-%.6f"):format(r.guid or r.number, r.start, r.stop)
  end
  return table.concat(parts, "|")
end

--------------------------------------------------------------------------------
-- Analysis: preflight + dry run + classification, in one blocking call
--------------------------------------------------------------------------------
-- Returns { plan, info, sig, gate_dbfs, srate, seconds }. Render settings and
-- region selection are restored before it returns, also after an error.
-- Cleanup after a blocking step: every part runs even if an earlier one fails.
-- Returns the leftovers (see restore) plus anything that could not be undone.
local function cleanup(state)
  local problems = {}
  if state.meter then
    local ok, err = pcall(remove_meter, state.meter)
    if not ok then problems[#problems + 1] = { what = "测量插件", err = "没能从 Master 上移除：" .. tostring(err) } end
    state.meter = nil
  end
  pcall(reaper.gmem_write, G.TOKEN, 0)
  if state.snap then
    local ok, res = pcall(restore, state.snap)
    if not ok then
      problems[#problems + 1] = { what = "渲染设置", err = tostring(res) }
    else
      for _, p in ipairs(res) do problems[#problems + 1] = p end
    end
    state.snap = nil
  end
  return problems
end

-- Error for leftovers, attached to (or replacing) the step's own error.
local function with_leftovers(err, problems)
  if #problems == 0 then return err end
  local lines = M.describe_leftovers(problems)
  local extra = "以下项目没能恢复，请打开渲染窗口检查：\n" .. table.concat(lines, "\n")
  if err then
    err.leftovers = problems
    err.detail = (err.detail and (err.detail .. "\n\n") or "") .. extra
    err.msg = err.msg .. "\n\n" .. extra
    return err
  end
  return { msg = "渲染设置没能完全恢复。\n\n" .. extra, short = "渲染设置没能完全恢复。",
           detail = extra, leftovers = problems }
end

-- Returns { plan, info, sig, gate_dbfs, srate, seconds, warnings }. Render
-- settings and region selection are restored before it returns, also after
-- an error; any leftover is raised as an error.
function M.analyze()
  local state = {}
  local t0 = reaper.time_precise()
  local ok, res = xpcall(function()
    return with_undo(function()
      local plan = preflight()
      state.snap = snapshot()
      local info = measure(plan, state)
      for _, r in ipairs(plan.targets) do classify(r) end
      return { plan = plan, info = info, sig = M.signature(plan), gate_dbfs = CONFIG.gate_dbfs,
               srate = info.srate, warnings = M.run_warnings(info) }
    end)
  end, M.error_handler)
  local problems = cleanup(state)
  if not ok then error(with_leftovers(res, problems), 0) end
  if #problems > 0 then error(with_leftovers(nil, problems), 0) end
  res.seconds = reaper.time_precise() - t0
  return res
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------
-- Windows paths: case-insensitive, either slash.
local function path_key(p)
  local k = p:gsub("/", "\\"):lower()
  return k
end
M.path_key = path_key

-- Compares the files of a single render with the user's settings (`original`)
-- against what the passes will write. Pure: works on name lists only.
--   collisions: target paths that occur more than once across all passes
--     (within one pass as well), so one file would overwrite another
--   added / missing: names that differ from a single render
--   count_mismatch: passes whose file count differs from their region count
--     (RENDER_TARGETS of a pass could not be matched to its regions)
function M.compare_names(original, passes)
  local orig, seen, out = {}, {}, { collisions = {}, added = {}, missing = {}, count_mismatch = {} }
  for _, f in ipairs(original) do orig[path_key(f)] = true end
  local all = {}
  for pi, p in ipairs(passes) do
    for _, f in ipairs(p.files) do
      local k = path_key(f)
      if seen[k] then
        if seen[k] ~= "dup" then out.collisions[#out.collisions + 1] = f end
        seen[k] = "dup"
      else
        seen[k] = pi
      end
      all[k] = true
      if not orig[k] then out.added[#out.added + 1] = f end
    end
    if p.regions and #p.files ~= #p.regions then out.count_mismatch[#out.count_mismatch + 1] = pi end
  end
  for _, f in ipairs(original) do
    if not all[path_key(f)] then out.missing[#out.missing + 1] = f end
  end
  out.unique = #out.collisions == 0
  out.same = #out.added == 0 and #out.missing == 0 and out.unique
  return out
end

-- Pure: why an export plan must not run (nil if it may).
function M.export_blocker(names)
  if #names.collisions > 0 then
    return ("%d 个目标文件路径重复：两遍导出（或同一遍里）会写同一个文件，后写的会覆盖先写的。"
      .. "请改文件名设置（例如用 $region 代替 $filenumber）后重新导出。"):format(#names.collisions)
  end
  if #names.count_mismatch > 0 then
    return "预演导出时，某一遍要写的文件数和 Region 数对不上，无法确认每个 Region 都会导出。请检查文件名设置。"
  end
  return nil
end

-- Wildcards whose value depends on how many files one render writes.
local COUNTING_WILDCARDS = { "$filenumber", "$filecount" }

function M.counting_wildcards(pattern)
  pattern = (pattern or ""):lower()
  local found = {}
  for _, w in ipairs(COUNTING_WILDCARDS) do
    if pattern:find(w, 1, true) then found[#found + 1] = w end
  end
  return found
end

-- Re-checks the project, matches it to the analysis and works out every file
-- each pass will write (`blocker` is set when the paths are not unique).
-- Leaves the project's settings as they were.
-- `analysis` is the M.analyze() result (with any r.override set by the UI).
function M.plan_export(analysis)
  return with_undo(function()
    local plan = preflight()
    if M.signature(plan) ~= analysis.sig then
      fail("分析之后 Region 或渲染范围有改动，请重新分析。")
    end
    -- the fresh plan has the current settings; take verdicts from the analysis
    for i, r in ipairs(plan.targets) do
      local a = analysis.plan.targets[i]
      r.kind, r.override, r.m = a.kind, a.override, a.m
    end
    local s = M.summarize(plan.targets)
    local state = { snap = snapshot() }
    local ok, res = xpcall(function()
      local original = render_targets()
      local passes = {}
      for _, p in ipairs({ { 1, s.mono, "单声道" }, { 2, s.rest, "立体声" } }) do
        if #p[2] > 0 then
          configure_pass(plan, p[2], p[1], false)
          passes[#passes + 1] = { channels = p[1], label = p[3], regions = p[2], files = render_targets() }
        end
      end
      return { original = original, passes = passes }
    end, M.error_handler)
    local problems = cleanup(state)
    if not ok then error(with_leftovers(res, problems), 0) end
    if #problems > 0 then error(with_leftovers(nil, problems), 0) end

    res.plan = plan
    res.summary = s
    -- every target path of both passes, checked before anything is written
    res.names = M.compare_names(res.original, res.passes)
    res.blocker = M.export_blocker(res.names)
    res.wildcards = M.counting_wildcards(proj_str("RENDER_PATTERN"))
    res.consistency = M.consistency_warnings(plan)
    res.total_files, res.existing = 0, 0
    for _, p in ipairs(res.passes) do
      for _, f in ipairs(p.files) do
        res.total_files = res.total_files + 1
        if file_exists(f) then res.existing = res.existing + 1 end
      end
    end
    res.out_dir = (res.passes[1] and res.passes[1].files[1] or ""):match("^(.*)[\\/]") or ""
    return res
  end)
end

-- JS_File_Stat and os.date share this format, so the strings compare in time order.
local STAMP_FMT = "%Y.%m.%d %H:%M:%S"

-- Splits `files` into the ones this pass wrote and the rest. A file counts as
-- written only if it exists, is not empty and was modified at or after
-- `since`; an older file with the same name (REAPER skipped it, or the render
-- was cancelled) does not. `stat(path)` returns (mtime, size) or nil.
function M.verify_files(files, since, stat)
  local written, missing = {}, {}
  for _, f in ipairs(files) do
    local mt, size = stat(f)
    if mt and mt >= since and (size or 0) > 0 then written[#written + 1] = f else missing[#missing + 1] = f end
  end
  return written, missing
end

local function stat_file(path)
  local rv, size, _, mt = reaper.JS_File_Stat(path)
  if rv ~= 0 then return nil end
  return mt, size
end

-- Pure: the outcome of one pass from its file check.
--   "ok"      every file written
--   "partial" some written, some not (skipped, cancelled half way, error)
--   "failed"  nothing written: counts as a failure, never as success
function M.pass_status(written, missing)
  if #missing == 0 and #written > 0 then return "ok" end
  if #written == 0 then return "failed" end
  return "partial"
end

-- One job renders the passes one call at a time so the UI can draw between them.
function M.export_new(xp)
  return { xp = xp, next = 1, results = {}, written = 0, missing = 0, stopped = nil, leftovers = {} }
end

function M.export_remaining(job)
  if job.stopped then return 0 end
  return #job.xp.passes - job.next + 1
end

-- Passes that never ran, for the final report.
function M.export_skipped(job)
  local list = {}
  for i = job.next, #job.xp.passes do list[#list + 1] = job.xp.passes[i] end
  return list
end

-- Called when the user cancels between passes: no further pass will run.
function M.export_cancel(job)
  if not job.stopped then job.stopped = "cancelled" end
end

-- Pure: the final verdict of a job.
--   "ok" all passes ok · "cancelled" stopped by the user · "failed" a pass wrote
--   nothing or raised · "partial" something written, not everything.
function M.export_outcome(job)
  local any_ok, any_bad = false, false
  for _, r in ipairs(job.results) do
    if r.status == "ok" then any_ok = true else any_bad = true end
    if r.status == "partial" then any_ok = true end
  end
  if job.stopped == "failed" then return "failed" end
  if job.stopped == "cancelled" then return "cancelled" end
  if #job.results < #job.xp.passes then return "partial" end
  if not any_bad then return "ok" end
  if job.written == 0 then return "failed" end
  return "partial"
end

-- Renders the next pass (blocks REAPER until it finishes) and restores the
-- project's settings straight after, so stopping between passes is always
-- safe. A pass that wrote no file stops the job: the next pass would most
-- likely fail the same way. Leftovers from the restore stop it as well.
function M.export_step(job, stat)
  if job.stopped then return nil end
  local p = job.xp.passes[job.next]
  if not p then return nil end
  local state = { snap = snapshot() }
  local since = os.date(STAMP_FMT)
  local ok, err = xpcall(function()
    with_undo(function()
      configure_pass(job.xp.plan, p.regions, p.channels, false)
      reaper.Main_OnCommand(ACTION_RENDER, 0)  -- blocks until the render has finished
    end)
  end, M.error_handler)
  local problems = cleanup(state)
  for _, pr in ipairs(problems) do job.leftovers[#job.leftovers + 1] = pr end

  local written, missing = M.verify_files(p.files, since, stat or stat_file)
  local res = { pass = p, written = written, missing = missing, status = M.pass_status(written, missing) }
  if not ok then res.status, res.error = "failed", err end
  job.results[#job.results + 1] = res
  job.written = job.written + #written
  job.missing = job.missing + #missing
  job.next = job.next + 1
  if res.status == "failed" or #problems > 0 then job.stopped = "failed" end
  if not ok then error(with_leftovers(err, problems), 0) end
  return res
end

return M

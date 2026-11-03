-- @description MC ChannelFit
-- @version 1.0
-- @author MC Scripts
-- @provides
--   ChannelFit_core.lua
--   MC_ChannelFit_Meter.jsfx
-- @about
--   Batch-exports regions with the channel count each file actually needs.
--   A dry run measures the master mix of every region. Regions whose left and
--   right channels carry the same signal (dual mono) are rendered as mono
--   files; all others keep the project's stereo setting. Every region can be
--   overridden by hand. Format, file names and output folder come from the
--   project's render settings, which are restored afterwards.
--
--   Supported: Source = Master mix (or a region render matrix that only uses
--   the Master column), Bounds = All project regions / Selected regions,
--   Channels = Stereo.
--
--   ----
--
--   按 Region 批量导出时，按实际内容决定每个文件用单声道还是立体声。先 Dry run
--   测量每个 Region 的 Master 混音：左右声道内容相同（双单声道）的导成单声道，
--   其余保持工程原来的立体声设置，每个 Region 都可以手动改。格式、文件名、输出
--   目录沿用工程现有的渲染设置，导完恢复原样。
--
--   支持：渲染源为 Master mix（或只勾了 Master 列的 Region 渲染矩阵），渲染范围为
--   所有 Region 或选中的 Region，声道为立体声。
--
--   Requires REAPER 7.62+, ReaImGui 0.10+ and js_ReaScriptAPI. Full guide:
--   README.md in the ChannelFit folder.
--   需要 REAPER 7.62 以上、ReaImGui 0.10 以上和 js_ReaScriptAPI。完整说明见 ChannelFit 目录下的 README.md。

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local EXT = "MC_ChannelFit"
local IMGUI_API = "0.10"

--------------------------------------------------------------------------------
-- Dependencies: explain what is missing instead of crashing
--------------------------------------------------------------------------------
local function missing_dependency(title, lines)
  reaper.ShowMessageBox(table.concat(lines, "\n"), "MC ChannelFit：" .. title, 0)
end

local REAPACK_STEPS = {
  "安装方法：",
  "  1. 菜单 Extensions > ReaPack > Browse packages…",
  "     （没有 ReaPack 菜单的话，先到 reapack.com 下载 reaper_reapack-x64.dll，",
  "      放进 REAPER 资源目录的 UserPlugins 文件夹，重启 REAPER）",
  "  2. 搜索 %s，右键 > Install，再点 Apply",
  "  3. 重启 REAPER 后重新运行 ChannelFit",
}

local function reapack_steps(package)
  local out = {}
  for i, l in ipairs(REAPACK_STEPS) do out[i] = l:format(package) end
  return table.concat(out, "\n")
end

if not reaper.ImGui_GetBuiltinPath then
  missing_dependency("需要 ReaImGui", {
    "ChannelFit 的界面需要 ReaImGui 扩展（" .. IMGUI_API .. " 或更新版本），当前没有安装。", "",
    reapack_steps("ReaImGui: ReaScript binding for Dear ImGui"),
  })
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ok_imgui, ImGui = pcall(function() return require("imgui")(IMGUI_API) end)
if not ok_imgui then
  local _, ver = reaper.ImGui_GetVersion()
  missing_dependency("ReaImGui 版本太旧", {
    ("已安装的 ReaImGui 是 %s，ChannelFit 需要 %s 或更新版本。"):format(ver or "?", IMGUI_API), "",
    "用 ReaPack 更新：Extensions > ReaPack > Synchronize packages，然后重启 REAPER。", "",
    "错误信息：" .. tostring(ImGui),
  })
  return
end

if not reaper.JS_Window_FindTop then
  missing_dependency("需要 js_ReaScriptAPI", {
    "ChannelFit 需要 js_ReaScriptAPI 扩展（用来关闭 Dry run 结果窗口、检查导出文件）。", "",
    reapack_steps("js_ReaScriptAPI"),
  })
  return
end

if not reaper.GetRegionOrMarker then
  missing_dependency("REAPER 版本太旧", { "ChannelFit 需要 REAPER 7.62 或更新版本。" })
  return
end

local ok_core, core = pcall(dofile, SCRIPT_DIR .. "ChannelFit_core.lua")
if not ok_core then
  missing_dependency("文件缺失", {
    "找不到或无法加载 ChannelFit_core.lua，它应和本脚本放在同一文件夹：",
    SCRIPT_DIR, "", tostring(core),
  })
  return
end

--------------------------------------------------------------------------------
-- Theme: dark neutral greys, one cool accent (blue), status colours
--------------------------------------------------------------------------------
local function rgba(hex, a) return (hex << 8) | math.floor((a or 1) * 255 + 0.5) end
local function alpha(col, a) return (col & 0xFFFFFF00) | math.floor(a * 255 + 0.5) end

local C = {
  -- surfaces, darkest to lightest
  bg       = rgba(0x14161B), card     = rgba(0x1B1E25), frame    = rgba(0x242832),
  raised   = rgba(0x2A2F39), hover    = rgba(0x323844), active   = rgba(0x3A414E),
  border   = rgba(0x2B3039), border2  = rgba(0x3C4350),
  -- text: primary / secondary / tertiary
  text     = rgba(0xE7EAEF), text2    = rgba(0xA9B0BC), faint    = rgba(0x747B89),
  -- accent and states
  accent   = rgba(0x3D9EF5), accent_h = rgba(0x62B3F8), accent_a = rgba(0x2C85D6),
  accent_t = rgba(0x82C3FA),
  ok       = rgba(0x4CC38A), warn     = rgba(0xE9AA3B), bad      = rgba(0xEF5B5E),
  white    = rgba(0xFFFFFF), clear    = 0,
}
-- verdict badge colours
local KIND_COLOR = {
  mono = rgba(0x3D9EF5), stereo = rgba(0xA387F3), one_side = rgba(0xE9AA3B),
  silent = rgba(0x7B8494), unmeasured = rgba(0xEF5B5E),
}

-- spacing (px) and type sizes; all layout below derives from these
local PAD_X, PAD_Y = 16, 14          -- window and card padding
local GAP = 10                       -- between cards
local FRAME_PAD_X, FRAME_PAD_Y = 10, 6
local BTN_H = 34                     -- main buttons (分析 / 导出)
local CARD_BTN_H = 32                -- 打开渲染设置
local FS_TITLE, FS_BODY, FS_SMALL = 15, 14, 12.5

local THEME_COLORS = {
  { ImGui.Col_WindowBg, C.bg }, { ImGui.Col_ChildBg, C.card }, { ImGui.Col_PopupBg, C.card },
  { ImGui.Col_Border, C.border }, { ImGui.Col_Text, C.text }, { ImGui.Col_TextDisabled, C.faint },
  { ImGui.Col_TitleBg, C.bg }, { ImGui.Col_TitleBgActive, rgba(0x1E222A) }, { ImGui.Col_TitleBgCollapsed, C.bg },
  { ImGui.Col_FrameBg, C.frame }, { ImGui.Col_FrameBgHovered, C.raised }, { ImGui.Col_FrameBgActive, C.hover },
  { ImGui.Col_Button, C.raised }, { ImGui.Col_ButtonHovered, C.hover }, { ImGui.Col_ButtonActive, C.active },
  { ImGui.Col_Header, alpha(C.accent, 0.20) }, { ImGui.Col_HeaderHovered, alpha(C.accent, 0.28) },
  { ImGui.Col_HeaderActive, alpha(C.accent, 0.36) },
  { ImGui.Col_SliderGrab, C.accent }, { ImGui.Col_SliderGrabActive, C.accent_h },
  { ImGui.Col_CheckMark, C.accent }, { ImGui.Col_PlotHistogram, C.accent },
  { ImGui.Col_Separator, C.border }, { ImGui.Col_TableHeaderBg, rgba(0x20242C) },
  { ImGui.Col_TableBorderStrong, C.border2 }, { ImGui.Col_TableBorderLight, C.border },
  { ImGui.Col_TableRowBg, C.clear }, { ImGui.Col_TableRowBgAlt, rgba(0xFFFFFF, 0.022) },
  { ImGui.Col_ScrollbarBg, C.clear }, { ImGui.Col_ScrollbarGrab, C.border2 },
  { ImGui.Col_ScrollbarGrabHovered, C.active }, { ImGui.Col_ScrollbarGrabActive, C.text2 },
  { ImGui.Col_ResizeGrip, alpha(C.accent, 0.12) }, { ImGui.Col_ResizeGripHovered, alpha(C.accent, 0.45) },
  { ImGui.Col_ResizeGripActive, C.accent }, { ImGui.Col_ModalWindowDimBg, rgba(0x000000, 0.55) },
  { ImGui.Col_NavCursor, C.accent },
}
local THEME_VARS = {
  { ImGui.StyleVar_WindowPadding, PAD_X, PAD_Y }, { ImGui.StyleVar_FramePadding, FRAME_PAD_X, FRAME_PAD_Y },
  { ImGui.StyleVar_ItemSpacing, 8, 8 }, { ImGui.StyleVar_ItemInnerSpacing, 6, 4 },
  { ImGui.StyleVar_CellPadding, 8, 4 },
  { ImGui.StyleVar_WindowRounding, 8 }, { ImGui.StyleVar_ChildRounding, 8 },
  { ImGui.StyleVar_FrameRounding, 6 }, { ImGui.StyleVar_PopupRounding, 8 },
  { ImGui.StyleVar_GrabRounding, 6 }, { ImGui.StyleVar_ScrollbarRounding, 8 },
  { ImGui.StyleVar_GrabMinSize, 10 }, { ImGui.StyleVar_ScrollbarSize, 11 },
  { ImGui.StyleVar_WindowBorderSize, 1 }, { ImGui.StyleVar_ChildBorderSize, 1 },
  { ImGui.StyleVar_PopupBorderSize, 1 }, { ImGui.StyleVar_FrameBorderSize, 0 },
  { ImGui.StyleVar_WindowTitleAlign, 0, 0.5 }, { ImGui.StyleVar_DisabledAlpha, 0.38 },
}

local function push_theme(ctx)
  for _, c in ipairs(THEME_COLORS) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(THEME_VARS) do
    if v[3] then ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) else ImGui.PushStyleVar(ctx, v[1], v[2]) end
  end
end

local function pop_theme(ctx)
  ImGui.PopStyleVar(ctx, #THEME_VARS)
  ImGui.PopStyleColor(ctx, #THEME_COLORS)
end

-- set up in the main loop section; the widgets below only read them
local font, font_bold

--------------------------------------------------------------------------------
-- Persistent settings (ExtState)
--------------------------------------------------------------------------------
local function load_config()
  core.set_config(core.parse_config(reaper.GetExtState(EXT, "thresholds")))
end

local function save_config()
  reaper.SetExtState(EXT, "thresholds", core.serialize_config(core.CONFIG), true)
end

-- "x,y,w,h" saved on exit; nil if never saved or unreadable
local function load_geometry()
  local x, y, w, h = reaper.GetExtState(EXT, "window"):match("^(-?[%d.]+),(-?[%d.]+),([%d.]+),([%d.]+)$")
  if not x then return nil end
  return tonumber(x), tonumber(y), math.max(760, tonumber(w)), math.max(540, tonumber(h))
end

local function save_geometry(x, y, w, h)
  reaper.SetExtState(EXT, "window", ("%d,%d,%d,%d"):format(x, y, w, h), true)
end

--------------------------------------------------------------------------------
-- App state
--------------------------------------------------------------------------------
-- phase: "idle" | "analyze_wait" | "analyze" | "confirm" | "export_wait" |
--        "export" | "done"
-- "*_wait" phases draw one frame with the busy overlay before the blocking
-- REAPER call, so the window shows what is happening while REAPER is frozen.
local app = {
  phase = "idle",
  status = nil,         -- core.check_settings() result
  status_t = 0,         -- time of the last check
  analysis = nil,       -- core.analyze() result
  stale = false,        -- region layout changed since the analysis
  rejudge = false,      -- thresholds changed: classification differs from the dry run
  job = nil,            -- export job
  xp = nil,             -- export plan
  cancel = false,
  log = {},             -- { kind = "ok" | "warn" | "err", text }
  log_scroll = false,   -- scroll the activity list to its newest line
  error = nil,          -- { short, detail, trace } for the error popup
  open_error = false,
  open_confirm = false,
  filter = 0,           -- table filter: 0 all, 1 mono, 2 stereo, 3 attention
  -- render window watch: set while REAPER's render window is open
  dialog = nil,         -- { before = fingerprint, t = last check } or nil
  dialog_open_pending = false,  -- open it at the start of the next frame
  leftovers = nil,      -- lines for settings that could not be restored
  confirm_ack = false,  -- user ticked "I have read the warnings" in the export dialog
  -- off by default: only then does anything go to the ReaScript console
  debug = reaper.GetExtState(EXT, "debug_console") == "1",
}

local CHECK_INTERVAL = 1.0     -- seconds between automatic settings checks
local DIALOG_INTERVAL = 0.25   -- seconds between render-window checks while it is open
local LOG_LINES = 4            -- visible lines of the activity list before it scrolls

local function log(kind, text)
  app.log[#app.log + 1] = { kind = kind, text = text }
  app.log_scroll = true
end

-- The only path to the ReaScript console, and only with the debug option on.
local function console(text)
  if app.debug then reaper.ShowConsoleMsg(text) end
end

local function set_debug(on)
  app.debug = on and true or false
  reaper.SetExtState(EXT, "debug_console", app.debug and "1" or "0", true)
end

local function show_error(e)
  app.error = { short = e.short or e.msg, detail = e.detail, trace = e.trace }
  app.open_error = true
  if e.trace then console(("%s\n%s\n"):format(e.msg, e.trace)) end
end

local function refresh_status()
  local ok, st = xpcall(core.check_settings, core.error_handler)
  if ok then
    app.status = st
  else
    app.status = { ok = false, rows = {}, error = st.short or st.msg, detail = st.detail }
  end
  app.status_t = reaper.time_precise()
  -- results only stay usable while the analysed regions are unchanged
  if app.analysis then
    app.stale = not (app.status.plan and core.signature(app.status.plan) == app.analysis.sig)
  end
end

local function reclassify()
  if not app.analysis then return end
  for _, r in ipairs(app.analysis.plan.targets) do core.classify(r) end
  -- the gate is applied inside the meter, so only a new dry run reflects it
  app.rejudge = math.abs(core.CONFIG.gate_dbfs - app.analysis.gate_dbfs) > 1e-9
end

--------------------------------------------------------------------------------
-- Render window watch
--------------------------------------------------------------------------------
-- Starts watching with the settings as they were before the window opened.
local function watch_dialog(before)
  app.dialog = { before = before or core.render_fingerprint(), t = reaper.time_precise() }
end

-- The window has closed: read the saved settings and say what changed.
local function dialog_closed()
  local kind, text = core.render_dialog_closed_message(app.dialog.before, core.render_fingerprint())
  app.dialog = nil
  log(kind, text)
  refresh_status()
end

-- Cheap check every DIALOG_INTERVAL; the full preflight only runs on close.
local function poll_dialog()
  local now = reaper.time_precise()
  if app.dialog then
    if now - app.dialog.t < DIALOG_INTERVAL then return end
    app.dialog.t = now
    if not core.render_dialog_open() then dialog_closed() end
  elseif core.render_dialog_open() then
    -- opened some other way (menu, shortcut): watch it as well
    watch_dialog()
    refresh_status()
  end
end

-- Runs in the frame after the click, so the hint is on screen first.
local function open_render_dialog()
  local before = core.render_fingerprint()
  local ok, res = xpcall(core.open_render_dialog, core.error_handler)
  if not ok then
    show_error(res)
    return
  end
  if res == "opened" and not core.render_dialog_open() then
    -- the action only returned after the window closed (modal), or it never opened
    app.dialog = { before = before, t = 0 }
    dialog_closed()
    return
  end
  watch_dialog(before)
  refresh_status()
end

local function apply_fix(key)
  local ok, res = xpcall(core.apply_fix, core.error_handler, key)
  if not ok then
    show_error(res)
  elseif res then
    log("ok", ("已%s（可用 Ctrl+Z 撤销）。"):format(res))
  end
  refresh_status()
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------
local function tooltip(ctx, text)
  if text and text ~= "" and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetTooltip(ctx, text)
  end
end

local function text_col(ctx, text, col)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, col)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx)
end

local function small_text(ctx, text, col)
  ImGui.PushFont(ctx, font, FS_SMALL)
  text_col(ctx, text, col or C.faint)
  ImGui.PopFont(ctx)
end

-- Wrapped text in one colour; wraps at the right edge of the current region.
local function wrapped(ctx, text, col)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, col)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopTextWrapPos(ctx)
  ImGui.PopStyleColor(ctx)
end

local function card_title(ctx, text)
  ImGui.PushFont(ctx, font_bold, FS_TITLE)
  text_col(ctx, text, C.text)
  ImGui.PopFont(ctx)
end

-- Button styles: fill, hover, active, text, border (nil = no border).
local BTN = {
  primary   = { C.accent_a, C.accent_h, C.accent, C.white },
  secondary = { C.raised, C.hover, C.active, C.text, C.border2 },
  ghost     = { C.clear, C.raised, C.hover, C.text2 },
  outline   = { alpha(C.accent, 0.10), alpha(C.accent, 0.20), alpha(C.accent, 0.28), C.accent_t,
                alpha(C.accent, 0.60) },
  seg_on    = { alpha(C.accent, 0.22), alpha(C.accent, 0.30), alpha(C.accent, 0.36), C.accent_t },
  seg_off   = { C.clear, C.raised, C.hover, C.text2 },
  danger    = { alpha(C.bad, 0.16), alpha(C.bad, 0.28), alpha(C.bad, 0.38), rgba(0xFFB8B9), alpha(C.bad, 0.55) },
}

local function button_width(ctx, label)
  return ImGui.CalcTextSize(ctx, (label:gsub("##.*$", ""))) + 2 * FRAME_PAD_X
end

-- One button in a named style; disabled buttons are dimmed by DisabledAlpha.
local function button(ctx, label, style, w, h, enabled)
  if enabled == nil then enabled = true end
  local s = BTN[style]
  ImGui.BeginDisabled(ctx, not enabled)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, s[1])
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, s[2])
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, s[3])
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, s[4])
  if s[5] then
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, s[5])
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  end
  local pressed = ImGui.Button(ctx, label, w or 0, h or 0)
  if s[5] then
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx, 5)
  else
    ImGui.PopStyleColor(ctx, 4)
  end
  ImGui.EndDisabled(ctx)
  return pressed and enabled
end

-- Rounded pill with centred text, vertically centred in a box of height `box_h`.
local function badge(ctx, text, col, width, box_h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.PushFont(ctx, font, FS_SMALL)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local w = math.max(width or 0, tw + 20)
  local h = th + 6
  local by = y + math.max(0, ((box_h or h) - h) / 2)
  ImGui.DrawList_AddRectFilled(dl, x, by, x + w, by + h, alpha(col, 0.15), h / 2)
  ImGui.DrawList_AddRect(dl, x, by, x + w, by + h, alpha(col, 0.45), h / 2)
  ImGui.DrawList_AddText(dl, x + (w - tw) / 2, by + 3, col, text)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, w, box_h or h)
end

-- Status dot with a soft halo, centred in a box of height `box_h`.
local function dot(ctx, col, box_h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = box_h or ImGui.GetTextLineHeight(ctx)
  ImGui.DrawList_AddCircleFilled(dl, x + 6, y + h / 2, 6, alpha(col, 0.18))
  ImGui.DrawList_AddCircleFilled(dl, x + 6, y + h / 2, 3.5, col)
  ImGui.Dummy(ctx, 14, h)
end

-- Upward-right arrow ("open in a new window"), 9 px, drawn at x, y.
local function draw_open_icon(ctx, x, y, col)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddLine(dl, x, y + 9, x + 9, y, col, 1.6)
  ImGui.DrawList_AddLine(dl, x + 3, y, x + 9, y, col, 1.6)
  ImGui.DrawList_AddLine(dl, x + 9, y, x + 9, y + 6, col, 1.6)
end

-- Number of wrapped lines `text` takes at `width` (estimate, used for sizing).
local function line_count(ctx, text, width)
  local n = 0
  for seg in (text .. "\n"):gmatch("([^\n]*)\n") do
    local tw = ImGui.CalcTextSize(ctx, seg)
    n = n + math.max(1, math.ceil(tw / math.max(1, width)))
  end
  return n
end

local function busy() return app.phase ~= "idle" and app.phase ~= "done" end

--------------------------------------------------------------------------------
-- Card: render settings status
--------------------------------------------------------------------------------
local STATE_PILL = {
  ok = { "就绪", C.ok }, bad = { "需要调整", C.bad },
  waiting = { "等待渲染窗口", C.accent }, unknown = { "检测中", C.faint },
}

local function status_state()
  local st = app.status
  if not st then return "unknown" end
  if st.waiting then return "waiting" end
  return st.ok and "ok" or "bad"
end

-- The line under the three rows: what will be exported, or what is wrong.
local function status_message()
  local st = app.status
  if not st then return "正在读取渲染设置……", C.faint end
  if st.ok then
    local p = st.plan
    local tail = p.tail_on and ("，含渲染尾巴 %d ms"):format(math.floor(p.tail_sec * 1000 + 0.5)) or ""
    return ("将导出 %d 个 Region%s。"):format(#p.targets, tail), C.text2
  end
  return st.error or "无法读取渲染设置", st.waiting and C.accent_t or C.bad
end

local function status_height(ctx, w)
  local fh, line = ImGui.GetFrameHeight(ctx), ImGui.GetTextLineHeightWithSpacing(ctx)
  local rows = app.status and #app.status.rows or 3
  local msg = status_message()
  return 2 * PAD_Y + fh + 17 + rows * (fh + 8) + line_count(ctx, msg, w - 2 * PAD_X) * line + 8 + CARD_BTN_H + 4
end

-- Full-width action at the foot of the card. Outlined in accent when the
-- settings are usable, filled (the most prominent button on screen) when
-- they need changing, since 分析 / 导出 are disabled then anyway.
local function open_render_button(ctx, w, state)
  local waiting = state == "waiting"
  local label = waiting and "切到渲染窗口" or "打开渲染设置"
  local style = state == "bad" and "primary" or "outline"
  local tw = ImGui.CalcTextSize(ctx, label)
  local icon_w, icon_gap = 9, 8
  -- centre text + icon together: shift the text left by half the icon
  local free = w - 2 * FRAME_PAD_X - tw
  local align = free > 0 and math.max(0, math.min(1, ((free - icon_w - icon_gap) / 2) / free)) or 0.5
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ButtonTextAlign, align, 0.5)
  local enabled = not busy() and not app.dialog_open_pending
  local pressed = button(ctx, label .. "##open", style, w, CARD_BTN_H, enabled)
  ImGui.PopStyleVar(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local text_x = x1 + FRAME_PAD_X + align * free
  local col = BTN[style][4]
  if not enabled then col = alpha(col, 0.38) end
  draw_open_icon(ctx, text_x + tw + icon_gap, y1 + (CARD_BTN_H - icon_w) / 2, col)
  tooltip(ctx, waiting and "把已经打开的 REAPER 渲染窗口切到前面。"
    or "打开 REAPER 的渲染窗口（File > Render）。\n设置好后点「Save settings」并关闭窗口，这里会自动重新检测。")
  return pressed
end

local function draw_status(ctx, w, h)
  if not ImGui.BeginChild(ctx, "##status", w, h, ImGui.ChildFlags_Borders) then return end
  local st = app.status
  local state = status_state()
  local waiting = state == "waiting"
  local inner = w - 2 * PAD_X
  local fh = ImGui.GetFrameHeight(ctx)

  -- header: title · state pill ............ 重新检测
  ImGui.AlignTextToFramePadding(ctx)
  card_title(ctx, "渲染设置")
  ImGui.SameLine(ctx, 0, 10)
  local pill = STATE_PILL[state]
  badge(ctx, pill[1], pill[2], 0, fh)
  local rw = button_width(ctx, "重新检测")
  ImGui.SameLine(ctx, PAD_X + inner - rw)
  if button(ctx, "重新检测", "ghost", rw, 0, not busy() and not waiting) then refresh_status() end
  tooltip(ctx, "重新读取工程里已保存的渲染设置。每秒也会自动检测一次。")
  ImGui.Separator(ctx)

  -- one row per checked setting: dot · label · value · fix
  for _, r in ipairs(st and st.rows or {}) do
    ImGui.PushID(ctx, r.key)
    dot(ctx, waiting and C.faint or (r.ok and C.ok or C.bad), fh)
    ImGui.SameLine(ctx, 0, 6)
    ImGui.AlignTextToFramePadding(ctx)
    text_col(ctx, r.label, C.text2)
    ImGui.SameLine(ctx, PAD_X + 96)
    ImGui.AlignTextToFramePadding(ctx)
    text_col(ctx, r.value, (waiting or r.ok) and C.text or C.bad)
    if not waiting and r.fix then
      ImGui.SameLine(ctx, 0, 10)
      if button(ctx, r.fix, "outline", 0, 0, not busy()) then apply_fix(r.key) end
      tooltip(ctx, (r.hint or "") .. "\n\n点击会修改工程的渲染设置，可以用 Ctrl+Z 撤销。")
    end
    ImGui.PopID(ctx)
  end

  local msg, msg_col = status_message()
  wrapped(ctx, msg, msg_col)
  if st and st.detail then tooltip(ctx, st.detail) end

  -- the action sits at the foot of the card, whatever the card height
  ImGui.SetCursorPosY(ctx, h - PAD_Y - CARD_BTN_H)
  if open_render_button(ctx, inner, state) then app.dialog_open_pending = true end
  ImGui.EndChild(ctx)
end

--------------------------------------------------------------------------------
-- Card: thresholds
--------------------------------------------------------------------------------
local SLIDERS = {
  { key = "mono_db", label = "S/M 能量阈值", fmt = "%.0f dB",
    tip = "侧信号（L−R）能量比中信号（L+R）低这么多以上，才可能判成双单声道。\n越低越严格。默认 −60 dB。" },
  { key = "mono_peak_db", label = "S/M 峰值阈值", fmt = "%.0f dB",
    tip = "侧信号峰值比中信号峰值低这么多以上，才判成双单声道。\n用来拦住整体很像单声道、但有一小段立体声的文件。默认 −30 dB，设成 0 等于关闭。" },
  { key = "one_side_db", label = "单侧门限", fmt = "%.0f dB",
    tip = "弱的一侧比强的一侧低这么多以上，判成单侧有声（只有 L 或只有 R）。默认 −60 dB。" },
  { key = "gate_dbfs", label = "静音门限", fmt = "%.0f dBFS",
    tip = "10 ms 窗口里较响的声道低于这个电平就不参与统计，避免底噪影响判定。\n修改后要重新分析才生效。默认 −70 dBFS。" },
}

local function thresholds_footer()
  if app.rejudge then return "静音门限改过了：重新分析后才按新门限统计。", C.warn end
  return table.concat(core.rules_text(), "；"), C.faint
end

local function thresholds_height(ctx, w)
  local fh, line = ImGui.GetFrameHeight(ctx), ImGui.GetTextLineHeightWithSpacing(ctx)
  local cell = line + fh + 8
  local text = thresholds_footer()
  return 2 * PAD_Y + fh + 17 + 2 * cell + 4 + line_count(ctx, text, w - 2 * PAD_X) * line + 4
end

local function draw_thresholds(ctx, w, h)
  if not ImGui.BeginChild(ctx, "##thresholds", w, h, ImGui.ChildFlags_Borders) then return end
  local inner = w - 2 * PAD_X

  ImGui.AlignTextToFramePadding(ctx)
  card_title(ctx, "判定阈值")
  local rw = button_width(ctx, "恢复默认")
  ImGui.SameLine(ctx, PAD_X + inner - rw)
  local is_default = core.config_is_default(core.CONFIG)
  if button(ctx, "恢复默认", "ghost", rw, 0, not busy() and not is_default) then
    core.set_config(core.DEFAULTS)
    save_config()
    reclassify()
  end
  ImGui.Separator(ctx)

  -- 2 x 2 grid, label above each slider so nothing collides when narrow
  local col_gap = 16
  local col_w = (inner - col_gap) / 2
  local changed_any = false
  ImGui.BeginDisabled(ctx, busy())
  for i, s in ipairs(SLIDERS) do
    if i % 2 == 0 then ImGui.SameLine(ctx, PAD_X + col_w + col_gap) end
    ImGui.BeginGroup(ctx)
    small_text(ctx, s.label, C.text2)
    tooltip(ctx, s.tip)
    ImGui.SetNextItemWidth(ctx, col_w)
    local lim = core.LIMITS[s.key]
    local changed, v = ImGui.SliderDouble(ctx, "##" .. s.key, core.CONFIG[s.key], lim[1], lim[2],
      s.fmt, ImGui.SliderFlags_AlwaysClamp)
    tooltip(ctx, s.tip .. "\n\n改动后立刻按已有的测量结果重新判定（静音门限除外）。Ctrl+点击可以直接输入数值。")
    if changed then
      core.CONFIG[s.key] = math.floor(v + 0.5)
      changed_any = true
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then save_config() end
    ImGui.EndGroup(ctx)
  end
  ImGui.EndDisabled(ctx)
  if changed_any then reclassify() end

  local text, col = thresholds_footer()
  ImGui.PushFont(ctx, font, FS_SMALL)
  wrapped(ctx, text, col)
  ImGui.PopFont(ctx)
  ImGui.EndChild(ctx)
end

--------------------------------------------------------------------------------
-- Card: results table
--------------------------------------------------------------------------------
local FILTERS = { "全部", "单声道", "立体声", "需留意" }
local CHANNEL_CHOICES = { "自动", "单声道", "立体声" }  -- override nil / 1 / 2
local WIDE_TABLE = 940  -- inner width from which the extra measurement columns show

local function needs_attention(r)
  return r.kind == "one_side" or r.kind == "unmeasured" or core.note_for(r) ~= ""
end

local function filter_counts(targets)
  local n = { #targets, 0, 0, 0 }
  for _, r in ipairs(targets) do
    if core.export_channels(r) == 1 then n[2] = n[2] + 1 else n[3] = n[3] + 1 end
    if needs_attention(r) then n[4] = n[4] + 1 end
  end
  return n
end

local function row_visible(r)
  if app.filter == 1 then return core.export_channels(r) == 1 end
  if app.filter == 2 then return core.export_channels(r) == 2 end
  if app.filter == 3 then return needs_attention(r) end
  return true
end

local function fmt_corr(r) return r.corr and ("%.3f"):format(r.corr) or "-" end

-- Columns; `wide` ones only show from WIDE_TABLE on (the row tooltip always
-- has every figure). align "r" = right-aligned numbers.
local COLUMNS = {
  { "#", 30, "r" }, { "名称", -2.0 }, { "时长", 60, "r" }, { "判定", 92 },
  { "S/M dB", 62, "r", function(r) return core.fmt_db(r.side_db) end },
  { "S峰 dB", 62, "r", function(r) return core.fmt_db(r.side_peak_db) end, wide = true },
  { "相关度", 58, "r", fmt_corr, wide = true },
  { "L/R dB", 58, "r", function(r) return core.fmt_db(r.balance_db) end, wide = true },
  { "导出声道", 124 }, { "备注", -2.6 },
}

-- Text in a table cell, vertically centred in the row, optionally right-aligned.
local function cell_text(ctx, text, col, row_h, right)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  if right then
    local avail = ImGui.GetContentRegionAvail(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, avail - tw))
  end
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + math.max(0, (row_h - th) / 2))
  text_col(ctx, text, col)
end

local function draw_channel_combo(ctx, r, row_h)
  local ch = core.export_channels(r)
  local preview = ch == 1 and "单声道" or "立体声"
  if r.override then preview = preview .. " · 手动" end
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + math.max(0, (row_h - ImGui.GetFrameHeight(ctx)) / 2))
  ImGui.SetNextItemWidth(ctx, -1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, r.override and C.accent_t or C.text)
  local open = ImGui.BeginCombo(ctx, "##ch", preview)
  ImGui.PopStyleColor(ctx)
  tooltip(ctx, r.override and "手动指定的导出声道。选「自动」恢复按判定导出。" or "按判定自动选择。可以手动改成单声道或立体声。")
  if open then
    for i, label in ipairs(CHANNEL_CHOICES) do
      local value = i == 1 and nil or (i - 1)
      local text = label
      if i == 1 then text = ("自动（%s）"):format(r.kind == "mono" and "单声道" or "立体声") end
      if ImGui.Selectable(ctx, text, r.override == value) then r.override = value end
    end
    ImGui.EndCombo(ctx)
  end
end

local function row_tooltip(r)
  local lines = {
    r.name ~= "" and r.name or "（未命名）",
    ("位置 %.3f – %.3f s · 时长 %s"):format(r.start, r.stop, core.fmt_duration(r.stop - r.start)),
    "判定：" .. core.LABEL[r.kind] .. (r.side and (r.side == "L" and "（只有左声道）" or "（只有右声道）") or ""),
    "",
    core.metrics_text(r),
  }
  local note = core.note_for(r)
  if note ~= "" then lines[#lines + 1] = "\n" .. note end
  return table.concat(lines, "\n")
end

-- Header row with right-aligned labels over the number columns.
local function table_headers(ctx, cols)
  ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
  ImGui.PushFont(ctx, font, FS_SMALL)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text2)
  for i, c in ipairs(cols) do
    ImGui.TableSetColumnIndex(ctx, i - 1)
    if c[3] == "r" then
      local tw = ImGui.CalcTextSize(ctx, c[1])
      local avail = ImGui.GetContentRegionAvail(ctx)
      ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, avail - tw))
    end
    ImGui.TableHeader(ctx, c[1])
  end
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
end

local function draw_table(ctx, a, inner)
  local cols = {}
  for _, c in ipairs(COLUMNS) do
    if not c.wide or inner >= WIDE_TABLE then cols[#cols + 1] = c end
  end
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_ScrollY
    | ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_Resizable | ImGui.TableFlags_PadOuterX
  -- separate ids keep the user's column widths per layout
  if not ImGui.BeginTable(ctx, #cols == #COLUMNS and "##table_wide" or "##table", #cols, flags) then return end
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  for _, c in ipairs(cols) do
    if c[2] < 0 then
      ImGui.TableSetupColumn(ctx, c[1], ImGui.TableColumnFlags_WidthStretch, -c[2])
    else
      ImGui.TableSetupColumn(ctx, c[1], ImGui.TableColumnFlags_WidthFixed, c[2])
    end
  end
  table_headers(ctx, cols)

  local row_h = math.floor(ImGui.GetFrameHeight(ctx) + 6)
  ImGui.BeginDisabled(ctx, busy())
  for i, r in ipairs(a.plan.targets) do
    if row_visible(r) then
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx, 0, row_h)
      for _, c in ipairs(cols) do
        ImGui.TableNextColumn(ctx)
        local name = c[1]
        if name == "#" then
          -- spans the row: hover highlight and the full-metrics tooltip
          ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, alpha(C.accent, 0.07))
          ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, alpha(C.accent, 0.12))
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.faint)
          ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 1, 0.5)
          ImGui.Selectable(ctx, tostring(r.number) .. "##row", false,
            ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowOverlap, 0, row_h)
          ImGui.PopStyleVar(ctx)
          ImGui.PopStyleColor(ctx, 3)
          tooltip(ctx, row_tooltip(r))
        elseif name == "名称" then
          cell_text(ctx, r.name ~= "" and r.name or "（未命名）", C.text, row_h)
        elseif name == "时长" then
          cell_text(ctx, core.fmt_duration(r.stop - r.start), C.text2, row_h, true)
        elseif name == "判定" then
          local label = core.LABEL[r.kind]
          if r.kind == "one_side" then label = label .. (r.side == "L" and " L" or " R") end
          badge(ctx, label, KIND_COLOR[r.kind], 84, row_h)
        elseif name == "导出声道" then
          draw_channel_combo(ctx, r, row_h)
        elseif name == "备注" then
          local note = core.note_for(r)
          local warn = r.kind == "one_side" or r.kind == "unmeasured"
          cell_text(ctx, note, warn and C.warn or C.faint, row_h)
          tooltip(ctx, note)
        else
          cell_text(ctx, c[4](r), C.text2, row_h, true)
        end
      end
      ImGui.PopID(ctx)
    end
  end
  ImGui.EndDisabled(ctx)
  ImGui.EndTable(ctx)
end

local function draw_empty(ctx, w)
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  local title, hint
  if app.status and app.status.waiting then
    title, hint = "渲染窗口已打开", "设置好后点「Save settings」并关闭窗口，再点「分析」。"
  elseif app.status and not app.status.ok then
    title, hint = "还没有分析结果", "先把上方的渲染设置调好（可以点「打开渲染设置」），再点「分析」。"
  else
    title, hint = "还没有分析结果", "点「分析」跑一遍 Dry run，测量每个 Region 的左右声道。"
  end
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + math.max(0, avail_h / 2 - 30))
  local tw = ImGui.CalcTextSize(ctx, title)
  ImGui.SetCursorPosX(ctx, math.max(PAD_X, (w - tw) / 2))
  text_col(ctx, title, C.text2)
  ImGui.PushFont(ctx, font, FS_SMALL)
  local hw = ImGui.CalcTextSize(ctx, hint)
  ImGui.SetCursorPosX(ctx, math.max(PAD_X, (w - hw) / 2))
  text_col(ctx, hint, C.faint)
  ImGui.PopFont(ctx)
end

-- "···" menu: copy the result text, and the hidden console switch.
local function draw_more_menu(ctx, a)
  if ImGui.BeginPopup(ctx, "##more_menu") then
    if ImGui.MenuItem(ctx, "复制分析结果（文本）", nil, false, a ~= nil) then
      ImGui.SetClipboardText(ctx, core.report(a.plan, a.info))
      log("ok", "分析结果已复制到剪贴板。")
    end
    ImGui.Separator(ctx)
    local pressed, v = ImGui.MenuItem(ctx, "调试：输出到 ReaScript 控制台", nil, app.debug)
    if pressed then set_debug(v) end
    ImGui.EndPopup(ctx)
  end
end

local function draw_results(ctx, w, h)
  if not ImGui.BeginChild(ctx, "##results", w, h, ImGui.ChildFlags_Borders) then return end
  local a = app.analysis
  local inner = w - 2 * PAD_X

  -- header: title · meta ........ [filters] [···]
  ImGui.AlignTextToFramePadding(ctx)
  card_title(ctx, "分析结果")
  local more_w = 34
  local right = PAD_X + inner - more_w
  if a then
    local counts = filter_counts(a.plan.targets)
    local labels, fw = {}, 0
    for i, f in ipairs(FILTERS) do
      labels[i] = ("%s %d##filter%d"):format(f, counts[i], i)
      fw = fw + button_width(ctx, labels[i]) + 2
    end
    local filters_x = right - 8 - fw
    local meta = ("%d 个 Region · Dry run %.1f s · %g kHz"):format(#a.plan.targets, a.seconds or 0,
      (a.srate or 0) / 1000)
    ImGui.SameLine(ctx, 0, 12)
    ImGui.PushFont(ctx, font, FS_SMALL)
    local mw = ImGui.CalcTextSize(ctx, meta)
    if ImGui.GetCursorPosX(ctx) + mw + 12 < filters_x then
      ImGui.AlignTextToFramePadding(ctx)
      text_col(ctx, meta, C.faint)
    end
    ImGui.PopFont(ctx)
    ImGui.SameLine(ctx, filters_x)
    for i, label in ipairs(labels) do
      if i > 1 then ImGui.SameLine(ctx, 0, 2) end
      if button(ctx, label, app.filter == i - 1 and "seg_on" or "seg_off") then app.filter = i - 1 end
    end
  end
  ImGui.SameLine(ctx, right)
  if button(ctx, "···##more", "ghost", more_w) then ImGui.OpenPopup(ctx, "##more_menu") end
  tooltip(ctx, "更多：复制分析结果、调试输出")
  draw_more_menu(ctx, a)
  ImGui.Separator(ctx)

  if a and app.stale then
    wrapped(ctx, "分析之后 Region 或渲染范围有改动，结果已过期，请重新分析。", C.warn)
  end
  if a then draw_table(ctx, a, inner) else draw_empty(ctx, w) end
  ImGui.EndChild(ctx)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------
local function can_analyze() return not busy() and app.status and app.status.ok end

local function can_export()
  return not busy() and app.analysis and not app.stale and not app.rejudge
    and app.status and app.status.ok
end

local function start_analyze()
  app.phase = "analyze_wait"
  app.log = {}
end

-- Leftovers stay on screen (red banner) until the user dismisses them.
local function note_leftovers(problems)
  if problems and #problems > 0 then app.leftovers = core.describe_leftovers(problems) end
end

-- Runs in the frame after "analyze_wait" was drawn. Everything the old
-- console report had is on screen: rules in the thresholds card, every figure
-- in the table and its row tooltips, totals in the bottom bar.
local function run_analyze()
  local old = app.analysis and app.analysis.plan.targets
  local ok, res = xpcall(core.analyze, core.error_handler)
  app.phase = "idle"
  if not ok then
    note_leftovers(res.leftovers)
    show_error(res)
    refresh_status()
    return
  end
  core.carry_overrides(old, res.plan.targets)
  app.analysis = res
  app.stale, app.rejudge = false, false
  local s = core.summarize(res.plan.targets)
  log("ok", ("分析完成：%d 个 Region，单声道 %d，立体声 %d。"):format(s.total, #s.mono, #s.rest))
  for _, w in ipairs(core.master_warnings()) do log("warn", w) end
  for _, w in ipairs(res.warnings or {}) do log("warn", w) end
  console("\n" .. core.report(res.plan, res.info) .. "\n")
  refresh_status()
end

local function start_export()
  local ok, xp = xpcall(core.plan_export, core.error_handler, app.analysis)
  if not ok then
    note_leftovers(xp.leftovers)
    show_error(xp)
    refresh_status()
    return
  end
  app.xp = xp
  app.confirm_ack = false
  app.open_confirm = true
  app.phase = "confirm"
end

local function begin_export()
  app.job = core.export_new(app.xp)
  app.cancel = false
  app.log = {}
  app.phase = "export_wait"
end

local PASS_STATUS = {
  ok = { "ok", "%s：%d 个文件已写出" },
  partial = { "warn", "%s：只写出 %d 个，另有 %d 个没有写出（被跳过、取消或渲染出错）" },
  failed = { "err", "%s：一个文件也没写出，算作失败" },
}

-- Logs the final outcome; every pass is reported as what actually happened.
local function finish_export()
  local job = app.job
  app.phase = "done"
  local outcome = core.export_outcome(job)
  local skipped = core.export_skipped(job)
  local skipped_text = ""
  if #skipped > 0 then
    local labels = {}
    for _, p in ipairs(skipped) do labels[#labels + 1] = ("%s %d 个"):format(p.label, #p.files) end
    skipped_text = "，没有导出：" .. table.concat(labels, "、")
  end
  local restored = #job.leftovers == 0 and "渲染设置已恢复。" or "部分渲染设置没能恢复，见上方红色提示。"
  if outcome == "ok" then
    log("ok", ("导出完成：共 %d 个文件。%s"):format(job.written, restored))
  elseif outcome == "cancelled" then
    log("warn", ("已取消：写出 %d 个文件%s。%s"):format(job.written, skipped_text, restored))
  elseif outcome == "partial" then
    log("warn", ("导出不完整：写出 %d 个，%d 个没写出%s。%s"):format(job.written, job.missing, skipped_text, restored))
  else
    log("err", ("导出失败：写出 %d 个文件%s。%s"):format(job.written, skipped_text, restored))
  end
  note_leftovers(job.leftovers)
  if app.debug then
    local lines = {}
    for _, l in ipairs(app.log) do lines[#lines + 1] = l.text end
    console("\n" .. core.SCRIPT_NAME .. " 导出：\n" .. table.concat(lines, "\n") .. "\n")
  end
  refresh_status()
end

-- One pass per call, so the window redraws (progress, cancel) in between.
local function run_export_step()
  local job = app.job
  local ok, res = xpcall(core.export_step, core.error_handler, job)
  if not ok then
    show_error(res)
    log("err", "导出中止：" .. (res.short or res.msg))
    finish_export()
    return
  end
  if res then
    local st = PASS_STATUS[res.status]
    log(st[1], st[2]:format(res.pass.label, #res.written, #res.missing))
  end
  if app.cancel then core.export_cancel(job) end
  if core.export_remaining(job) == 0 then
    finish_export()
  else
    app.phase = "export_wait"
  end
end

--------------------------------------------------------------------------------
-- Bottom bar: progress, activity list, counts, main buttons
--------------------------------------------------------------------------------
local function show_progress()
  return app.job and (app.phase == "export_wait" or app.phase == "export" or app.phase == "done")
end

local function log_height(ctx)
  if #app.log == 0 then return 0 end
  return math.min(#app.log, LOG_LINES) * ImGui.GetTextLineHeightWithSpacing(ctx) + 2 * 8
end

local function bottom_height(ctx)
  local h = 8 + BTN_H
  if show_progress() then h = h + 22 + 8 end
  if #app.log > 0 then h = h + log_height(ctx) + 8 end
  return h
end

local function draw_counts(ctx)
  ImGui.PushFont(ctx, font, FS_SMALL)
  local a = app.analysis
  if not a then
    text_col(ctx, "尚未分析", C.faint)
    ImGui.PopFont(ctx)
    return
  end
  local s = core.summarize(a.plan.targets)
  text_col(ctx, ("共 %d 个"):format(s.total), C.text)
  local function chip(col, text, tcol)
    ImGui.SameLine(ctx, 0, 16)
    dot(ctx, col)
    ImGui.SameLine(ctx, 0, 2)
    text_col(ctx, text, tcol or C.text2)
  end
  chip(KIND_COLOR.mono, ("单声道 %d"):format(#s.mono))
  chip(KIND_COLOR.stereo, ("立体声 %d"):format(#s.rest))
  local attention = s.kinds.one_side + s.kinds.unmeasured
  if attention > 0 then chip(C.warn, ("需留意 %d"):format(attention), C.warn) end
  if s.overridden > 0 then chip(C.accent, ("手动指定 %d"):format(s.overridden), C.accent_t) end
  ImGui.PopFont(ctx)
end

local function draw_progress(ctx, w)
  local job = app.job
  local total = #job.xp.passes
  local done = job.next - 1
  local cur = job.xp.passes[job.next]
  local overlay
  if (app.phase == "export_wait" or app.phase == "export") and cur then
    local first = cur.files[1] and cur.files[1]:match("([^\\/]+)$") or ""
    overlay = ("第 %d / %d 遍 · %s · %d 个文件 · %s"):format(job.next, total, cur.label, #cur.files, first)
  else
    overlay = ("%d / %d 遍完成"):format(done, total)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 11)
  ImGui.ProgressBar(ctx, total > 0 and done / total or 1, w, 22, overlay)
  ImGui.PopStyleVar(ctx)
end

local LOG_COLOR = { ok = C.ok, warn = C.warn, err = C.bad }

local function draw_log(ctx, w)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, rgba(0x181B21))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 8)
  if ImGui.BeginChild(ctx, "##log", w, log_height(ctx), ImGui.ChildFlags_Borders) then
    ImGui.PushFont(ctx, font, FS_SMALL)
    for _, l in ipairs(app.log) do
      local col = LOG_COLOR[l.kind] or C.text2
      dot(ctx, col)
      ImGui.SameLine(ctx, 0, 4)
      wrapped(ctx, l.text, l.kind == "ok" and C.text or col)
    end
    if app.log_scroll then
      ImGui.SetScrollHereY(ctx, 1.0)
      app.log_scroll = false
    end
    ImGui.PopFont(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
end

local function export_disabled_reason()
  if app.status and app.status.waiting then return "渲染窗口还开着：保存并关闭后再导出。" end
  if not app.analysis then return "先点「分析」。" end
  if app.stale then return "分析之后有改动，请重新分析。" end
  if app.rejudge then return "静音门限改过了，请重新分析。" end
  if app.status and not app.status.ok then return "渲染设置检测没通过。" end
  return nil
end

local function draw_bottom(ctx, w)
  if show_progress() then draw_progress(ctx, w) end
  if #app.log > 0 then draw_log(ctx, w) end

  local bw = 128
  local y0 = ImGui.GetCursorPosY(ctx)
  -- counts on the left, vertically centred on the buttons
  ImGui.SetCursorPos(ctx, PAD_X, y0 + (BTN_H - ImGui.GetTextLineHeight(ctx)) / 2)
  draw_counts(ctx)
  -- buttons on the right: [分析 / 取消] [导出]
  ImGui.SetCursorPos(ctx, PAD_X + w - 2 * bw - 8, y0)
  if app.phase == "export_wait" or app.phase == "export" then
    if button(ctx, app.cancel and "正在停止…" or "取消", "danger", bw, BTN_H, not app.cancel) then
      app.cancel = true
    end
    tooltip(ctx, "当前这一遍渲染完成后停止，不再导出剩下的。渲染设置会恢复原样。\n要中断正在进行的这一遍，请点 REAPER 渲染窗口里的 Abort。")
  else
    local label = app.analysis and "重新分析" or "分析"
    if button(ctx, label, "secondary", bw, BTN_H, can_analyze()) then start_analyze() end
    tooltip(ctx, (app.status and app.status.waiting) and "渲染窗口还开着：保存并关闭后再分析。"
      or "按当前渲染设置跑一遍 Dry run，测量每个 Region。不会写出文件。")
  end
  ImGui.SameLine(ctx, 0, 8)
  if button(ctx, "导出", "primary", bw, BTN_H, can_export()) then start_export() end
  if not can_export() and not busy() then tooltip(ctx, export_disabled_reason()) end
end

--------------------------------------------------------------------------------
-- Popups
--------------------------------------------------------------------------------
local function center_next_popup(ctx, w)
  local cx, cy = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Appearing, 0.5, 0.5)
  ImGui.SetNextWindowSize(ctx, w, 0, ImGui.Cond_Appearing)
end

local function bullet_list(ctx, color, items, max)
  for i, f in ipairs(items) do
    if i > max then
      text_col(ctx, ("  …… 共 %d 个"):format(#items), C.faint)
      break
    end
    text_col(ctx, "  " .. (f:match("([^\\/]+)$") or f), color)
  end
end

-- Right-aligned [secondary] [primary] pair at the foot of a popup.
local function popup_buttons(ctx, cancel_label, ok_label, ok_enabled)
  local bw = 112
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - 2 * bw - 8 - PAD_X)
  local cancel = button(ctx, cancel_label, "secondary", bw, 32)
  ImGui.SameLine(ctx, 0, 8)
  local ok = button(ctx, ok_label, "primary", bw, 32, ok_enabled)
  return cancel, ok
end

local function draw_confirm(ctx)
  if app.open_confirm then
    ImGui.OpenPopup(ctx, "确认导出")
    app.open_confirm = false
  end
  center_next_popup(ctx, 560)
  if not ImGui.BeginPopupModal(ctx, "确认导出", true, ImGui.WindowFlags_NoResize) then
    if app.phase == "confirm" then app.phase = "idle" end  -- closed with the X
    return
  end
  local xp = app.xp
  if not xp then
    ImGui.CloseCurrentPopup(ctx)
    ImGui.EndPopup(ctx)
    return
  end
  local s = xp.summary
  ImGui.PushTextWrapPos(ctx, 528)
  ImGui.PushFont(ctx, font_bold, FS_TITLE)
  text_col(ctx, ("将导出 %d 个文件"):format(xp.total_files), C.text)
  ImGui.PopFont(ctx)
  text_col(ctx, ("单声道 %d · 立体声 %d · 分 %d 遍渲染"):format(#s.mono, #s.rest, #xp.passes), C.text2)
  small_text(ctx, "输出目录：" .. (xp.out_dir ~= "" and xp.out_dir or "（工程目录）"), C.faint)
  small_text(ctx, "格式和文件名沿用当前的渲染设置。", C.faint)
  ImGui.Spacing(ctx)

  if #xp.wildcards > 0 then
    wrapped(ctx, ("文件名用了 %s：分两遍导出时，编号会和一次导出不同。"):format(table.concat(xp.wildcards, "、")), C.warn)
  end
  local n = xp.names
  if xp.blocker then
    wrapped(ctx, xp.blocker, C.bad)
    if #n.collisions > 0 then bullet_list(ctx, C.bad, n.collisions, 5) end
  elseif not n.same and #n.added > 0 then
    wrapped(ctx, "和一次导出相比，文件名有变化：", C.warn)
    bullet_list(ctx, C.warn, n.added, 5)
  end
  if xp.existing > 0 then
    wrapped(ctx, ("输出目录里已经有 %d 个同名文件，REAPER 会询问是否覆盖。"):format(xp.existing), C.warn)
  end
  for _, w in ipairs(core.master_warnings()) do wrapped(ctx, w, C.warn) end
  -- settings whose effect on two passes is untested: the user has to confirm
  local need_ack = #(xp.consistency or {}) > 0
  if need_ack then
    ImGui.Spacing(ctx)
    wrapped(ctx, "以下设置可能让两遍导出的结果和一次导出不同：", C.warn)
    for _, w in ipairs(xp.consistency) do wrapped(ctx, "· " .. w, C.warn) end
    local _, v = ImGui.Checkbox(ctx, "我已了解，仍然导出", app.confirm_ack)
    app.confirm_ack = v and true or false
  end
  ImGui.PopTextWrapPos(ctx)

  local can_start = not xp.blocker and (not need_ack or app.confirm_ack)
  local cancel, ok = popup_buttons(ctx, "取消", "开始导出", can_start)
  if not can_start then
    tooltip(ctx, xp.blocker and "目标文件路径有重复，不能导出。" or "请先勾选「我已了解，仍然导出」。")
  end
  if cancel or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    app.phase = "idle"
    ImGui.CloseCurrentPopup(ctx)
  elseif ok then
    ImGui.CloseCurrentPopup(ctx)
    begin_export()
  end
  ImGui.EndPopup(ctx)
end

-- Red banner for settings that could not be restored; stays until dismissed.
local function draw_leftovers(ctx, w)
  if not app.leftovers or #app.leftovers == 0 then return end
  local line = ImGui.GetTextLineHeightWithSpacing(ctx)
  local h = ImGui.GetFrameHeight(ctx) + line * #app.leftovers + 2 * PAD_Y
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, alpha(C.bad, 0.10))
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, alpha(C.bad, 0.55))
  if ImGui.BeginChild(ctx, "##leftovers", w, h, ImGui.ChildFlags_Borders) then
    ImGui.AlignTextToFramePadding(ctx)
    text_col(ctx, "部分渲染设置没能恢复，请打开渲染窗口检查：", C.bad)
    local bw = button_width(ctx, "知道了")
    ImGui.SameLine(ctx, w - PAD_X - bw)
    if button(ctx, "知道了##leftovers", "ghost", bw) then app.leftovers = nil end
    for _, l in ipairs(app.leftovers or {}) do text_col(ctx, "· " .. l, C.text) end
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx, 2)
end

local function draw_error(ctx)
  if app.open_error then
    ImGui.OpenPopup(ctx, "ChannelFit 出错")
    app.open_error = false
  end
  center_next_popup(ctx, 560)
  if not ImGui.BeginPopupModal(ctx, "ChannelFit 出错", true, ImGui.WindowFlags_NoResize) then return end
  local e = app.error or {}
  ImGui.PushTextWrapPos(ctx, 528)
  text_col(ctx, e.short or "", C.bad)
  if e.detail then
    ImGui.Spacing(ctx)
    text_col(ctx, e.detail, C.text2)
  end
  ImGui.PopTextWrapPos(ctx)
  -- script errors carry a traceback: shown here, not in the console
  if e.trace and ImGui.CollapsingHeader(ctx, "技术细节") then
    if ImGui.BeginChild(ctx, "##trace", 0, 140, ImGui.ChildFlags_Borders) then
      ImGui.PushFont(ctx, font, FS_SMALL)
      wrapped(ctx, e.trace, C.faint)
      ImGui.PopFont(ctx)
      ImGui.EndChild(ctx)
    end
  end
  local copy, close = popup_buttons(ctx, "复制信息", "知道了", true)
  if copy then
    ImGui.SetClipboardText(ctx, (e.short or "") .. "\n\n" .. (e.detail or "") .. (e.trace and ("\n\n" .. e.trace) or ""))
  end
  if close or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end

-- Dims the window and names the blocking step; drawn the frame before it runs.
local function draw_busy_overlay(ctx)
  local text
  if app.dialog_open_pending then
    text = "正在打开渲染窗口……设置好后点「Save settings」并关闭窗口"
  elseif app.phase == "analyze_wait" or app.phase == "analyze" then
    text = "正在 Dry run 测量……REAPER 会暂时没有响应"
  elseif app.phase == "export_wait" or app.phase == "export" then
    local p = app.job.xp.passes[app.job.next]
    text = p and ("正在导出 %s（第 %d / %d 遍）……"):format(p.label, app.job.next, #app.job.xp.passes) or nil
  end
  if not text then return end
  local dl = ImGui.GetForegroundDrawList(ctx)
  local x, y = ImGui.GetWindowPos(ctx)
  local w, h = ImGui.GetWindowSize(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, rgba(0x000000, 0.50), 8)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local bx, by = x + (w - tw) / 2 - 22, y + (h - th) / 2 - 16
  ImGui.DrawList_AddRectFilled(dl, bx, by, bx + tw + 44, by + th + 32, C.card, 10)
  ImGui.DrawList_AddRect(dl, bx, by, bx + tw + 44, by + th + 32, alpha(C.accent, 0.8), 10, 0, 1.5)
  ImGui.DrawList_AddText(dl, bx + 22, by + 16, C.text, text)
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local ctx = ImGui.CreateContext(core.SCRIPT_NAME)
font = ImGui.CreateFont("sans-serif")
font_bold = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
ImGui.Attach(ctx, font)
ImGui.Attach(ctx, font_bold)

load_config()
refresh_status()

local TITLE = ("%s v%s###MC_ChannelFit"):format(core.SCRIPT_NAME, core.VERSION)
local MIN_W, MIN_H = 760, 540
local geometry = { load_geometry() }
local last_geometry

local function draw_window()
  if geometry[1] then
    ImGui.SetNextWindowPos(ctx, geometry[1], geometry[2], ImGui.Cond_FirstUseEver)
    ImGui.SetNextWindowSize(ctx, geometry[3], geometry[4], ImGui.Cond_FirstUseEver)
  else
    ImGui.SetNextWindowSize(ctx, 1040, 720, ImGui.Cond_FirstUseEver)
  end
  ImGui.SetNextWindowSizeConstraints(ctx, MIN_W, MIN_H, 4000, 4000)

  local flags = ImGui.WindowFlags_NoCollapse
  if busy() then flags = flags | ImGui.WindowFlags_NoResize end
  local visible, open = ImGui.Begin(ctx, TITLE, true, flags)
  if visible then
    local wx, wy = ImGui.GetWindowPos(ctx)
    local ww, wh = ImGui.GetWindowSize(ctx)
    last_geometry = { wx, wy, ww, wh }

    local w = ImGui.GetContentRegionAvail(ctx)
    draw_leftovers(ctx, w)
    -- top row: two cards of equal height
    local left = math.floor((w - GAP) / 2)
    local right = w - GAP - left
    local top_h = math.max(status_height(ctx, left), thresholds_height(ctx, right))
    draw_status(ctx, left, top_h)
    ImGui.SameLine(ctx, 0, GAP)
    draw_thresholds(ctx, right, top_h)

    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    draw_results(ctx, w, math.max(160, avail_h - bottom_height(ctx)))
    draw_bottom(ctx, w)

    draw_confirm(ctx)
    draw_error(ctx)
    draw_busy_overlay(ctx)
  end
  ImGui.End(ctx)  -- required after every Begin, visible or not
  return open
end

local function loop()
  -- blocking steps run at the start of the frame after their overlay was drawn
  if app.phase == "analyze" then
    run_analyze()
  elseif app.phase == "export" then
    run_export_step()
  elseif app.dialog_open_pending then
    app.dialog_open_pending = false
    open_render_dialog()
  end

  if not busy() then
    poll_dialog()
    -- while the render window is open the project holds stale values: skip
    -- the full check until it closes
    if not app.dialog and reaper.time_precise() - app.status_t > CHECK_INTERVAL then refresh_status() end
  end

  push_theme(ctx)
  ImGui.PushFont(ctx, font, FS_BODY)
  local open = draw_window()
  ImGui.PopFont(ctx)
  pop_theme(ctx)

  if app.phase == "analyze_wait" then app.phase = "analyze"
  elseif app.phase == "export_wait" then app.phase = "export" end

  -- keep running until the current export pass is done, even if closed
  if open or busy() then
    reaper.defer(loop)
  end
end

reaper.atexit(function()
  if last_geometry then save_geometry(table.unpack(last_geometry)) end
  save_config()
end)

reaper.defer(loop)

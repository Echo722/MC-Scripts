-- @description MC ItemArrange
-- @version 1.3.0
-- @author MC Scripts
-- @provides
--   ItemArrange_core.lua
-- @about
--   Lays selected media items out at a fixed interval and snaps every item so
--   its left edge sits on the grid line to its left. One dialog, two modes:
--
--   Item start - each item starts a fixed number of seconds after the previous
--                item started.
--   Item end   - each item starts a fixed number of seconds after the previous
--                item ended, so unequal lengths never overlap.
--
--   Snap to grid is ticked by default. Untick it to lay items out at exactly
--   the interval without touching the grid, for batches that should stay
--   unquantised.
--
--   The first item keeps its position and merely snaps left; the rest follow in
--   their current left-to-right order, across tracks. One undo step.
--
--   ----
--
--   把选中的媒体对象按固定间隔摆开，同时让每个对象的左边界落在它左边的网格
--   线上。一个对话框，两个模式：
--
--   起点相隔 - 每个对象的起点，比上一个对象的起点晚固定秒数。
--   结尾相隔 - 每个对象的起点，在上一个对象结尾之后固定秒数，长短不一也不会重叠。
--
--   「Snap to grid」默认勾选。取消勾选就只按间隔摆开、不碰网格，适合本来
--   就不需要对网格的批次。
--
--   第一个对象保持原位、只向左吸附；其余按当前从左到右的顺序依次排列，可以跨
--   轨道。整次操作只产生一步撤销。
--
--   Requires REAPER 6.0+ and ReaImGui 0.8+. SWS is optional (better grid
--   support when installed). Without ReaImGui it falls back to a plain prompt.
--   需要 REAPER 6.0 以上、ReaImGui 0.8 以上。SWS 可选（装了网格支持更全）。
--   没有 ReaImGui 时会退回系统自带的输入框。

local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""

local EXT = "MC ItemArrange"
local ACTION_NAME = "MC: 摆开并吸附到左侧网格线"
local EXT_SECTION = "MC_ItemArrange"
local EXT_KEY_GAP = "gap_sec"
local EXT_KEY_MODE = "mode"
local EXT_KEY_SNAP = "snap"

--------------------------------------------------------------------------------
-- Core module
--------------------------------------------------------------------------------
local function load_core()
  local path = SCRIPT_DIR .. "ItemArrange_core.lua"
  local chunk, err = loadfile(path)
  if not chunk then
    reaper.ShowMessageBox(
      "找不到 ItemArrange_core.lua：\n" .. tostring(err) .. "\n\n" ..
      "请把脚本和 ItemArrange_core.lua 放在同一个文件夹里重新安装一次。",
      EXT, 0)
    return nil
  end
  local ok, mod = pcall(chunk)
  if not ok or type(mod) ~= "table" then
    reaper.ShowMessageBox("ItemArrange_core.lua 载入失败：\n" .. tostring(mod), EXT, 0)
    return nil
  end
  return mod
end

--------------------------------------------------------------------------------
-- Grid detection
--
-- 1. SWS BR_GetPrevGridDivision - zoom independent, knows every grid mode.
-- 2. Project grid math - decodes projgridframe / projgriddiv ourselves.
-- 3. Nothing usable -> refuse to run instead of guessing.
--
-- SnapToGrid() is deliberately never used: its result depends on the zoom
-- level because REAPER thins out grid lines below projgridmin pixels.
--------------------------------------------------------------------------------
local function cfg_int(name)
  local v = reaper.SNM_GetIntConfigVar(name, 0)
  if type(v) ~= "number" then return nil end
  return v
end

local function cfg_double(name)
  local v = reaper.SNM_GetDoubleConfigVar(name, 0)
  if type(v) ~= "number" then return nil end
  return v
end

local function make_project_math_grid(core)
  local frame_mode = cfg_int("projgridframe")
  if frame_mode and frame_mode > 0 then
    local fps = cfg_int("projfrbase")
    if not fps or fps <= 0 then return nil end
    return core.MathGrid.new({ mode = "frames", fps = fps, frame_div = 1 })
  end

  local div = cfg_double("projgriddiv")
  if not div or div <= 0 then return nil end
  return core.MathGrid.new({
    mode = "beats",
    div_qn = div,
    swing = cfg_double("projgridswing") or 0,
    time_to_qn = function(t) return reaper.TimeMap2_timeToQN(0, t) end,
    qn_to_time = function(qn) return reaper.TimeMap2_QNToTime(0, qn) end,
  })
end

local function choose_grid(core)
  if reaper.APIExists and reaper.APIExists("BR_GetPrevGridDivision") then
    return core.SWSGrid.new(function(t) return reaper.BR_GetPrevGridDivision(t) end), "sws"
  end
  local g = make_project_math_grid(core)
  if g then return g, "project" end
  return nil, nil
end

--------------------------------------------------------------------------------
-- Item collection
--------------------------------------------------------------------------------
local function collect_items()
  local items = {}
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
      items[#items + 1] = {
        item = item,
        pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        lock = reaper.GetMediaItemInfo_Value(item, "I_LOCK"),
        group = reaper.GetMediaItemInfo_Value(item, "I_GROUPID"),
        selected = reaper.IsMediaItemSelected(item) and true or false,
      }
    end
  end
  return items
end

--------------------------------------------------------------------------------
-- Settings persistence
--------------------------------------------------------------------------------
local function load_settings(core)
  local gap = tonumber(reaper.GetExtState(EXT_SECTION, EXT_KEY_GAP)) or core.GAP_DEFAULT
  local mode = reaper.GetExtState(EXT_SECTION, EXT_KEY_MODE)
  if mode ~= "start" and mode ~= "end" then mode = core.MODE_DEFAULT end
  -- Snapping defaults to on; only an explicit "0" turns it off.
  local snap = reaper.GetExtState(EXT_SECTION, EXT_KEY_SNAP) ~= "0"
  return gap, mode, snap
end

local function save_settings(gap, mode, snap)
  reaper.SetExtState(EXT_SECTION, EXT_KEY_GAP, tostring(gap), true)
  reaper.SetExtState(EXT_SECTION, EXT_KEY_MODE, mode, true)
  reaper.SetExtState(EXT_SECTION, EXT_KEY_SNAP, snap and "1" or "0", true)
end

--------------------------------------------------------------------------------
-- Applying a plan
--------------------------------------------------------------------------------
local function apply_plan(core, plan, source)
  if not plan.ok then
    reaper.ShowMessageBox("计算失败，已取消操作（没有做任何改动）。", EXT, 0)
    return
  end
  if core.count_changed(plan) == 0 then
    reaper.ShowMessageBox("所有对象已经在目标位置上，没有需要移动的。", EXT, 0)
    return
  end

  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  for _, mv in ipairs(plan.moves) do
    if mv.delta ~= 0 then
      reaper.SetMediaItemInfo_Value(mv.item.item, "D_POSITION", mv.to)
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(0, ACTION_NAME, -1)
  reaper.UpdateArrange()

  if plan.skipped_locked > 0 or plan.overlaps > 0 then
    reaper.ShowMessageBox(
      core.describe_plan(plan) .. ("\n（网格来源：%s）"):format(source), EXT, 0)
  end
end

--------------------------------------------------------------------------------
-- Dialog fallback when ReaImGui is missing.
-- GetUserInputs has a single checkbox column, so the two radio modes cannot be
-- reproduced faithfully; the mode and the snap flag are kept from the last run
-- and only the interval is asked for.
--------------------------------------------------------------------------------
local function ask_plain(gap0)
  local ok, ret = reaper.GetUserInputs(
    EXT .. "：间隔（秒）", 1, "间隔,秒", ("%.4f"):format(gap0))
  if not ok then return nil end
  local gap = tonumber(ret)
  if not gap then
    reaper.ShowMessageBox("间隔不是一个数字，已取消。", EXT, 0)
    return nil
  end
  return gap
end

--------------------------------------------------------------------------------
-- Theme: warm cream paper, espresso title bar, one terracotta accent.
--
-- The accent marks exactly the things that are "on" or confirm: the selected
-- radio, the ticked checkbox and OK. Everything else stays in warm neutrals so
-- the dialog reads at a glance. Small rounded corners, 1px warm borders.
--------------------------------------------------------------------------------
local UI = {
  bg        = 0xF4EEE4,   -- window background (warm cream)
  win_edge  = 0xC4B6A2,   -- window outline
  title     = 0x3E3026,   -- title bar (espresso)
  title_fg  = 0xF6ECDE,   -- title bar text
  text      = 0x30241C,   -- body text (deep brown)
  text_sub  = 0x7A6858,   -- secondary text (warm taupe)
  field     = 0xFDFAF5,   -- input fields, radio/checkbox wells
  field_h   = 0xFFFFFF,
  edge      = 0xD0C2AF,   -- control borders
  edge_h    = 0xB9A890,
  sep       = 0xDED3C3,   -- separators
  btn       = 0xE9E0D2,   -- neutral buttons (Cancel, -, +)
  btn_h     = 0xF1EADF,
  btn_a     = 0xDDD2C1,
  accent    = 0xD67034,   -- terracotta
  accent_h  = 0xE08048,
  accent_a  = 0xBF5F28,
  on_accent = 0xFFFBF6,   -- text / tick on the accent
}

-- ReaImGui packs colours into a single integer (ColorConvertDouble4ToU32).
-- PushStyleColor takes (ctx, color_index, packed), not r,g,b,a - passing four
-- floats raises "expected 3 arguments maximum" and leaves the style stack
-- unbalanced, so always go through color().
local function color(hex, a)
  local r = (hex >> 16) & 0xFF
  local g = (hex >> 8) & 0xFF
  local b = hex & 0xFF
  return reaper.ImGui_ColorConvertDouble4ToU32(r / 255, g / 255, b / 255, a or 1.0)
end

-- Theme tables: push/pop counts derive from their lengths so the two can
-- never drift apart. Built lazily because the ImGui_Col_* functions only
-- exist once ReaImGui is confirmed present.
--
-- Col_Text is the title bar text colour here: ImGui draws the title inside
-- Begin() with whatever Text colour is current. The body text colour is
-- pushed right after Begin() and popped right before End() (see draw_dialog).
local THEME_COLORS, THEME_VARS

local function build_theme()
  local R = reaper
  THEME_COLORS = {
    { R.ImGui_Col_WindowBg(),          color(UI.bg) },
    { R.ImGui_Col_PopupBg(),           color(UI.bg) },
    { R.ImGui_Col_TitleBg(),           color(UI.title) },
    { R.ImGui_Col_TitleBgActive(),     color(UI.title) },
    { R.ImGui_Col_TitleBgCollapsed(),  color(UI.title) },
    { R.ImGui_Col_Text(),              color(UI.title_fg) },
    { R.ImGui_Col_TextDisabled(),      color(UI.text_sub) },
    { R.ImGui_Col_Border(),            color(UI.edge) },
    { R.ImGui_Col_BorderShadow(),      color(0, 0) },
    { R.ImGui_Col_Separator(),         color(UI.sep) },
    { R.ImGui_Col_CheckMark(),         color(UI.accent) },
    { R.ImGui_Col_Button(),            color(UI.btn) },
    { R.ImGui_Col_ButtonHovered(),     color(UI.btn_h) },
    { R.ImGui_Col_ButtonActive(),      color(UI.btn_a) },
    { R.ImGui_Col_FrameBg(),           color(UI.field) },
    { R.ImGui_Col_FrameBgHovered(),    color(UI.field_h) },
    { R.ImGui_Col_FrameBgActive(),     color(UI.field_h) },
    { R.ImGui_Col_TextSelectedBg(),    color(UI.accent, 0.30) },
    { R.ImGui_Col_ResizeGrip(),        color(UI.accent, 0.15) },
    { R.ImGui_Col_ResizeGripHovered(), color(UI.accent, 0.45) },
    { R.ImGui_Col_ResizeGripActive(),  color(UI.accent, 0.80) },
  }
  THEME_VARS = {
    { R.ImGui_StyleVar_WindowRounding(),   8 },
    { R.ImGui_StyleVar_FrameRounding(),    4 },
    { R.ImGui_StyleVar_GrabRounding(),     4 },
    { R.ImGui_StyleVar_WindowBorderSize(), 1 },
    { R.ImGui_StyleVar_FrameBorderSize(),  1 },
    { R.ImGui_StyleVar_WindowPadding(),    16, 12 },
    { R.ImGui_StyleVar_FramePadding(),     8, 4 },
    { R.ImGui_StyleVar_ItemSpacing(),      8, 7 },
  }
end

local function push_theme(ctx)
  if not THEME_COLORS then build_theme() end
  for _, c in ipairs(THEME_COLORS) do reaper.ImGui_PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(THEME_VARS) do
    if v[3] then reaper.ImGui_PushStyleVar(ctx, v[1], v[2], v[3])
    else reaper.ImGui_PushStyleVar(ctx, v[1], v[2]) end
  end
end

local function pop_theme(ctx)
  reaper.ImGui_PopStyleVar(ctx, #THEME_VARS)
  reaper.ImGui_PopStyleColor(ctx, #THEME_COLORS)
end

-- Push n colour overrides given as { idx, hex [, alpha] } and return n.
local function push_colors(ctx, list)
  for _, c in ipairs(list) do
    reaper.ImGui_PushStyleColor(ctx, c[1], color(c[2], c[3]))
  end
  return #list
end

-- Thin terracotta rule along the bottom of the title bar. The window's own
-- clip rect starts below the title, so widen it for this one shape.
local function draw_title_accent(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww = reaper.ImGui_GetWindowWidth(ctx)
  local th = reaper.ImGui_GetFrameHeight(ctx)   -- title bar height
  reaper.ImGui_DrawList_PushClipRect(dl, wx, wy, wx + ww, wy + th + 2, false)
  reaper.ImGui_DrawList_AddRectFilled(dl, wx + 1, wy + th - 1, wx + ww - 1, wy + th + 1, color(UI.accent))
  reaper.ImGui_DrawList_PopClipRect(dl)
end

-- Widgets in the accent style. Each pushes and pops its own overrides inside
-- the window, so the stack is identical at Begin() and End().
local function sub_text(ctx, s)
  reaper.ImGui_TextColored(ctx, color(UI.text_sub), s)
end

local function radio(ctx, label, active)
  local n = push_colors(ctx, {
    { reaper.ImGui_Col_Border(), active and UI.accent or UI.edge },
  })
  local pressed = reaper.ImGui_RadioButton(ctx, label, active)
  reaper.ImGui_PopStyleColor(ctx, n)
  return pressed
end

-- Ticked: filled terracotta box with a cream tick. Unticked: empty cream well.
local function checkbox(ctx, label, value)
  local C = reaper
  local list
  if value then
    list = {
      { C.ImGui_Col_FrameBg(), UI.accent }, { C.ImGui_Col_FrameBgHovered(), UI.accent_h },
      { C.ImGui_Col_FrameBgActive(), UI.accent_a }, { C.ImGui_Col_CheckMark(), UI.on_accent },
      { C.ImGui_Col_Border(), UI.accent },
    }
  else
    list = { { C.ImGui_Col_Border(), UI.edge_h } }
  end
  local n = push_colors(ctx, list)
  local changed, v = reaper.ImGui_Checkbox(ctx, label, value)
  reaper.ImGui_PopStyleColor(ctx, n)
  return changed, v
end

local function primary_button(ctx, label, w, h)
  local C = reaper
  local n = push_colors(ctx, {
    { C.ImGui_Col_Button(), UI.accent }, { C.ImGui_Col_ButtonHovered(), UI.accent_h },
    { C.ImGui_Col_ButtonActive(), UI.accent_a }, { C.ImGui_Col_Text(), UI.on_accent },
    { C.ImGui_Col_Border(), UI.accent_a },
  })
  local pressed = reaper.ImGui_Button(ctx, label, w, h)
  reaper.ImGui_PopStyleColor(ctx, n)
  return pressed
end

--------------------------------------------------------------------------------
-- Dialog: mirrors the Xenakios "Reposition Items" layout, plus a snap toggle.
-- Returns "pending" while open, or "ok" / "cancel".
--
-- ReaImGui's contract differs from plain ImGui in two ways, both learned from
-- real failures in REAPER:
--
--   1. Begin() must be paired with End() only when it reports visible. Calling
--      End() on a collapsed/hidden frame raises "Calling End() too many times!".
--   2. The style stack must be identical at Begin() and End(). Pushing after
--      Begin and popping after End is still wrong: End() itself validates the
--      stack, so it raises "Missing PopStyleColor()" before the pop can run.
--
-- So the theme is pushed BEFORE Begin and popped AFTER End, and the push
-- happens unconditionally to keep the two frames symmetric. Overrides inside
-- the window (body text colour, accent widgets) are pushed and popped in pairs
-- between Begin and End, which leaves the stack unchanged at End().
--------------------------------------------------------------------------------
local BUTTON_H = 28

local function draw_dialog(ctx, state)
  reaper.ImGui_SetNextWindowSize(ctx, 320, 0, reaper.ImGui_Cond_FirstUseEver())

  push_theme(ctx)
  local visible, open = reaper.ImGui_Begin(ctx, "Reposition Items", true)

  if not visible then
    -- No End() here: ReaImGui never opened a draw scope for a hidden window.
    -- The theme pop still has to happen to balance the push above.
    pop_theme(ctx)
    if not open then return "cancel" end
    return "pending"
  end

  draw_title_accent(ctx)
  -- Body text colour; the theme's Text colour belongs to the title bar.
  local n_body = push_colors(ctx, { { reaper.ImGui_Col_Text(), UI.text } })

  reaper.ImGui_Spacing(ctx)
  sub_text(ctx, "Add time interval to")
  reaper.ImGui_Indent(ctx)
  if radio(ctx, "Item end", state.mode == "end") then state.mode = "end" end
  if radio(ctx, "Item start", state.mode == "start") then state.mode = "start" end
  reaper.ImGui_Unindent(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Time interval")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemWidth(ctx, 120)
  local changed, new_gap = reaper.ImGui_InputDouble(ctx, "##gap", state.gap, 0.05, 0.25, "%.2f")
  if changed then state.gap = new_gap end
  reaper.ImGui_PopItemWidth(ctx)
  reaper.ImGui_SameLine(ctx)
  sub_text(ctx, "seconds")

  reaper.ImGui_Spacing(ctx)
  local s_changed, s_val = checkbox(ctx, "Snap to grid", state.snap)
  if s_changed then state.snap = s_val end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local result = "pending"
  local bw = (reaper.ImGui_GetContentRegionAvail(ctx) - 8) / 2
  if bw < 80 then bw = 80 end
  if primary_button(ctx, "OK", bw, BUTTON_H) then result = "ok" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel", bw, BUTTON_H) then result = "cancel" end

  reaper.ImGui_PopStyleColor(ctx, n_body)
  reaper.ImGui_End(ctx)
  pop_theme(ctx)
  if result == "pending" and not open then result = "cancel" end
  return result
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------
local function main()
  local core = load_core()
  if not core then return end

  local items = collect_items()
  local n_sel = 0
  for _, it in ipairs(items) do
    if it.selected then n_sel = n_sel + 1 end
  end

  if n_sel == 0 then
    reaper.ShowMessageBox("先选中至少一个对象。", EXT, 0)
    return
  end

  local grid, source = choose_grid(core)
  if not grid then
    reaper.ShowMessageBox(
      "读不出当前工程的网格设置，已取消操作。\n\n" ..
      "装一下 SWS 扩展就能支持所有网格类型；或者把网格设成节拍或帧再试。",
      EXT, 0)
    return
  end

  local gap0, mode0, snap0 = load_settings(core)

  -- Without ReaImGui the radio choice is unavailable; ask for the interval and
  -- reuse the last mode and snap setting.
  if not reaper.ImGui_CreateContext then
    local gap = ask_plain(gap0)
    if not gap then return end
    save_settings(gap, mode0, snap0)
    apply_plan(core, core.build_arrange_plan(grid, items, {
      mode = mode0, gap_sec = gap, snap = snap0,
      skip_locked = true, propagate_groups = true,
    }), source)
    return
  end

  -- ReaImGui: one context per run. Segoe UI suits the rounded, warm theme;
  -- Tahoma is the fallback, then the built-in face if neither file exists.
  local ctx = reaper.ImGui_CreateContext(EXT)
  local font
  do
    local candidates = { "C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\tahoma.ttf" }
    for _, path in ipairs(candidates) do
      local f = io.open(path, "rb")
      if f then
        f:close()
        local ok, created = pcall(reaper.ImGui_CreateFontFromFile, path, 15)
        if ok and created then font = created break end
      end
    end
  end
  if not font then font = reaper.ImGui_CreateFont("sans-serif", 15) end
  reaper.ImGui_Attach(ctx, font)

  local state = { gap = gap0, mode = mode0, snap = snap0 }

  local function frame()
    local res = draw_dialog(ctx, state)
    if res == "pending" then
      reaper.defer(frame)
      return
    end
    if res == "cancel" then return end

    save_settings(state.gap, state.mode, state.snap)
    apply_plan(core, core.build_arrange_plan(grid, items, {
      mode = state.mode, gap_sec = state.gap, snap = state.snap,
      skip_locked = true, propagate_groups = true,
    }), source)
  end

  frame()
end

main()

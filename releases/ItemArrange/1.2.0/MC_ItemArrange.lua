-- @description MC ItemArrange
-- @version 1.2.0
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
-- Native look for the ReaImGui window.
--
-- The Xenakios dialog in the SWS DLL is a compiled Windows DIALOG template
-- (MS Sans Serif, grey button face, 1px etched borders). ReaScript cannot
-- create those, so the closest thing is to restyle ImGui to match: flat grey
-- window, square corners, hard 1px dark borders, tight spacing, system font.
-- Colours below are the classic Windows 95..2000 control colours.
--------------------------------------------------------------------------------
local UI = {
  face      = 0.752941,   -- #C0C0C0 button face / window bg
  light     = 0.898039,   -- #E5E5E5 raised edge (top-left)
  shadow    = 0.501961,   -- #808080 sunken edge (bottom-right)
  dkshadow  = 0.250980,   -- #404040 text / darkest edge
  text      = 0.078431,   -- #141414 near-black body text
  field     = 1.000000,   -- #FFFFFF sunken edit field
  selecting = 0.000000,   -- selection/hover tint (kept flat like WinClassic)
}

-- ReaImGui packs colours into a single integer (ColorConvertDouble4ToU32).
-- PushStyleColor takes (ctx, color_index, packed), not r,g,b,a - passing four
-- floats raises "expected 3 arguments maximum" and leaves the style stack
-- unbalanced, so always go through color().
local function color(r, g, b, a)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a or 1.0)
end

-- Counts stay in one place so push/pop can never drift apart.
local N_COLORS = 15
local N_STYLE_VARS = 8

local function push_native_style(ctx)
  local C = reaper.ImGui_PushStyleColor
  local function c(idx, r, g, b)
    C(ctx, idx, color(r, g, b))
  end

  c(reaper.ImGui_Col_WindowBg(),       UI.face, UI.face, UI.face)
  c(reaper.ImGui_Col_PopupBg(),        UI.face, UI.face, UI.face)
  c(reaper.ImGui_Col_TitleBg(),        UI.dkshadow, UI.dkshadow, UI.dkshadow)
  c(reaper.ImGui_Col_TitleBgActive(),  UI.dkshadow, UI.dkshadow, UI.dkshadow)
  c(reaper.ImGui_Col_Text(),           UI.text, UI.text, UI.text)
  c(reaper.ImGui_Col_Border(),         UI.shadow, UI.shadow, UI.shadow)
  c(reaper.ImGui_Col_BorderShadow(),   UI.light, UI.light, UI.light)
  c(reaper.ImGui_Col_Separator(),      UI.shadow, UI.shadow, UI.shadow)
  c(reaper.ImGui_Col_CheckMark(),      UI.dkshadow, UI.dkshadow, UI.dkshadow)
  -- buttons: classic raised face, inverse on press
  c(reaper.ImGui_Col_Button(),         UI.face, UI.face, UI.face)
  c(reaper.ImGui_Col_ButtonHovered(),  UI.light, UI.light, UI.light)
  c(reaper.ImGui_Col_ButtonActive(),   UI.shadow, UI.shadow, UI.shadow)
  -- edit fields: white sunken box
  c(reaper.ImGui_Col_FrameBg(),        UI.field, UI.field, UI.field)
  c(reaper.ImGui_Col_FrameBgHovered(), UI.field, UI.field, UI.field)
  c(reaper.ImGui_Col_FrameBgActive(),  UI.field, UI.field, UI.field)

  local V = reaper.ImGui_PushStyleVar
  V(ctx, reaper.ImGui_StyleVar_WindowRounding(),   0)
  V(ctx, reaper.ImGui_StyleVar_FrameRounding(),    0)
  V(ctx, reaper.ImGui_StyleVar_GrabRounding(),     0)
  V(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  V(ctx, reaper.ImGui_StyleVar_FrameBorderSize(),  1)
  V(ctx, reaper.ImGui_StyleVar_WindowPadding(),    10, 8)
  V(ctx, reaper.ImGui_StyleVar_FramePadding(),     5, 3)
  V(ctx, reaper.ImGui_StyleVar_ItemSpacing(),      6, 5)
end

local function pop_native_style(ctx)
  reaper.ImGui_PopStyleVar(ctx, N_STYLE_VARS)
  reaper.ImGui_PopStyleColor(ctx, N_COLORS)
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
-- So styles are pushed BEFORE Begin and popped AFTER End, and the push happens
-- unconditionally to keep the two frames symmetric.
--------------------------------------------------------------------------------
local function draw_dialog(ctx, state)
  reaper.ImGui_SetNextWindowSize(ctx, 300, 0, reaper.ImGui_Cond_FirstUseEver())

  push_native_style(ctx)
  local visible, open = reaper.ImGui_Begin(ctx, "Reposition Items", true)

  if not visible then
    -- No End() here: ReaImGui never opened a draw scope for a hidden window.
    -- The style pop still has to happen to balance the push above.
    pop_native_style(ctx)
    if not open then return "cancel" end
    return "pending"
  end

  reaper.ImGui_Text(ctx, "Add time interval to")
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Indent(ctx)
  if reaper.ImGui_RadioButton(ctx, "Item end", state.mode == "end") then state.mode = "end" end
  if reaper.ImGui_RadioButton(ctx, "Item start", state.mode == "start") then state.mode = "start" end
  reaper.ImGui_Unindent(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Time interval")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemWidth(ctx, 90)
  local changed, new_gap = reaper.ImGui_InputDouble(ctx, "##gap", state.gap, 0.05, 0.25, "%.2f")
  if changed then state.gap = new_gap end
  reaper.ImGui_PopItemWidth(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "seconds")

  reaper.ImGui_Spacing(ctx)
  local s_changed, s_val = reaper.ImGui_Checkbox(ctx, "Snap to grid", state.snap)
  if s_changed then state.snap = s_val end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local result = "pending"
  local bw = (reaper.ImGui_GetContentRegionAvail(ctx) - 8) / 2
  if bw < 80 then bw = 80 end
  if reaper.ImGui_Button(ctx, "OK", bw, 0) then result = "ok" end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel", bw, 0) then result = "cancel" end

  reaper.ImGui_End(ctx)
  pop_native_style(ctx)
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

  -- ReaImGui: one context per run. Tahoma is the closest available match for
  -- the compiled dialog's MS Sans Serif (the .FON bitmap font ImGui cannot
  -- load); fall back to the built-in face if the file is missing.
  local ctx = reaper.ImGui_CreateContext(EXT)
  local font
  do
    local candidates = { "C:\\Windows\\Fonts\\tahoma.ttf", "C:\\Windows\\Fonts\\segoeui.ttf" }
    for _, path in ipairs(candidates) do
      local f = io.open(path, "rb")
      if f then
        f:close()
        local ok, created = pcall(reaper.ImGui_CreateFontFromFile, path, 14)
        if ok and created then font = created break end
      end
    end
  end
  if not font then font = reaper.ImGui_CreateFont("sans-serif", 14) end
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

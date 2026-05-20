--
-- ui.lua  —  ReaImGui chat panel for MCAssistant.
--
-- Replaces the previous gfx-based UI. Key wins:
--   - Direct CJK / Unicode input via ImGui_InputTextMultiline (no Ctrl+E modal).
--   - Native scrolling, text wrapping, hit-testing.
--   - Better high-DPI handling.
--
-- Public API (consumed by MCAssistant.lua):
--   M.new(chat, opts)                          → ui state table
--   M.frame(ui)                                → returns false when user closes
--   M.set_web_search_state(ui, on)             → sync toggle pill display
--   M.open_settings_overlay(ui, provider_name, model, search_key) → request popup
--
-- All input handling + drawing happens inside frame() as one immediate-mode
-- pass. The chat tick is driven from MCAssistant.lua.

local json = require("json")

local M = {}

--------------------------------------------------------------------------------
-- constants
--------------------------------------------------------------------------------
local EXT             = "MCAssistant"
local FONT_SIZE       = 16
local FONT_SIZE_SMALL = 13
local INPUT_LINES     = 2   -- visible rows in the input box (multi-line via Ctrl+Enter)
local MIN_W, MIN_H    = 480, 380

local THINKING_PHRASES = {
    "思考中…",
    "琢磨中…",
    "整理思路…",
    "推敲中…",
    "组织语言…",
}
local THINKING_CYCLE = 2.5

-- RGBA pack: r,g,b,a in 0..1 → 0xRRGGBBAA
local function rgba(r, g, b, a)
    a = a or 1
    return (math.floor(r * 255) << 24)
         | (math.floor(g * 255) << 16)
         | (math.floor(b * 255) << 8)
         |  math.floor(a * 255)
end

local COL = {
    bg              = rgba(0.071, 0.071, 0.075),
    panel           = rgba(0.090, 0.090, 0.094),
    sep             = rgba(0.16,  0.16,  0.18),
    user_text       = rgba(1.00,  1.00,  1.00),
    user_bubble     = rgba(0.70,  0.32,  0.20),   -- deep terracotta / brick
    assistant       = rgba(0.86,  0.87,  0.89),
    assistant_live  = rgba(0.94,  0.86,  0.66),
    tool            = rgba(0.55,  0.78,  0.62),
    tool_dim        = rgba(0.38,  0.55,  0.45),
    tool_bubble     = rgba(0.085, 0.115, 0.100),
    search_text     = rgba(0.55,  0.70,  0.85),
    error_text      = rgba(0.95,  0.58,  0.58),
    error_bubble    = rgba(0.18,  0.09,  0.09),
    dim             = rgba(0.55,  0.55,  0.60),
    very_dim        = rgba(0.40,  0.40,  0.44),
    title           = rgba(0.93,  0.93,  0.94),
    accent          = rgba(0.96,  0.62,  0.36),
    pill_on_bg      = rgba(0.18,  0.32,  0.22),
    pill_off_bg     = rgba(0.22,  0.22,  0.26),
    pill_on_text    = rgba(0.82,  0.94,  0.84),
    pill_off_text   = rgba(0.60,  0.60,  0.64),
    -- frame-wide theme overrides
    input_bg        = rgba(0.105, 0.105, 0.110),
    input_bg_hover  = rgba(0.130, 0.130, 0.140),
    input_bg_active = rgba(0.155, 0.155, 0.165),
    button_bg       = rgba(0.20,  0.20,  0.23),
    button_hover    = rgba(0.28,  0.28,  0.32),
    button_active   = rgba(0.34,  0.34,  0.38),
    -- Popup-specific: lighter body + visible border + distinct title bar so the
    -- settings window reads as a proper "lifted" panel over the main UI.
    popup_bg        = rgba(0.17,  0.17,  0.20),
    popup_border    = rgba(0.40,  0.40,  0.46),
    popup_title_bg  = rgba(0.26,  0.26,  0.30),
    sb_bg           = rgba(0.05,  0.05,  0.06),
    sb_grab         = rgba(0.30,  0.30,  0.34),
    sb_grab_hover   = rgba(0.40,  0.40,  0.44),
    sb_grab_active  = rgba(0.50,  0.50,  0.54),
    jump_bg         = rgba(0.20,  0.20,  0.23, 0.92),
    jump_hover      = rgba(0.30,  0.30,  0.34, 0.95),
    jump_text       = rgba(0.85,  0.85,  0.88),
}

-- Pulsing accent alpha for the ✱ thinking spinner. Matches the old gfx version.
local function pulse_accent()
    local pulse = 0.55 + 0.45 * math.sin(reaper.time_precise() * 2.6)
    return rgba(0.96, 0.62, 0.36, pulse)
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function summarize_tool_input(input)
    if type(input) ~= "table" then return "" end
    local parts = {}
    for k, v in pairs(input) do
        local sv
        if type(v) == "table" then sv = "[...]"
        elseif type(v) == "string" then sv = '"' .. v:sub(1, 40) .. (#v > 40 and "…" or "") .. '"'
        else sv = tostring(v) end
        parts[#parts + 1] = k .. "=" .. sv
        if #parts >= 4 then break end
    end
    return table.concat(parts, "  ")
end

local function summarize_tool_output(output)
    if type(output) ~= "table" then return tostring(output) end
    if output.ok == false then return "✗ " .. tostring(output.error or "?") end
    local hints = {}
    for _, k in ipairs({ "count", "modified", "inserted", "split", "items_transposed",
                         "transposed", "item_start", "imported", "file_count" }) do
        if output[k] ~= nil then
            local v = output[k]
            if type(v) == "table" then v = "[" .. #v .. "]" end
            hints[#hints + 1] = k .. "=" .. tostring(v)
        end
    end
    if #hints == 0 then
        local ok, enc = pcall(json.encode, output)
        return ok and enc:sub(1, 80) or "✓"
    end
    return "✓ " .. table.concat(hints, "  ")
end

local function format_sources(sources)
    if not sources or #sources == 0 then return "" end
    local lines = { "", "来源:" }
    for i, s in ipairs(sources) do
        local title = s.title or s.url or ""
        local url   = s.url or ""
        if title ~= "" and title ~= url then
            lines[#lines + 1] = ("[%d] %s — %s"):format(i, title, url)
        else
            lines[#lines + 1] = ("[%d] %s"):format(i, url)
        end
    end
    return table.concat(lines, "\n")
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

--------------------------------------------------------------------------------
-- manual word wrap
--
-- We render chat content with ReadOnly ImGui_InputTextMultiline so the user
-- can drag-select + Ctrl+C. InputText doesn't auto-wrap (upstream design,
-- imgui#383), so we pre-wrap with explicit \n. Result cached per event so
-- frozen messages don't re-measure each frame; window resize invalidates by
-- cache key.
--------------------------------------------------------------------------------
local function wrap_line(ctx, line, wrap_w, out)
    if line == "" then out[#out + 1] = ""; return end

    while line ~= "" do
        if reaper.ImGui_CalcTextSize(ctx, line) <= wrap_w then
            out[#out + 1] = line
            return
        end

        -- Binary-search the longest byte prefix fitting in wrap_w pixels,
        -- snapping to a utf-8 char boundary (so we never cut a CJK glyph
        -- in half).
        local lo, hi = 1, #line
        local best = 0
        while lo <= hi do
            local mid = (lo + hi) // 2
            while mid < #line do
                local b = string.byte(line, mid + 1)
                if not b or b < 0x80 or b >= 0xC0 then break end
                mid = mid + 1
            end
            local w = reaper.ImGui_CalcTextSize(ctx, line:sub(1, mid))
            if w <= wrap_w then best = mid; lo = mid + 1
            else hi = mid - 1 end
        end

        if best == 0 then
            -- wrap_w narrower than the first glyph — force at least one
            -- char through to guarantee progress.
            best = 1
            while best < #line do
                local b = string.byte(line, best + 1)
                if not b or b < 0x80 or b >= 0xC0 then break end
                best = best + 1
            end
        end

        -- Prefer breaking at the last space in the back ~60% so English
        -- words aren't sliced mid-letter; CJK has no spaces so we fall
        -- through to the byte break and that's fine.
        local seg = line:sub(1, best)
        local space_idx
        local min_keep = math.max(1, math.floor(#seg * 0.4))
        for i = #seg, min_keep, -1 do
            if string.byte(seg, i) == 0x20 then space_idx = i; break end
        end
        if space_idx then
            out[#out + 1] = line:sub(1, space_idx - 1)
            line = line:sub(space_idx + 1)
        else
            out[#out + 1] = seg
            line = line:sub(best + 1)
        end
    end
end

local function wrap_text(ctx, text, wrap_w)
    if not text or text == "" then return "" end
    local out = {}
    for s in (text .. "\n"):gmatch("([^\n]*)\n") do
        wrap_line(ctx, s, wrap_w, out)
    end
    return table.concat(out, "\n")
end

-- Cached wrap. Returns wrapped_text, line_count, longest_line_pixel_width.
-- Cache is attached to the event itself so it survives across frames but
-- dies with the event (e.g. on chat:clear()).
local function wrap_for_event(ctx, ev, text, wrap_w)
    local c = ev._wrap_cache
    if c and c.text == text and c.wrap_w == wrap_w then
        return c.result, c.n_lines, c.max_line_w
    end
    local wrapped = wrap_text(ctx, text, wrap_w)
    local n = 1
    for _ in wrapped:gmatch("\n") do n = n + 1 end
    local maxw = 0
    for ln in (wrapped .. "\n"):gmatch("([^\n]*)\n") do
        if ln ~= "" then
            local lw = reaper.ImGui_CalcTextSize(ctx, ln)
            if lw > maxw then maxw = lw end
        end
    end
    ev._wrap_cache = {
        text       = text,
        wrap_w     = wrap_w,
        result     = wrapped,
        n_lines    = n,
        max_line_w = maxw,
    }
    return wrapped, n, maxw
end

--------------------------------------------------------------------------------
-- geometry persistence
--------------------------------------------------------------------------------
local function load_geom()
    local w = tonumber(reaper.GetExtState(EXT, "win_w")) or 640
    local h = tonumber(reaper.GetExtState(EXT, "win_h")) or 720
    local x = tonumber(reaper.GetExtState(EXT, "win_x")) or 200
    local y = tonumber(reaper.GetExtState(EXT, "win_y")) or 120
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    return w, h, x, y
end

local function save_geom(ctx)
    local x, y = reaper.ImGui_GetWindowPos(ctx)
    local w, h = reaper.ImGui_GetWindowSize(ctx)
    reaper.SetExtState(EXT, "win_w", tostring(math.floor(w)), true)
    reaper.SetExtState(EXT, "win_h", tostring(math.floor(h)), true)
    reaper.SetExtState(EXT, "win_x", tostring(math.floor(x)), true)
    reaper.SetExtState(EXT, "win_y", tostring(math.floor(y)), true)
end

--------------------------------------------------------------------------------
-- new
--------------------------------------------------------------------------------
function M.new(chat, opts)
    opts = opts or {}
    local ctx  = reaper.ImGui_CreateContext("MCAssistant")
    local font = reaper.ImGui_CreateFont("sans-serif", FONT_SIZE)
    reaper.ImGui_Attach(ctx, font)

    return {
        chat                     = chat,
        ctx                      = ctx,
        font                     = font,

        on_save_settings         = opts.on_save_settings,
        on_settings              = opts.on_settings,
        on_toggle_search         = opts.on_toggle_search,

        input_buf                = "",
        focus_input              = true,  -- focus on first frame

        _web_search_on           = false,
        _open_settings_request   = false,
        -- Settings popup draft state (populated when popup opens)
        _draft_type              = "",
        _draft_base_url          = "",
        _draft_model             = "",
        _draft_api_key           = "",
        _draft_search_key        = "",
        _show_api_key            = false,
        _show_search_key         = false,

        _first_frame             = true,
        _last_event_n            = 0,
        _scroll_to_bottom        = false,
        _was_at_bottom           = true,    -- tracked frame-to-frame
    }
end

function M.set_web_search_state(ui, on)
    ui._web_search_on = on and true or false
end

-- Open the settings popup with editable draft fields populated from the
-- current settings. Caller passes the full settings table.
function M.open_settings_overlay(ui, settings)
    settings = settings or {}
    -- Normalize legacy "claude" → "anthropic".
    local t = settings.type or ""
    if t == "claude" then t = "anthropic" end
    ui._draft_type       = (t ~= "" and t) or "anthropic"
    ui._draft_base_url   = settings.base_url or ""
    ui._draft_model      = settings.model or ""
    ui._draft_api_key    = settings.api_key or ""
    ui._draft_search_key = settings.search_api_key or ""
    ui._show_api_key     = false
    ui._show_search_key  = false
    ui._open_settings_request = true
end

--------------------------------------------------------------------------------
-- event rendering
--
-- Content goes into ReadOnly ImGui_InputTextMultiline widgets so the user can
-- drag-select + Ctrl+C. The widget is styled to look like the old bubble
-- (FrameBg = bubble color, custom FramePadding, no border) or like plain text
-- (transparent frame, zero padding) depending on is_bubble.
--
-- Widget size is computed up-front from the cached wrapped text so the
-- multiline never opens a scrollbar (height = n_lines * line_h + paddings).
-- No AutoResize anywhere — the earlier ChildFlags_AlwaysAutoResize approach
-- crashed during streaming, and InputTextMultiline with explicit (w,h) avoids
-- that whole class of bug.
--------------------------------------------------------------------------------
local function colored_wrap(ctx, color, text)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
    reaper.ImGui_TextWrapped(ctx, text)
    reaper.ImGui_PopStyleColor(ctx)
end

-- Render text selectably. is_bubble=true draws a rounded colored frame
-- (used for user / tool_call / tool_result / error); is_bubble=false draws
-- transparent (used for the streaming assistant body).
--
-- align_right is used only by the user bubble (mirrors a chat-app message
-- coming from "the right side").
local function render_selectable(ctx, ev, id, text, max_w, align_right,
                                  bg_color, text_color, rounding, is_bubble)
    local pad = is_bubble and 12 or 0
    -- -4 buffer absorbs sub-pixel wrap rounding so InputTextMultiline never
    -- decides one of our lines is one pixel too wide and pops a scrollbar.
    local content_w = math.max(40, max_w - pad * 2 - 4)

    local wrapped, n_lines, max_line_w =
        wrap_for_event(ctx, ev, text or "", content_w)

    local line_h   = reaper.ImGui_GetTextLineHeight(ctx)
    local widget_h = math.ceil(n_lines * line_h) + pad * 2 + 4
    local widget_w
    if is_bubble then
        widget_w = math.min(math.ceil(max_line_w) + pad * 2 + 6, max_w)
    else
        widget_w = max_w
    end
    widget_w = math.max(40, widget_w)

    if align_right then
        local avail = reaper.ImGui_GetContentRegionAvail(ctx)
        if avail > widget_w then
            reaper.ImGui_SetCursorPosX(ctx,
                reaper.ImGui_GetCursorPosX(ctx) + (avail - widget_w))
        end
    end

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),
        is_bubble and (rounding or 10) or 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), pad, pad)

    local frame_bg = bg_color or 0x00000000
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        frame_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), frame_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  frame_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           text_color)

    local flags = reaper.ImGui_InputTextFlags_ReadOnly()
                | reaper.ImGui_InputTextFlags_NoHorizontalScroll()

    reaper.ImGui_InputTextMultiline(ctx, "##sel" .. tostring(id), wrapped,
        widget_w, widget_h, flags)

    reaper.ImGui_PopStyleColor(ctx, 4)
    reaper.ImGui_PopStyleVar(ctx, 3)
end

local function draw_event(ctx, ev, i)
    local k = ev.kind

    if k == "user" then
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local max_w = math.min(math.floor(avail_w * 0.78), 560)
        render_selectable(ctx, ev, i, ev.text or "", max_w, true,
            COL.user_bubble, COL.user_text, 14, true)

    elseif k == "assistant" then
        local body = ev.text or ""
        if ev.live and body == "" then
            -- Pre-token thinking spinner: stays as non-selectable Text since
            -- it's a placeholder, not content the user would want to copy.
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), pulse_accent())
            reaper.ImGui_Text(ctx, "✱")
            reaper.ImGui_PopStyleColor(ctx)
            reaper.ImGui_SameLine(ctx)
            local idx = 1 + math.floor(reaper.time_precise() / THINKING_CYCLE) % #THINKING_PHRASES
            colored_wrap(ctx, COL.accent, "  " .. THINKING_PHRASES[idx])
        else
            local color = ev.live and COL.assistant_live or COL.assistant
            local full  = body .. format_sources(ev.sources)
            local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
            render_selectable(ctx, ev, i, full, avail_w, false,
                nil, color, 0, false)
        end

    elseif k == "tool_call" then
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local text = "⚙ " .. (ev.name or "") .. "    " .. summarize_tool_input(ev.input)
        render_selectable(ctx, ev, i, text, avail_w - 4, false,
            COL.tool_bubble, COL.tool, 6, true)

    elseif k == "tool_result" then
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local text = "← " .. (ev.name or "") .. "    " .. summarize_tool_output(ev.output)
        render_selectable(ctx, ev, i, text, avail_w - 4, false,
            COL.tool_bubble, COL.tool_dim, 6, true)

    elseif k == "search_status" then
        colored_wrap(ctx, COL.search_text, ev.text or "")

    elseif k == "error" then
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local text = "错误: " .. (ev.text or "")
        render_selectable(ctx, ev, i, text, avail_w - 4, false,
            COL.error_bubble, COL.error_text, 6, true)
    end
end

--------------------------------------------------------------------------------
-- log / input / status bar
--------------------------------------------------------------------------------
local function draw_status_bar(ctx, ui)
    -- Window title bar already says "MCAssistant"; we only show
    -- provider/model + transient status here to avoid redundancy.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.dim)
    reaper.ImGui_Text(ctx, ui.chat.provider.model)
    reaper.ImGui_PopStyleColor(ctx)

    if ui.chat.state ~= "idle" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.accent)
        reaper.ImGui_Text(ctx, " · " .. ui.chat:status_text())
        reaper.ImGui_PopStyleColor(ctx)
    end

    -- Gear button right-aligned ON THE SAME LINE as the title.
    local btn_w   = 28
    local right_x = reaper.ImGui_GetWindowWidth(ctx) - btn_w - 12
    reaper.ImGui_SameLine(ctx, right_x)
    if reaper.ImGui_Button(ctx, "⚙##settings", btn_w, 0) then
        -- Delegate to on_settings so the parent can populate draft fields
        -- with the live settings table before the popup opens.
        if ui.on_settings then ui.on_settings() end
    end

    reaper.ImGui_Separator(ctx)
end

local function draw_log(ctx, ui, log_h)
    local has_live = ui.chat.live_event ~= nil

    if reaper.ImGui_BeginChild(ctx, "log", 0, log_h) then
        -- Capture "was the user at bottom?" BEFORE this frame's content
        -- changes ScrollMaxY. ImGui carries scroll state across frames, so at
        -- this point we see the previous frame's geometry.
        local was_at_bottom = reaper.ImGui_GetScrollY(ctx)
                           >= reaper.ImGui_GetScrollMaxY(ctx) - 20
        ui._was_at_bottom = was_at_bottom

        local events = ui.chat.events
        local n = #events
        local prev_kind = nil
        for i, ev in ipairs(events) do
            -- Extra air at user↔assistant turn boundaries.
            local boundary = (prev_kind == "user"      and ev.kind == "assistant")
                          or (prev_kind == "assistant" and ev.kind == "user")
            if boundary then reaper.ImGui_Dummy(ctx, 1, 10) end

            draw_event(ctx, ev, i)
            if i < n then reaper.ImGui_Dummy(ctx, 1, 6) end
            prev_kind = ev.kind
        end

        local n_changed = ui._last_event_n ~= n
        if ui._scroll_to_bottom then
            reaper.ImGui_SetScrollHereY(ctx, 1.0)
            ui._scroll_to_bottom = false
        elseif (n_changed or has_live) and was_at_bottom then
            reaper.ImGui_SetScrollHereY(ctx, 1.0)
        end
        ui._last_event_n = n
    end
    reaper.ImGui_EndChild(ctx)

    -- "↓ 跳到最新" floating button — drawn AFTER EndChild so it overlays the
    -- bottom of the log area. We pull the cursor back up into the log region
    -- with SetCursorPos, draw the button, then restore.
    if has_live and not ui._was_at_bottom then
        local cx, cy = reaper.ImGui_GetCursorPos(ctx)
        local win_w = reaper.ImGui_GetWindowWidth(ctx)
        local btn_w, btn_h = 110, 28
        local btn_x = win_w - btn_w - 24
        local btn_y = cy - btn_h - 10
        reaper.ImGui_SetCursorPos(ctx, btn_x, btn_y)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        COL.jump_bg)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COL.jump_hover)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.jump_text)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 14)
        if reaper.ImGui_Button(ctx, "↓ 跳到最新##jump", btn_w, btn_h) then
            ui._scroll_to_bottom = true
        end
        reaper.ImGui_PopStyleVar(ctx)
        reaper.ImGui_PopStyleColor(ctx, 3)
        reaper.ImGui_SetCursorPos(ctx, cx, cy)
    end
end

local function cancel_busy(ui)
    if ui.chat.req and ui.chat.req.handle then
        local http = require("http")
        http.cancel(ui.chat.req.handle)
    end
    ui.chat:_finish()
end

local function draw_input(ctx, ui)
    local is_busy = ui.chat.state ~= "idle"
    local line_h  = reaper.ImGui_GetTextLineHeight(ctx)
    local input_h = line_h * INPUT_LINES + 12
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local btn_w   = 80
    local input_w = math.max(120, avail_w - btn_w - 12)

    -- Only auto-focus when we can actually receive input (not while ReadOnly
    -- during a streaming response — focusing a read-only multiline has caused
    -- problems in past ReaImGui versions).
    if ui.focus_input and not is_busy then
        reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
        ui.focus_input = false
    end

    local flags = reaper.ImGui_InputTextFlags_CtrlEnterForNewLine()
                | reaper.ImGui_InputTextFlags_EnterReturnsTrue()
    if is_busy then
        flags = flags | reaper.ImGui_InputTextFlags_ReadOnly()
    end

    local rv, new_buf = reaper.ImGui_InputTextMultiline(ctx, "##input",
        ui.input_buf, input_w, input_h, flags)
    ui.input_buf = new_buf

    local should_send = rv and not is_busy

    reaper.ImGui_SameLine(ctx)
    if is_busy then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
            rgba(0.28, 0.12, 0.10))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            rgba(0.96, 0.58, 0.50))
        if reaper.ImGui_Button(ctx, "停止", btn_w, input_h) then
            cancel_busy(ui)
        end
        reaper.ImGui_PopStyleColor(ctx, 2)
    else
        if reaper.ImGui_Button(ctx, "发送", btn_w, input_h) then
            should_send = true
        end
    end

    -- hint row
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.very_dim)
    if is_busy then
        reaper.ImGui_Text(ctx, "AI 正在生成…  Esc 停止")
    else
        reaper.ImGui_Text(ctx,
            "Enter 发送 · Ctrl+Enter 换行 · 拖选可复制 · Ctrl+L 清屏 · 搜索: "
            .. (ui._web_search_on and "ON" or "OFF"))
    end
    reaper.ImGui_PopStyleColor(ctx)

    if should_send then
        local t = trim(ui.input_buf)
        if t ~= "" then
            ui.chat:send_user(t)
            ui.input_buf = ""
        end
        ui.focus_input = true
    end
end

--------------------------------------------------------------------------------
-- settings popup
--------------------------------------------------------------------------------
local SETTINGS_POPUP = "MCAssistant 设置##mcap"

local function draw_settings_popup(ctx, ui)
    if ui._open_settings_request then
        reaper.ImGui_OpenPopup(ctx, SETTINGS_POPUP)
        ui._open_settings_request = false
    end

    reaper.ImGui_SetNextWindowSize(ctx, 560, 460,
        reaper.ImGui_Cond_Appearing())

    -- Popup-specific styling so the settings window reads as visually
    -- distinct from the main UI: brighter body bg, visible border, lighter
    -- title bar. Pushes here are local to the popup; pops happen on both
    -- return paths below.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         COL.popup_border)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),        COL.popup_title_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),  COL.popup_title_bg)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),   8)

    if not reaper.ImGui_BeginPopupModal(ctx, SETTINGS_POPUP, nil,
            reaper.ImGui_WindowFlags_NoResize()) then
        reaper.ImGui_PopStyleVar(ctx, 2)
        reaper.ImGui_PopStyleColor(ctx, 3)
        return
    end

    -- ── API section ───────────────────────────────────────────────────
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.title)
    reaper.ImGui_Text(ctx, "API")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Separator(ctx)

    -- Provider radio
    reaper.ImGui_Text(ctx, "Provider")
    reaper.ImGui_SameLine(ctx, 110)
    if reaper.ImGui_RadioButton(ctx, "anthropic##type",
            ui._draft_type == "anthropic") then
        ui._draft_type = "anthropic"
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "openai##type",
            ui._draft_type == "openai") then
        ui._draft_type = "openai"
    end

    -- Base URL
    reaper.ImGui_Text(ctx, "Base URL")
    reaper.ImGui_SameLine(ctx, 110)
    reaper.ImGui_PushItemWidth(ctx, -1)
    local _, new_url = reaper.ImGui_InputText(ctx, "##base_url", ui._draft_base_url)
    ui._draft_base_url = new_url
    reaper.ImGui_PopItemWidth(ctx)

    -- Model
    reaper.ImGui_Text(ctx, "Model")
    reaper.ImGui_SameLine(ctx, 110)
    reaper.ImGui_PushItemWidth(ctx, -1)
    local _, new_model = reaper.ImGui_InputText(ctx, "##model", ui._draft_model)
    ui._draft_model = new_model
    reaper.ImGui_PopItemWidth(ctx)

    -- API key (with show/hide)
    reaper.ImGui_Text(ctx, "API key")
    reaper.ImGui_SameLine(ctx, 110)
    local key_flags = ui._show_api_key and 0
                    or reaper.ImGui_InputTextFlags_Password()
    reaper.ImGui_PushItemWidth(ctx, -84)
    local _, new_key = reaper.ImGui_InputText(ctx, "##api_key",
        ui._draft_api_key, key_flags)
    ui._draft_api_key = new_key
    reaper.ImGui_PopItemWidth(ctx)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, (ui._show_api_key and "隐藏" or "显示") .. "##sk", 76, 0) then
        ui._show_api_key = not ui._show_api_key
    end

    -- ── Web search section ─────────────────────────────────────────────
    reaper.ImGui_Dummy(ctx, 1, 10)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.title)
    reaper.ImGui_Text(ctx, "联网搜索")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Separator(ctx)

    local label = ui._web_search_on and "  ON  " or " OFF "
    local pill_bg   = ui._web_search_on and COL.pill_on_bg   or COL.pill_off_bg
    local pill_text = ui._web_search_on and COL.pill_on_text or COL.pill_off_text
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), pill_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),   pill_text)
    if reaper.ImGui_Button(ctx, label .. "##search_toggle") then
        if ui.on_toggle_search then ui.on_toggle_search(false) end
    end
    reaper.ImGui_PopStyleColor(ctx, 2)

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.dim)
    reaper.ImGui_Text(ctx, ui._web_search_on and "  Tavily 搜索已开启" or "  已关闭")
    reaper.ImGui_PopStyleColor(ctx)

    -- Search key field only shows when the toggle is ON. The draft value is
    -- still preserved across toggles, so switching off→on doesn't erase it.
    if ui._web_search_on then
        reaper.ImGui_Dummy(ctx, 1, 4)
        reaper.ImGui_Text(ctx, "Search key")
        reaper.ImGui_SameLine(ctx, 110)
        local skey_flags = ui._show_search_key and 0
                         or reaper.ImGui_InputTextFlags_Password()
        reaper.ImGui_PushItemWidth(ctx, -84)
        local _, new_skey = reaper.ImGui_InputText(ctx, "##search_key",
            ui._draft_search_key, skey_flags)
        ui._draft_search_key = new_skey
        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx,
                (ui._show_search_key and "隐藏" or "显示") .. "##ssk", 76, 0) then
            ui._show_search_key = not ui._show_search_key
        end
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.very_dim)
        reaper.ImGui_TextWrapped(ctx,
            "Tavily 免费 1000 次/月  ·  tvly-... 形式  ·  留空则模型不能联网搜索")
        reaper.ImGui_PopStyleColor(ctx)
    end

    -- ── Footer: Cancel / Save ─────────────────────────────────────────
    reaper.ImGui_Dummy(ctx, 1, 12)
    reaper.ImGui_Separator(ctx)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_Dummy(ctx, math.max(1, avail - 200), 1)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "取消", 90, 0)
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "保存", 100, 0) then
        if ui.on_save_settings then
            local ok, err = ui.on_save_settings({
                type           = trim(ui._draft_type),
                base_url       = trim(ui._draft_base_url),
                model          = trim(ui._draft_model),
                api_key        = trim(ui._draft_api_key),
                search_api_key = trim(ui._draft_search_key),
            })
            if ok then
                reaper.ImGui_CloseCurrentPopup(ctx)
            elseif err then
                reaper.MB(err, "MCAssistant", 0)
            end
        else
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
    end

    reaper.ImGui_EndPopup(ctx)
    reaper.ImGui_PopStyleVar(ctx, 2)   -- WindowBorderSize, WindowRounding
    reaper.ImGui_PopStyleColor(ctx, 3) -- Border, TitleBg, TitleBgActive
end

--------------------------------------------------------------------------------
-- shortcuts
--------------------------------------------------------------------------------
local function handle_shortcuts(ctx, ui)
    -- Ctrl+L: clear chat (only when input is empty)
    local ctrl_l = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_L()
    if reaper.ImGui_IsKeyChordPressed(ctx, ctrl_l) and ui.input_buf == "" then
        ui.chat:clear()
        ui._last_event_n = 0
    end

    -- Ctrl+W: request close
    local ctrl_w = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_W()
    if reaper.ImGui_IsKeyChordPressed(ctx, ctrl_w) then
        return false  -- signal quit
    end

    -- Esc: cascade (cancel busy / clear input)
    -- (Settings popup handles its own Esc internally)
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        if ui.chat.state ~= "idle" then
            cancel_busy(ui)
        elseif ui.input_buf ~= "" then
            ui.input_buf = ""
            ui.focus_input = true
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- frame
--------------------------------------------------------------------------------
function M.frame(ui)
    local ctx = ui.ctx

    if ui._first_frame then
        local w, h, x, y = load_geom()
        reaper.ImGui_SetNextWindowSize(ctx, w, h, reaper.ImGui_Cond_FirstUseEver())
        reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_FirstUseEver())
        ui._first_frame = false
    end

    reaper.ImGui_PushFont(ctx, ui.font, FONT_SIZE)

    -- Frame-wide dark theme overrides. Push count must match the Pop at the end.
    -- ModalWindowDimBg is pushed here (not inside the popup function) because a
    -- local push happens AFTER ImGui has already resolved the dim for that
    -- frame, which produced a grey flash when dragging the popup.
    local pushes = {
        { reaper.ImGui_Col_ModalWindowDimBg(),   0x00000000 },
        { reaper.ImGui_Col_WindowBg(),           COL.bg },
        { reaper.ImGui_Col_ChildBg(),            COL.bg },
        { reaper.ImGui_Col_PopupBg(),            COL.popup_bg },
        { reaper.ImGui_Col_Separator(),          COL.sep },
        { reaper.ImGui_Col_FrameBg(),            COL.input_bg },
        { reaper.ImGui_Col_FrameBgHovered(),     COL.input_bg_hover },
        { reaper.ImGui_Col_FrameBgActive(),      COL.input_bg_active },
        { reaper.ImGui_Col_Button(),             COL.button_bg },
        { reaper.ImGui_Col_ButtonHovered(),      COL.button_hover },
        { reaper.ImGui_Col_ButtonActive(),       COL.button_active },
        { reaper.ImGui_Col_ScrollbarBg(),        COL.sb_bg },
        { reaper.ImGui_Col_ScrollbarGrab(),      COL.sb_grab },
        { reaper.ImGui_Col_ScrollbarGrabHovered(), COL.sb_grab_hover },
        { reaper.ImGui_Col_ScrollbarGrabActive(),  COL.sb_grab_active },
        { reaper.ImGui_Col_Border(),             COL.sep },
        { reaper.ImGui_Col_TitleBg(),            COL.bg },
        { reaper.ImGui_Col_TitleBgActive(),      COL.panel },
    }
    for _, p in ipairs(pushes) do
        reaper.ImGui_PushStyleColor(ctx, p[1], p[2])
    end

    local visible, open = reaper.ImGui_Begin(ctx, "MCAssistant##mcap", true,
        reaper.ImGui_WindowFlags_NoCollapse())

    -- ImGui rule: Begin must always be paired with End regardless of `visible`.
    local stay_open = true
    if visible then
        save_geom(ctx)

        draw_status_bar(ctx, ui)

        -- Compute log/input layout. The input strip = N rows + button + hint row.
        -- Reserve a healthy padding (28px) so the hint row at the very bottom
        -- isn't clipped by item spacing / separator height.
        local line_h  = reaper.ImGui_GetTextLineHeight(ctx)
        local input_h = line_h * INPUT_LINES + 12
        local hint_h  = line_h + 4
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local log_h   = math.max(80, avail_h - input_h - hint_h - 28)

        draw_log(ctx, ui, log_h)
        reaper.ImGui_Separator(ctx)
        draw_input(ctx, ui)

        draw_settings_popup(ctx, ui)

        if not handle_shortcuts(ctx, ui) then
            stay_open = false
        end
    end
    reaper.ImGui_End(ctx)

    reaper.ImGui_PopStyleColor(ctx, #pushes)
    reaper.ImGui_PopFont(ctx)

    return open and stay_open
end

return M

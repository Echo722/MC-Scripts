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

local image_mod  -- lazy require to avoid circular dep at load time

--------------------------------------------------------------------------------
-- constants
--------------------------------------------------------------------------------
local EXT             = "MCAssistant"
local FONT_SIZE       = 16
local FONT_SIZE_SMALL = 13
local INPUT_LINES     = 2   -- visible rows in the input box (multi-line via Ctrl+Enter)
local MIN_W, MIN_H    = 480, 380
local MSG_THUMB_MAX   = 280
local IMG_GAP         = 6
local IMG_BUBBLE_GAP  = 2

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
    popup_bg        = rgba(0.105, 0.108, 0.125),
    popup_border    = rgba(0.34,  0.35,  0.42),
    popup_title_bg  = rgba(0.26,  0.26,  0.30),
    sb_bg           = rgba(0.05,  0.05,  0.06),
    sb_grab         = rgba(0.30,  0.30,  0.34),
    sb_grab_hover   = rgba(0.40,  0.40,  0.44),
    sb_grab_active  = rgba(0.50,  0.50,  0.54),
    jump_bg         = rgba(0.20,  0.20,  0.23, 0.92),
    jump_hover      = rgba(0.30,  0.30,  0.34, 0.95),
    jump_text       = rgba(0.85,  0.85,  0.88),
    -- 0.8.3 visual polish: grouped cards + emphasized controls.
    card_bg         = rgba(0.130, 0.132, 0.150),
    card_border     = rgba(0.24,  0.25,  0.30),
    segment_on_bg   = rgba(0.70,  0.32,  0.20),   -- matches user_bubble
    segment_on_hov  = rgba(0.78,  0.36,  0.22),
    segment_off_bg  = rgba(0.165, 0.165, 0.180),
    btn_outline     = rgba(0.92,  0.92,  0.94),
    status_dot_on   = rgba(0.35,  0.78,  0.45),
    send_text       = rgba(1.00,  1.00,  1.00),
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

local function push_style_var_if(ctx, style_fn, ...)
    if not style_fn then return 0 end
    reaper.ImGui_PushStyleVar(ctx, style_fn(), ...)
    return 1
end

local function begin_card(ctx, id, height)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COL.card_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  COL.card_border)

    local vars = 0
    vars = vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_ChildRounding, 10)
    vars = vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_ChildBorderSize, 1)
    vars = vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_WindowPadding, 0, 0)

    local border_arg = 0
    if reaper.ImGui_ChildFlags_Border then
        border_arg = reaper.ImGui_ChildFlags_Border()
    end

    return reaper.ImGui_BeginChild(ctx, id, 0, height, border_arg), vars
end

local function end_card(ctx, vars)
    reaper.ImGui_EndChild(ctx)
    if vars and vars > 0 then reaper.ImGui_PopStyleVar(ctx, vars) end
    reaper.ImGui_PopStyleColor(ctx, 2)
end

local function draw_segmented_provider(ctx, value, right_pad)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx) - (right_pad or 0)
    local gap = 3
    local seg_w = math.max(96, math.floor((avail_w - gap) / 2))
    local options = {
        { label = "anthropic", value = "anthropic" },
        { label = "openai",    value = "openai" },
    }

    local vars = push_style_var_if(ctx, reaper.ImGui_StyleVar_FrameRounding, 8)
    for i, opt in ipairs(options) do
        if i > 1 then reaper.ImGui_SameLine(ctx, 0, gap) end

        local is_on = value == opt.value
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
            is_on and COL.segment_on_bg or COL.segment_off_bg)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
            is_on and COL.segment_on_hov or COL.button_hover)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
            is_on and COL.segment_on_hov or COL.button_active)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            is_on and COL.send_text or COL.assistant)

        if reaper.ImGui_Button(ctx, opt.label .. "##provider_" .. opt.value, seg_w, 32) then
            value = opt.value
        end

        reaper.ImGui_PopStyleColor(ctx, 4)
    end
    if vars > 0 then reaper.ImGui_PopStyleVar(ctx, vars) end

    return value
end

local function outline_button(ctx, label, w, h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(1.0, 1.0, 1.0, 0.08))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(1.0, 1.0, 1.0, 0.14))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.title)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        COL.btn_outline)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)

    local clicked = reaper.ImGui_Button(ctx, label, w, h)

    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 5)
    return clicked
end

local function filled_button(ctx, label, w, h)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        COL.segment_on_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COL.segment_on_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  COL.segment_on_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.send_text)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8)

    local clicked = reaper.ImGui_Button(ctx, label, w, h)

    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 4)
    return clicked
end

local function card_text(ctx, x, text)
    reaper.ImGui_SetCursorPosX(ctx, x)
    reaper.ImGui_Text(ctx, text)
end

local function card_row_label(ctx, label_x, field_x, label)
    reaper.ImGui_SetCursorPosX(ctx, label_x)
    reaper.ImGui_Text(ctx, label)
    reaper.ImGui_SameLine(ctx, field_x)
end

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
        _input_capture_cb        = nil,

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

        -- Image attachment state
        _pending_attachments     = {},  -- { {path, mime, b64, byte_count, image_id, thumb_w, thumb_h}, ... }
        _image_pool              = {},  -- event_index → image_id (history thumbnail cache)
    }
end

function M.set_web_search_state(ui, on)
    ui._web_search_on = on and true or false
end

local function is_abs_path(path)
    return type(path) == "string"
        and (path:match("^[A-Za-z]:[\\/]") or path:match("^\\\\") or path:match("^/"))
end

local function join_path(dir, name)
    if not dir or dir == "" then return name end
    if is_abs_path(name) then return name end
    local sep = dir:match("[\\/]$") and "" or "\\"
    return dir .. sep .. name
end

local function dialog_files_to_paths(files)
    local out = {}
    if type(files) == "table" then
        for _, fpath in ipairs(files) do
            if fpath and fpath ~= "" then out[#out + 1] = fpath end
        end
        return out
    end

    files = tostring(files or "")
    local parts = {}
    for part in (files .. "\0"):gmatch("([^\0]+)\0") do
        if part ~= "" then parts[#parts + 1] = part end
    end

    if #parts > 1 and not is_abs_path(parts[2]) then
        local dir = parts[1]
        for i = 2, #parts do out[#out + 1] = join_path(dir, parts[i]) end
    else
        out = parts
    end
    return out
end

local function create_image_handle(ctx, path)
    if not reaper.ImGui_CreateImage then return nil end

    local ok, img_id
    if reaper.ImGui_ImageFlags_NoErrors then
        ok, img_id = pcall(reaper.ImGui_CreateImage, path, reaper.ImGui_ImageFlags_NoErrors())
    else
        ok, img_id = pcall(reaper.ImGui_CreateImage, path)
    end
    if not ok or not img_id then return nil end

    reaper.ImGui_Attach(ctx, img_id)
    return img_id
end

local function thumb_display_size(img_id)
    local w, h = 200, 200
    if reaper.ImGui_Image_GetSize and img_id then
        local ok, iw, ih = pcall(reaper.ImGui_Image_GetSize, img_id)
        if ok and iw and ih and iw > 0 and ih > 0 then
            w, h = iw, ih
        end
    end

    local longest = math.max(w, h)
    if longest > MSG_THUMB_MAX then
        local scale = MSG_THUMB_MAX / longest
        w = math.floor(w * scale + 0.5)
        h = math.floor(h * scale + 0.5)
    end
    return w, h
end

--- Add an image file to the pending attachment strip.
-- Loads bytes, base64-encodes, creates an ImGui image handle.
function M.add_attachment(ui, path)
    if not image_mod then image_mod = require("image") end
    local data, err = image_mod.load_for_send(path)
    if not data then
        reaper.MB(tostring(err), "MCAssistant", 0)
        return
    end
    local img_id = create_image_handle(ui.ctx, path)
    local att = {
        path       = data.path,
        mime       = data.mime,
        b64        = data.b64,
        byte_count = data.byte_count,
        image_id   = img_id,
        thumb_w    = 64,
        thumb_h    = 64,
    }
    ui._pending_attachments[#ui._pending_attachments + 1] = att
end

--- Remove a pending attachment by index.
function M.remove_attachment(ui, idx)
    table.remove(ui._pending_attachments, idx)
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

local function draw_event(ctx, ui, ev, i)
    local k = ev.kind

    if k == "user" then
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local max_w = math.min(math.floor(avail_w * 0.78), 560)
        -- Draw attachment thumbnails above the text bubble.
        if ev.attachments and #ev.attachments > 0 then
            local thumbs = {}
            for ai, att in ipairs(ev.attachments) do
                if att.path then
                    -- Lazy-load image handle into the pool.
                    local pool_key = i .. "_" .. ai
                    local img_id = ui._image_pool[pool_key]
                    if img_id == nil then
                        img_id = create_image_handle(ctx, att.path)
                        ui._image_pool[pool_key] = img_id or false
                    end
                    if img_id then
                        local w, h = thumb_display_size(img_id)
                        thumbs[#thumbs + 1] = { id = img_id, w = w, h = h }
                    end
                end
            end

            if #thumbs > 0 then
                local row_w = 0
                for ti, t in ipairs(thumbs) do
                    row_w = row_w + t.w + (ti > 1 and IMG_GAP or 0)
                end
                if row_w > max_w then
                    local scale = max_w / row_w
                    row_w = 0
                    for _, t in ipairs(thumbs) do
                        t.w = math.max(1, math.floor(t.w * scale + 0.5))
                        t.h = math.max(1, math.floor(t.h * scale + 0.5))
                        row_w = row_w + t.w
                    end
                    row_w = row_w + IMG_GAP * (#thumbs - 1)
                end

                local cx = reaper.ImGui_GetCursorPosX(ctx)
                reaper.ImGui_SetCursorPosX(ctx, cx + avail_w - row_w)
                reaper.ImGui_PushStyleVar(ctx,
                    reaper.ImGui_StyleVar_ItemSpacing(), IMG_GAP, IMG_BUBBLE_GAP)
                for ti, t in ipairs(thumbs) do
                    if ti > 1 then reaper.ImGui_SameLine(ctx) end
                    reaper.ImGui_Image(ctx, t.id, t.w, t.h)
                end
                reaper.ImGui_PopStyleVar(ctx)
            end
        end
        local text = ev.text or ""
        if text ~= "" then
            render_selectable(ctx, ev, i, text, max_w, true,
                COL.user_bubble, COL.user_text, 14, true)
        end

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
    local dot_col = (ui.chat.state == "idle") and COL.status_dot_on or COL.accent
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), dot_col)
    reaper.ImGui_Text(ctx, "●")
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.dim)
    reaper.ImGui_Text(ctx, ui.chat.provider.model)
    reaper.ImGui_PopStyleColor(ctx)

    if ui.chat.state ~= "idle" then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.accent)
        reaper.ImGui_Text(ctx, " · " .. ui.chat:status_text())
        reaper.ImGui_PopStyleColor(ctx)
    end

    local btn_w   = 28
    local right_x = reaper.ImGui_GetWindowWidth(ctx) - btn_w - 12
    reaper.ImGui_SameLine(ctx, right_x)
    if reaper.ImGui_Button(ctx, "⚙##settings", btn_w, 0) then
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

            draw_event(ctx, ui, ev, i)
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

local function left_mouse_activated(ctx)
    local button = reaper.ImGui_MouseButton_Left
        and reaper.ImGui_MouseButton_Left() or 0
    local clicked = reaper.ImGui_IsMouseClicked
        and reaper.ImGui_IsMouseClicked(ctx, button)
    local released = reaper.ImGui_IsMouseReleased
        and reaper.ImGui_IsMouseReleased(ctx, button)
    return clicked or released
end

local function mouse_in_rect(ctx, x1, y1, x2, y2)
    if not reaper.ImGui_GetMousePos then return false end
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

local function draw_send_button(ctx, id, size, kind)
    kind = kind or "send"
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local clicked
    if reaper.ImGui_InvisibleButton then
        clicked = reaper.ImGui_InvisibleButton(ctx, id, size, size)
    else
        clicked = reaper.ImGui_Button(ctx, "##" .. id, size, size)
    end

    local hovered = reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx)
    local active = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
    local bg = active and rgba(0.84, 0.40, 0.25)
        or (hovered and rgba(0.78, 0.36, 0.22) or COL.user_bubble)

    if reaper.ImGui_GetWindowDrawList then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        if reaper.ImGui_DrawList_AddRectFilled then
            reaper.ImGui_DrawList_AddRectFilled(dl,
                sx, sy, sx + size, sy + size, bg, size * 0.5)
        end

        local cx = sx + size * 0.5
        local cy = sy + size * 0.5
        if kind == "stop" then
            local s = 5
            if reaper.ImGui_DrawList_AddRectFilled then
                reaper.ImGui_DrawList_AddRectFilled(dl,
                    cx - s, cy - s, cx + s, cy + s, COL.send_text, 1)
            end
        else
            if reaper.ImGui_DrawList_AddTriangleFilled then
                local s = 8
                reaper.ImGui_DrawList_AddTriangleFilled(dl,
                    cx - s * 0.45, cy - s,
                    cx - s * 0.45, cy + s,
                    cx + s * 0.85, cy,
                    COL.send_text)
            end
        end
    end

    if not clicked and mouse_in_rect(ctx, sx, sy, sx + size, sy + size)
        and left_mouse_activated(ctx) then
        clicked = true
    end

    return clicked
end

local INPUT_BTN_SIZE   = 40
local INPUT_PILL_MIN_H = 56
local INPUT_MAX_LINES  = 5

local function count_lines(s)
    if not s or s == "" then return 1 end
    local n = 1
    for _ in s:gmatch("\n") do n = n + 1 end
    return n
end

-- Returns visible_text_h, pill_h, stacked.
-- ChatGPT-style: pill grows vertically up to INPUT_MAX_LINES lines, then the
-- inner InputTextMultiline scrolls. For single-line input we keep the compact
-- centered capsule; multi-line switches to a stacked layout (text on top,
-- buttons anchored at the bottom).
local function compute_input_metrics(ctx, ui)
    local line_h    = reaper.ImGui_GetTextLineHeight(ctx)
    local raw_lines = count_lines(ui.input_buf)
    local n_lines   = math.min(INPUT_MAX_LINES, math.max(1, raw_lines))
    local stacked   = n_lines > 1
    local text_h, pill_h
    if stacked then
        text_h = n_lines * line_h + 8
        pill_h = text_h + INPUT_BTN_SIZE + 24
    else
        text_h = 30
        pill_h = INPUT_PILL_MIN_H
    end
    return text_h, pill_h, stacked
end

-- Clear the InputText buffer. We can only reset the Lua-side string; ImGui
-- keeps its own internal copy of the InputText buffer and will redisplay it
-- on the next frame. The stable workaround is to avoid rendering the
-- InputTextMultiline widget at all in the busy branch (see draw_input_stable
-- below) — that combination of EEL CallbackAlways + ReadOnly on the same
-- widget has been observed to take the GPU driver down hard enough to
-- trigger a Windows TDR BSOD on this machine.
--
-- Note: the EEL capture callback itself must be ImGui_Attach'd to the ctx
-- at creation (see draw_input_stable), otherwise it gets GC'd mid-stream
-- and the next InputTextMultiline call dereferences a stale pointer.
-- Keep this function trivial.
local function clear_input_buf(ui)
    ui.input_buf = ""
end

local function submit_input(ui)
    if ui.chat.state ~= "idle" then return false end

    local t = trim(ui.input_buf)
    local has_att = #ui._pending_attachments > 0
    if t == "" and not has_att then return false end

    local attachments = nil
    if has_att then
        attachments = {}
        for _, att in ipairs(ui._pending_attachments) do
            attachments[#attachments + 1] = {
                mime = att.mime,
                b64  = att.b64,
                path = att.path,
            }
        end
        ui._pending_attachments = {}
    end

    ui.chat:send_user(t, attachments)
    clear_input_buf(ui)
    return true
end

-- Draw the horizontal thumbnail strip for pending attachments above the input.
-- Each thumbnail is 64×64 with an ✕ remove button at the top-right corner.
-- If the current model doesn't support vision, a ⚠ warning is shown at the end.
local function draw_pending_strip(ctx, ui)
    local atts = ui._pending_attachments
    if #atts == 0 then return end

    local strip_h = 72
    if reaper.ImGui_BeginChild(ctx, "att_strip", 0, strip_h) then
        for i, att in ipairs(atts) do
            if i > 1 then reaper.ImGui_SameLine(ctx) end
            -- Thumbnail
            local thumb_x = reaper.ImGui_GetCursorPosX(ctx)
            local thumb_y = reaper.ImGui_GetCursorPosY(ctx)
            if att.image_id then
                reaper.ImGui_Image(ctx, att.image_id, 64, 64)
            else
                reaper.ImGui_Dummy(ctx, 64, 64)
            end
            -- ✕ remove button at top-right corner of the thumbnail.
            reaper.ImGui_SetCursorPos(ctx, thumb_x + 46, thumb_y)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(0.9, 0.3, 0.3, 0.6))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(0.9, 0.3, 0.3, 0.8))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          rgba(1.0, 1.0, 1.0, 0.9))
            if reaper.ImGui_Button(ctx, "✕##rmatt" .. i, 18, 18) then
                M.remove_attachment(ui, i)
            end
            reaper.ImGui_PopStyleColor(ctx, 4)
            -- Restore cursor after the ✕ button so the next thumbnail starts correctly.
            reaper.ImGui_SetCursorPos(ctx, thumb_x + 64, thumb_y)
        end

        -- Vision warning if model doesn't support it.
        local provider = ui.chat.provider
        if provider and provider.model then
            local prov_mod = require("provider")
            if not prov_mod.model_supports_vision(provider.model) then
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.accent)
                reaper.ImGui_Text(ctx, "  ⚠ 当前模型可能不支持图像")
                reaper.ImGui_PopStyleColor(ctx)
            end
        end
    end
    reaper.ImGui_EndChild(ctx)
end

local function draw_input(ctx, ui)
    local is_busy = ui.chat.state ~= "idle"
    local input_h = 56
    local btn_size = 40

    local flags = reaper.ImGui_InputTextFlags_CtrlEnterForNewLine()
                | reaper.ImGui_InputTextFlags_EnterReturnsTrue()
    if is_busy then
        flags = flags | reaper.ImGui_InputTextFlags_ReadOnly()
    end

    local should_send = false

    local child_flags = 0
    if reaper.ImGui_ChildFlags_Border then
        child_flags = reaper.ImGui_ChildFlags_Border()
    end

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COL.input_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  COL.sep)
    local child_vars = 0
    child_vars = child_vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_ChildRounding, 28)
    child_vars = child_vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_ChildBorderSize, 1)
    child_vars = child_vars + push_style_var_if(ctx, reaper.ImGui_StyleVar_WindowPadding, 8, 8)

    if reaper.ImGui_BeginChild(ctx, "input_pill", 0, input_h, child_flags) then
        local start_x = reaper.ImGui_GetCursorPosX(ctx)
        local inner_y = reaper.ImGui_GetCursorPosY(ctx)
        local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
        local center_y = inner_y + input_h * 0.5
        local text_h = 30
        local btn_y = center_y - btn_size * 0.5
        local sep_h = 30
        local sep_y = center_y - sep_h * 0.5
        local text_y = center_y - text_h * 0.5
        local plus_x = start_x
        local sep_x = plus_x + btn_size + 6
        local text_x = sep_x + 13
        local send_x = start_x + math.max(0, avail_w - btn_size)
        local text_w = math.max(40, send_x - text_x - 8)

        if is_busy then
            reaper.ImGui_SetCursorPos(ctx, plus_x, btn_y)
            reaper.ImGui_Dummy(ctx, btn_size, btn_size)
        else
            reaper.ImGui_SetCursorPos(ctx, plus_x, btn_y)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(1.0, 1.0, 1.0, 0.08))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(1.0, 1.0, 1.0, 0.14))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.title)
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 18)
            reaper.ImGui_PushFont(ctx, ui.font, 24)
            if reaper.ImGui_Button(ctx, "+##attach", btn_size, btn_size) then
                if reaper.JS_Dialog_BrowseForOpenFiles then
                    local ok, files = reaper.JS_Dialog_BrowseForOpenFiles(
                        "选择图片", "", "",
                        "PNG/JPG/GIF/WebP\0*.png;*.jpg;*.jpeg;*.gif;*.webp\0\0",
                        true)  -- allowMulti
                    if ok and files then
                        for _, fpath in ipairs(dialog_files_to_paths(files)) do
                            M.add_attachment(ui, fpath)
                        end
                    end
                end
            end
            reaper.ImGui_PopFont(ctx)
            reaper.ImGui_PopStyleVar(ctx)
            reaper.ImGui_PopStyleColor(ctx, 4)
        end

        reaper.ImGui_SetCursorPos(ctx, sep_x, sep_y)
        if reaper.ImGui_GetCursorScreenPos and reaper.ImGui_GetWindowDrawList
            and reaper.ImGui_DrawList_AddRectFilled then
            local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
            local dl = reaper.ImGui_GetWindowDrawList(ctx)
            reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx + 1, sy + sep_h, COL.sep)
        end
        reaper.ImGui_Dummy(ctx, 1, sep_h)

        reaper.ImGui_SetCursorPos(ctx, text_x, text_y)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x00000000)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 4)
        local old_buf = ui.input_buf
        local rv, new_buf = reaper.ImGui_InputTextMultiline(ctx, "##input",
            old_buf, text_w, text_h, flags)
        if rv and not is_busy then should_send = true end
        local input_active = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
        local input_focused = reaper.ImGui_IsItemFocused and reaper.ImGui_IsItemFocused(ctx)
        local input_edited = reaper.ImGui_IsItemEdited and reaper.ImGui_IsItemEdited(ctx)
        new_buf = new_buf or old_buf
        if input_active or input_focused or input_edited or new_buf ~= "" or old_buf == "" then
            ui.input_buf = new_buf
        end
        local ix, iy = 0, 0
        if reaper.ImGui_GetItemRectMin then
            ix, iy = reaper.ImGui_GetItemRectMin(ctx)
        end
        reaper.ImGui_PopStyleVar(ctx, 3)
        reaper.ImGui_PopStyleColor(ctx, 3)

        if ui.input_buf == "" and not is_busy and not input_active and not input_focused then
            if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddText then
                local dl = reaper.ImGui_GetWindowDrawList(ctx)
                reaper.ImGui_DrawList_AddText(dl, ix, iy + 5, COL.very_dim,
                    "输入消息…")
            end
        end

        reaper.ImGui_SetCursorPos(ctx, send_x, btn_y)
        if is_busy then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                rgba(0.28, 0.12, 0.10))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                rgba(0.36, 0.16, 0.13))
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                rgba(0.96, 0.58, 0.50))
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 20)
            reaper.ImGui_PushFont(ctx, ui.font, 18)
            if reaper.ImGui_Button(ctx, "■##stop", btn_size, btn_size) then
                cancel_busy(ui)
            end
            reaper.ImGui_PopFont(ctx)
            reaper.ImGui_PopStyleVar(ctx)
            reaper.ImGui_PopStyleColor(ctx, 3)
        else
            if draw_send_button(ctx, "send_button", btn_size) then
                submit_input(ui)
            end
        end
    end

    reaper.ImGui_EndChild(ctx)
    if child_vars > 0 then reaper.ImGui_PopStyleVar(ctx, child_vars) end
    reaper.ImGui_PopStyleColor(ctx, 2)

    -- hint row
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.very_dim)
    if is_busy then
        reaper.ImGui_Text(ctx, "AI 正在生成…  Esc 停止")
    else
        local att_hint = #ui._pending_attachments > 0
            and (" · 📎 " .. #ui._pending_attachments .. " 张图") or ""
        reaper.ImGui_Text(ctx, "Enter 发送 · Ctrl+Enter 换行 · 拖选可复制 · Ctrl+L 清屏 · ")
        reaper.ImGui_SameLine(ctx, 0, 0)
        local dot_col = ui._web_search_on and COL.status_dot_on or COL.very_dim
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), dot_col)
        reaper.ImGui_Text(ctx, "●")
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_Text(ctx,
            "搜索: " .. (ui._web_search_on and "ON" or "OFF") .. att_hint)
    end
    reaper.ImGui_PopStyleColor(ctx)

    if should_send then submit_input(ui) end
end

local function draw_input_stable(ctx, ui)
    local is_busy = ui.chat.state ~= "idle"
    local text_h, input_h, stacked = compute_input_metrics(ctx, ui)
    local btn_size = INPUT_BTN_SIZE

    local flags = reaper.ImGui_InputTextFlags_CtrlEnterForNewLine()
                | reaper.ImGui_InputTextFlags_EnterReturnsTrue()
    -- IMPORTANT: Only attach the EEL CallbackAlways function in the idle
    -- branch. The combination of CallbackAlways + ReadOnly on the same
    -- InputTextMultiline widget has been observed to trigger a Windows TDR
    -- BSOD on this machine when the user clicks the window during the AI
    -- generation stage. The busy branch below skips InputTextMultiline
    -- entirely (renders the buffer as static text), so neither flag is set.
    if (not is_busy)
        and reaper.ImGui_CreateFunctionFromEEL
        and reaper.ImGui_InputTextFlags_CallbackAlways then
        if not ui._input_capture_cb then
            ui._input_capture_cb = reaper.ImGui_CreateFunctionFromEEL([[
                strcpy(#LastBuf, #Buf);
            ]])
            -- Must attach to ctx — otherwise ReaImGui GCs the EEL function
            -- under string-allocation pressure (e.g. mid AI streaming) and the
            -- next InputTextMultiline call sees a stale pointer:
            --   "ImGui_InputTextMultiline: expected a valid ImGui_Function*"
            -- Same lifetime pattern as fonts (ui.lua:400) and images (ui.lua:487).
            if ui._input_capture_cb and reaper.ImGui_Attach then
                reaper.ImGui_Attach(ctx, ui._input_capture_cb)
            end
        end
        flags = flags | reaper.ImGui_InputTextFlags_CallbackAlways()
    end

    local should_send = false
    local base_x = reaper.ImGui_GetCursorPosX(ctx)
    local initial_y = reaper.ImGui_GetCursorPosY(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local line_h = reaper.ImGui_GetTextLineHeight(ctx)
    -- Anchor the hint to the very bottom of the window, and float the pill
    -- just above it. Any slack space pushes the pill down rather than leaving
    -- whitespace below the hint.
    local hint_y = initial_y + avail_h - line_h - 4
    local pill_y = hint_y - 8 - input_h
    if pill_y < initial_y then pill_y = initial_y end
    reaper.ImGui_SetCursorPos(ctx, base_x, pill_y)
    local base_y = pill_y

    local pill_w = math.max(160, avail_w)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)

    if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddRectFilled then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy,
            sx + pill_w, sy + input_h, COL.input_bg, 28)
        if reaper.ImGui_DrawList_AddRect then
            reaper.ImGui_DrawList_AddRect(dl, sx, sy,
                sx + pill_w, sy + input_h, COL.sep, 28, 0, 1)
        end
    end

    local center_y = base_y + input_h * 0.5
    local plus_x = base_x + 8
    local send_x = base_x + pill_w - btn_size - 8
    local sep_x = plus_x + btn_size + 6
    local btn_y, sep_h, sep_y, text_y, text_x, text_w
    if stacked then
        -- ChatGPT-style: text fills the top area, + and send sit at the
        -- bottom corners; no vertical separator (the multi-line text is
        -- already visually distinct from the button row).
        btn_y  = base_y + input_h - btn_size - 8
        text_y = base_y + 10
        text_x = base_x + 16
        text_w = math.max(40, pill_w - 32)
        sep_h  = 0
        sep_y  = 0
    else
        -- Single-line capsule: text + buttons centered on one row, with a
        -- thin vertical separator between the + button and the text.
        btn_y  = center_y - btn_size * 0.5
        sep_h  = 30
        sep_y  = center_y - sep_h * 0.5
        text_y = center_y - text_h * 0.5
        text_x = sep_x + 13
        text_w = math.max(40, send_x - text_x - 8)
    end

    if is_busy then
        reaper.ImGui_SetCursorPos(ctx, plus_x, btn_y)
        reaper.ImGui_Dummy(ctx, btn_size, btn_size)
    else
        reaper.ImGui_SetCursorPos(ctx, plus_x, btn_y)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(1.0, 1.0, 1.0, 0.08))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(1.0, 1.0, 1.0, 0.14))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.title)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 18)
        reaper.ImGui_PushFont(ctx, ui.font, 24)
        if reaper.ImGui_Button(ctx, "+##attach_stable", btn_size, btn_size) then
            if reaper.JS_Dialog_BrowseForOpenFiles then
                local ok, files = reaper.JS_Dialog_BrowseForOpenFiles(
                    "选择图片", "", "",
                    "PNG/JPG/GIF/WebP\0*.png;*.jpg;*.jpeg;*.gif;*.webp\0\0",
                    true)
                if ok and files then
                    for _, fpath in ipairs(dialog_files_to_paths(files)) do
                        M.add_attachment(ui, fpath)
                    end
                end
            end
        end
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_PopStyleVar(ctx)
        reaper.ImGui_PopStyleColor(ctx, 4)
    end

    if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddRectFilled then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl,
            sx + (sep_x - base_x), sy + (sep_y - base_y),
            sx + (sep_x - base_x) + 1, sy + (sep_y - base_y) + sep_h,
            COL.sep)
    end

    reaper.ImGui_SetCursorPos(ctx, text_x, text_y)
    if not is_busy then
        -- idle: real, editable InputTextMultiline with EEL capture callback
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x00000000)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 4)
        local prev_buf = ui.input_buf or ""
        local rv, new_buf = reaper.ImGui_InputTextMultiline(ctx, "##input_main",
            prev_buf, text_w, text_h, flags, ui._input_capture_cb)
        if rv then should_send = true end
        local input_active = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
        local input_focused = reaper.ImGui_IsItemFocused and reaper.ImGui_IsItemFocused(ctx)
        if ui._input_capture_cb and reaper.ImGui_Function_GetValue_String then
            local captured = reaper.ImGui_Function_GetValue_String(ui._input_capture_cb, "#LastBuf")
            if captured and (captured ~= "" or input_active or input_focused) then
                new_buf = captured
            end
        end
        new_buf = new_buf or prev_buf
        if new_buf == "" and prev_buf ~= "" and not input_active and not input_focused then
            ui.input_buf = prev_buf
        else
            ui.input_buf = new_buf
        end
        local ix, iy = 0, 0
        if reaper.ImGui_GetItemRectMin then
            ix, iy = reaper.ImGui_GetItemRectMin(ctx)
        end
        reaper.ImGui_PopStyleVar(ctx, 3)
        reaper.ImGui_PopStyleColor(ctx, 3)

        if ui.input_buf == "" and not input_active and not input_focused then
            if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddText then
                local dl = reaper.ImGui_GetWindowDrawList(ctx)
                reaper.ImGui_DrawList_AddText(dl, ix, iy + 5, COL.very_dim, "输入消息...")
            end
        end
    else
        -- busy: do NOT render InputTextMultiline. Just draw the buffer as
        -- static text and reserve the same vertical slot via Dummy(). Avoids
        -- the CallbackAlways + ReadOnly combination that BSODs the machine
        -- when the user clicks during AI generation.
        local sx0, sy0 = reaper.ImGui_GetCursorScreenPos(ctx)
        if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddText then
            local dl = reaper.ImGui_GetWindowDrawList(ctx)
            local display = (ui.input_buf and ui.input_buf ~= "")
                and ui.input_buf or "AI 生成中，请稍候…"
            reaper.ImGui_DrawList_AddText(dl, sx0, sy0 + 5, COL.very_dim, display)
        end
        reaper.ImGui_Dummy(ctx, text_w, text_h)
    end

    reaper.ImGui_SetCursorPos(ctx, send_x, btn_y)
    if is_busy then
        if draw_send_button(ctx, "stop_button_stable", btn_size, "stop") then
            cancel_busy(ui)
        end
    else
        if draw_send_button(ctx, "send_button_stable", btn_size) then
            submit_input(ui)
        end
    end

    reaper.ImGui_SetCursorPos(ctx, base_x, hint_y)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.very_dim)
    if is_busy then
        reaper.ImGui_Text(ctx, "AI 正在生成... Esc 停止")
    else
        local att_hint = #ui._pending_attachments > 0
            and (" · " .. #ui._pending_attachments .. " 张图") or ""
        reaper.ImGui_Text(ctx, "Enter 发送 · Ctrl+Enter 换行 · 拖选可复制 · Ctrl+L 清屏 · ")
        reaper.ImGui_SameLine(ctx, 0, 0)
        local dot_col = ui._web_search_on and COL.status_dot_on or COL.very_dim
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), dot_col)
        reaper.ImGui_Text(ctx, "●")
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_SameLine(ctx, 0, 4)
        reaper.ImGui_Text(ctx,
            "搜索: " .. (ui._web_search_on and "ON" or "OFF") .. att_hint)
    end
    reaper.ImGui_PopStyleColor(ctx)

    if should_send then submit_input(ui) end
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

    reaper.ImGui_SetNextWindowSize(ctx, 560, 580,
        reaper.ImGui_Cond_Appearing())
    if reaper.ImGui_SetNextWindowSizeConstraints then
        reaper.ImGui_SetNextWindowSizeConstraints(ctx, 520, 520, 10000, 10000)
    end

    -- Popup-specific styling so the settings window reads as a lifted panel.
    -- Title bar is drawn manually to match the 0.8.3 visual direction.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  COL.popup_border)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), COL.popup_bg)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),   8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),    6)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(),  1)

    local flags = 0
    if reaper.ImGui_WindowFlags_NoTitleBar then
        flags = flags | reaper.ImGui_WindowFlags_NoTitleBar()
    end
    if reaper.ImGui_WindowFlags_NoScrollbar then
        flags = flags | reaper.ImGui_WindowFlags_NoScrollbar()
    end
    if reaper.ImGui_WindowFlags_NoScrollWithMouse then
        flags = flags | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    end

    if not reaper.ImGui_BeginPopupModal(ctx, SETTINGS_POPUP, nil, flags) then
        reaper.ImGui_PopStyleVar(ctx, 4)
        reaper.ImGui_PopStyleColor(ctx, 2)
        return
    end

    reaper.ImGui_PushFont(ctx, ui.font, 18)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.title)
    reaper.ImGui_Text(ctx, "MCAssistant 设置")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopFont(ctx)

    local close_x = reaper.ImGui_GetWindowWidth(ctx) - 42
    reaper.ImGui_SameLine(ctx, close_x)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), rgba(1.0, 1.0, 1.0, 0.08))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  rgba(1.0, 1.0, 1.0, 0.14))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          COL.dim)
    if reaper.ImGui_Button(ctx, "✕##settings_close", 28, 28) then
        reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 4)

    reaper.ImGui_Dummy(ctx, 1, 10)

    local label_x = 28
    local field_x = 150
    local right_pad = 24
    local api_visible, api_vars = begin_card(ctx, "card_api", 230)
    if api_visible then
        reaper.ImGui_Dummy(ctx, 1, 12)
        reaper.ImGui_PushFont(ctx, ui.font, 18)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.title)
        card_text(ctx, label_x, "API")
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopFont(ctx)

        reaper.ImGui_Dummy(ctx, 1, 8)
        card_row_label(ctx, label_x, field_x, "Provider")
        ui._draft_type = draw_segmented_provider(ctx, ui._draft_type, right_pad)

        reaper.ImGui_Dummy(ctx, 1, 7)
        card_row_label(ctx, label_x, field_x, "Base URL")
        reaper.ImGui_PushItemWidth(ctx, -right_pad)
        local _, new_url = reaper.ImGui_InputText(ctx, "##base_url", ui._draft_base_url)
        ui._draft_base_url = new_url
        reaper.ImGui_PopItemWidth(ctx)

        reaper.ImGui_Dummy(ctx, 1, 5)
        card_row_label(ctx, label_x, field_x, "Model")
        reaper.ImGui_PushItemWidth(ctx, -right_pad)
        local _, new_model = reaper.ImGui_InputText(ctx, "##model", ui._draft_model)
        ui._draft_model = new_model
        reaper.ImGui_PopItemWidth(ctx)

        reaper.ImGui_Dummy(ctx, 1, 5)
        card_row_label(ctx, label_x, field_x, "API key")
        local key_flags = ui._show_api_key and 0
                        or reaper.ImGui_InputTextFlags_Password()
        reaper.ImGui_PushItemWidth(ctx, -(right_pad + 84))
        local _, new_key = reaper.ImGui_InputText(ctx, "##api_key",
            ui._draft_api_key, key_flags)
        ui._draft_api_key = new_key
        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, (ui._show_api_key and "隐藏" or "显示") .. "##sk", 76, 0) then
            ui._show_api_key = not ui._show_api_key
        end
    end
    end_card(ctx, api_vars)

    reaper.ImGui_Dummy(ctx, 1, 10)
    local search_h = 172
    local search_visible, search_vars = begin_card(ctx, "card_search", search_h)
    if search_visible then
        reaper.ImGui_Dummy(ctx, 1, 12)
        reaper.ImGui_PushFont(ctx, ui.font, 18)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.title)
        card_text(ctx, label_x, "联网搜索")
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopFont(ctx)

        reaper.ImGui_Dummy(ctx, 1, 8)
        reaper.ImGui_SetCursorPosX(ctx, label_x)
        local label = ui._web_search_on and "●  ON" or "OFF"
        local pill_bg   = ui._web_search_on and COL.pill_on_bg   or COL.pill_off_bg
        local pill_text = ui._web_search_on and COL.pill_on_text or COL.pill_off_text
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        pill_bg)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), pill_bg)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          pill_text)
        if reaper.ImGui_Button(ctx, label .. "##search_toggle", 88, 36) then
            if ui.on_toggle_search then ui.on_toggle_search(false) end
        end
        reaper.ImGui_PopStyleColor(ctx, 3)
        reaper.ImGui_PopStyleVar(ctx)

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL.dim)
        reaper.ImGui_Text(ctx, ui._web_search_on and "Tavily 搜索已开启" or "已关闭")
        reaper.ImGui_PopStyleColor(ctx)

        reaper.ImGui_Dummy(ctx, 1, 9)
        card_row_label(ctx, label_x, field_x, "Search key")
        local skey_flags = ui._show_search_key and 0
                         or reaper.ImGui_InputTextFlags_Password()
        reaper.ImGui_PushItemWidth(ctx, -(right_pad + 84))
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
        reaper.ImGui_SetCursorPosX(ctx, label_x)
        reaper.ImGui_TextWrapped(ctx,
            "Tavily 免费 1000 次/月  ·  tvly-... 形式  ·  留空则模型不能联网搜索")
        reaper.ImGui_PopStyleColor(ctx)
    end
    end_card(ctx, search_vars)

    reaper.ImGui_Dummy(ctx, 1, 12)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local footer_w = 90 + 110 + 12
    reaper.ImGui_Dummy(ctx, math.max(1, avail - footer_w), 1)
    reaper.ImGui_SameLine(ctx)
    if outline_button(ctx, "取消", 90, 36)
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if filled_button(ctx, "保存", 110, 36) then
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
    reaper.ImGui_PopStyleVar(ctx, 4)   -- WindowBorderSize, WindowRounding, FrameRounding, FrameBorderSize
    reaper.ImGui_PopStyleColor(ctx, 2) -- Border, PopupBg
end

--------------------------------------------------------------------------------
-- shortcuts
--------------------------------------------------------------------------------
local function handle_shortcuts(ctx, ui)
    -- Ctrl+V: paste image from clipboard (only when not busy)
    if ui.chat.state == "idle" then
        local ctrl_v = reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_V()
        if reaper.ImGui_IsKeyChordPressed(ctx, ctrl_v) then
            if not image_mod then image_mod = require("image") end
            local path = image_mod.paste_clipboard()
            if path then
                M.add_attachment(ui, path)
            end
        end
    end

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
            clear_input_buf(ui)
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
        -- isn't clipped by item spacing / separator height. The input height
        -- grows with the typed line count (capped at INPUT_MAX_LINES).
        local line_h  = reaper.ImGui_GetTextLineHeight(ctx)
        local _, input_h = compute_input_metrics(ctx, ui)
        local hint_h  = line_h + 4
        local strip_h = #ui._pending_attachments > 0 and 72 or 0
        local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local log_h   = math.max(80, avail_h - input_h - hint_h - strip_h - 28)

        draw_log(ctx, ui, log_h)

        -- Drag-drop target for the chat log area.
        if reaper.ImGui_BeginDragDropTarget(ctx) then
            local ok_files, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
            if ok_files and count and count > 0 then
                if not image_mod then image_mod = require("image") end
                for i = 0, count - 1 do
                    local ok_file, fpath = reaper.ImGui_GetDragDropPayloadFile(ctx, i)
                    if ok_file and fpath and fpath ~= "" and image_mod.infer_mime(fpath) then
                        M.add_attachment(ui, fpath)
                    end
                end
            end
            reaper.ImGui_EndDragDropTarget(ctx)
        end

        reaper.ImGui_Separator(ctx)

        draw_pending_strip(ctx, ui)
        draw_input_stable(ctx, ui)

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

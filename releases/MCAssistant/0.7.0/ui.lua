--
-- ui.lua  —  gfx-based chat panel with in-panel text input.
-- Claude-desktop-inspired dark theme.
--
-- Layout:
--   [ status bar (BAR_H, ⚙ settings click target on right) ]
--   [ message log, scrollable ]
--   [ input strip (auto-grow up to MAX_INPUT_LINES, hint row at bottom) ]
--

local json = require("json")

local M = {}

local function set_color(r, g, b, a)
    gfx.r, gfx.g, gfx.b, gfx.a = r, g, b, a or 1
end

local PALETTE = {
    bg                = { 0.071, 0.071, 0.075 },
    panel_bg          = { 0.090, 0.090, 0.094 },
    bar_bg            = { 0.071, 0.071, 0.075 },
    bar_text          = { 0.93,  0.93,  0.94  },
    bar_text_dim      = { 0.46,  0.46,  0.50  },
    user_bubble_bg    = { 0.165, 0.165, 0.180 },
    user_text         = { 0.93,  0.93,  0.95  },
    assistant_text    = { 0.86,  0.87,  0.89  },
    assistant_live    = { 0.94,  0.86,  0.66  },
    dot_dim           = { 0.30,  0.30,  0.32  },
    dot_bright        = { 0.78,  0.78,  0.80  },
    tool_bg           = { 0.085, 0.115, 0.100 },
    tool_text         = { 0.55,  0.78,  0.62  },
    tool_dim_text     = { 0.38,  0.55,  0.45  },
    error_bg          = { 0.18,  0.09,  0.09  },
    error_text        = { 0.95,  0.58,  0.58  },
    input_bg          = { 0.105, 0.105, 0.110 },
    input_border      = { 0.24,  0.24,  0.28  },
    input_text        = { 0.93,  0.93,  0.95  },
    input_placeholder = { 0.42,  0.42,  0.46  },
    caret             = { 0.96,  0.62,  0.36  },
    sep               = { 0.13,  0.13,  0.15  },
    scrollbar         = { 0.16,  0.16,  0.18  },
    scrollbar_thumb   = { 0.34,  0.34,  0.38  },
    cancel_bg         = { 0.28,  0.12,  0.10  },
    cancel_text       = { 0.96,  0.58,  0.50  },
    jump_bg           = { 0.20,  0.20,  0.23  },
    jump_text         = { 0.82,  0.82,  0.84  },
    gear_dim          = { 0.46,  0.46,  0.50  },
    gear_bright       = { 0.86,  0.86,  0.88  },
    claude_orange     = { 0.85,  0.47,  0.34  },  -- ≈ #D97757, matches Claude desktop spinner
}

local PAD             = 14
local GAP             = 10
local ROLE_GAP        = 16  -- extra vertical air between a user→assistant turn boundary
local MARGIN          = 16
local BAR_H           = 36
local MAX_INPUT_LINES = 6
local HINT_H          = 18
local INPUT_VPAD      = 8
local SPINNER_SIZE    = 30  -- ✱ glyph size (matches font_size + 14 default)

-- Cycling phrases shown next to the ✱ spinner while waiting for the AI.
local THINKING_PHRASES = {
    "思考中…",
    "琢磨中…",
    "整理思路…",
    "推敲中…",
    "组织语言…",
}
local THINKING_CYCLE = 2.5  -- seconds between phrase swaps

local function utf8_byte_count(b)
    if b >= 0xF0 then return 4
    elseif b >= 0xE0 then return 3
    elseif b >= 0xC0 then return 2
    else return 1 end
end

-- gfx.getchar() returns these magic numbers for non-textual special keys.
local SPECIAL_KEYS = {
    [127]        = true, -- DEL
    [9]          = true, -- Tab
    [30064]      = true, -- Up
    [1685026670] = true, -- Down
    [1818584692] = true, -- Left
    [1919379572] = true, -- Right
    [1885828464] = true, -- PageUp
    [1885824110] = true, -- PageDown
    [1752132965] = true, -- Home
    [6647396]    = true, -- End
    [6909555]    = true, -- Insert
    [6579564]    = true, -- Delete
}

local function codepoint_to_utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + (cp >> 6),
                           0x80 + (cp & 0x3F))
    end
    if cp < 0x10000 then
        return string.char(0xE0 + (cp >> 12),
                           0x80 + ((cp >> 6) & 0x3F),
                           0x80 + (cp & 0x3F))
    end
    return string.char(0xF0 + (cp >> 18),
                       0x80 + ((cp >> 12) & 0x3F),
                       0x80 + ((cp >> 6) & 0x3F),
                       0x80 + (cp & 0x3F))
end

local function utf8_pop_back(s)
    if s == "" then return s end
    local i = #s
    while i > 1 do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i - 1)
end

local function wrap_line(line, max_w)
    if line == "" then return { "" } end
    local out = {}
    local cur = ""
    local i = 1
    while i <= #line do
        local b = line:byte(i) or 0
        local len = utf8_byte_count(b)
        local c = line:sub(i, i + len - 1)
        local w = gfx.measurestr(cur .. c)
        if w > max_w and cur ~= "" then
            out[#out + 1] = cur
            cur = c
        else
            cur = cur .. c
        end
        i = i + len
    end
    if cur ~= "" then out[#out + 1] = cur end
    return out
end

local function wrap_text(text, max_w)
    local lines = {}
    for chunk in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
        for _, w in ipairs(wrap_line(chunk, max_w)) do
            lines[#lines + 1] = w
        end
    end
    return lines
end

local function summarize_tool_input(input)
    if type(input) ~= "table" then return "" end
    local parts = {}
    for k, v in pairs(input) do
        local sv
        if type(v) == "table" then sv = "[...]"
        elseif type(v) == "string" then sv = '"' .. v:sub(1, 40) .. (v:len() > 40 and "…" or "") .. '"'
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
        local ok_enc, encoded = pcall(json.encode, output)
        return ok_enc and (encoded:sub(1, 80)) or "✓"
    end
    return "✓ " .. table.concat(hints, "  ")
end

local function bubble_config(ev)
    local kind = ev.kind
    if kind == "user" then
        return PALETTE.user_bubble_bg, PALETTE.user_text, "right", 0.72
    elseif kind == "assistant" then
        local tc = ev.live and PALETTE.assistant_live or PALETTE.assistant_text
        return PALETTE.bg, tc, "left", 1.0
    elseif kind == "tool_call" then
        return PALETTE.tool_bg, PALETTE.tool_text, "left", 1.0
    elseif kind == "tool_result" then
        return PALETTE.tool_bg, PALETTE.tool_dim_text, "left", 1.0
    elseif kind == "search_status" then
        -- Ephemeral "🔍 搜索中…" row — borrow the tool palette so it reads
        -- as a sibling of tool_call rows without competing with the
        -- assistant text bubble below it.
        return PALETTE.tool_bg, PALETTE.tool_dim_text, "left", 1.0
    elseif kind == "error" then
        return PALETTE.error_bg, PALETTE.error_text, "left", 1.0
    end
    return PALETTE.bg, PALETTE.assistant_text, "left", 1.0
end

local function event_label(ev)
    if ev.kind == "user"          then return "" end
    -- Claude desktop renders AI messages without a sender label — just plain
    -- text on the page. We follow that.
    if ev.kind == "assistant"     then return "" end
    if ev.kind == "tool_call"     then return "⚙ " .. ev.name end
    if ev.kind == "tool_result"   then return "← " .. ev.name end
    if ev.kind == "search_status" then return "" end
    if ev.kind == "error"         then return "错误" end
    return ""
end

-- Format ev.sources (list of {url, title}) as a trailing block appended to an
-- assistant message body. Empty/nil sources → empty string (no separator).
local function format_sources(sources)
    if not sources or #sources == 0 then return "" end
    local lines = { "", "来源:" }
    for i, s in ipairs(sources) do
        local title = s.title or s.url or ""
        local url   = s.url or ""
        -- "[1] Title — https://example.com/path"  (wrap_text will break long
        -- URLs across lines if the bubble is narrow).
        if title ~= "" and title ~= url then
            lines[#lines + 1] = ("[%d] %s — %s"):format(i, title, url)
        else
            lines[#lines + 1] = ("[%d] %s"):format(i, url)
        end
    end
    return table.concat(lines, "\n")
end

local function event_body(ev)
    if ev.kind == "user"          then return ev.text end
    if ev.kind == "assistant"     then return (ev.text or "") .. format_sources(ev.sources) end
    if ev.kind == "tool_call"     then return summarize_tool_input(ev.input) end
    if ev.kind == "tool_result"   then return summarize_tool_output(ev.output) end
    if ev.kind == "search_status" then return ev.text or "" end
    if ev.kind == "error"         then return ev.text end
    return ""
end

local function draw_dot(cx, cy)
    if gfx.circle then
        gfx.circle(cx, cy, 3, 1, 1)
    else
        gfx.rect(cx - 1, cy - 2, 3, 5, 1)
        gfx.rect(cx - 2, cy - 1, 5, 3, 1)
    end
end

-- Filled rounded rectangle: two rectangles + four anti-aliased corner circles.
local function draw_rounded_rect_filled(x, y, w, h, r)
    if r <= 0 or w < 2 * r or h < 2 * r then
        gfx.rect(x, y, w, h, 1)
        return
    end
    gfx.rect(x + r, y,         w - 2 * r, h,         1)
    gfx.rect(x,     y + r,     w,         h - 2 * r, 1)
    if gfx.circle then
        gfx.circle(x + r,         y + r,         r, 1, 1)
        gfx.circle(x + w - r - 1, y + r,         r, 1, 1)
        gfx.circle(x + r,         y + h - r - 1, r, 1, 1)
        gfx.circle(x + w - r - 1, y + h - r - 1, r, 1, 1)
    end
end

-- ✱ pulse: a single warm-orange asterisk-sextile that gently breathes,
-- replacing the three-dot waiting animation.
local function draw_star_pulse(cx, cy, base_color, size)
    local pulse = 0.55 + 0.45 * math.sin(reaper.time_precise() * 2.6)
    set_color(base_color[1], base_color[2], base_color[3], pulse)
    gfx.setfont(1, "Arial", size)
    local s = "✱"
    local sw = gfx.measurestr(s)
    gfx.x = cx - math.floor(sw / 2)
    gfx.y = cy - math.floor(size / 2)
    gfx.drawstr(s)
end

local function is_dot_anim(c)
    if not (c.kind == "assistant" and c.live == true) then return false end
    for _, ln in ipairs(c.lines) do
        if ln ~= "" then return false end
    end
    return true
end

local function bubble_content_h(c, lh)
    if is_dot_anim(c) then return SPINNER_SIZE + PAD * 2 end
    local has_label = (c.label ~= nil and c.label ~= "")
    local label_rows = has_label and 1 or 0
    local rows = label_rows + math.max(1, #c.lines)
    return rows * lh + PAD * 2
end

function M.new(chat, opts)
    opts = opts or {}
    local lh = opts.line_height or 22
    return {
        chat              = chat,
        on_settings       = opts.on_settings,
        on_chinese_input  = opts.on_chinese_input,
        on_toggle_search       = opts.on_toggle_search,
        on_overlay_edit_provider = opts.on_overlay_edit_provider,
        on_overlay_edit_key      = opts.on_overlay_edit_key,
        _web_search_on         = false,
        _show_settings_overlay = false,
        hwnd              = opts.hwnd,            -- gfx window (for focus restore after modal)
        font_size         = opts.font_size or 16,
        font_size_small   = opts.font_size_small or 12,
        line_height       = lh,
        scroll_y          = 0,
        _at_bottom        = true,
        last_event_n      = 0,
        last_w            = 0,
        wrapped_cache     = {},
        input_buf         = "",
        input_lines_cache = nil,
        input_h_target    = lh + PAD + INPUT_VPAD * 2 + HINT_H,
        caret_blink_t     = reaper.time_precise(),
    }
end

function M.append_input(ui, text)
    if not text or text == "" then return end
    ui.input_buf = (ui.input_buf or "") .. text
    ui.caret_blink_t = reaper.time_precise()
end

function M.set_web_search_state(ui, on)
    ui._web_search_on = on
end

function M.open_settings_overlay(ui, provider_name, model, search_key)
    ui._settings_provider = provider_name or ""
    ui._settings_model = model or ""
    ui._settings_search_key = search_key or ""
    ui._show_settings_overlay = true
    ui._mouse_was_down = true
end

local function refresh_cache(ui)
    local events = ui.chat.events
    local w_changed = ui.last_w ~= gfx.w

    for i, ev in ipairs(events) do
        local entry = ui.wrapped_cache[i]
        local is_live = ev.kind == "assistant" and ev.live
        local body = event_body(ev)
        local body_changed = entry and entry.body ~= body
        local live_changed = entry and entry.live ~= is_live
        local need_rebuild = not entry or w_changed or is_live or body_changed or live_changed

        if need_rebuild then
            local _, _, align, ratio = bubble_config(ev)
            local bubble_w = (align == "right")
                and (math.floor(gfx.w * ratio) - MARGIN * 2)
                or  (gfx.w - MARGIN * 2 - 6)
            local max_w = math.max(80, bubble_w - PAD * 2)

            ui.wrapped_cache[i] = {
                label = event_label(ev),
                lines = wrap_text(body, max_w),
                live  = is_live,
                body  = body,
                kind  = ev.kind,
            }
        end
    end
    for i = #events + 1, #ui.wrapped_cache do ui.wrapped_cache[i] = nil end
    ui.last_w = gfx.w
end

local function draw_bubble(ui, c, y, log_y, log_h)
    local lh = ui.line_height
    local bg, tc, align, ratio = bubble_config({ kind = c.kind, live = c.live })

    -- For user bubbles, auto-fit width to text + padding (pill shape).
    local bubble_w
    if c.kind == "user" then
        gfx.setfont(1, "Arial", ui.font_size)
        local longest = 0
        for _, line in ipairs(c.lines) do
            local lw = gfx.measurestr(line)
            if lw > longest then longest = lw end
        end
        local cap = math.floor(gfx.w * ratio) - MARGIN * 2
        bubble_w = math.min(cap, longest + PAD * 2)
        if bubble_w < lh + PAD then bubble_w = lh + PAD end
    elseif align == "right" then
        bubble_w = math.floor(gfx.w * ratio) - MARGIN * 2
    else
        bubble_w = gfx.w - MARGIN * 2 - 6
    end

    local has_label = (c.label ~= nil and c.label ~= "")
    local content_h = bubble_content_h(c, lh)
    local bx = (align == "right") and (gfx.w - MARGIN - bubble_w) or MARGIN

    -- Bubble background:
    --   - plain assistant text (not live, not dots): NO bubble — render on page bg
    --   - user / tool / error / spinner bubbles: filled, rounded if user
    local plain_assistant = (c.kind == "assistant" and not c.live and not is_dot_anim(c))
    if not plain_assistant then
        set_color(bg[1], bg[2], bg[3])
        if c.kind == "user" then
            draw_rounded_rect_filled(bx, y, bubble_w, content_h, 14)
        else
            gfx.rect(bx, y, bubble_w, content_h, 1)
        end
    end

    -- Label (tool / error chips only — assistant has no label now)
    if has_label and not c.live then
        gfx.setfont(1, "Arial", ui.font_size_small, string.byte("b"))
        set_color(tc[1], tc[2], tc[3], 0.55)
        gfx.x = bx + PAD
        gfx.y = y + PAD
        gfx.drawstr(c.label)
    end

    -- ✱ pulse waiting animation (replaces three dots)
    if is_dot_anim(c) then
        local cx = bx + PAD + math.floor(SPINNER_SIZE / 2)
        local cy = y + math.floor(content_h / 2)
        draw_star_pulse(cx, cy, PALETTE.claude_orange, SPINNER_SIZE)

        -- cycling thinking phrase right of the spinner
        local idx = 1 + math.floor(reaper.time_precise() / THINKING_CYCLE) % #THINKING_PHRASES
        local phrase = THINKING_PHRASES[idx]
        gfx.setfont(1, "Arial", ui.font_size)
        set_color(PALETTE.claude_orange[1], PALETTE.claude_orange[2], PALETTE.claude_orange[3], 0.78)
        gfx.x = bx + PAD + SPINNER_SIZE + 12
        gfx.y = y + math.floor((content_h - ui.font_size) / 2)
        gfx.drawstr(phrase)
        return content_h + GAP
    end

    -- Text body
    if c.live then tc = PALETTE.assistant_live end
    gfx.setfont(1, "Arial", ui.font_size)
    set_color(tc[1], tc[2], tc[3])
    local label_rows = has_label and 1 or 0
    local text_y0 = y + PAD + label_rows * lh
    -- For plain assistant text on the page bg, use a smaller left inset (no PAD)
    -- so it aligns with the page margin rather than indented as if in a bubble.
    local text_x = (plain_assistant) and (bx + PAD) or (bx + PAD)
    for li, line in ipairs(c.lines) do
        local ly = text_y0 + (li - 1) * lh
        if ly >= log_y - lh and ly <= log_y + log_h then
            gfx.x = text_x
            gfx.y = ly
            gfx.drawstr(line)
        end
    end

    return content_h + GAP
end

-- ---------------------------------------------------------------------------
-- Input strip
-- ---------------------------------------------------------------------------

local function input_box_metrics(ui)
    -- Compute input strip height based on how many wrapped lines the buffer has.
    gfx.setfont(1, "Arial", ui.font_size)
    local box_w = gfx.w - MARGIN * 2
    local max_text_w = box_w - PAD * 2
    local lines = wrap_text(ui.input_buf, max_text_w)
    if #lines == 0 then lines = { "" } end
    local n = math.max(1, #lines)
    local visible_lines = math.min(n, MAX_INPUT_LINES)
    local lh = ui.line_height
    local box_h = visible_lines * lh + PAD
    local strip_h = INPUT_VPAD + box_h + INPUT_VPAD + HINT_H
    return strip_h, box_h, box_w, lines, visible_lines
end

local function draw_input_strip(ui, input_y, strip_h, box_h, box_w, lines, visible_lines)
    local is_busy = ui.chat.state ~= "idle"
    local box_x = MARGIN
    local box_y = input_y + INPUT_VPAD
    local lh    = ui.line_height

    -- background + top separator
    set_color(PALETTE.bg[1], PALETTE.bg[2], PALETTE.bg[3])
    gfx.rect(0, input_y, gfx.w, strip_h, 1)
    set_color(PALETTE.sep[1], PALETTE.sep[2], PALETTE.sep[3])
    gfx.line(0, input_y, gfx.w, input_y)

    -- input box body (rounded, no border — matches Claude desktop's look)
    set_color(PALETTE.input_bg[1], PALETTE.input_bg[2], PALETTE.input_bg[3])
    draw_rounded_rect_filled(box_x, box_y, box_w, box_h, 12)

    -- placeholder when empty
    if ui.input_buf == "" then
        gfx.setfont(1, "Arial", ui.font_size)
        set_color(PALETTE.input_placeholder[1], PALETTE.input_placeholder[2], PALETTE.input_placeholder[3])
        gfx.x = box_x + PAD
        gfx.y = box_y + math.floor((box_h - ui.font_size) / 2)
        gfx.drawstr("发送消息  ·  Ctrl+E 输入中文")
    else
        -- typed text — only render the last `visible_lines` so the caret stays in view
        gfx.setfont(1, "Arial", ui.font_size)
        set_color(PALETTE.input_text[1], PALETTE.input_text[2], PALETTE.input_text[3])
        local first = math.max(1, #lines - visible_lines + 1)
        local row = 0
        for li = first, #lines do
            gfx.x = box_x + PAD
            gfx.y = box_y + math.floor(PAD / 2) + row * lh
            gfx.drawstr(lines[li])
            row = row + 1
        end
    end

    -- blinking caret at end of last visible line
    do
        local elapsed = reaper.time_precise() - ui.caret_blink_t
        local on = (elapsed % 1.0) < 0.55
        if on then
            local last_line = (#lines > 0) and lines[#lines] or ""
            local first = math.max(1, #lines - visible_lines + 1)
            local last_row = #lines - first  -- 0-indexed within visible window
            local caret_x = box_x + PAD + gfx.measurestr(last_line)
            local caret_y = box_y + math.floor(PAD / 2) + last_row * lh
            set_color(PALETTE.caret[1], PALETTE.caret[2], PALETTE.caret[3])
            gfx.rect(caret_x, caret_y, 2, math.floor(ui.font_size * 1.15), 1)
        end
    end

    -- hint row (or busy notice)
    local hint_y = box_y + box_h + 4
    gfx.setfont(1, "Arial", ui.font_size_small)
    if is_busy then
        -- left: streaming hint; right: Esc cancel
        set_color(PALETTE.bar_text_dim[1], PALETTE.bar_text_dim[2], PALETTE.bar_text_dim[3])
        gfx.x = box_x + 2
        gfx.y = hint_y
        gfx.drawstr("AI 正在生成…")
        local cancel = "Esc 停止"
        local cw = gfx.measurestr(cancel)
        set_color(PALETTE.cancel_text[1], PALETTE.cancel_text[2], PALETTE.cancel_text[3])
        gfx.x = box_x + box_w - cw - 2
        gfx.y = hint_y
        gfx.drawstr(cancel)
    else
        local hint = "Enter 发送 · Shift+Enter 换行 · Ctrl+E 输入中文 · Ctrl+L 清屏 · Ctrl+W 关闭"
        set_color(PALETTE.bar_text_dim[1], PALETTE.bar_text_dim[2], PALETTE.bar_text_dim[3], 0.85)
        gfx.x = box_x + 2
        gfx.y = hint_y
        gfx.drawstr(hint)
    end
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

local GEAR_W = 28  -- clickable settings region width on the status bar

local function draw_status_bar(ui)
    set_color(PALETTE.bar_bg[1], PALETTE.bar_bg[2], PALETTE.bar_bg[3])
    gfx.rect(0, 0, gfx.w, BAR_H, 1)
    set_color(PALETTE.sep[1], PALETTE.sep[2], PALETTE.sep[3])
    gfx.line(0, BAR_H, gfx.w, BAR_H)

    -- left: title
    gfx.setfont(1, "Arial", ui.font_size, string.byte("b"))
    set_color(PALETTE.bar_text[1], PALETTE.bar_text[2], PALETTE.bar_text[3])
    gfx.x = 14
    gfx.y = math.floor((BAR_H - ui.font_size) / 2)
    gfx.drawstr("MCAssistant")

    -- right: gear (settings)
    local gear_x = gfx.w - GEAR_W
    local hovered = (gfx.mouse_x >= gear_x and gfx.mouse_x <= gfx.w
                  and gfx.mouse_y >= 0 and gfx.mouse_y <= BAR_H)
    local gc = hovered and PALETTE.gear_bright or PALETTE.gear_dim
    gfx.setfont(1, "Arial", 18)
    set_color(gc[1], gc[2], gc[3])
    local gw = gfx.measurestr("⚙")
    gfx.x = gear_x + math.floor((GEAR_W - gw) / 2)
    gfx.y = math.floor((BAR_H - 18) / 2)
    gfx.drawstr("⚙")

    -- right of title: provider / model
    local model_str = ui.chat.provider.name .. "  /  " .. ui.chat.provider.model
    gfx.setfont(1, "Arial", ui.font_size_small)
    set_color(PALETTE.bar_text_dim[1], PALETTE.bar_text_dim[2], PALETTE.bar_text_dim[3])
    local mw = gfx.measurestr(model_str)
    gfx.x = gear_x - mw - 12
    gfx.y = math.floor((BAR_H - ui.font_size_small) / 2)
    gfx.drawstr(model_str)

    -- center: status text (only when not idle)
    if ui.chat.state ~= "idle" then
        local s = ui.chat:status_text()
        local sw = gfx.measurestr(s)
        local title_right = 14 + gfx.measurestr("MCAssistant") + 16
        local cx = title_right + math.floor((gear_x - mw - 24 - title_right - sw) / 2)
        if cx > title_right then
            set_color(PALETTE.bar_text_dim[1], PALETTE.bar_text_dim[2], PALETTE.bar_text_dim[3], 0.7)
            gfx.x = cx
            gfx.y = math.floor((BAR_H - ui.font_size_small) / 2)
            gfx.drawstr(s)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings overlay
-- ---------------------------------------------------------------------------

local function draw_settings_overlay(ui)
    local pw = math.min(gfx.w - 40, 420)
    local ph = 280
    local px = math.floor((gfx.w - pw) / 2)
    local py = math.floor((gfx.h - ph) / 2)

    -- backdrop
    set_color(0.10, 0.10, 0.13)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    -- panel
    set_color(0.15, 0.15, 0.18)
    gfx.rect(px, py, pw, ph, 1)
    set_color(0.50, 0.50, 0.55)
    gfx.rect(px, py, pw, 1, 1)
    gfx.rect(px, py + ph - 1, pw, 1, 1)
    gfx.rect(px, py, 1, ph, 1)
    gfx.rect(px + pw - 1, py, 1, ph, 1)

    local cx = px + 20
    local line_h = 30
    local rx = px + pw - 20

    gfx.setfont(1, "Arial", 16, string.byte("b"))
    set_color(0.93, 0.93, 0.94)
    gfx.x = cx
    gfx.y = py + 16
    gfx.drawstr("Settings")

    set_color(0.30, 0.30, 0.34)
    gfx.line(cx, py + 42, rx, py + 42)

    gfx.setfont(1, "Arial", 14, string.byte("b"))
    set_color(0.93, 0.93, 0.94)
    gfx.x = cx
    gfx.y = py + 52
    gfx.drawstr("API")

    local info_y = py + 76
    gfx.setfont(1, "Arial", 13)
    set_color(0.70, 0.70, 0.74)
    gfx.x = cx + 8
    gfx.y = info_y
    gfx.drawstr("Provider:  " .. (ui._settings_provider or ""))
    gfx.x = cx + 8
    gfx.y = info_y + line_h
    gfx.drawstr("Model:     " .. (ui._settings_model or ""))

    local btn1_w, btn1_h = 100, 24
    local btn1_x = rx - btn1_w
    local btn1_y = info_y + 6
    local btn1_hover = (gfx.mouse_x >= btn1_x and gfx.mouse_x < btn1_x + btn1_w
                    and gfx.mouse_y >= btn1_y and gfx.mouse_y < btn1_y + btn1_h)
    set_color(btn1_hover and 0.35 or 0.25, btn1_hover and 0.35 or 0.25, btn1_hover and 0.40 or 0.30)
    gfx.rect(btn1_x, btn1_y, btn1_w, btn1_h, 1)
    set_color(0.93, 0.93, 0.94)
    gfx.setfont(1, "Arial", 12)
    local b1t = "Edit"
    local b1tw = gfx.measurestr(b1t)
    gfx.x = btn1_x + math.floor((btn1_w - b1tw) / 2)
    gfx.y = btn1_y + math.floor((btn1_h - 12) / 2)
    gfx.drawstr(b1t)

    set_color(0.30, 0.30, 0.34)
    gfx.line(cx, info_y + line_h * 2 + 8, rx, info_y + line_h * 2 + 8)

    gfx.setfont(1, "Arial", 14, string.byte("b"))
    set_color(0.93, 0.93, 0.94)
    gfx.x = cx
    gfx.y = info_y + line_h * 2 + 18
    gfx.drawstr("Web Search")

    local pill_w, pill_h = 52, 22
    local pill_x = cx + 110
    local pill_y = info_y + line_h * 2 + 16
    local is_on = ui._web_search_on
    local pill_hover = (gfx.mouse_x >= pill_x and gfx.mouse_x < pill_x + pill_w
                    and gfx.mouse_y >= pill_y and gfx.mouse_y < pill_y + pill_h)

    if is_on then
        set_color(pill_hover and 0.22 or 0.18, pill_hover and 0.40 or 0.32, pill_hover and 0.28 or 0.22)
    else
        set_color(pill_hover and 0.28 or 0.22, pill_hover and 0.28 or 0.22, pill_hover and 0.32 or 0.26)
    end
    gfx.rect(pill_x, pill_y, pill_w, pill_h, 1)

    local dot_x = is_on and (pill_x + pill_w - 9) or (pill_x + 9)
    local dot_y = pill_y + pill_h / 2
    set_color(is_on and 0.96 or 0.50, is_on and 0.62 or 0.50, is_on and 0.36 or 0.54)
    gfx.circle(dot_x, dot_y, 5, 1, 1)

    gfx.setfont(1, "Arial", 11)
    local state_label = is_on and "ON" or "OFF"
    local slw = gfx.measurestr(state_label)
    set_color(is_on and 0.80 or 0.55, is_on and 0.90 or 0.55, is_on and 0.82 or 0.58)
    gfx.x = is_on and (pill_x + 6) or (pill_x + pill_w - slw - 6)
    gfx.y = pill_y + math.floor((pill_h - 11) / 2)
    gfx.drawstr(state_label)

    gfx.setfont(1, "Arial", 13)
    local key_y = pill_y + pill_h + 12
    if is_on then
        local key = ui._settings_search_key or ""
        local masked = key ~= "" and (key:sub(1, 4) .. "***") or "(not set)"
        set_color(0.70, 0.70, 0.74)
        gfx.x = cx + 8
        gfx.y = key_y
        gfx.drawstr("Key: " .. masked)

        local btn2_w, btn2_h = 90, 22
        local btn2_x = rx - btn2_w
        local btn2_y = key_y - 2
        local btn2_hover = (gfx.mouse_x >= btn2_x and gfx.mouse_x < btn2_x + btn2_w
                        and gfx.mouse_y >= btn2_y and gfx.mouse_y < btn2_y + btn2_h)
        set_color(btn2_hover and 0.35 or 0.25, btn2_hover and 0.35 or 0.25, btn2_hover and 0.40 or 0.30)
        gfx.rect(btn2_x, btn2_y, btn2_w, btn2_h, 1)
        set_color(0.93, 0.93, 0.94)
        gfx.setfont(1, "Arial", 12)
        local b2t = "Edit Key"
        local b2tw = gfx.measurestr(b2t)
        gfx.x = btn2_x + math.floor((btn2_w - b2tw) / 2)
        gfx.y = btn2_y + math.floor((btn2_h - 12) / 2)
        gfx.drawstr(b2t)
    else
        set_color(0.45, 0.45, 0.48)
        gfx.x = cx + 8
        gfx.y = key_y
        gfx.drawstr("Disabled")
    end

    set_color(0.30, 0.30, 0.34)
    gfx.line(cx, py + ph - 48, rx, py + ph - 48)

    local btn3_w, btn3_h = 80, 28
    local btn3_x = px + pw - 20 - btn3_w
    local btn3_y = py + ph - 40
    local btn3_hover = (gfx.mouse_x >= btn3_x and gfx.mouse_x < btn3_x + btn3_w
                    and gfx.mouse_y >= btn3_y and gfx.mouse_y < btn3_y + btn3_h)
    set_color(btn3_hover and 0.35 or 0.25, btn3_hover and 0.35 or 0.25, btn3_hover and 0.40 or 0.30)
    gfx.rect(btn3_x, btn3_y, btn3_w, btn3_h, 1)
    set_color(0.93, 0.93, 0.94)
    gfx.setfont(1, "Arial", 13)
    local b3t = "Done"
    local b3tw = gfx.measurestr(b3t)
    gfx.x = btn3_x + math.floor((btn3_w - b3tw) / 2)
    gfx.y = btn3_y + math.floor((btn3_h - 13) / 2)
    gfx.drawstr(b3t)
end

-- ---------------------------------------------------------------------------
-- Main draw + input
-- ---------------------------------------------------------------------------

function M.draw(ui)
    -- background
    set_color(PALETTE.bg[1], PALETTE.bg[2], PALETTE.bg[3])
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    draw_status_bar(ui)

    -- compute input strip height (auto-grow)
    local strip_h, box_h, box_w, lines, visible_lines = input_box_metrics(ui)
    ui.input_h_target = strip_h
    local input_y = gfx.h - strip_h

    -- log area
    local log_y = BAR_H + 2
    local log_h = input_y - log_y - 2

    gfx.setfont(1, "Arial", ui.font_size)
    refresh_cache(ui)

    local lh = ui.line_height
    local function role_extra(prev, cur)
        local boundary = (prev == "user" and cur == "assistant")
                      or (prev == "assistant" and cur == "user")
        return boundary and ROLE_GAP or 0
    end

    local total_h = 0
    do
        local prev_kind = nil
        for _, c in ipairs(ui.wrapped_cache) do
            total_h = total_h + role_extra(prev_kind, c.kind) + bubble_content_h(c, lh) + GAP
            prev_kind = c.kind
        end
    end

    -- smart auto-scroll
    local max_scroll  = math.max(0, total_h - log_h)
    local near_bottom = (max_scroll - ui.scroll_y) < (lh * 3)
    local n_changed   = ui.last_event_n ~= #ui.chat.events
    local has_live    = false
    for _, c in ipairs(ui.wrapped_cache) do if c.live then has_live = true; break end end

    if n_changed and ui._at_bottom then ui.scroll_y = math.huge end
    if has_live  and near_bottom    then ui.scroll_y = math.huge end

    if ui.scroll_y > max_scroll then ui.scroll_y = max_scroll end
    if ui.scroll_y < 0          then ui.scroll_y = 0 end
    ui._at_bottom    = (max_scroll - ui.scroll_y) < 2
    ui.last_event_n  = #ui.chat.events

    -- draw bubbles (clip to log area)
    local y = log_y - ui.scroll_y
    local prev_kind = nil
    for _, c in ipairs(ui.wrapped_cache) do
        y = y + role_extra(prev_kind, c.kind)
        local bh = bubble_content_h(c, lh) + GAP
        if y + bh >= log_y and y <= log_y + log_h then
            draw_bubble(ui, c, y, log_y, log_h)
        end
        y = y + bh
        prev_kind = c.kind
    end

    -- scrollbar
    if total_h > log_h then
        local sb_x  = gfx.w - 5
        local sb_track = log_h
        set_color(PALETTE.scrollbar[1], PALETTE.scrollbar[2], PALETTE.scrollbar[3], 0.4)
        gfx.rect(sb_x, log_y, 5, sb_track, 1)
        local thumb_h = math.max(20, math.floor(sb_track * log_h / total_h))
        local thumb_y = log_y + math.floor(
            (ui.scroll_y / math.max(1, total_h - log_h)) * (sb_track - thumb_h))
        set_color(PALETTE.scrollbar_thumb[1], PALETTE.scrollbar_thumb[2], PALETTE.scrollbar_thumb[3])
        gfx.rect(sb_x, thumb_y, 5, thumb_h, 1)
    end

    -- "↓ 跳到最新" indicator
    if has_live and not near_bottom then
        local ind_w, ind_h = 110, 24
        local ind_x = gfx.w - ind_w - 20
        local ind_y = input_y - ind_h - 8
        set_color(PALETTE.jump_bg[1], PALETTE.jump_bg[2], PALETTE.jump_bg[3], 0.90)
        gfx.rect(ind_x, ind_y, ind_w, ind_h, 1)
        gfx.setfont(1, "Arial", 13, string.byte("b"))
        set_color(PALETTE.jump_text[1], PALETTE.jump_text[2], PALETTE.jump_text[3])
        local tw = gfx.measurestr("↓ 跳到最新")
        gfx.x = ind_x + math.floor((ind_w - tw) / 2)
        gfx.y = ind_y + math.floor((ind_h - 13) / 2)
        gfx.drawstr("↓ 跳到最新")
    end

    -- input strip last (so it draws over the log area's bottom edge)
    draw_input_strip(ui, input_y, strip_h, box_h, box_w, lines, visible_lines)

    if ui._show_settings_overlay then
        local ok, err = pcall(draw_settings_overlay, ui)
        if not ok then
            ui._show_settings_overlay = false
            reaper.ShowMessageBox("Settings overlay error:\n" .. tostring(err), "MCAssistant", 0)
        end
    end
end

-- Reset caret blink to make it visible right after a keystroke / paste / etc.
local function reset_caret(ui)
    ui.caret_blink_t = reaper.time_precise()
end

local function cancel_busy(ui)
    if ui.chat.req and ui.chat.req.handle then
        local http = require("http")
        http.cancel(ui.chat.req.handle)
    end
    ui.chat:_finish()
end

local function paste_clipboard(ui)
    if not reaper.CF_GetClipboard then return end
    local clip = reaper.CF_GetClipboard("") or ""
    if clip == "" then return end
    clip = clip:gsub("\r\n", "\n"):gsub("\r", "\n")
    clip = clip:gsub("[%z\1-\8\11\12\14-\31]", "")
    ui.input_buf = ui.input_buf .. clip
    reset_caret(ui)
end

function M.handle_input(ui)
    -- Mouse wheel scroll on the log
    if gfx.mouse_wheel ~= 0 then
        ui.scroll_y    = ui.scroll_y - gfx.mouse_wheel * 0.5
        ui._at_bottom  = false
        gfx.mouse_wheel = 0
    end

    -- Mouse click handling (gear, jump-to-bottom, refocus EDIT)
    local left_down = (gfx.mouse_cap & 1) == 1
    if left_down and not ui._mouse_was_down then
        ui._mouse_was_down = true

        if ui._show_settings_overlay then
            local pw = math.min(gfx.w - 40, 420)
            local ph = 280
            local px = math.floor((gfx.w - pw) / 2)
            local py = math.floor((gfx.h - ph) / 2)
            local cx = px + 20
            local rx = px + pw - 20
            local info_y = py + 76
            local line_h = 30

            local function in_rect(x1, y1, w, h)
                return gfx.mouse_x >= x1 and gfx.mouse_x < x1 + w
                   and gfx.mouse_y >= y1 and gfx.mouse_y < y1 + h
            end

            -- toggle pill
            local pill_x = cx + 110
            local pill_y = info_y + line_h * 2 + 16
            if in_rect(pill_x, pill_y, 52, 22) then
                if ui.on_toggle_search then ui.on_toggle_search(false) end
                return true
            end

            -- [Edit] provider
            local btn1_x = rx - 100
            local btn1_y = info_y + 6
            if in_rect(btn1_x, btn1_y, 100, 24) then
                if ui.on_overlay_edit_provider then ui.on_overlay_edit_provider() end
                return true
            end

            -- [Edit Key] (only when search is on)
            if ui._web_search_on then
                local btn2_x = rx - 90
                local btn2_y = info_y + line_h * 2 + 16 + 22 + 12 - 2
                if in_rect(btn2_x, btn2_y, 90, 22) then
                    if ui.on_overlay_edit_key then ui.on_overlay_edit_key() end
                    return true
                end
            end

            -- [Done]
            local btn3_x = px + pw - 20 - 80
            local btn3_y = py + ph - 40
            if in_rect(btn3_x, btn3_y, 80, 28) then
                ui._show_settings_overlay = false
                return true
            end

            -- click outside panel → close
            if not in_rect(px, py, pw, ph) then
                ui._show_settings_overlay = false
                return true
            end

            return true
        end

        local gear_x = gfx.w - GEAR_W
        if gfx.mouse_x >= gear_x and gfx.mouse_y >= 0 and gfx.mouse_y <= BAR_H then
            if ui.on_settings then ui.on_settings() end
        end

        local has_live = false
        for _, c in ipairs(ui.wrapped_cache) do if c.live then has_live = true; break end end
        if has_live and not ui._at_bottom then
            local input_y = gfx.h - (ui.input_h_target or 60)
            local ind_w, ind_h = 110, 24
            local ind_x = gfx.w - ind_w - 20
            local ind_y = input_y - ind_h - 8
            if gfx.mouse_x >= ind_x and gfx.mouse_x <= ind_x + ind_w
               and gfx.mouse_y >= ind_y and gfx.mouse_y <= ind_y + ind_h then
                ui.scroll_y    = math.huge
                ui._at_bottom  = true
            end
        end
    elseif not left_down then
        ui._mouse_was_down = false
    end

    -- Keystroke loop (PRIMARY input path — this is what was working before).
    while true do
        local c = gfx.getchar()
        if c < 0 then return false end
        if c == 0 then break end

        if c == 5 then                            -- Ctrl+E → Chinese modal
            if ui.on_chinese_input then ui.on_chinese_input() end

        elseif c == 27 then                       -- Esc cascade
            if ui._show_settings_overlay then
                ui._show_settings_overlay = false
            elseif ui.chat.state ~= "idle" then
                cancel_busy(ui)
            elseif ui.input_buf ~= "" then
                ui.input_buf = ""
                reset_caret(ui)
            else
                return false
            end

        elseif c == 13 then                       -- Enter (Shift+Enter = newline)
            if (gfx.mouse_cap & 8) ~= 0 then
                ui.input_buf = ui.input_buf .. "\n"
                reset_caret(ui)
            else
                if ui.chat.state == "idle" and ui.input_buf ~= "" then
                    local text = ui.input_buf
                    ui.input_buf = ""
                    ui.chat:send_user(text)
                    reset_caret(ui)
                end
            end

        elseif c == 8 then                        -- Backspace
            ui.input_buf = utf8_pop_back(ui.input_buf)
            reset_caret(ui)

        elseif c == 22 then                       -- Ctrl+V
            paste_clipboard(ui)

        elseif c == 12 then                       -- Ctrl+L (clear chat when buffer empty)
            if ui.input_buf == "" then
                ui.chat:clear()
                ui.wrapped_cache = {}
                ui.last_event_n  = 0
                ui._at_bottom    = true
            end

        elseif c == 23 then                       -- Ctrl+W
            return false

        elseif c == 9 then                        -- Tab — ignore
            -- intentionally no-op

        elseif c >= 32 and c < 0x110000 and not SPECIAL_KEYS[c] then
            ui.input_buf = ui.input_buf .. codepoint_to_utf8(c)
            reset_caret(ui)
        end
    end

    return true
end

return M

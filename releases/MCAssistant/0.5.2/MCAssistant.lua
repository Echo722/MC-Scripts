-- @description MCAssistant — In-REAPER AI chat with streaming + batch-operation tools
-- @version 0.5.2
-- @author MC Scripts
-- @about
--   Chat panel inside REAPER driving batch operations through tool calls.
--
--   v0.5.0:
--     - UI: in-panel text input — type directly in the chat window; no more
--       modal Send dialog. Multi-line via Shift+Enter; auto-grows up to ~6
--       lines and scrolls internally beyond.
--     - UI: streaming feels right — user message appears the instant Enter
--       is pressed, AI tokens flow in token-by-token.
--     - UI: Ctrl+V paste (requires SWS extension's CF_GetClipboard).
--     - UI: settings now opened by clicking the ⚙ icon in the status bar
--       (S key is no longer a hotkey, since it goes into the buffer).
--     - UI: visual refresh closer to Claude desktop — warm caret accent,
--       denser typography (16/12), refined spacing, AI text on the page bg.
--     - 27 tools covering SFX / Item / Track+FX / MIDI / Region / Project,
--       including loudness analysis + normalisation and project_render.
--
--   Providers (switch via the ⚙ button in the status bar):
--     - anthropic — Anthropic Messages API (api.anthropic.com or proxy)
--     - openai    — OpenAI Chat Completions (api.openai.com, OpenRouter,
--       Groq, DeepSeek, local Ollama at /v1, etc.)
--
--   Requires:
--     - js_ReaScriptAPI extension
--     - Windows with C:\Windows\System32\curl.exe
--     - API key for one of the supported services
--
-- @requires js_ReaScriptAPI
-- @changelog
--   * 0.5.2  Rename provider type 'claude' → 'anthropic' so both providers
--            use vendor names (anthropic / openai). Old configs saying
--            'claude' continue to work as a silent alias, so this is a
--            no-op for users on 0.5.1; the rename fixes a startup crash
--            when an extstate has 'anthropic' written by another build of
--            MCAssistant that shares the same EXT section.
--   * 0.5.1  Move the ReaPack install path to MC Scripts Release/MCAssistant.
--   * 0.5.0  In-panel text input replaces the modal Send dialog. User
--            messages now appear instantly and AI streams in token-by-
--            token (was: both batched after the modal closed). Multi-
--            line input via Shift+Enter; Ctrl+V paste via SWS extension.
--            Visual refresh closer to Claude desktop (warm caret accent,
--            denser typography, refined spacing). Settings now opens via
--            the ⚙ button in the status bar (S key is freed for typing).
--   * 0.4.2  Add project_render tool (bounds + format presets, exposes
--            REAPER's Render Project via GetSetProjectInfo_String +
--            Main_OnCommand 42230). bounds=selected_items renders each
--            selected item ISOLATED to its own file by default
--            (other items muted, time range = item bounds, filename =
--            sanitized take name); pass merge=true for a single
--            mixdown. items_get_info now also reports source_type /
--            source_samplerate / source_channels.
--   * 0.4.1  Add loudness analysis + normalisation: items_get_loudness
--            (read-only LUFS-I / RMS / peak / true peak) and
--            items_normalize_loudness (target_db + mode, single Undo).
--   * 0.4.0  Claude.ai-inspired UI: deep dark theme, three-dot waiting animation,
--    neutral user bubbles, condensed status bar.
--   * 0.3.1  Hotfixes (ID collision, undo leak, curl redaction) + UI refresh.
--   * 0.3.0  Async HTTP + SSE streaming. Expanded to 22 tools. Tick-based
--      chat state machine so UI stays responsive during network I/O.
--   * 0.2.0  OpenAI-compatible provider. Settings dialog for type/base_url/
--            model/api_key (OpenRouter, Groq, Ollama, etc.).
--   * 0.1.0  Initial demo: Claude provider, 4 tools, gfx chat UI.
--------------------------------------------------------------------------------
-- module loading
--------------------------------------------------------------------------------
local SCRIPT_DIR = debug.getinfo(1, "S").source:match("@(.+)[/\\][^/\\]+$") or "."
package.path = SCRIPT_DIR .. "/?.lua;" .. (package.path or "")

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
     reaper.MB("MCAssistant: failed to load module '" .. name .. "'\n\n" ..
               tostring(mod), "MCAssistant", 0)
        return nil
    end
    return mod
end

local json     = safe_require("json")
local http     = safe_require("http")
local provider = safe_require("provider")
local tools    = safe_require("tools")
local chat_mod = safe_require("chat")
local ui_mod   = safe_require("ui")

if not (json and http and provider and tools and chat_mod and ui_mod) then return end

--------------------------------------------------------------------------------
-- guards
--------------------------------------------------------------------------------
if not reaper.JS_Window_Find then
  reaper.MB("MCAssistant requires the js_ReaScriptAPI extension.\n\n" ..
           "Install via ReaPack.", "MCAssistant", 0)
 return
end

local curl_ok, curl_err = http.check_curl()
if not curl_ok then
    reaper.MB("MCAssistant: " .. tostring(curl_err) .. "\n\n" ..
  "This build expects curl.exe at C:\\Windows\\System32\\curl.exe " ..
        "(Windows 10/11 default).", "MCAssistant", 0)
    return
end

if reaper.set_action_options then reaper.set_action_options(1) end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------
local EXT = "MCAssistant"

local SETTINGS_HELP = [[
MCAssistant — API 配置

Provider type:
  anthropic — Anthropic Messages API
  openai    — OpenAI Chat Completions (覆盖 OpenRouter / Groq / DeepSeek / 本地 Ollama 等所有兼容端点)

常见预设 (type / base URL / model / api key):
  Anthropic:  anthropic / (留空) / claude-sonnet-4-6 / sk-ant-...
  OpenAI: openai / (留空) / gpt-4o / sk-...
  OpenRouter: openai / https://openrouter.ai/api/v1 / anthropic/claude-sonnet-4-5 / sk-or-...
  Groq:   openai / https://api.groq.com/openai/v1 / llama-3.3-70b-versatile / gsk_...
  DeepSeek:   openai / https://api.deepseek.com / deepseek-chat / sk-...
  Ollama 本地: openai / http://localhost:11434/v1 / llama3.1 / 任意非空字符串

API key 以明文存于 reaper-extstate.ini —— 建议用低额度专用 key。
]]

local function load_settings()
  return {
        type  = reaper.GetExtState(EXT, "provider_type"),
     base_url = reaper.GetExtState(EXT, "base_url"),
  model   = reaper.GetExtState(EXT, "model"),
     api_key  = reaper.GetExtState(EXT, "api_key"),
    }
end

local function save_settings(s)
    reaper.SetExtState(EXT, "provider_type", s.type or "",     true)
    reaper.SetExtState(EXT, "base_url",      s.base_url or "", true)
 reaper.SetExtState(EXT, "model",         s.model or "",    true)
    reaper.SetExtState(EXT, "api_key",       s.api_key or "",  true)
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function prompt_settings(current, show_help)
    if show_help then reaper.MB(SETTINGS_HELP, "MCAssistant — Settings", 0) end
    local fields = "Type (anthropic/openai),Base URL (blank=default),Model,API key,extrawidth=520,separator=|"
    local default = table.concat({
   (current and current.type)     or "anthropic",
    (current and current.base_url) or "",
   (current and current.model) or "claude-sonnet-4-6",
   (current and current.api_key)  or "",
    }, "|")
    local ok, csv = reaper.GetUserInputs("MCAssistant — API Settings", 4, fields, default)
    if not ok then return nil end
    local parts = {}
  for p in (csv .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
    local s = {
        type     = trim(parts[1]):lower(),
base_url = trim(parts[2]),
   model    = trim(parts[3]),
        api_key  = trim(parts[4]),
    }
    if s.type ~= "anthropic" and s.type ~= "claude" and s.type ~= "openai" then
        -- 'claude' is accepted as a legacy alias for 'anthropic' so old configs keep working.
        reaper.MB("Provider type 必须是 'anthropic' 或 'openai'。", "MCAssistant", 0)
        return nil
    end
    if s.api_key == "" then
  reaper.MB("API key 不能为空。", "MCAssistant", 0)
        return nil
    end
  return s
end

local settings = load_settings()
if (settings.api_key or "") == "" then
    settings = prompt_settings(settings, true)
    if not settings then return end
    save_settings(settings)
end

--------------------------------------------------------------------------------
-- wire up
--------------------------------------------------------------------------------
local prov = provider.create(settings)
local chat = chat_mod.new(prov, tools)

local function on_settings()
    local s = prompt_settings(settings, false)
    if not s then return end
    settings = s
    save_settings(settings)
    chat.provider = provider.create(settings)
end

--------------------------------------------------------------------------------
-- window geometry
--------------------------------------------------------------------------------
local function load_geom()
    local w = tonumber(reaper.GetExtState(EXT, "win_w")) or 640
    local h = tonumber(reaper.GetExtState(EXT, "win_h")) or 720
    local x = tonumber(reaper.GetExtState(EXT, "win_x")) or 200
    local y = tonumber(reaper.GetExtState(EXT, "win_y")) or 120
    local d = tonumber(reaper.GetExtState(EXT, "win_d")) or 0
    if w < 360 then w = 640 end
    if h < 320 then h = 720 end
    return w, h, x, y, d
end

local function save_geom()
    local d, x, y = gfx.dock(-1, 0, 0, 0, 0)
    reaper.SetExtState(EXT, "win_w", tostring(gfx.w), true)
    reaper.SetExtState(EXT, "win_h", tostring(gfx.h), true)
    reaper.SetExtState(EXT, "win_x", tostring(x),     true)
    reaper.SetExtState(EXT, "win_y", tostring(y),     true)
    reaper.SetExtState(EXT, "win_d", tostring(d),     true)
end

local w, h, x, y, dock = load_geom()
gfx.init("MCAssistant", w, h, dock, x, y)
gfx.setfont(1, "Arial", 14)
reaper.atexit(save_geom)

-- Capture the gfx window handle so we can restore keyboard focus to it after
-- the Ctrl+E Chinese-input modal closes.
--
-- Why no hidden Win32 EDIT child for direct IME input here: iteration 6/7/8
-- explored a hidden Win32 EDIT child as a Chinese keyboard sink. On this
-- REAPER setup the EDIT (sized 1×1 off-screen) was a key black hole — it
-- stole focus from gfx but didn't accept character/IME messages either. So
-- we stick with the proven path: gfx.getchar handles ASCII; Ctrl+E opens a
-- GetUserInputs modal for Chinese / Unicode.
local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("MCAssistant", true) or nil

local ui

local function on_chinese_input()
    local ok, text = reaper.GetUserInputs("MCAssistant — 输入中文/Unicode 文本", 1,
        "文本:,extrawidth=520", "")
    if ok and text then
        text = trim(text)
        if text ~= "" and ui_mod.append_input then
            ui_mod.append_input(ui, text)
        end
    end
    if hwnd and reaper.JS_Window_SetFocus then
        reaper.JS_Window_SetFocus(hwnd)
    end
end

ui = ui_mod.new(chat, {
    on_settings      = on_settings,
    on_chinese_input = on_chinese_input,
    hwnd             = hwnd,
})

--------------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------------
local function main()
 if not ui_mod.handle_input(ui) then
     save_geom()
        gfx.quit()
    return
    end
    chat:tick()   -- advance async state machine
 ui_mod.draw(ui)
    gfx.update()
    reaper.defer(main)
end

main()

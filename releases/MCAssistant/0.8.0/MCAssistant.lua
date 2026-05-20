-- @description MCAssistant — In-REAPER AI chat with streaming + batch-operation tools
-- @version 0.8.0
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
--     - ReaImGui extension (new in 0.8.0 — install via ReaPack)
--     - Windows with C:\Windows\System32\curl.exe
--     - API key for one of the supported services
--
-- @requires js_ReaScriptAPI, ReaImGui
-- @changelog
--   * 0.8.0  ReaImGui port — native Chinese / Unicode input, no more
--            Ctrl+E modal.
--            - Full UI rewrite from gfx to ReaImGui. InputTextMultiline
--              handles IME composition directly, so the Ctrl+E
--              GetUserInputs workaround is gone. Just type Chinese.
--            - User messages render as right-aligned terracotta bubbles
--              (drawn via the window draw list, not BeginChild — earlier
--              prototypes crashed during streaming when ChildFlags_
--              AlwaysAutoResize forced re-measurement every frame).
--            - Settings popup is now an inline ImGui modal with editable
--              Provider radio (anthropic / openai), Base URL, Model, API
--              key, Search key fields — replaces the chained
--              GetUserInputs dialogs. API/Search keys default to masked
--              with a Show/Hide toggle. The Tavily Search key row only
--              appears when web search is ON. Modal-dim overlay set
--              transparent so the main UI isn't greyed; popup itself
--              uses a distinct lighter bg + visible border + brighter
--              title bar.
--            - Status bar shows just the model name (no "openai /"
--              prefix that read as a vendor name on third-party
--              providers).
--            - ✱ thinking spinner is now an alpha-pulsing accent glyph;
--              role gaps between user↔assistant turns; ↓ 跳到最新
--              floating button when scrolled up during streaming.
--            - Hard dependency on ReaImGui added in @requires.
--            - chat.lua / provider.lua / http.lua / tools.lua /
--              json.lua untouched — the migration is contained to
--              ui.lua + the MCAssistant.lua entrypoint.
--   * 0.7.0  Settings overlay with visual web search toggle. Click the ⚙
--            gear icon to open a gfx-based Settings panel showing:
--            - API config (provider/model) with Edit button
--            - Web Search toggle pill (click to switch ON/OFF)
--            - Search API key display and Edit Key button
--            - Done button to close
--            The old text-field toggle (typing 1/0) is replaced by a visual
--            click-to-toggle pill. Settings dialog (Edit button) is now a
--            clean 4-field form (type/base_url/model/api_key). Web search
--            settings are preserved across provider edits.
--            Bug fix: moved `local ui` declaration before callback functions
--            to fix nil-reference when callbacks capture the ui upvalue.
--            Added pcall protection around overlay rendering to prevent
--            defer-loop crashes from Lua errors in draw code.
--   * 0.6.2  Provider-agnostic web search via two new client-side tools:
--            - web_search(query, max_results): hits Tavily (free 1000/mo)
--              and returns {title, url, content} snippets. The model gets
--              a normal tool definition and calls it like any other; we
--              execute locally and feed results back. Works with ANY
--              endpoint / API key, including mimo Token Plan that has no
--              server-side search of its own.
--            - web_fetch(url, max_bytes, mode): pulls a URL through Jina
--              Reader by default (HTML → clean markdown, no key needed);
--              mode='raw' GETs the body as-is for JSON / text endpoints.
--            Plumbing additions:
--            - tools.lua: REGISTRY entries can now declare async=true with
--              start/poll fns. M.dispatch returns a pending wrapper for
--              async tools; chat.lua polls each tick (new running_tool
--              state, _poll_running_tool / _finish_tool helpers). UI stays
--              responsive during the 1-5s search/fetch round-trip.
--            - http.lua: build_curl_cmd accepts opts.method (default POST,
--              GET supported); M.start skips --data-binary when body=nil.
--            - Settings dialog grows a 5th field "Search API key" (Tavily,
--              tvly-..., optional). When empty, web_search returns a clear
--              error instead of crashing.
--            - The 0.6.0 Anthropic server-side web_search injection and the
--              0.6.0 OpenAI *-search-preview path are still in place;
--              client-side tools are a parallel mechanism that works on
--              all the other channels.
--            - Thinking-mode preservation. Providers like mimo v2/v2.5 and
--              DeepSeek-R1 stream the model's hidden reasoning via
--              delta.reasoning_content and REQUIRE that text to be echoed
--              back as message.reasoning_content on subsequent turns
--              (otherwise the multi-round tool-use loop 400s with "The
--              reasoning_content in the thinking mode must be passed back
--              to the API"). The OpenAI provider now collects this stream,
--              stores it as a Lua {type="thinking", thinking=...} block in
--              the canonical message history, and messages_to_openai
--              re-emits it on the next request. The block is intentionally
--              not rendered by ui.lua — it's purely roundtrip plumbing.
--   * 0.6.1  Settings help: document mimo Token Plan vs pay-as-you-go split.
--            The Token Plan (tp-xxx key + token-plan-cn.xiaomimimo.com) is a
--            separate billing system from pay-as-you-go (sk-xxx key +
--            api.xiaomimimo.com); the Web Search Plugin activation only
--            applies to the latter. An earlier draft of 0.6.1 tried to
--            auto-inject mimo's {type:"web_search"} tool whenever the base
--            URL pointed at xiaomimimo.com — that hit a 400 on Token Plan
--            ("webSearchEnabled is false") and was reverted. Server-side
--            web search through mimo is currently only reachable via the
--            pay-as-you-go endpoint with a sk- key, and we leave that to
--            the user to opt into manually for now.
--   * 0.6.0  Server-side web search via provider-native APIs. When connected
--            to api.anthropic.com (or any *.anthropic.com host) the Anthropic
--            provider auto-attaches the web_search_20250305 tool with
--            max_uses=5. The OpenAI provider auto-enables web_search_options
--            for *-search-preview models. Detection is by settings.base_url /
--            model only — no UI toggle. Third-party Anthropic-compat proxies
--            (e.g. mimo) are skipped so they don't get the server tool sent
--            as a client tool ("unknown tool: web_search"). UI shows
--            "🔍 搜索中…" inline while Anthropic is searching, and both
--            providers list source URLs at the end of the assistant message.
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

if not reaper.ImGui_CreateContext then
    reaper.MB("MCAssistant requires the ReaImGui extension.\n\n" ..
              "Install via ReaPack (Extensions → ReaPack → Browse packages → ReaImGui).",
              "MCAssistant", 0)
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
  小米 mimo Token Plan: openai / https://token-plan-cn.xiaomimimo.com/v1 / mimo-v2.5 / tp-...
       （Token Plan 套餐不含联网搜索；要联网需切到 pay-as-you-go: sk-... + api.xiaomimimo.com/v1）
  Ollama 本地: openai / http://localhost:11434/v1 / llama3.1 / 任意非空字符串

Search API key (可选): 联网搜索通过本地工具 web_search / web_fetch 实现，
跟模型厂商无关。后端用 Tavily (https://tavily.com)，免费 1000 次/月。
注册后拿 tvly-... 形式的 key，通过状态栏的「搜索」开关配置。
留空则模型没法搜，但其他功能照常。
HTML→纯文本走 Jina Reader (r.jina.ai)，免登录，无需额外 key。

API key 以明文存于 reaper-extstate.ini —— 建议用低额度专用 key。
]]

local function load_settings()
  return {
        type               = reaper.GetExtState(EXT, "provider_type"),
        base_url           = reaper.GetExtState(EXT, "base_url"),
        model              = reaper.GetExtState(EXT, "model"),
        api_key            = reaper.GetExtState(EXT, "api_key"),
        search_api_key     = reaper.GetExtState(EXT, "search_api_key"),
        web_search_enabled = reaper.GetExtState(EXT, "web_search_enabled"),
    }
end

local function save_settings(s)
    reaper.SetExtState(EXT, "provider_type",      s.type               or "", true)
    reaper.SetExtState(EXT, "base_url",           s.base_url           or "", true)
    reaper.SetExtState(EXT, "model",              s.model              or "", true)
    reaper.SetExtState(EXT, "api_key",            s.api_key            or "", true)
    reaper.SetExtState(EXT, "search_api_key",     s.search_api_key     or "", true)
    reaper.SetExtState(EXT, "web_search_enabled", s.web_search_enabled or "", true)
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- Resolve whether web search is enabled. Migration rule: if the flag is
-- empty (pre-0.6.3 user), treat a non-empty search_api_key as "implicitly
-- enabled" so existing users don't have to reconfigure after upgrade.
local function is_web_search_enabled_for(settings)
    if not settings then return false end
    local flag = settings.web_search_enabled or ""
    if flag == "" then return (settings.search_api_key or "") ~= "" end
    return flag == "1"
end

-- Follow-up dialog shown when the user just flipped web search ON but had no
-- Tavily key on file. A single-field prompt so it's not jarring.
local function prompt_search_key(current_key)
    local ok, csv = reaper.GetUserInputs(
        "MCAssistant — Tavily Search Key",
        1,
        "Search API key (tvly-...),extrawidth=520",
        current_key or "")
    if not ok then return nil end
    return trim(csv)
end

local function prompt_settings(current, show_help)
    if show_help then reaper.MB(SETTINGS_HELP, "MCAssistant — Settings", 0) end

    local fields = "Type (anthropic/openai),Base URL (blank=default),Model,API key,extrawidth=520,separator=|"
    local default = table.concat({
        (current and current.type)     or "anthropic",
        (current and current.base_url) or "",
        (current and current.model)    or "claude-sonnet-4-6",
        (current and current.api_key)  or "",
    }, "|")
    local ok, csv = reaper.GetUserInputs("MCAssistant — API Settings", 4, fields, default)
    if not ok then return nil end

    local parts = {}
    for p in (csv .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
    local s = {
        type     = trim(parts[1] or ""):lower(),
        base_url = trim(parts[2] or ""),
        model    = trim(parts[3] or ""),
        api_key  = trim(parts[4] or ""),
    }

    if s.type ~= "anthropic" and s.type ~= "claude" and s.type ~= "openai" then
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
local ui  -- forward declaration for callbacks

-- Open the in-app settings popup, pre-populated with the current values.
local function on_settings()
    if not ui then return end
    ui_mod.open_settings_overlay(ui, settings)
end

-- Save callback fired by the settings popup. Returns (ok, err_message).
-- ok=true → popup closes; err_message=string → MB shown, popup stays open.
local function on_save_settings(s)
    if s.type ~= "anthropic" and s.type ~= "openai" then
        return false, "Provider type 必须是 'anthropic' 或 'openai'。"
    end
    if s.api_key == "" then
        return false, "API key 不能为空。"
    end
    -- Preserve web_search_enabled flag (managed via the toggle button, not the
    -- text fields here).
    s.web_search_enabled = settings.web_search_enabled
    settings = s
    save_settings(settings)
    chat.provider = provider.create(settings)
    return true
end

local function on_toggle_search(_is_right)
    local currently_on = is_web_search_enabled_for(settings)
    local new_on = not currently_on
    settings.web_search_enabled = new_on and "1" or "0"
    save_settings(settings)

    if ui then ui_mod.set_web_search_state(ui, new_on) end
end

--------------------------------------------------------------------------------
-- wire up UI
--------------------------------------------------------------------------------
-- Window geometry is persisted inside ui.frame() each tick (ReaImGui exposes
-- GetWindowPos/GetWindowSize directly). No gfx, no atexit save, no hwnd —
-- ReaImGui's InputTextMultiline handles CJK / IME natively, so the old
-- on_chinese_input modal path is gone.
ui = ui_mod.new(chat, {
    on_settings      = on_settings,
    on_save_settings = on_save_settings,
    on_toggle_search = on_toggle_search,
})

ui_mod.set_web_search_state(ui, is_web_search_enabled_for(settings))

--------------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------------
local function main()
    chat:tick()   -- advance async state machine
    if not ui_mod.frame(ui) then return end   -- user closed window
    reaper.defer(main)
end

main()

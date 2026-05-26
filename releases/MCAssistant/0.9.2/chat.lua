--
-- chat.lua  —  Tick-based conversation state machine.
--
-- send_user(text) schedules work. tick() must be called every main-loop
-- frame to advance the state machine. The UI reads self.events for display.
--
-- States:
--   idle    — nothing in flight
--   awaiting     — waiting for first bytes from provider
--   streaming    — receiving deltas; live_event.text grows
--   tool_dispatch— running pending tool calls one per tick
--
-- live_event (nil when not streaming) points at the event the UI should
-- re-wrap every frame. After done we clear it and the cache caches it.
--

local json = require("json")

local M = {}

local DEFAULT_SYSTEM = [[
You are an assistant embedded in REAPER, a digital audio workstation. The user
is a sound designer working primarily with sound-effects libraries through
REAPER's Media Explorer, plus normal multitrack editing.

You can call tools to inspect REAPER state and perform batch operations on
items, tracks, FX, and MIDI. Write tools are wrapped in Undo blocks (user can
revert with Ctrl+Z).

Guidelines:
- Be concise. The chat panel is small.
- Prefer to call tools directly rather than asking permission. If a
  precondition is missing (e.g. "no items selected"), state what's missing
  in one short sentence.
- Use dedicated tools first. If the existing tools cannot express the task,
  use reaper_lua_execute to run a short Lua snippet against REAPER's API.
  Keep generated code small, inspect project state before changing indexes,
  return a compact table/string when useful, and explain the result briefly.
  Do not use reaper_lua_execute for filesystem access, network access,
  external processes, background defer loops, or long-running / CPU-heavy work
  (a tight loop will freeze REAPER). It runs in a restricted sandbox, preflights
  blocked identifiers/APIs before execution, and records prints/results in the
  chat. Each run must be confirmed by the user, so keep snippets tiny and
  obviously safe. Large numeric literals are rejected (no `for i=1,1e7`, no
  `string.rep(x, 1e6)`); iterate over project collections by their real counts
  (e.g. reaper.CountMediaItems) instead of huge fixed ranges. Do not try to
  bypass the sandbox via the action system (reaper.Main_OnCommand), ReaPack, or
  by registering scripts — those are blocked. If the user asks to test a
  dangerous API such as os.execute or reaper.defer, call reaper_lua_execute with
  that snippet and let preflight report the block; do not try to work around it.
- Before destructive or ambiguous operations (delete, bulk overwrite, render,
  irreversible changes, or vague user intent), ask for confirmation.
- For MIDI: scientific pitch (C4 = MIDI 60); default 120 BPM (0.5s/beat);
  default velocity 96.
- FX parameter workflow: when the user asks to adjust an FX parameter,
  first call track_fx_list (if you don't know the fx_index) then
  track_fx_list_params to see exact parameter names and current values —
  do NOT guess parameter names. Then call track_fx_set_params. Prefer
  value_text (e.g. "-6dB", "440Hz") when the user gave a concrete value;
  fall back to value_normalized (0-1) otherwise.
- Loudness normalisation (items_normalize_loudness): if the user gives
  an explicit target (e.g. "-16 LUFS"), use it. If the user describes
  content instead (e.g. "casual game UI SFX", "podcast voice",
  "broadcast"), propose an industry-appropriate target — typically
  -16 LUFS for streaming/games, -23 LUFS for broadcast (EBU R128),
  -14 LUFS for Spotify, -1 dBTP for safety-only — and confirm with the
  user BEFORE calling the tool. Call items_get_loudness first if it
  helps explain the proposal.
- Audio export (project_render): bounds and format are required and have
  no defaults. If the user is vague ("帮我导出"), ASK before calling. If
  the user is concrete ("导出选中的到桌面"), infer bounds=selected_items
  and output_directory= their Desktop (Windows: C:\\Users\\<name>\\Desktop).
  For "按原格式导出 / match source format", call items_get_info first to
  read source_type / source_samplerate / source_channels, then pick the
  closest preset (WAVE → wav_24, MP3 → mp3_320, FLAC → flac). When
  multiple items are selected, the tool defaults to one file per item;
  only pass merge=true if the user EXPLICITLY asks to combine/mixdown
  (合并 / 混成一个 / 拼一起 / one file). Render is synchronous and
  freezes REAPER's UI for the render duration — mention this if the
  scope is large (whole project, many regions).
- Web access: when the user asks about something you can't know from training
  data (current news, today's weather, prices, fresh docs, etc.), use the
  web_search tool — it queries Tavily and returns title/url/content snippets
  that are usually enough to answer directly. Only fall through to web_fetch
  when the snippet isn't detailed enough or the user pastes a specific URL
  they want read. web_fetch defaults to Jina Reader for clean markdown; pass
  mode='raw' for JSON / plain-text endpoints. Both tools are provider-agnostic
  (work on any LLM endpoint) and run asynchronously without freezing REAPER.
- The user may write in Chinese; respond in Chinese when they do.
]]

local Chat = {}
Chat.__index = Chat

function M.new(provider, tools_module, system_prompt)
    return setmetatable({
    provider   = provider,
        tools      = tools_module,
        system     = system_prompt or DEFAULT_SYSTEM,
        messages   = {},
     events     = {},
        state      = "idle",
        req        = nil,
        live_event = nil,
        live_index = nil,
  pending_tools = nil,  -- array of tool_use blocks to execute
        local_tool_final = nil, -- local assistant text when no provider follow-up is needed
        running_tool = nil,  -- { tu, pending } for the currently-running async tool
        iter    = 0,
  max_iters  = 8,
     is_busy    = false,
    }, Chat)
end

function Chat:add_event(ev)
    self.events[#self.events + 1] = ev
    return #self.events
end

function Chat:clear()
    self.messages = {}
    self.events = {}
    self.live_event = nil
    self.live_index = nil
end

-- Start a new request round: call provider:start and enter awaiting state.
function Chat:_begin_request()
    self.iter = self.iter + 1
    if self.iter > self.max_iters then
        self:add_event({ kind = "error", text = "max tool-use iterations reached" })
        self:_finish()
        return
    end

    local req = self.provider:start(self.system, self.messages, self.tools.TOOL_LIST)
    if req.err then
   self:add_event({ kind = "error", text = req.err })
   self:_finish()
      return
    end
    self.req = req
    self.state = "awaiting"

    -- live_event may already exist (set by send_user, or carried over from a
    -- previous round). Only pre-create if it's missing (e.g. follow-up round
    -- after tool dispatch).
    if not self.live_event then
        local ev = { kind = "assistant", text = "", live = true }
        self.live_index = self:add_event(ev)
        self.live_event = ev
    end
end

function Chat:_finish()
    self.state = "idle"
    self.req = nil
self.pending_tools = nil
    self.local_tool_final = nil
    self.running_tool = nil
    self.is_busy = false
    self.iter = 0
    self:_set_search_status(false)
    if self.live_event then
        self.live_event.live = false
      -- If the live event ended up empty (e.g. only tool_use, no text),
        -- drop it so the UI doesn't render a phantom "AI" line.
      if (self.live_event.text or "") == "" then
       table.remove(self.events, self.live_index)
   end
    end
    self.live_event = nil
 self.live_index = nil
end

function Chat:send_user(text, attachments)
    if self.state ~= "idle" then return end
    -- Allow send with only images (no text).
    local has_text = text and text ~= ""
    local has_att  = attachments and #attachments > 0
    if not has_text and not has_att then return end
    self.is_busy = true

    -- Build user event for display (carries attachments for thumbnail rendering).
    local user_ev = { kind = "user", text = text or "" }
    if has_att then user_ev.attachments = attachments end
    self:add_event(user_ev)

    -- Build message content: string when text-only, block array when images.
    if has_att then
        local blocks = {}
        if has_text then
            blocks[#blocks + 1] = { type = "text", text = text }
        end
        for _, att in ipairs(attachments) do
            blocks[#blocks + 1] = {
                type   = "image",
                source = {
                    type       = "base64",
                    media_type = att.mime,
                    data       = att.b64,
                },
            }
        end
        self.messages[#self.messages + 1] = { role = "user", content = blocks }
    else
        self.messages[#self.messages + 1] = { role = "user", content = text }
    end

    -- Pre-create the live assistant event so the spinner shows in the SAME
    -- frame as the user bubble (this frame).
    local ev = { kind = "assistant", text = "", live = true }
    self.live_index = self:add_event(ev)
    self.live_event  = ev
    self.iter  = 0
    self.state = "queued"  -- tick() advances queued→starting (next frame)→awaiting
end

-- Append final assistant blocks to messages and queue any tool_use blocks.
function Chat:_handle_done(content, stop_reason)
    self.messages[#self.messages + 1] = { role = "assistant", content = content }

    -- Clear the "🔍 搜索中…" indicator in case the model finished without
    -- emitting a matching server_search_result (defensive: covers any edge
    -- case where the result block was missed by the SSE parser).
    self:_set_search_status(false)

    -- Drop the live text event; we replace it with canonical text blocks.
    if self.live_event then
       self.live_event.live = false
        if (self.live_event.text or "") == "" then
         table.remove(self.events, self.live_index)
 end
    end
    self.live_event = nil
    self.live_index = nil

  local tool_uses = {}
    local had_text = false
    for _, block in ipairs(content) do
     if block.type == "text" and block.text and block.text ~= "" then
     had_text = true
       -- The streamed text is already in events via live updates, but if
  -- we dropped a live event (empty), re-add the real text now.
       -- Simpler path: always re-add as a frozen event, and skip the
-- now-deleted live one.
    -- To avoid duplication, only add if no live text was shown.
       -- In practice streaming fills live_event; we check had_text and
        -- see if the last event is assistant-kind with matching text.
    local last = self.events[#self.events]
      if not (last and last.kind == "assistant" and last.text == block.text) then
       self:add_event({ kind = "assistant", text = block.text })
            end
        elseif block.type == "tool_use" then
       tool_uses[#tool_uses + 1] = block
   end
    end

  if stop_reason == "tool_use" and #tool_uses > 0 then
        self.pending_tools = tool_uses
        self.pending_results = {}
        self.state = "tool_dispatch"
    else
        self:_finish()
    end
end

-- Record the final result of a tool_use (sync or async) and stash it in
-- pending_results to be sent back as the next user message.
function Chat:_finish_tool(tu, result)
    self:add_event({ kind = "tool_result", name = tu.name, output = result })
    local ok2, encoded = pcall(json.encode, result)
    if not ok2 then encoded = '{"ok":false,"error":"could not encode tool result"}' end
    self.pending_results[#self.pending_results + 1] = {
     type        = "tool_result",
        tool_use_id = tu.id,
     content   = encoded,
        is_error    = (result and result.ok == false) or nil,
    }

    -- Security blocks are already the final answer. Sending them back into some
    -- OpenAI-compatible providers as a second tool-result round has caused hangs
    -- on this setup, so finish locally and return to idle. Covers both static
    -- preflight rejections (^blocked ...) and runtime sandbox blocks raised from
    -- the proxy mid-execution (blocked field access, API cap, read-only reaper).
    -- Ordinary compile/runtime errors are intentionally NOT caught here — they
    -- go back to the model so it can self-correct.
    if tu.name == "reaper_lua_execute"
        and result and result.ok == false
        and type(result.error) == "string" then
        local e = result.error
        if e:match("^blocked")        -- preflight: identifier/API/syntax/expression/numeric-literal
           or e:find("is blocked in reaper_lua_execute", 1, true)  -- runtime proxy block
           or e:find("API call limit exceeded", 1, true)
           or e:find("reaper table is read-only", 1, true) then
            self.local_tool_final = "已拦截：" .. e .. "（沙箱安全限制）。"
        elseif e:find("execution declined by user", 1, true) then
            self.local_tool_final = "已取消：你拒绝了这段代码的执行。"
        end
    end
end

-- Continue an already-started async tool. Called every tick while running_tool
-- is set; returns immediately (and stays in this state) until poll() yields a
-- non-nil result.
function Chat:_poll_running_tool()
    local rt = self.running_tool
    local result = self.tools.poll(rt.pending)
    if result == nil then return end  -- still pending; try next tick
    self.running_tool = nil
    self:_finish_tool(rt.tu, result)
end

-- Run ONE pending tool per tick to keep UI responsive. Sync tools finish in
-- the same tick; async tools transition to running_tool and finish later via
-- _poll_running_tool.
function Chat:_step_tool_dispatch()
    if self.running_tool then return self:_poll_running_tool() end

    if not self.pending_tools or #self.pending_tools == 0 then
      -- All tools done — build user message with results and re-enter request.
        self.messages[#self.messages + 1] = { role = "user", content = self.pending_results }
        -- Only short-circuit to a local answer when the blocked snippet was the
        -- ONLY tool in this batch. If other tools also ran, their results must
        -- go back to the model, so fall through to a normal follow-up request.
        if self.local_tool_final and #self.pending_results <= 1 then
            self.messages[#self.messages + 1] = {
                role = "assistant",
                content = self.local_tool_final,
            }
            self:add_event({ kind = "assistant", text = self.local_tool_final })
            self.local_tool_final = nil
            self.pending_tools = nil
            self.pending_results = nil
            self:_finish()
            return
        end
        self.local_tool_final = nil
        self.pending_tools = nil
        self.pending_results = nil
        self:_begin_request()
        return
    end

    local tu = table.remove(self.pending_tools, 1)
    self:add_event({ kind = "tool_call", name = tu.name, input = tu.input })
    local result = self.tools.dispatch(tu.name, tu.input)
    if type(result) == "table" and result.pending then
        self.running_tool = { tu = tu, pending = result }
        return  -- next tick enters _poll_running_tool
    end
    self:_finish_tool(tu, result)
end

function Chat:tick()
    if self.state == "idle" then return end

    if self.state == "tool_dispatch" then
        self:_step_tool_dispatch()
     return
    end

    -- One-frame defer between user input and the blocking provider:start I/O,
    -- so the user bubble + spinner paint before HTTP setup happens.
    if self.state == "queued" then
        self.state = "starting"
        return
    end

    if self.state == "starting" then
        self:_begin_request()
        return
    end

    -- awaiting / streaming
    local r = self.provider:poll(self.req)
    if r.kind == "delta" then
        if self.state == "awaiting" then self.state = "streaming" end
        if self.live_event then
  self.live_event.text = self.live_event.text .. r.text
      end
    elseif r.kind == "done" then
 if r.tail_delta and self.live_event then
      self.live_event.text = self.live_event.text .. r.tail_delta
        end
        -- OpenAI delivers url_citation sources alongside done; merge them
        -- onto the live assistant event before _handle_done freezes it.
        if r.sources and self.live_event then
            self:_merge_sources(self.live_event, r.sources)
        end
        self:_handle_done(r.content, r.stop_reason)
    elseif r.kind == "server_search_start" then
        -- Anthropic only: the model is about to run web_search. Drop a
        -- transient "searching" indicator above the live assistant text.
        -- It gets cleared when the matching result arrives (or when the
        -- assistant message finishes).
        self:_set_search_status(true)
    elseif r.kind == "server_search_result" then
        if self.live_event and r.sources then
            self:_merge_sources(self.live_event, r.sources)
        end
        self:_set_search_status(false)
    elseif r.kind == "error" then
        self:add_event({ kind = "error", text = r.err })
        self:_finish()
    end
    -- r.kind == "idle" -> no change
end

-- Merge an incoming sources array onto an event's .sources, deduping by URL.
function Chat:_merge_sources(ev, sources)
    if not ev or not sources or #sources == 0 then return end
    ev.sources = ev.sources or {}
    ev._source_urls = ev._source_urls or {}
    for _, s in ipairs(sources) do
        local url = s and s.url
        if url and not ev._source_urls[url] then
            ev._source_urls[url] = true
            ev.sources[#ev.sources + 1] = { url = url, title = s.title or url }
        end
    end
end

-- Toggle the ephemeral "🔍 搜索中…" status row. Stored at self.search_event
-- so we can remove it on result/done without scanning self.events.
function Chat:_set_search_status(on)
    if on then
        if self.search_event then return end  -- already showing
        local ev = { kind = "search_status", text = "🔍 搜索中…" }
        self.search_index = self:add_event(ev)
        self.search_event = ev
    else
        if not self.search_event then return end
        -- Remove by identity rather than index — other events may have been
        -- appended in between, shifting the stored index.
        for i = #self.events, 1, -1 do
            if self.events[i] == self.search_event then
                table.remove(self.events, i)
                break
            end
        end
        self.search_event = nil
        self.search_index = nil
    end
end

function Chat:status_text()
    if self.state == "idle" then return "空闲" end
    if self.state == "queued" or self.state == "starting" then return "等待响应…" end
    if self.state == "awaiting" then return "等待响应…" end
    if self.state == "streaming" then
   local n = (self.live_event and #self.live_event.text) or 0
 return ("● 流式中 (%d字)"):format(n)
    end
    if self.state == "tool_dispatch" then
        if self.running_tool then
            return ("运行 %s…"):format(self.running_tool.tu.name)
        end
        local pending = self.pending_tools and #self.pending_tools or 0
        return ("运行工具 (还剩 %d)"):format(pending)
    end
    return self.state
end

return M

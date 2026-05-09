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
items, tracks, FX, and MIDI. Tools execute synchronously inside REAPER and
are wrapped in Undo blocks (user can revert with Ctrl+Z).

Guidelines:
- Be concise. The chat panel is small.
- Prefer to call tools directly rather than asking permission. If a
  precondition is missing (e.g. "no items selected"), state what's missing
  in one short sentence.
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
    self.is_busy = false
    self.iter = 0
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

function Chat:send_user(text)
    if self.state ~= "idle" then return end
    if not text or text == "" then return end
    self.is_busy = true
    self:add_event({ kind = "user", text = text })
    self.messages[#self.messages + 1] = { role = "user", content = text }
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

-- Run ONE pending tool per tick to keep UI responsive.
function Chat:_step_tool_dispatch()
    if not self.pending_tools or #self.pending_tools == 0 then
      -- All tools done — build user message with results and re-enter request.
        self.messages[#self.messages + 1] = { role = "user", content = self.pending_results }
   self.pending_tools = nil
        self.pending_results = nil
      self:_begin_request()
 return
    end

    local tu = table.remove(self.pending_tools, 1)
    self:add_event({ kind = "tool_call", name = tu.name, input = tu.input })
    local result = self.tools.dispatch(tu.name, tu.input)
    self:add_event({ kind = "tool_result", name = tu.name, output = result })

    local ok2, encoded = pcall(json.encode, result)
    if not ok2 then encoded = '{"ok":false,"error":"could not encode tool result"}' end
    self.pending_results[#self.pending_results + 1] = {
     type        = "tool_result",
        tool_use_id = tu.id,
     content   = encoded,
        is_error    = (result and result.ok == false) or nil,
    }
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
        self:_handle_done(r.content, r.stop_reason)
    elseif r.kind == "error" then
        self:add_event({ kind = "error", text = r.err })
        self:_finish()
    end
    -- r.kind == "idle" -> no change
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
        local pending = self.pending_tools and #self.pending_tools or 0
return ("运行工具 (还剩 %d)"):format(pending)
    end
    return self.state
end

return M

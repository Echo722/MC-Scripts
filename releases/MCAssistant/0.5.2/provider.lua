--
-- provider.lua  —  AI provider abstraction, streaming-first.
--
-- Internal message shape mirrors Anthropic's Messages API:
--   { role = "user"|"assistant", content = string OR { block, ... } }
-- Block types:
--   { type="text", text="..." }
--{ type="tool_use", id="...", name="...", input={ ... } }
--   { type="tool_result", tool_use_id="...", content="..." }   -- in user role
--
-- Interface:
-- req = provider:start(system, messages, tools)
-- ev  = provider:poll(req)
-- returns { kind="delta", text=string }
--    | { kind="tool_partial" }     (swallowed internally)
--       | { kind="idle" }
--       | { kind="done", content=blocks, stop_reason=string }
--     | { kind="error", err=string }
--
-- Two flavors: "claude" (Anthropic) and "openai" (OpenAI-compatible).
--

local json = require("json")
local http = require("http")

local M = {}

-- Force tool_use.input tables to encode as JSON objects even when empty.
local function mark_tool_inputs(blocks)
    if type(blocks) ~= "table" then return blocks end
    for _, b in ipairs(blocks) do
        if type(b) == "table" and b.type == "tool_use" and type(b.input) == "table" then
        json.as_object(b.input)
      end
  end
 return blocks
end

-- Split an SSE buffer on blank lines. Returns array of event strings plus
-- the unconsumed tail (for the next poll). Handles \n\n and \r\n\r\n.
local function split_sse(buf)
    local events = {}
    local i = 1
    while true do
    local s, e = buf:find("\r?\n\r?\n", i)
    if not s then break end
        events[#events + 1] = buf:sub(i, s - 1)
        i = e + 1
    end
    return events, buf:sub(i)
end

-- Parse one SSE event block into { event=name, data=string }.
-- "data:" lines are concatenated with newlines per the SSE spec.
local function parse_sse_event(block)
    local name, data_parts = nil, {}
    for line in (block .. "\n"):gmatch("([^\r\n]*)\r?\n") do
local k, v = line:match("^([^:]+):%s?(.*)$")
        if k == "event" then name = v
   elseif k == "data"  then data_parts[#data_parts + 1] = v end
    end
    return { event = name, data = table.concat(data_parts, "\n") }
end

--==============================================================================
-- Claude (Anthropic Messages API) — streaming
--==============================================================================

local function claude_start(self, system, messages, tools)
    local body = {
        model      = self.model,
        max_tokens = 4096,
 messages   = messages,
        stream     = true,
    }
    if system and system ~= "" then body.system = system end
if tools and #tools > 0 then body.tools = tools end

    local ok, body_json = pcall(json.encode, body)
    if not ok then return { err = "json encode: " .. tostring(body_json) } end

local base = (self.base_url ~= "" and self.base_url) or "https://api.anthropic.com"
    base = base:gsub("/+$", "")

    local headers = {
   ["x-api-key"]  = self.api_key,
     ["anthropic-version"] = "2023-06-01",
        ["content-type"]= "application/json",
        ["accept"]        = "text/event-stream",
    }

    local handle = http.start(base .. "/v1/messages", headers, body_json,
 { stream = true, timeout_ms = 120000 })

    return {
     flavor = "claude",
    handle = handle,
        sse_buf = "",
   blocks = {},     -- accumulated content blocks
        block_json_acc = {}, -- index -> partial_json string for tool_use
    stop_reason = nil,
        err = nil,
        done = false,
    }
end

local function claude_handle_event(req, ev)
    if ev.event == "message_start" or ev.event == "ping" then return end
    if ev.data == "" then return end
    local okp, payload = pcall(json.decode, ev.data)
    if not okp then return end

    if ev.event == "content_block_start" then
    local idx = payload.index or 0
        local cb= payload.content_block or {}
        local block = { type = cb.type }
        if cb.type == "text" then
            block.text = cb.text or ""
        elseif cb.type == "tool_use" then
            block.id   = cb.id
       block.name = cb.name
       block.input = {}
         json.as_object(block.input)
 req.block_json_acc[idx] = ""
 end
        req.blocks[idx + 1] = block
        return
    end

    if ev.event == "content_block_delta" then
local idx = payload.index or 0
  local d = payload.delta or {}
        local block = req.blocks[idx + 1]
        if not block then return end
        if d.type == "text_delta" and d.text then
     block.text = (block.text or "") .. d.text
      return { kind = "delta", text = d.text }
   elseif d.type == "input_json_delta" and d.partial_json then
       req.block_json_acc[idx] = (req.block_json_acc[idx] or "") .. d.partial_json
    end
 return
    end

    if ev.event == "content_block_stop" then
        local idx = payload.index or 0
    local block = req.blocks[idx + 1]
        if block and block.type == "tool_use" then
      local acc = req.block_json_acc[idx] or ""
  if acc ~= "" then
       local okj, parsed = pcall(json.decode, acc)
                if okj and type(parsed) == "table" then
  block.input = parsed
   json.as_object(block.input)
           end
            end
        end
   return
    end

    if ev.event == "message_delta" then
    if payload.delta and payload.delta.stop_reason then
      req.stop_reason = payload.delta.stop_reason
        end
 return
    end

    if ev.event == "message_stop" then
        req.stop_reason = req.stop_reason or "end_turn"
    return
    end
end

local function claude_poll(self, req)
    if req.done then return { kind = "idle" } end

    local r = http.poll(req.handle)
  if r.partial and r.partial ~= "" then
        req.sse_buf = req.sse_buf .. r.partial
    end

 local events, tail = split_sse(req.sse_buf)
 req.sse_buf = tail

  local delta_text = nil
    for _, block_str in ipairs(events) do
   local parsed = parse_sse_event(block_str)
        local out = claude_handle_event(req, parsed)
  if out and out.kind == "delta" then
   delta_text = (delta_text or "") .. out.text
  end
 end

    if r.done then
   req.done = true
   if r.err then
          -- Error may still be an HTTP error body in req.sse_buf; prefer that
         local err = r.err
      if req.sse_buf ~= "" then err = err .. "  body=" .. req.sse_buf:sub(1, 300) end
         return { kind = "error", err = err }
        end
        if r.status and r.status >= 400 then
     local msg = (r.body or ""):sub(1, 300)
    return { kind = "error", err = ("API %d: %s"):format(r.status, msg) }
  end
  -- Compact blocks (remove holes from sparse indexing)
        local final = {}
for _, b in pairs(req.blocks) do final[#final + 1] = b end
        mark_tool_inputs(final)
        if delta_text then
          -- bundle last delta with done
    return { kind = "done", content = final,
  stop_reason = req.stop_reason or "end_turn",
           tail_delta = delta_text }
  end
 return { kind = "done", content = final, stop_reason = req.stop_reason or "end_turn" }
    end

    if delta_text then return { kind = "delta", text = delta_text } end
    return { kind = "idle" }
end

--==============================================================================
-- OpenAI Chat Completions compatible — streaming
--==============================================================================

local function tools_to_openai(tools)
  if not tools or #tools == 0 then return nil end
    local out = {}
    for _, t in ipairs(tools) do
  out[#out + 1] = {
     type = "function",
  ["function"] = {
           name        = t.name,
       description = t.description,
                parameters  = t.input_schema or { type = "object", properties = {} },
        }
 }
    end
    return out
end

local function messages_to_openai(messages, system)
    local out = {}
    if system and system ~= "" then
  out[#out + 1] = { role = "system", content = system }
    end
    for _, m in ipairs(messages) do
if type(m.content) == "string" then
      out[#out + 1] = { role = m.role, content = m.content }
   elseif m.role == "user" then
            local text_parts, tool_results = {}, {}
  for _, b in ipairs(m.content) do
   if b.type == "tool_result" then
    tool_results[#tool_results + 1] = b
      elseif b.type == "text" then
               text_parts[#text_parts + 1] = b.text
      end
end
 for _, tr in ipairs(tool_results) do
     local content = tr.content
   if type(content) ~= "string" then content = json.encode(content or {}) end
    out[#out + 1] = {
               role = "tool",
 tool_call_id = tr.tool_use_id,
    content = content,
      }
    end
            if #text_parts > 0 then
        out[#out + 1] = { role = "user", content = table.concat(text_parts, "\n") }
        end
      elseif m.role == "assistant" then
            local text_parts, tool_calls = {}, {}
      for _, b in ipairs(m.content or {}) do
                if b.type == "text" then
       text_parts[#text_parts + 1] = b.text
       elseif b.type == "tool_use" then
       tool_calls[#tool_calls + 1] = {
    id   = b.id,
             type = "function",
        ["function"] = {
     name      = b.name,
       arguments = json.encode(b.input or {}),
   }
       }
          end
     end
  local msg = { role = "assistant",
     content = (#text_parts > 0) and table.concat(text_parts, "\n") or "" }
     if #tool_calls > 0 then msg.tool_calls = tool_calls end
     out[#out + 1] = msg
  end
    end
    return out
end

local function openai_finish_to_stop_reason(finish)
    if finish == "tool_calls" then return "tool_use" end
    if finish == "length"     then return "max_tokens" end
    if finish == "stop"  then return "end_turn" end
    return finish or "end_turn"
end

local function openai_start(self, system, messages, tools)
    local body = {
        model    = self.model,
        messages = messages_to_openai(messages, system),
  stream   = true,
    }
    local oa_tools = tools_to_openai(tools)
    if oa_tools then body.tools = oa_tools end

    local ok, body_json = pcall(json.encode, body)
    if not ok then return { err = "json encode: " .. tostring(body_json) } end

 local base = (self.base_url ~= "" and self.base_url) or "https://api.openai.com/v1"
    base = base:gsub("/+$", "")

    local headers = {
  ["authorization"] = "Bearer " .. self.api_key,
        ["content-type"]  = "application/json",
        ["accept"]     = "text/event-stream",
    }
    if base:match("openrouter%.ai") then
        headers["http-referer"] = "https://github.com/Echo722/MCAssistant"
 headers["x-title"]      = "MCAssistant"
    end

    local handle = http.start(base .. "/chat/completions", headers, body_json,
       { stream = true, timeout_ms = 120000 })

    return {
      flavor = "openai",
        handle = handle,
      sse_buf = "",
text = "",
      tool_calls = {},  -- index -> { id, name, args_str }
        stop_reason = nil,
        done = false,
}
end

local function openai_handle_event(req, ev)
    local data = ev.data
    if data == "" or data == "[DONE]" then return end
    local okp, payload = pcall(json.decode, data)
    if not okp or type(payload) ~= "table" then return end

 local choice = payload.choices and payload.choices[1]
    if not choice then return end

    local delta = choice.delta or {}
    if delta.content and delta.content ~= "" then
      req.text = req.text .. delta.content
 return { kind = "delta", text = delta.content }
    end

  if delta.tool_calls then
        for _, tc in ipairs(delta.tool_calls) do
            local idx = tc.index or 0
     local slot = req.tool_calls[idx]
    if not slot then
          slot = { id = tc.id, name = "", args_str = "" }
             req.tool_calls[idx] = slot
            end
            if tc.id and tc.id ~= "" then slot.id = tc.id end
    local fn = tc["function"]
            if fn then
     if fn.name and fn.name ~= "" then slot.name = fn.name end
       if fn.arguments then slot.args_str = slot.args_str .. fn.arguments end
    end
  end
 end

    if choice.finish_reason then
    req.stop_reason = openai_finish_to_stop_reason(choice.finish_reason)
    end
end

local function openai_finalize_blocks(req)
    local blocks = {}
    if req.text ~= "" then
     blocks[#blocks + 1] = { type = "text", text = req.text }
end
    -- tool_calls is sparse-indexed by tc.index; iterate by numeric key order.
    local indices = {}
    for k in pairs(req.tool_calls) do indices[#indices + 1] = k end
    table.sort(indices)
    for _, idx in ipairs(indices) do
        local slot = req.tool_calls[idx]
        local input = {}
    if slot.args_str ~= "" then
       local okj, parsed = pcall(json.decode, slot.args_str)
 if okj and type(parsed) == "table" then input = parsed end
     end
      json.as_object(input)
        blocks[#blocks + 1] = {
     type = "tool_use",
     id   = slot.id or ("call_" .. tostring(idx)),
            name = slot.name,
            input = input,
  }
 end
    mark_tool_inputs(blocks)
    return blocks
end

local function openai_poll(self, req)
    if req.done then return { kind = "idle" } end

    local r = http.poll(req.handle)
    if r.partial and r.partial ~= "" then
      req.sse_buf = req.sse_buf .. r.partial
    end

    local events, tail = split_sse(req.sse_buf)
    req.sse_buf = tail

    local delta_text = nil
 for _, block_str in ipairs(events) do
  local parsed = parse_sse_event(block_str)
        local out = openai_handle_event(req, parsed)
        if out and out.kind == "delta" then
            delta_text = (delta_text or "") .. out.text
        end
    end

    if r.done then
        req.done = true
      if r.err then
         local err = r.err
    if req.sse_buf ~= "" then err = err .. "  body=" .. req.sse_buf:sub(1, 300) end
            return { kind = "error", err = err }
  end
        if r.status and r.status >= 400 then
     return { kind = "error",
    err = ("API %d: %s"):format(r.status, (r.body or ""):sub(1, 300)) }
        end
      local blocks = openai_finalize_blocks(req)
 return { kind = "done", content = blocks,
      stop_reason = req.stop_reason or "end_turn",
 tail_delta = delta_text }
    end

    if delta_text then return { kind = "delta", text = delta_text } end
    return { kind = "idle" }
end

--==============================================================================
-- Factory
--==============================================================================

function M.create(cfg)
  local t = (cfg.type or "anthropic"):lower()
    if t == "claude" then t = "anthropic" end  -- back-compat alias
    if t == "anthropic" then
        return {
  name     = "anthropic",
type     = "anthropic",
       model    = (cfg.model ~= "" and cfg.model) or "claude-sonnet-4-6",
  base_url = cfg.base_url or "",
            api_key  = cfg.api_key,
       start    = claude_start,
            poll     = claude_poll,
        }
    elseif t == "openai" then
    return {
name     = "openai",
       type  = "openai",
            model  = (cfg.model ~= "" and cfg.model) or "gpt-4o-mini",
            base_url = cfg.base_url or "https://api.openai.com/v1",
       api_key  = cfg.api_key,
            start    = openai_start,
       poll     = openai_poll,
  }
    else
        error("unknown provider type: " .. tostring(t))
    end
end

return M

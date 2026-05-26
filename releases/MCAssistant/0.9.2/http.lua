--
-- http.lua  —  Async HTTP via curl.exe backgrounded through a .bat shim.
--
-- Interface:
--   handle = M.start(url, headers, body, opts)
--   result = M.poll(handle)  ->  { done, status, body, partial, err }
--M.cancel(handle)
-- ok, msg = M.check_curl()
--
-- Why a .bat shim (not direct ExecProcess(curl)):
--   reaper.ExecProcess with timeout=0 launches the command detached. On
--   Windows we need a wrapper that writes a "done" marker when the child
--   exits so poll() can tell we're finished.
--
-- Quirks handled:
--   - CMD expands % inside .bat files. Never write literal % to the bat.
--     That means NO -w "%{http_code}" — use -D headerfile instead and
--     parse the status line from the response headers.
--   - CMD requires backslashes for .bat invocation paths; forward slashes
--     sometimes trigger "9009 command not recognized".
--   - When the entire command line begins with a quoted program, CMD's
--     special "strip outermost quotes" rule can eat our quotes. Using
-- `call "path" ...` avoids it.
--

local M = {}

local CURL = [[C:\Windows\System32\curl.exe]]
local TEMP_DIR = nil

-- Seed once per session so unique_id() is non-deterministic across fast calls.
math.randomseed(math.floor((reaper.time_precise() * 1e6) % 2147483647))

local function ensure_temp_dir()
    if TEMP_DIR then return TEMP_DIR end
    TEMP_DIR = reaper.GetResourcePath() .. "\\Data\\MCAssistant"
    reaper.RecursiveCreateDirectory(TEMP_DIR, 0)
  return TEMP_DIR
end

local function to_win_path(p)
 return (p or ""):gsub("/", "\\")
end

local function write_text(path, data)
    local f = io.open(path, "wb"); if not f then return false end
    f:write(data or ""); f:close(); return true
end

local function read_all(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end

local function read_from(path, offset)
    local f = io.open(path, "rb"); if not f then return "", offset end
    f:seek("set", offset)
    local d = f:read("*a") or ""
    local new_off = offset + #d
    f:close()
    return d, new_off
end

local function file_exists(p)
    local f = io.open(p, "rb"); if f then f:close(); return true end
 return false
end

local _id_counter = 0
local function unique_id()
    _id_counter = _id_counter + 1
    return string.format("%d_%d_%d", os.time(),
      math.floor(reaper.time_precise() * 1e4) % 100000, _id_counter)
end

local function q(s)
    s = tostring(s or "")
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
end

-- Build the curl command. NO % signs (CMD would eat them in .bat context).
-- body_path is nil for body-less methods (GET / HEAD) — --data-binary is omitted.
local function build_curl_cmd(url, headers, body_path, resp_path, hdr_path, stream, method)
    local parts = { "call", q(CURL), "-sS", "-X", q(method or "POST") }
    if stream then
        parts[#parts + 1] = "-N"
        parts[#parts + 1] = "--no-buffer"
 end
    if headers then
 for k, v in pairs(headers) do
     parts[#parts + 1] = "-H"
parts[#parts + 1] = q(k .. ": " .. v)
   end
    end
    if body_path then
        parts[#parts + 1] = "--data-binary"
        parts[#parts + 1] = q("@" .. body_path)
    end
 parts[#parts + 1] = "-o"
    parts[#parts + 1] = q(resp_path)
    parts[#parts + 1] = "-D"
    parts[#parts + 1] = q(hdr_path)
    parts[#parts + 1] = q(url)
    return table.concat(parts, " ")
end

function M.start(url, headers, body, opts)
 opts = opts or {}
 local dir = ensure_temp_dir()
    local id = unique_id()
 local resp_path = to_win_path(dir .. "\\resp_" .. id .. ".bin")
    local hdr_path  = to_win_path(dir .. "\\hdr_"  .. id .. ".txt")
    local bat_path  = to_win_path(dir .. "\\run_"  .. id .. ".bat")
    local done_path = to_win_path(dir .. "\\done_" .. id .. ".txt")
    local err_path  = to_win_path(dir .. "\\err_"  .. id .. ".log")

    -- Body file only when a body is supplied. GET / HEAD pass nil and we skip
    -- writing req_*.bin entirely; build_curl_cmd then omits --data-binary.
    local body_path = nil
    if body ~= nil then
        body_path = to_win_path(dir .. "\\req_"  .. id .. ".bin")
        if not write_text(body_path, body) then
            return { id = id, done = true, err = "failed to write req body" }
        end
    end
    write_text(resp_path, "")
    write_text(hdr_path, "")

  local curl_cmd = build_curl_cmd(url, headers, body_path, resp_path, hdr_path, opts.stream, opts.method)

    -- Shim: run curl, then capture exit code into done_<id>.txt.
    -- We use ENABLEDELAYEDEXPANSION and !ERRORLEVEL! to avoid CMD's
    -- immediate % expansion quirks. `call` avoids the "outer quotes
  -- stripped" case. `>nul` on the chcp keeps the output clean.
    local bat = table.concat({
        "@echo off",
    "setlocal ENABLEDELAYEDEXPANSION",
        "chcp 65001 >nul",
        curl_cmd .. " 2> " .. q(err_path),
  "set RC=!ERRORLEVEL!",
        ">" .. q(done_path) .. " echo !RC!",
   "endlocal",
    }, "\r\n") .. "\r\n"
    if not write_text(bat_path, bat) then
        return { id = id, done = true, err = "failed to write bat shim" }
    end

    reaper.ExecProcess(q(bat_path), 0)

    return {
        id   = id,
        body_path  = body_path,
   resp_path  = resp_path,
     hdr_path   = hdr_path,
   bat_path   = bat_path,
        done_path  = done_path,
        err_path   = err_path,
        offset     = 0,
    stream     = opts.stream and true or false,
      started_at = reaper.time_precise(),
        timeout_ms = opts.timeout_ms or 120000,
        done  = false,
    }
end

local function cleanup(h)
 if h.body_path then os.remove(h.body_path) end
    if h.resp_path then os.remove(h.resp_path) end
    if h.hdr_path  then os.remove(h.hdr_path)  end
    if h.bat_path  then os.remove(h.bat_path)  end
    if h.done_path then os.remove(h.done_path) end
    if h.err_path  then os.remove(h.err_path)  end
end

local function parse_status_from_headers(hdr)
    if not hdr or hdr == "" then return 0 end
  -- Take the LAST HTTP/... status line (handles 100-continue / redirects).
    local last = 0
    for code in hdr:gmatch("HTTP/[%d%.]+ (%d+)") do
      last = tonumber(code) or last
    end
    return last
end

function M.poll(h)
    if h.done then return { done = true, err = h.err, status = h.status, body = h.body } end

    if (reaper.time_precise() - h.started_at) * 1000 > h.timeout_ms then
  h.done = true
        h.err  = "request timed out"
        cleanup(h)
        return { done = true, err = h.err }
    end

local chunk, new_off = read_from(h.resp_path, h.offset)
    h.offset = new_off

    if not file_exists(h.done_path) then
        return { done = false, partial = chunk }
    end

    local final_chunk, _ = read_from(h.resp_path, h.offset)
    h.offset = h.offset + #final_chunk
    local total = (chunk or "") .. (final_chunk or "")

  local body    = read_all(h.resp_path) or ""
    local hdr   = read_all(h.hdr_path)  or ""
  local exit= tonumber((read_all(h.done_path) or ""):match("(%-?%d+)"))
    local err_log = read_all(h.err_path)  or ""

    local status = parse_status_from_headers(hdr)

    h.done = true
    if exit ~= 0 then
        local safe_err = err_log
            :gsub("[Aa]uthorization:[^\r\n]*", "Authorization: [REDACTED]")
   :gsub("x%-api%-key:[^\r\n]*", "x-api-key: [REDACTED]")
  h.err = ("curl exit=%s  stderr=%s"):format(tostring(exit), safe_err:sub(1, 120))
 cleanup(h)
        return { done = true, err = h.err, partial = total }
    end

    h.status = status
    h.body = body
    cleanup(h)
  return { done = true, status = status, body = body, partial = total }
end

function M.cancel(h)
    if h.done then return end
 h.done = true
    h.err  = "cancelled"
    cleanup(h)
end

function M.check_curl()
    local out = reaper.ExecProcess(q(CURL) .. " --version", 5000)
    if not out or out == "" then
        return false, "curl not found at " .. CURL
    end
    local retcode = out:match("^(%-?%d+)\n")
    if tonumber(retcode) ~= 0 then
        return false, "curl --version failed: " .. out:sub(1, 200)
    end
    return true
end

return M

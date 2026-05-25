--
-- update.lua  —  Startup ReaPack update check for MCAssistant.
--
-- Asynchronously GETs the unified MC-Scripts ReaPack index, finds the latest
-- MCAssistant version, and compares it to the running version. Pull-based:
-- start() once, poll() each frame until done. All failures are silent — this
-- is a non-critical background check and must never block or break chat.
--
--   start()        → http handle | nil
--   poll(handle)   → { done, latest="x.y.z"|nil, err }
--   compare(a, b)  → -1 | 0 | 1   (semver, numeric per dot-segment)
--

local http = require("http")

local M = {}

-- Candidate URLs for the unified MC-Scripts ReaPack index, tried in order
-- until one returns a parseable body. We need fallbacks because REAPER's
-- curl runs WITHOUT the user's HTTP(S)_PROXY env (unlike a shell), so a
-- China-direct connection to raw.githubusercontent.com gets reset by the
-- GFW (curl exit 35 / http 000). jsDelivr mirrors the repo over a CDN that
-- is reachable on a bare connection.
--   * raw.githubusercontent — fast for users abroad / with a system proxy
--   * jsDelivr (cdn/fastly/gcore) — work on a direct China connection
-- jsDelivr caches branch refs for up to ~12h, so a freshly published version
-- may take a few hours to be detected — fine for an update *notification*.
-- (The local reapack.json `url` is the old per-package repo and does NOT
-- carry the latest releases, so it must not be used here.)
M.MIRRORS = {
    "https://raw.githubusercontent.com/Echo722/MC-Scripts/main/index.xml",
    "https://cdn.jsdelivr.net/gh/Echo722/MC-Scripts@main/index.xml",
    "https://fastly.jsdelivr.net/gh/Echo722/MC-Scripts@main/index.xml",
    "https://gcore.jsdelivr.net/gh/Echo722/MC-Scripts@main/index.xml",
}

local function split_ver(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- Compare two dotted version strings numerically. Returns -1 if a<b, 0 if
-- equal, 1 if a>b. Missing trailing segments count as 0 (1.8 == 1.8.0).
function M.compare(a, b)
    local A, B = split_ver(a), split_ver(b)
    local n = math.max(#A, #B)
    for i = 1, n do
        local x, y = A[i] or 0, B[i] or 0
        if x < y then return -1 elseif x > y then return 1 end
    end
    return 0
end

-- Extract the highest MCAssistant version from the ReaPack index XML. The
-- index holds multiple packages (MCAssistant, MediaEye, …), so we scope to
-- the <category name="MCAssistant"> … </category> block before scanning
-- <version name="…"> entries. Version order in the file is not guaranteed,
-- so we take the semver-max rather than first/last. Returns nil if absent.
local function parse_latest(xml)
    if not xml or xml == "" then return nil end
    local s = xml:find('<category name="MCAssistant">', 1, true)
    if not s then return nil end
    local e = xml:find('</category>', s, true)
    local block = xml:sub(s, e and (e - 1) or #xml)
    local best = nil
    for v in block:gmatch('version name="([%d%.]+)"') do
        if not best or M.compare(v, best) > 0 then best = v end
    end
    return best
end

local function start_req(url)
    return http.start(url, nil, nil, { method = "GET", timeout_ms = 6000 })
end

-- Kick off the check against the first mirror. Returns a wrapper { idx, h }
-- to poll, or nil if http is unavailable. Subsequent mirrors are tried lazily
-- by poll() on failure, so this stays a single in-flight request at a time.
function M.start()
    if not (http and http.start) then return nil end
    local w = { idx = 1, h = start_req(M.MIRRORS[1]) }
    if not w.h then return nil end
    return w
end

-- Poll the wrapper. While in flight: { done = false }. On a mirror failure
-- (network error, HTTP >= 400, or 200 with an unparseable body) it advances
-- to the next mirror and keeps { done = false }. Once a mirror yields a
-- version: { done = true, latest = "x.y.z" }. When all mirrors are exhausted:
-- { done = true, err = … }. Caller ignores errors silently.
function M.poll(w)
    if not w or not w.h then return { done = true, err = "no handle" } end
    local r = http.poll(w.h)
    if not r.done then return { done = false } end

    if not r.err and not (r.status and r.status >= 400) then
        local latest = parse_latest(r.body)
        if latest then return { done = true, latest = latest } end
    end

    -- This mirror failed — fall through to the next one if any remain.
    if w.idx < #M.MIRRORS then
        w.idx = w.idx + 1
        w.h = start_req(M.MIRRORS[w.idx])
        if w.h then return { done = false } end
    end
    return { done = true, err = r.err or "all mirrors failed" }
end

return M

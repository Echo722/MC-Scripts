-- @description MediaEye
-- @version 3.0
-- @author MC Scripts
-- @about
--   Shows embedded cover art for the file currently selected in REAPER's
--   Media Explorer. Parses ID3v2 (MP3 / WAV with `id3 ` chunk) and FLAC
--   PICTURE blocks natively — no ffmpeg required.
--
--   Fallback chain: embedded picture → image files in the same folder, in
--   subfolders of that folder, in the parent folder, and in subfolders of
--   the parent folder (covers Boom Library / Documents / Artwork layouts).
--
--   ----
--
--   在 REAPER 媒体浏览器中显示当前选中文件的封面图。原生解析 ID3v2
--   (MP3 / 含 `id3 ` chunk 的 WAV)以及 FLAC PICTURE 块,无需 ffmpeg。
--
--   回退顺序:嵌入封面 → 同目录下、同目录的子文件夹、父目录、父目录的
--   子文件夹中的图片(覆盖 Boom Library / Documents / Artwork 等布局)。
--
-- @changelog
--   * Always-on smart pinning: the window stays on top only inside REAPER and
--     hides itself automatically while another application is in the foreground,
--     reappearing pinned when REAPER returns. The Pin On Top toggle button has
--     been removed — there is no state to get wrong anymore.
--   ----
--   * 置顶改为始终开启的智能行为:仅在 REAPER 内保持最上层,切到其它程序时窗口
--     自动隐藏,切回 REAPER 自动恢复置顶;移除 Pin On Top 开关按钮。
-- @requires js_ReaScriptAPI

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local POLL_INTERVAL  = 0.2
local CACHE_SIZE     = 20
local WAV_CHUNK_SCAN = true         -- stream WAV chunks instead of reading whole file
local EXT_SECTION    = "MediaEye"
local WINDOW_TITLE   = "Album Art Preview"

-- Temp files go into REAPER's resource directory to avoid writing runtime
-- artifacts into the installed ReaPack package folder.
local TEMP_PREFIX
do
    local temp_dir = reaper.GetResourcePath() .. "/Data/MediaEye"
    reaper.RecursiveCreateDirectory(temp_dir, 0)
    TEMP_PREFIX = temp_dir .. "/tmp"
end

local SUPPORTED_EXT = { mp3 = true, wav = true, flac = true }

-- ReaPack note:
-- Keep runtime cache outside the installed script folder. ReaPack manages the
-- package files; generated temp files should live under REAPER's resource path.

--------------------------------------------------------------------------------
-- Guard: js_ReaScriptAPI
--------------------------------------------------------------------------------
if not reaper.JS_Window_Find then
    reaper.MB("This script requires the js_ReaScriptAPI extension.", "MediaEye", 0)
    return
end

if reaper.set_action_options then
    reaper.set_action_options(1)
end

--------------------------------------------------------------------------------
-- Byte helpers (no bit ops — works on any Lua)
--------------------------------------------------------------------------------
local function u32be(s, o)
    local a, b, c, d = s:byte(o, o + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function u32le(s, o)
    local a, b, c, d = s:byte(o, o + 3)
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

local function syncsafe(s, o)
    local a, b, c, d = s:byte(o, o + 3)
    return (a % 128) * 0x200000 + (b % 128) * 0x4000 + (c % 128) * 0x80 + (d % 128)
end

local function de_unsync(s) return (s:gsub("\xFF%z", "\xFF")) end

local function strip_nulls(s) return (s:gsub("%z+$", "")) end

local function lower_ext(p) return (p:match("%.([^.]+)$") or ""):lower() end

local function file_exists(p)
    local f = io.open(p, "rb"); if f then f:close(); return true end
    return false
end

local function is_directory(p)
    if not p or p == "" then return false end
    if file_exists(p) then return false end
    if reaper.EnumerateFiles(p, 0) ~= nil then return true end
    if reaper.EnumerateSubdirectories(p, 0) ~= nil then return true end
    return false
end

local function write_file(p, d)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(d); f:close(); return true
end

--------------------------------------------------------------------------------
-- ID3v2 parser  (handles v2.3 + v2.4 main cases; v2.2 best-effort)
--------------------------------------------------------------------------------
local function parse_id3v2(data, offset)
    offset = offset or 1
    if #data < offset + 9 then return nil end
    if data:sub(offset, offset + 2) ~= "ID3" then return nil end

    local major = data:byte(offset + 3)
    if major < 2 or major > 4 then return nil end
    local flags = data:byte(offset + 5)
    local tag_size = syncsafe(data, offset + 6)

    local body = data:sub(offset + 10, offset + 9 + tag_size)
    if flags >= 128 and major == 3 then body = de_unsync(body) end

    local pos = 1
    -- Extended header
    if (flags % 128) >= 64 then
        local ext
        if major >= 4 then ext = syncsafe(body, pos); pos = pos + ext
        else ext = u32be(body, pos); pos = pos + ext + 4 end
    end

    local result = {}
    local fid_len  = (major == 2) and 3 or 4
    local hdr_len  = (major == 2) and 6 or 10

    while pos + hdr_len - 1 <= #body do
        local frame_id = body:sub(pos, pos + fid_len - 1)
        if frame_id:byte(1) == 0 then break end  -- padding

        local fsize
        if major == 2 then
            local a, b, c = body:byte(pos + 3, pos + 5)
            fsize = a * 0x10000 + b * 0x100 + c
        elseif major == 3 then
            fsize = u32be(body, pos + 4)
        else
            fsize = syncsafe(body, pos + 4)
        end

        if fsize <= 0 or pos + hdr_len + fsize - 1 > #body then break end

        local fbody = body:sub(pos + hdr_len, pos + hdr_len + fsize - 1)

        -- v2.4 per-frame unsync
        if major == 4 then
            local fflags = body:byte(pos + 9) or 0
            if (fflags % 4) >= 2 then fbody = de_unsync(fbody) end
        end

        local is_picture = (frame_id == "APIC") or (frame_id == "PIC")
        if is_picture and not result.picture then
            local enc = fbody:byte(1) or 0
            local p   = 2
            local mime

            if major == 2 then
                local fmt = fbody:sub(2, 4)
                mime = (fmt == "JPG" and "image/jpeg")
                    or (fmt == "PNG" and "image/png")
                    or  nil
                p = 5
            else
                local mend = fbody:find("\0", p, true)
                if mend then
                    mime = fbody:sub(p, mend - 1):lower()
                    p = mend + 1
                end
            end

            if mime then
                p = p + 1  -- picture type byte

                local desc_end
                if enc == 1 or enc == 2 then   -- UTF-16 double-null, even-aligned
                    local q = p
                    while q <= #fbody - 1 do
                        if fbody:byte(q) == 0 and fbody:byte(q + 1) == 0 then
                            desc_end = q + 1; break
                        end
                        q = q + 2
                    end
                else
                    desc_end = fbody:find("\0", p, true)
                end

                if desc_end and desc_end < #fbody then
                    result.picture = fbody:sub(desc_end + 1)
                    result.mime    = mime
                end
            end

        elseif not result.title  and (frame_id == "TIT2" or frame_id == "TT2") then
            result.title  = strip_nulls(fbody:sub(2))
        elseif not result.artist and (frame_id == "TPE1" or frame_id == "TP1") then
            result.artist = strip_nulls(fbody:sub(2))
        elseif not result.album  and (frame_id == "TALB" or frame_id == "TAL") then
            result.album  = strip_nulls(fbody:sub(2))
        end

        pos = pos + hdr_len + fsize
    end

    return result
end

--------------------------------------------------------------------------------
-- FLAC parser (streaming — metadata lives at the top of the file)
--------------------------------------------------------------------------------
local function parse_flac(path)
    local f = io.open(path, "rb"); if not f then return nil end
    if f:read(4) ~= "fLaC" then f:close(); return nil end

    local result = {}
    while true do
        local hdr = f:read(4)
        if not hdr or #hdr < 4 then break end
        local h = hdr:byte(1)
        local is_last = h >= 128
        local btype   = h % 128
        local b2, b3, b4 = hdr:byte(2, 4)
        local blen    = b2 * 0x10000 + b3 * 0x100 + b4

        if btype == 6 then                                          -- PICTURE
            local body = f:read(blen); if not body then break end
            local bp = 1 + 4                                        -- skip pic type
            local mlen = u32be(body, bp); bp = bp + 4
            local mime = body:sub(bp, bp + mlen - 1):lower()
            bp = bp + mlen
            local dlen = u32be(body, bp); bp = bp + 4 + dlen
            bp = bp + 16                                            -- w/h/depth/colors
            local plen = u32be(body, bp); bp = bp + 4
            result.picture = body:sub(bp, bp + plen - 1)
            result.mime    = mime
        elseif btype == 4 then                                      -- VORBIS_COMMENT
            local body = f:read(blen); if not body then break end
            local bp = 1
            local vl = u32le(body, bp); bp = bp + 4 + vl
            if bp + 3 <= #body then
                local cnt = u32le(body, bp); bp = bp + 4
                for _ = 1, cnt do
                    if bp + 3 > #body then break end
                    local cl = u32le(body, bp); bp = bp + 4
                    if bp + cl - 1 > #body then break end
                    local k, v = body:sub(bp, bp + cl - 1):match("^([^=]+)=(.*)$")
                    bp = bp + cl
                    if k then
                        k = k:upper()
                        if     k == "TITLE"  and not result.title  then result.title  = v
                        elseif k == "ARTIST" and not result.artist then result.artist = v
                        elseif k == "ALBUM"  and not result.album  then result.album  = v
                        end
                    end
                end
            end
        else
            f:seek("cur", blen)
        end

        if is_last then break end
    end
    f:close()
    return result
end

--------------------------------------------------------------------------------
-- WAV parser (streaming — skips huge `data` chunks without reading them)
--------------------------------------------------------------------------------
local function parse_wav(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local hdr = f:read(12)
    if not hdr or #hdr < 12 or hdr:sub(1, 4) ~= "RIFF" or hdr:sub(9, 12) ~= "WAVE" then
        f:close(); return nil
    end

    while true do
        local ch = f:read(8); if not ch or #ch < 8 then break end
        local id = ch:sub(1, 4)
        local a, b, c, d = ch:byte(5, 8)
        local size = a + b * 0x100 + c * 0x10000 + d * 0x1000000

        if id:lower() == "id3 " then
            local body = f:read(size); f:close()
            if body then return parse_id3v2(body, 1) end
            return nil
        end

        f:seek("cur", size + (size % 2))       -- chunks are even-padded
    end
    f:close()
    return nil
end

--------------------------------------------------------------------------------
-- MP3 parser (ID3v2 tag at file start)
--------------------------------------------------------------------------------
local function parse_mp3(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local hdr = f:read(10)
    if not hdr or #hdr < 10 or hdr:sub(1, 3) ~= "ID3" then f:close(); return nil end
    local size = syncsafe(hdr, 7)
    local body = f:read(size)
    f:close()
    if not body then return nil end
    return parse_id3v2(hdr .. body, 1)
end

--------------------------------------------------------------------------------
-- Orchestrator
--------------------------------------------------------------------------------
local function extract_cover_info(filepath)
    local ext = lower_ext(filepath)
    if     ext == "mp3"  then return parse_mp3(filepath)
    elseif ext == "wav"  then return parse_wav(filepath)
    elseif ext == "flac" then return parse_flac(filepath)
    end
    return nil
end

local function find_folder_image(filepath)
    local audio_dir  = filepath:match("^(.*)[/\\]")
    if not audio_dir then return nil end

    local audio_base = (filepath:match("([^/\\]+)$") or ""):gsub("%.[^.]+$", ""):lower()

    local IMG_EXTS = { jpg = true, jpeg = true, png = true, bmp = true }
    local KEYWORDS = { "folder", "cover", "front", "album", "artwork", "art", "jacket", "poster" }
    local ASSET_FOLDER_NAMES = {
        artwork = true, art = true,
        documents = true, document = true, docs = true, doc = true,
        images = true, pictures = true, pics = true,
        covers = true, scans = true,
    }

    local function score_name(stem)
        for _, kw in ipairs(KEYWORDS) do
            if stem == kw then return 4 end
        end
        for _, kw in ipairs(KEYWORDS) do
            if stem:find(kw, 1, true) then return 3 end
        end
        if audio_base ~= "" and stem == audio_base then return 2 end
        return 1
    end

    local best_path, best_score = nil, 0

    local function scan_dir(dir, weight)
        if not dir then return end
        local i = 0
        while true do
            local fname = reaper.EnumerateFiles(dir, i)
            if not fname then break end
            i = i + 1
            local ext = (fname:match("%.([^.]+)$") or ""):lower()
            if IMG_EXTS[ext] then
                local stem  = fname:gsub("%.[^.]+$", ""):lower()
                local score = score_name(stem) * weight
                if score > best_score then
                    best_score = score
                    best_path  = dir .. "/" .. fname
                end
            end
        end
    end

    local function enum_subdirs(dir)
        local out, i = {}, 0
        if not dir then return out end
        while true do
            local sub = reaper.EnumerateSubdirectories(dir, i)
            if not sub then break end
            i = i + 1
            out[#out + 1] = sub
        end
        return out
    end

    -- Same dir
    scan_dir(audio_dir, 1.0)

    -- Same dir's subfolders (asset-named keywords get a weight bonus)
    for _, sub in ipairs(enum_subdirs(audio_dir)) do
        local w = ASSET_FOLDER_NAMES[sub:lower()] and 0.9 or 0.7
        scan_dir(audio_dir .. "/" .. sub, w)
    end

    -- Walk up the tree. At each ancestor, scan the dir's own files and ONLY
    -- its asset-named subfolders (Artwork/Documents/Pictures/...). Scanning
    -- non-asset sibling folders here would dip into unrelated libraries
    -- packaged at the same parent (e.g. picking up <PackB>'s cover when
    -- previewing audio from <PackA>/Sounds/file.wav).
    local LEVEL_WEIGHTS = {
        { dir = 0.60, asset = 0.85 },  -- parent
        { dir = 0.40, asset = 0.70 },  -- grandparent
        { dir = 0.25, asset = 0.55 },  -- great-grandparent
    }

    local current = audio_dir
    for _, cfg in ipairs(LEVEL_WEIGHTS) do
        local up = current:match("^(.*)[/\\]")
        if not up or up == "" then break end
        scan_dir(up, cfg.dir)
        for _, sub in ipairs(enum_subdirs(up)) do
            if ASSET_FOLDER_NAMES[sub:lower()] then
                scan_dir(up .. "/" .. sub, cfg.asset)
            end
        end
        current = up
    end

    return best_path
end

-- gfx image slot pool. gfx.loadimg loads into a numbered slot; we manage
-- the slot pool so LRU eviction properly reclaims slots.
local slot_pool = {}
for i = 0, CACHE_SIZE - 1 do slot_pool[#slot_pool + 1] = i end

local function acquire_slot() return table.remove(slot_pool) end
local function release_slot(s) if s then slot_pool[#slot_pool + 1] = s end end

-- Write picture bytes to a SLOT-UNIQUE temp file so successive loads into
-- different slots can't collide on the same path (some image cache layers
-- may key by filename).
local function load_image_from_bytes(bytes, mime)
    if not bytes or #bytes < 4 then return nil end
    local is_png = bytes:sub(1, 8) == "\137PNG\r\n\26\n"
    local is_jpg = bytes:sub(1, 3) == "\255\216\255"

    local slot = acquire_slot(); if not slot then return nil end

    local ext
    if is_png or (mime and mime:find("png", 1, true)) then
        ext = ".png"
    elseif is_jpg or (mime and (mime:find("jpeg", 1, true) or mime:find("jpg", 1, true))) then
        ext = ".jpg"
    else
        release_slot(slot); return nil
    end

    -- gfx.loadimg caches bitmaps by file path in REAPER. Writing new bytes
    -- to the same path does NOT invalidate the cache — the slot keeps the
    -- stale bitmap (this was the Magic/Cinematic mix-up bug). Fix: unique
    -- path per call + setimgdim(0,0) to zero the slot first.
    _G.__mediaeye_load_counter = (_G.__mediaeye_load_counter or 0) + 1
    local n = _G.__mediaeye_load_counter
    local t = math.floor(reaper.time_precise() * 1000)
    local path = string.format("%s_%d_%d%s", TEMP_PREFIX, n, t, ext)
    if not write_file(path, bytes) then release_slot(slot); return nil end

    gfx.setimgdim(slot, 0, 0)
    local rc = gfx.loadimg(slot, path)
    os.remove(path)  -- bitmap now in memory; remove disk copy
    if rc == -1 then release_slot(slot); return nil end
    return slot
end

local function load_image_from_file(path)
    local slot = acquire_slot(); if not slot then return nil end
    gfx.setimgdim(slot, 0, 0)
    local rc = gfx.loadimg(slot, path)
    if rc == -1 then release_slot(slot); return nil end
    return slot
end

--------------------------------------------------------------------------------
-- LRU cache
--------------------------------------------------------------------------------
local cache, cache_seq = {}, 0

local function cache_get(path)
    local e = cache[path]
    if e then cache_seq = cache_seq + 1; e.order = cache_seq end
    return e
end

-- Evict oldest entries until cache has room for one more. Call BEFORE
-- acquiring a slot so the slot pool has something to hand out.
local function evict_until_room()
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    while count >= CACHE_SIZE do
        local oldest_k, oldest_o = nil, math.huge
        for k, v in pairs(cache) do
            if v.order < oldest_o then oldest_k, oldest_o = k, v.order end
        end
        if not oldest_k then break end
        release_slot(cache[oldest_k].img_slot)
        cache[oldest_k] = nil
        count = count - 1
    end
end

local function cache_put(path, entry)
    cache_seq = cache_seq + 1
    entry.order = cache_seq
    cache[path] = entry
end

local function cache_count()
    local n = 0; for _ in pairs(cache) do n = n + 1 end; return n
end

local function cache_clear()
    for _, v in pairs(cache) do release_slot(v.img_slot) end
    cache = {}
end

--------------------------------------------------------------------------------
-- Media Explorer hookup (cached handles, revalidated on demand)
--------------------------------------------------------------------------------
local me_hwnd, me_listview, me_combos = nil, nil, {}

local function is_valid(h) return h and reaper.JS_Window_IsWindow(h) end

local function is_abs(p)
    return p and ((p:match("^[A-Za-z]:[/\\]") ~= nil) or (p:match("^[/\\][/\\]") ~= nil))
end

local function refresh_me()
    -- Re-find ME window if handle is stale.
    if not is_valid(me_hwnd) then
        me_hwnd = reaper.JS_Window_Find("Media Explorer", true)
    end
    if not me_hwnd then
        me_listview, me_combos = nil, {}
        return false
    end

    -- Re-scan children every call — combos may be added/removed dynamically
    -- and the listview HWND sometimes changes on folder navigation.
    me_listview = nil
    me_combos   = {}
    local _, addrs = reaper.JS_Window_ListAllChild(me_hwnd)
    for a in addrs:gmatch("[^,]+") do
        local h = reaper.JS_Window_HandleFromAddress(tonumber(a))
        if h then
            local c = reaper.JS_Window_GetClassName(h) or ""
            if c == "SysListView32" and not me_listview then
                me_listview = h
            elseif c:match("ComboBox") or c == "Edit" then
                me_combos[#me_combos + 1] = h
            end
        end
    end
    return me_listview ~= nil
end

local function join_dir(dir, name)
    local sep = dir:sub(-1)
    if sep ~= "\\" and sep ~= "/" then dir = dir .. "\\" end
    return dir .. name
end

-- INI cache (parsed once)
local ini_explorer = nil

local function get_ini_explorer()
    if ini_explorer ~= nil then return ini_explorer end
    ini_explorer = {}
    local rp = reaper.GetResourcePath()
    local f = io.open(rp .. "/REAPER.ini", "r")
    if not f then return ini_explorer end
    local in_section = false
    for line in f:lines() do
        if line:match("^%[reaper_explorer%]") then in_section = true
        elseif line:match("^%[") then in_section = false
        elseif in_section then
            local k, v = line:match("^([^=]+)=(.*)$")
            if k then ini_explorer[k] = v end
        end
    end
    f:close()
    return ini_explorer end

local function get_selected_path()
    if not refresh_me() then return nil end
    local cnt, csv = reaper.JS_ListView_ListAllSelItems(me_listview)
    if cnt == 0 then return nil end
    local idx = tonumber(csv:match("[^,]+")); if not idx then return nil end

    local fname = reaper.JS_ListView_GetItem(me_listview, idx, 0) or ""
    if fname == "" then return nil end
    if is_abs(fname) then return fname end

    -- ME often exposes a Path/Directory column whose value is the absolute
    -- folder, even in database mode where the folder combobox is empty.
    -- Scan extra columns for an absolute path that resolves the file.
    local col = 1
    while col < 16 do
        local cv = reaper.JS_ListView_GetItem(me_listview, idx, col) or ""
        if cv == "" then break end
        if is_abs(cv) then
            if file_exists(cv) then
                local cb = cv:match("([^/\\]+)$") or ""
                if cb:lower() == fname:lower() then return cv end
            end
            local full = join_dir(cv, fname)
            if file_exists(full) then return full end
        end
        col = col + 1
    end

    -- Multiple comboboxes may hold abs-looking text (current folder, history,
    -- shortcuts). Prefer one where folder\fname actually exists on disk; fall
    -- back to the first abs-looking combo if none match (still surfaces the
    -- guess so the user can see it's wrong).
    local fallback = nil
    for _, h in ipairs(me_combos) do
        local t = reaper.JS_Window_GetTitle(h) or ""
        if is_abs(t) then
            local full = join_dir(t, fname)
            if file_exists(full) then return full end
            fallback = fallback or full
        end
    end
    if fallback then return fallback end

    -- Database mode: ListView returns a relative path (e.g. "Boom Library\...\file.wav").
    -- No combo holds an abs directory. Resolve by reading REAPER.ini for the
    -- SFX library roots (lastaddpath + Shortcut entries).
    local ini = get_ini_explorer()
    -- 1. Try lastaddpath first (most recent / primary library root)
    local lap = ini.lastaddpath
    if lap and is_abs(lap) then
        local full = join_dir(lap, fname)
        if file_exists(full) then return full end
    end
    -- 2. Try matching first path component of fname against Shortcut entries
    local top_dir = fname:match("^([^/\\]+)")
    if top_dir then
        local tl = top_dir:lower()
        for k, v in pairs(ini) do
            if k:match("^Shortcut%d+$") and is_abs(v) then
                local base = v:match("([^/\\]+)$") or ""
                if base:lower() == tl then
                    -- Strip the duplicate top_dir prefix from fname before joining;
                    -- otherwise <v>\<top_dir>\<rest> doubles up the library segment.
                    local rest = fname:sub(#top_dir + 2)
                    local full = (rest ~= "") and join_dir(v, rest) or v
                    if file_exists(full) then return full end
                end
            end
        end
        -- 3. Try each shortcut as a root (slower, covers nested structures)
        for k, v in pairs(ini) do
            if k:match("^Shortcut%d+$") and is_abs(v) then
                local full = join_dir(v, fname)
                if file_exists(full) then return full end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Main state + processing
--------------------------------------------------------------------------------
local current = nil     -- currently displayed cache entry
local last_path     = ""
local latest_path   = nil     -- live value from each poll, for debug display
local last_check    = 0
local last_status   = ""
local last_pic_size = 0

-- UI: toggle-info button state
local show_debug     = (reaper.GetExtState(EXT_SECTION, "show_debug") ~= "0")
local info_btn_rect  = { x = 0, y = 0, w = 0, h = 0 }
local last_mouse_cap = 0
local script_hwnd    = nil

local function point_in_rect(x, y, r)
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function refresh_script_hwnd()
    if not is_valid(script_hwnd) then
        script_hwnd = reaper.JS_Window_Find(WINDOW_TITLE, true)
    end
    return script_hwnd
end

-- Actual WS_EX_TOPMOST (0x8) bit of the window right now. -1 = unknown.
-- Needed because on Windows 11 demoting a topmost window does not reliably clear
-- the flag (observed: SetZOrder BOTTOM left WS_EX_TOPMOST set), so the cached
-- state can lie and writes must be verified against the real bit.
local function get_ex_topmost(h)
    if not h or not reaper.JS_Window_GetLong then return -1 end
    local ex = reaper.JS_Window_GetLong(h, "EXSTYLE") or 0
    if ex < 0 then ex = ex + 4294967296 end
    return math.floor(ex / 8) % 2
end

-- Transient Windows-shell overlays (taskbar, Alt-Tab, snap layouts...) grab the
-- foreground for a moment while the user is still effectively inside REAPER.
-- Treat them as "indeterminate" instead of "another app", otherwise touching the
-- taskbar slams MediaEye to the bottom (observed with XamlExplorerHostIslandWindow).
local SHELL_CLASSES = {
    XamlExplorerHostIslandWindow   = true,  -- Win11 taskbar / Alt-Tab / snap layouts host
    ForegroundStaging              = true,  -- Alt-Tab transition helper
    MultitaskingViewFrame          = true,  -- task view
    TaskListThumbnailWnd           = true,  -- taskbar thumbnails
    TaskSwitcherWnd                = true,  -- classic Alt-Tab
    Shell_TrayWnd                  = true,  -- taskbar
    Shell_SecondaryTrayWnd         = true,  -- taskbar on secondary monitors
    ["Windows.UI.Core.CoreWindow"] = true,  -- start menu / search
}

-- Is any REAPER window the foreground application? Used to keep MediaEye topmost
-- only inside REAPER, so it stops covering other apps (browser, etc.).
-- Returns true (REAPER), false (another app), or nil (shell overlay: hold state).
local function reaper_is_foreground()
    if not reaper.JS_Window_GetForeground then return true end  -- no API: keep old behaviour
    local fg = reaper.JS_Window_GetForeground()
    if not fg then return true end
    if reaper.JS_Window_GetClassName then
        local cls = reaper.JS_Window_GetClassName(fg)
        if cls and SHELL_CLASSES[cls] then return nil end
    end
    local main = reaper.GetMainHwnd()
    if fg == main or fg == script_hwnd then return true end
    -- Floating windows (Media Explorer / FX) are OWNED by main: walk the owner chain.
    local w, guard = fg, 0
    while w and guard < 12 do
        if w == main then return true end
        local owner = reaper.JS_Window_GetRelated and reaper.JS_Window_GetRelated(w, "OWNER")
        if not owner or owner == w then break end
        w, guard = owner, guard + 1
    end
    -- Docked windows are children of main: walk the parent chain.
    w, guard = fg, 0
    while w and guard < 12 do
        if w == main then return true end
        local parent = reaper.JS_Window_GetParent and reaper.JS_Window_GetParent(w)
        if not parent or parent == w then break end
        w, guard = parent, guard + 1
    end
    return false
end

-- Z-order behaviour is always-on and has two states, re-evaluated (throttled) each
-- frame and only written on change:
--   "top"  = REAPER is the foreground app -> window shown + TOPMOST, so the cover
--            art stays above the Media Explorer and every other REAPER window.
--   "away" = another app is foreground    -> window hidden. Hiding (instead of
--            demoting) sidesteps a Win11 bug where neither HWND_BOTTOM nor
--            re-inserting below a non-topmost window clears WS_EX_TOPMOST, which
--            left the window floating above other apps. Hidden, the window keeps
--            its topmost-band position, so showing it again fully restores it.
-- Extra rules learned from diagnostics on this machine:
--   * A shell overlay as foreground (Alt-Tab, taskbar) holds the current state, and
--     "away" needs two consecutive verdicts, so transient focus flips don't hide us.
--   * The real WS_EX_TOPMOST bit is checked against the cache and re-asserted if
--     something external strips it.
--   * Docked, the gfx window is a child pane: never hide it or touch its Z-order.
local applied_z   = nil   -- "top" | "away" | nil (unknown)
local away_streak = 0     -- consecutive "another app is foreground" verdicts
local last_z_time = 0
local Z_INTERVAL  = 0.2

local function update_topmost(force)
    local now = reaper.time_precise()
    if not force and (now - last_z_time) < Z_INTERVAL then return end
    last_z_time = now

    if gfx.dock(-1) % 2 == 1 then
        if applied_z == "away" then
            local h = refresh_script_hwnd()
            if h and reaper.JS_Window_Show then reaper.JS_Window_Show(h, "SHOWNA") end
        end
        applied_z, away_streak = nil, 0
        return
    end

    local fg_ok = reaper_is_foreground()
    local target
    if fg_ok == true then
        target = "top"
        away_streak = 0
    elseif fg_ok == nil then              -- shell overlay: hold current state
        target = applied_z or "top"
        away_streak = 0
    else
        away_streak = away_streak + 1
        target = (away_streak >= 2) and "away" or (applied_z or "top")
    end

    local hwnd = refresh_script_hwnd()
    if not hwnd then return end
    local ex = get_ex_topmost(hwnd)

    if target ~= applied_z then
        if target == "top" then
            if reaper.JS_Window_Show then reaper.JS_Window_Show(hwnd, "SHOWNA") end
            if ex ~= 1 and reaper.JS_Window_SetZOrder then
                reaper.JS_Window_SetZOrder(hwnd, "TOPMOST")
            end
            applied_z = target
        elseif reaper.JS_Window_Show then
            reaper.JS_Window_Show(hwnd, "HIDE")
            applied_z = target
        end
    elseif target == "top" and ex == 0 and reaper.JS_Window_SetZOrder then
        -- Self-heal: something external stripped the topmost bit.
        reaper.JS_Window_SetZOrder(hwnd, "TOPMOST")
    end
end

local function handle_mouse()
    local cap = gfx.mouse_cap or 0
    local pressed_now = (cap % 2 == 1) and (last_mouse_cap % 2 == 0)
    if pressed_now then
        if point_in_rect(gfx.mouse_x, gfx.mouse_y, info_btn_rect) then
            show_debug = not show_debug
            reaper.SetExtState(EXT_SECTION, "show_debug", show_debug and "1" or "0", true)
        end
    end
    last_mouse_cap = cap
end

local function draw_button(label, rect, x, y)
    local tw, th = gfx.measurestr(label)
    local pad_x, pad_y = 8, 4
    local bw, bh = tw + pad_x * 2, th + pad_y * 2
    rect.x, rect.y, rect.w, rect.h = x, y, bw, bh

    local hover = point_in_rect(gfx.mouse_x, gfx.mouse_y, rect)
    if hover then gfx.set(0.28, 0.28, 0.32, 1) else gfx.set(0.18, 0.18, 0.20, 1) end
    gfx.rect(x, y, bw, bh, 1)
    gfx.set(0.45, 0.45, 0.50, 1)
    gfx.rect(x, y, bw, bh, 0)

    gfx.set(0.90, 0.90, 0.90, 1)
    gfx.x, gfx.y = x + pad_x, y + pad_y
    gfx.drawstr(label)
    return bw, bh
end

local function draw_controls()
    local info_label = show_debug and "Hide Info" or "Show Info"

    local info_tw = select(1, gfx.measurestr(info_label))
    local info_w  = info_tw + 16
    draw_button(info_label, info_btn_rect, gfx.w - info_w - 6, 6)
end

local function process_selection()
    local path = get_selected_path()
    latest_path = path  -- always update for debug display

    -- No change? skip.
    if path == last_path then return end
    last_path = path

    -- No selection (folder switched, nothing selected, etc.): clear display.
    if not path then
        current = { meta = {}, source = "no selection", img_slot = nil }
        last_status = "no selection"
        last_pic_size = 0
        return
    end

    -- Folder selected: clear display, do not scan the parent for images.
    if is_directory(path) then
        current = { meta = {}, source = "folder selected", img_slot = nil }
        last_status = "folder selected"
        last_pic_size = 0
        return
    end

    local hit = cache_get(path)
    if hit then current = hit; last_status = (hit.source or "cache") .. " (hit)"; return end

    -- Free a slot NOW (before loading) if the cache is full.
    evict_until_room()

    local entry = { meta = {}, source = nil, img_slot = nil }

    if SUPPORTED_EXT[lower_ext(path)] then
        local ok, info = pcall(extract_cover_info, path)
        if ok and info then
            entry.meta.title  = info.title
            entry.meta.artist = info.artist
            entry.meta.album  = info.album
            if info.picture then
                last_pic_size = #info.picture
                entry.img_slot = load_image_from_bytes(info.picture, info.mime)
                entry.source   = entry.img_slot
                    and string.format("embedded %s %dB", info.mime or "?", #info.picture)
                    or  string.format("embed-decode-failed %s %dB", info.mime or "?", #info.picture)
            else
                entry.source = "no embedded picture"
            end
        elseif ok then
            entry.source = "parser returned nil"
        else
            entry.source = "parser error: " .. tostring(info)
        end
    else
        entry.source = "unsupported ext (" .. lower_ext(path) .. ")"
    end

    if not entry.img_slot then
        local fp = find_folder_image(path)
        if fp then
            entry.img_slot = load_image_from_file(fp)
            if entry.img_slot then entry.source = "folder-image" end
        end
    end

    cache_put(path, entry)
    current = entry
    last_status = entry.source
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
local function draw()
    gfx.set(0.08, 0.08, 0.08, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

    local meta_h = show_debug and 130 or 0
    local img_h  = gfx.h - meta_h
    if img_h < 40 then img_h = gfx.h; meta_h = 0 end

    if current and current.img_slot then
        local slot = current.img_slot
        local sw, sh = gfx.getimgdim(slot)
        if sw > 0 and sh > 0 then
            local scale = math.min(gfx.w / sw, img_h / sh)
            local dw, dh = sw * scale, sh * scale
            local dx, dy = (gfx.w - dw) / 2, (img_h - dh) / 2
            gfx.blit(slot, 1, 0, 0, 0, sw, sh, dx, dy, dw, dh)
        end
    else
        gfx.set(0.5, 0.5, 0.5, 1)
        local msg = "No cover art"
        local tw, th = gfx.measurestr(msg)
        gfx.x = (gfx.w - tw) / 2
        gfx.y = (img_h - th) / 2
        gfx.drawstr(msg)
    end

    if meta_h > 0 then
        local meta = (current and current.meta) or {}
        local lines = {}
        if meta.title  then lines[#lines + 1] = "Title: "  .. meta.title  end
        if meta.artist then lines[#lines + 1] = "Artist: " .. meta.artist end
        if meta.album  then lines[#lines + 1] = "Album: "  .. meta.album  end
        lines[#lines + 1] = "[" .. last_status .. "]"
        lines[#lines + 1] = "path: " .. (last_path ~= "" and last_path or "(nil)")
        if latest_path ~= last_path then
            lines[#lines + 1] = "LIVE: " .. tostring(latest_path)
        end
        lines[#lines + 1] = string.format("cache:%d/%d  free-slots:%d  slot:%s  pic:%dB",
                                          cache_count(), CACHE_SIZE, #slot_pool,
                                          tostring(current and current.img_slot),
                                          last_pic_size)

        local y = img_h + 4
        for _, line in ipairs(lines) do
            gfx.set(0.85, 0.85, 0.85, 1)
            gfx.x, gfx.y = 8, y
            -- Tail-truncate so status prefix is preserved
            local shown = line
            if #shown > 95 then shown = shown:sub(1, 45) .. "..." .. shown:sub(-45) end
            gfx.drawstr(shown)
                  y = y + 16
        end
    end

    draw_controls()
end

--------------------------------------------------------------------------------
-- Window state persistence
--------------------------------------------------------------------------------
local function save_window_state()
    local dock, x, y = gfx.dock(-1, 0, 0, 0, 0)
    reaper.SetExtState(EXT_SECTION, "w",    tostring(gfx.w), true)
    reaper.SetExtState(EXT_SECTION, "h",    tostring(gfx.h), true)
    reaper.SetExtState(EXT_SECTION, "x",    tostring(x),     true)
    reaper.SetExtState(EXT_SECTION, "y",    tostring(y),     true)
    reaper.SetExtState(EXT_SECTION, "dock", tostring(dock),  true)
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
local function main()
    update_topmost()

    local now = reaper.time_precise()
    if now - last_check >= POLL_INTERVAL then
  last_check = now
    process_selection()
    end

  handle_mouse()
    draw()

    if gfx.getchar() >= 0 then
        reaper.defer(main)
    else
        save_window_state()
        cache_clear()
        gfx.quit()
    end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
local w    = tonumber(reaper.GetExtState(EXT_SECTION, "w"))    or 400
local h    = tonumber(reaper.GetExtState(EXT_SECTION, "h"))    or 460
local x    = tonumber(reaper.GetExtState(EXT_SECTION, "x"))    or 200
local y    = tonumber(reaper.GetExtState(EXT_SECTION, "y"))    or 200
local dock = tonumber(reaper.GetExtState(EXT_SECTION, "dock")) or 0
if w < 200 then w = 400 end
if h < 200 then h = 460 end

gfx.init(WINDOW_TITLE, w, h, dock, x, y)
reaper.atexit(save_window_state)
gfx.setfont(1, "Arial", 14)
main()

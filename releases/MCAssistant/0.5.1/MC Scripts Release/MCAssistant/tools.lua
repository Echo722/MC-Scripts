--
-- tools.lua — REAPER tools exposed to the AI.
--
-- Tools are registered once; TOOL_LIST and DISPATCH are generated from the
-- same table to keep them in sync.
--
-- Each tool: { name, description, schema, execute(input) -> table }
-- execute returns a Lua table that is JSON-encoded as the tool_result.
-- Write operations are wrapped in Undo blocks.
--

local json = require("json")

local M = {}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function ok(t)  t = t or {}; t.ok = true; return t end
local function fail(msg) return { ok = false, error = msg } end

local function with_undo(name, fn)
    reaper.Undo_BeginBlock()
    local ok_call, result = pcall(fn)
    reaper.Undo_EndBlock(name, -1)
    reaper.UpdateArrange()
    if not ok_call then return fail("tool error: " .. tostring(result)) end
    return result
end

local function db_to_amp(db) return 10 ^ (db / 20) end
local function amp_to_db(a)return (a > 0) and (20 * math.log(a, 10)) or -math.huge end

local function file_exists(p)
    local f = io.open(p, "rb"); if f then f:close(); return true end
    return false
end

local function is_abs_path(p)
 return p and ((p:match("^[A-Za-z]:[/\\]") ~= nil) or (p:match("^[/\\][/\\]") ~= nil))
end

local function join_dir(dir, name)
    local sep = dir:sub(-1)
    if sep ~= "\\" and sep ~= "/" then dir = dir .. "\\" end
return dir .. name
end

local function track_name(tr)
    local _, n = reaper.GetTrackName(tr)
  return n
end

local NORMALIZE_MODES = {
    lufs_i     = 0,  -- LUFS integrated (EBU R128)
    rms_i      = 1,  -- RMS integrated
    peak       = 2,
    true_peak  = 3,
    lufs_m_max = 4,
    lufs_s_max = 5,
}

-- gain = 10^((target - current)/20)  =>  current = target - 20*log10(gain)
local function gain_to_current_db(gain, target)
    if not gain or gain <= 0 then return nil end
    return target - 20 * math.log(gain, 10)
end

local RENDER_BOUNDS = {
    custom           = 0,
    entire_project   = 1,
    time_selection   = 2,
    all_regions      = 3,
    selected_items   = 4,
    selected_regions = 5,
}

-- 4-byte fourCC + format-specific config bytes. REAPER's RENDER_FORMAT is a
-- binary string; the user can fall back to "current" if a preset is rejected.
local function render_format_blob(fourcc, body)
    return fourcc .. (body or string.rep("\0", 12))
end

-- Strip filename-illegal chars (Windows + control chars). Returns nil for empty.
local function sanitize_filename(s)
    if not s or s == "" then return nil end
    local out = s:gsub('[<>:"/\\|?*]', "_"):gsub("[%z\1-\31]", "_")
    if out == "" then return nil end
    return out
end

local RENDER_FORMATS = {
    -- WAV: bit depth in first uint32 of body (16, 24, 32-float).
    wav_16  = render_format_blob("evaw", "\x10\x00\x00\x00" .. string.rep("\0", 8)),
    wav_24  = render_format_blob("evaw", "\x18\x00\x00\x00" .. string.rep("\0", 8)),
    wav_32f = render_format_blob("evaw", "\x20\x00\x00\x00\x01\x00\x00\x00" .. string.rep("\0", 4)),
    -- MP3 (LAME): bitrate-based config.
    mp3_320 = render_format_blob("l3pm", "\x40\x01\x00\x00" .. string.rep("\0", 8)),
    mp3_192 = render_format_blob("l3pm", "\xc0\x00\x00\x00" .. string.rep("\0", 8)),
    -- FLAC: compression level (0-8) in first byte.
    flac    = render_format_blob("calf", "\x05" .. string.rep("\0", 11)),
}

-- ---------------------------------------------------------------------------
-- SFX / Media Explorer
-- ---------------------------------------------------------------------------

local function me_listview()
    if not reaper.JS_Window_Find then
        return nil, "js_ReaScriptAPI extension required"
 end
    local me = reaper.JS_Window_Find("Media Explorer", true)
    if not me then return nil, "Media Explorer is not open" end
    local _, addrs = reaper.JS_Window_ListAllChild(me)
    for a in (addrs or ""):gmatch("[^,]+") do
        local h = reaper.JS_Window_HandleFromAddress(tonumber(a))
        if h and reaper.JS_Window_GetClassName(h) == "SysListView32" then
   return h
 end
    end
    return nil, "could not locate ME file list"
end

local function _me_current_folder_cached()
    if not reaper.JS_Window_Find then return nil end
    local me = reaper.JS_Window_Find("Media Explorer", true)
    if not me then return nil end
  local _, addrs = reaper.JS_Window_ListAllChild(me)
    local best
    for a in (addrs or ""):gmatch("[^,]+") do
   local h = reaper.JS_Window_HandleFromAddress(tonumber(a))
        if h then
      local cls = reaper.JS_Window_GetClassName(h) or ""
         if cls == "ComboBox" or cls == "Edit" or cls == "ComboBoxEx32" then
   local txt = reaper.JS_Window_GetTitle(h) or ""
     if is_abs_path(txt) and (not best or #txt > #best) then
        best = txt
     end
     end
        end
    end
 return best
end

local function resolve_me_path(listview, idx, fname)
  if is_abs_path(fname) and file_exists(fname) then return fname end
    for col = 1, 15 do
        local cv = reaper.JS_ListView_GetItem(listview, idx, col) or ""
        if cv == "" then break end
   if is_abs_path(cv) then
        if file_exists(cv) then
       local base = cv:match("([^/\\]+)$") or ""
            if base:lower() == fname:lower() then return cv end
        end
   local full = join_dir(cv, fname)
      if file_exists(full) then return full end
        end
    end
  local folder = _me_current_folder_cached()
    if folder then
        local full = join_dir(folder, fname)
        if file_exists(full) then return full end
    end
    return nil
end

local function tool_me_get_selection(_input)
    local listview, err = me_listview()
    if not listview then return fail(err) end
 local cnt, csv = reaper.JS_ListView_ListAllSelItems(listview)
    if cnt == 0 then return ok({ count = 0, items = {} }) end
    local items = {}
    for idx_str in csv:gmatch("[^,]+") do
  local idx = tonumber(idx_str)
  if idx then
     local fname = reaper.JS_ListView_GetItem(listview, idx, 0) or ""
local resolved = resolve_me_path(listview, idx, fname)
    items[#items + 1] = { name = fname, path = resolved or fname,
     resolved = resolved ~= nil }
end
    end
    return ok({ count = #items, items = items })
end

local function tool_me_import_to_track(input)
    local listview, err = me_listview()
    if not listview then return fail(err) end
  local _, csv = reaper.JS_ListView_ListAllSelItems(listview)
    if not csv or csv == "" then return fail("no file selected in Media Explorer") end

    local track
    local tcount = reaper.CountSelectedTracks(0)
    if tcount > 0 then
        track = reaper.GetSelectedTrack(0, 0)
    else
  local n = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(n, true)
     track = reaper.GetTrack(0, n)
    end

    local position = tonumber(input.position_seconds) or reaper.GetCursorPosition()

    return with_undo("MCAssistant: me_import_to_track", function()
        local imported = {}
  local cur_pos = position
        for idx_str in csv:gmatch("[^,]+") do
            local idx = tonumber(idx_str)
        if idx then
         local fname = reaper.JS_ListView_GetItem(listview, idx, 0) or ""
     local path = resolve_me_path(listview, idx, fname)
                if path then
    reaper.SetOnlyTrackSelected(track)
              reaper.SetEditCurPos(cur_pos, false, false)
  local ok_ins = reaper.InsertMedia(path, 0)  -- 0 = into selected track
     if ok_ins and ok_ins ~= 0 then
  imported[#imported + 1] = { path = path }
    local item = reaper.GetTrackMediaItem(track,
         reaper.CountTrackMediaItems(track) - 1)
     if item then
       cur_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
         + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
   end
  end
     end
 end
    end
    return ok({ count = #imported, imported = imported,
track = track_name(track) })
    end)
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

local function tool_items_batch_edit(input)
  local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return fail("no media items selected") end

    local vol_db   = tonumber(input.volume_db)
    local pitch_st = tonumber(input.pitch_semitones)
 local rate   = tonumber(input.rate)
    if not (vol_db or pitch_st or rate) then
        return fail("specify volume_db / pitch_semitones / rate")
    end
    if rate and rate <= 0 then return fail("rate must be > 0") end

    return with_undo("MCAssistant: items_batch_edit", function()
        local modified = 0
  for i = 0, n - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
      if vol_db then
    local cur = reaper.GetMediaItemInfo_Value(item, "D_VOL")
 reaper.SetMediaItemInfo_Value(item, "D_VOL", cur * db_to_amp(vol_db))
end
 local take = reaper.GetActiveTake(item)
 if take and not reaper.TakeIsMIDI(take) then
        if pitch_st then
 local cur = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
   reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", cur + pitch_st)
        end
  if rate then
             reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
        end
 end
   modified = modified + 1
   end
      return ok({ modified = modified,
applied = { volume_db = vol_db, pitch_semitones = pitch_st, rate = rate } })
    end)
end

local function tool_items_set_fades(input)
    local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then return fail("no media items selected") end
    local fin = tonumber(input.fade_in_seconds)
    local fout = tonumber(input.fade_out_seconds)
    if not fin and not fout then
        return fail("specify fade_in_seconds or fade_out_seconds")
    end
 return with_undo("MCAssistant: items_set_fades", function()
        local modified = 0
     for i = 0, n - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
       if fin  then reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN",  fin)  end
 if fout then reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fout) end
   modified = modified + 1
        end
   return ok({ modified = modified, fade_in = fin, fade_out = fout })
 end)
end

local function tool_items_split_at_cursor(_input)
    local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return fail("no media items selected") end
    local pos = reaper.GetCursorPosition()
    return with_undo("MCAssistant: items_split_at_cursor", function()
  local split = 0
  -- collect first since SplitMediaItem mutates selection
  local items = {}
      for i = 0, n - 1 do items[#items + 1] = reaper.GetSelectedMediaItem(0, i) end
   for _, item in ipairs(items) do
            local p  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
     local ln = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
if pos > p and pos < p + ln then
  if reaper.SplitMediaItem(item, pos) then split = split + 1 end
         end
    end
      return ok({ split = split, cursor = pos })
    end)
end

local function tool_items_get_info(_input)
 local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return ok({ count = 0, items = {} }) end
    local items = {}
    for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
        local info = {
            position   = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
   length   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
     volume_db  = amp_to_db(reaper.GetMediaItemInfo_Value(item, "D_VOL")),
   fade_in    = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
       fade_out   = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
        }
   if take then
        local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
   info.take_name = nm
          info.is_midi   = reaper.TakeIsMIDI(take)
      if not info.is_midi then
           info.pitch_semitones = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
     info.rate= reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
            local src = reaper.GetMediaItemTake_Source(take)
            if src then
                info.source_path       = reaper.GetMediaSourceFileName(src, "") or ""
                info.source_type       = reaper.GetMediaSourceType(src, "")
                info.source_samplerate = reaper.GetMediaSourceSampleRate(src)
                info.source_channels   = reaper.GetMediaSourceNumChannels(src)
            end
      end
        end
        items[#items + 1] = info
    end
    return ok({ count = #items, items = items })
end

local function take_audio_source(item)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then return nil end
    return reaper.GetMediaItemTake_Source(take)
end

local function tool_items_get_loudness(_input)
    if not reaper.CalculateNormalization then
        return fail("reaper.CalculateNormalization missing — REAPER 6.x+ required")
    end
    local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return ok({ count = 0, items = {} }) end
    local items = {}
    for i = 0, n - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local src = take_audio_source(item)
        local entry = { index = i }
        if src then
            local g_lufs = reaper.CalculateNormalization(src, NORMALIZE_MODES.lufs_i,    -23, 0, 0)
            local g_rms  = reaper.CalculateNormalization(src, NORMALIZE_MODES.rms_i,     -23, 0, 0)
            local g_pk   = reaper.CalculateNormalization(src, NORMALIZE_MODES.peak,       -1, 0, 0)
            local g_tp   = reaper.CalculateNormalization(src, NORMALIZE_MODES.true_peak,  -1, 0, 0)
            entry.lufs_i       = gain_to_current_db(g_lufs, -23)
            entry.rms_i        = gain_to_current_db(g_rms,  -23)
            entry.peak_db      = gain_to_current_db(g_pk,   -1)
            entry.true_peak_db = gain_to_current_db(g_tp,   -1)
        else
            entry.skipped = "MIDI or empty take"
        end
        items[#items + 1] = entry
    end
    return ok({ count = #items, items = items })
end

local function tool_items_normalize_loudness(input)
    if not reaper.CalculateNormalization then
        return fail("reaper.CalculateNormalization missing — REAPER 6.x+ required")
    end
    local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return fail("no media items selected") end
    local target = tonumber(input.target_db)
    if not target then
        return fail("target_db required (e.g. -16 streaming/games, -23 broadcast, -14 Spotify, -1 dBTP safety)")
    end
    local mode_str = (input.mode or "lufs_i"):lower()
    local mode_id  = NORMALIZE_MODES[mode_str]
    if not mode_id then
        return fail("mode must be one of: lufs_i, rms_i, peak, true_peak, lufs_m_max, lufs_s_max")
    end

    return with_undo("MCAssistant: items_normalize_loudness", function()
        local results = {}
        for i = 0, n - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            local src = take_audio_source(item)
            local entry = { index = i }
            if src then
                local gain = reaper.CalculateNormalization(src, mode_id, target, 0, 0)
                if gain and gain > 0 then
                    -- gain is "multiplier on the raw source to hit target", so
                    -- replace D_VOL outright (matches REAPER's native Normalize).
                    reaper.SetMediaItemInfo_Value(item, "D_VOL", gain)
                    entry.gain_db     = 20 * math.log(gain, 10)
                    entry.measured_db = gain_to_current_db(gain, target)
                    entry.target_db   = target
                else
                    entry.skipped = "could not compute loudness (silent or unsupported source)"
                end
            else
                entry.skipped = "MIDI or empty take"
            end
            results[#results + 1] = entry
        end
        return ok({ count = #results, results = results,
                    target_db = target, mode = mode_str })
    end)
end

-- ---------------------------------------------------------------------------
-- Tracks / FX
-- ---------------------------------------------------------------------------

local function tool_track_add_fx(input)
    local fx_name = input.fx_name
    if type(fx_name) ~= "string" or fx_name == "" then
        return fail("fx_name required, e.g. 'ReaEQ' or 'VST3: Pro-Q 4'")
    end
    local n = reaper.CountSelectedTracks(0)
    if n == 0 then return fail("no tracks selected") end
  return with_undo("MCAssistant: track_add_fx " .. fx_name, function()
        local results = {}
        for i = 0, n - 1 do
     local tr = reaper.GetSelectedTrack(0, i)
    local idx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
     if idx >= 0 then
     results[#results + 1] = { track = track_name(tr), fx_index = idx }
     else
         results[#results + 1] = { track = track_name(tr),
           error = "FX not found: " .. fx_name }
     end
        end
        return ok({ count = #results, results = results })
    end)
end

local function tool_track_create(input)
    local name = input.name
    local color = tonumber(input.color_rgb)
    return with_undo("MCAssistant: track_create", function()
        local idx = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idx, true)
     local tr = reaper.GetTrack(0, idx)
        if not tr then return fail("InsertTrackAtIndex failed") end
        if name and name ~= "" then
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  end
   if color then
       -- REAPER wants |0x01000000 to mark as custom color
   reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color | 0x01000000)
    end
     return ok({ index = idx, name = name or "" })
    end)
end

local function tool_track_set_volume(input)
    local n = reaper.CountSelectedTracks(0)
    if n == 0 then return fail("no tracks selected") end
    local vol_db = tonumber(input.volume_db)
    if not vol_db then return fail("volume_db required") end
    return with_undo("MCAssistant: track_set_volume", function()
    local modified = 0
  for i = 0, n - 1 do
     local tr = reaper.GetSelectedTrack(0, i)
 reaper.SetMediaTrackInfo_Value(tr, "D_VOL", db_to_amp(vol_db))
        modified = modified + 1
    end
 return ok({ modified = modified, volume_db = vol_db })
    end)
end

local function tool_track_get_info(_input)
    local n = reaper.CountSelectedTracks(0)
 if n == 0 then return ok({ count = 0, tracks = {} }) end
    local tracks = {}
    for i = 0, n - 1 do
 local tr = reaper.GetSelectedTrack(0, i)
        local fx_count = reaper.TrackFX_GetCount(tr)
      local fxs = {}
        for j = 0, fx_count - 1 do
      local _, fxn = reaper.TrackFX_GetFXName(tr, j, "")
   fxs[#fxs + 1] = fxn
        end
      tracks[#tracks + 1] = {
            name  = track_name(tr),
       volume_db = amp_to_db(reaper.GetMediaTrackInfo_Value(tr, "D_VOL")),
            pan    = reaper.GetMediaTrackInfo_Value(tr, "D_PAN"),
       fx    = fxs,
    }
    end
    return ok({ count = #tracks, tracks = tracks })
end

-- ---------------------------------------------------------------------------
-- FX parameter control
-- ---------------------------------------------------------------------------

local function resolve_track(input)
    local ti = tonumber(input and input.track_index)
    if ti then
local tr = reaper.GetTrack(0, ti)
        if not tr then return nil, "track_index out of range: " .. tostring(ti) end
        return tr
    end
    if reaper.CountSelectedTracks(0) == 0 then
        return nil, "no track selected and track_index not given"
    end
    return reaper.GetSelectedTrack(0, 0)
end

local function fx_bounds_check(tr, fx_index)
    local count = reaper.TrackFX_GetCount(tr)
    if fx_index < 0 or fx_index >= count then
        return false, ("fx_index %d out of range (track has %d FX)"):format(fx_index, count)
    end
    return true
end

local function tool_track_fx_list(input)
local tr, err = resolve_track(input)
    if not tr then return fail(err) end
    local count = reaper.TrackFX_GetCount(tr)
    local fxs = {}
    for i = 0, count - 1 do
        local _, fxname = reaper.TrackFX_GetFXName(tr, i, "")
        fxs[#fxs + 1] = {
         index = i,
            name = fxname,
  enabled = reaper.TrackFX_GetEnabled(tr, i),
   num_params = reaper.TrackFX_GetNumParams(tr, i),
        }
    end
    return ok({ track = track_name(tr), count = count, fx = fxs })
end

local function tool_track_fx_list_params(input)
    local tr, err = resolve_track(input)
    if not tr then return fail(err) end
    local fx_index = tonumber(input.fx_index)
    if not fx_index then return fail("fx_index required") end
    local okb, e = fx_bounds_check(tr, fx_index)
    if not okb then return fail(e) end
    local np = reaper.TrackFX_GetNumParams(tr, fx_index)
    local params = {}
    for p = 0, np - 1 do
        local _, pname = reaper.TrackFX_GetParamName(tr, fx_index, p, "")
        local norm = reaper.TrackFX_GetParamNormalized(tr, fx_index, p)
    local _, formatted = reaper.TrackFX_GetFormattedParamValue(tr, fx_index, p, "")
        local val, minv, maxv = reaper.TrackFX_GetParam(tr, fx_index, p)
        params[#params + 1] = {
       index = p, name = pname,
    normalized = norm,
    formatted = formatted,
    raw = val, min = minv, max = maxv,
 }
    end
    local _, fxname = reaper.TrackFX_GetFXName(tr, fx_index, "")
    return ok({ track = track_name(tr), fx_index = fx_index, fx_name = fxname,
  num_params = np, params = params })
end

local function tool_track_fx_set_params(input)
    local tr, err = resolve_track(input)
    if not tr then return fail(err) end
    local fx_index = tonumber(input.fx_index)
    if not fx_index then return fail("fx_index required") end
 local okb, e = fx_bounds_check(tr, fx_index)
    if not okb then return fail(e) end
    local params = input.params
    if type(params) ~= "table" or #params == 0 then
        return fail("params array required")
  end

    local np = reaper.TrackFX_GetNumParams(tr, fx_index)
    local name_to_idx = {}
    for p = 0, np - 1 do
        local _, pname = reaper.TrackFX_GetParamName(tr, fx_index, p, "")
     name_to_idx[pname:lower()] = p
    end

    return with_undo("MCAssistant: track_fx_set_params", function()
        local applied = {}
  local skipped = {}
        for _, spec in ipairs(params) do
         local pidx = tonumber(spec.index)
            if not pidx and type(spec.name) == "string" then
          pidx = name_to_idx[spec.name:lower()]
         end
            if not pidx or pidx < 0 or pidx >= np then
                skipped[#skipped + 1] = { spec = spec, reason = "param not found" }
    else
   local set_ok = false
        local used_value
      if spec.value_normalized ~= nil then
        local v = tonumber(spec.value_normalized)
           if v then
         v = math.max(0, math.min(1, v))
               set_ok = reaper.TrackFX_SetParamNormalized(tr, fx_index, pidx, v)
                  used_value = { normalized = v }
    end
    elseif spec.value_raw ~= nil then
     local v = tonumber(spec.value_raw)
           if v then
      set_ok = reaper.TrackFX_SetParam(tr, fx_index, pidx, v)
            used_value = { raw = v }
      end
        elseif spec.value_text ~= nil then
 local _, parsed_norm = reaper.TrackFX_FormatParamValueNormalized(
     tr, fx_index, pidx, 0, tostring(spec.value_text))
             if type(parsed_norm) == "number" then
    set_ok = reaper.TrackFX_SetParamNormalized(tr, fx_index, pidx, parsed_norm)
       used_value = { text = spec.value_text, parsed_normalized = parsed_norm }
              else
   skipped[#skipped + 1] = { spec = spec, reason = "value_text could not be parsed" }
     end
       else
                skipped[#skipped + 1] = { spec = spec, reason = "no value given (use value_normalized / value_raw / value_text)" }
                end
  if set_ok then
           local norm = reaper.TrackFX_GetParamNormalized(tr, fx_index, pidx)
            local _, formatted = reaper.TrackFX_GetFormattedParamValue(tr, fx_index, pidx, "")
         applied[#applied + 1] = { index = pidx, name = spec.name, used = used_value,
            normalized = norm, formatted = formatted }
         end
            end
end
return ok({ applied = applied, applied_count = #applied,
             skipped = skipped, skipped_count = #skipped })
    end)
end

local function tool_track_fx_set_enabled(input)
    local tr, err = resolve_track(input)
    if not tr then return fail(err) end
 local fx_index = tonumber(input.fx_index)
    if not fx_index then return fail("fx_index required") end
    local okb, e = fx_bounds_check(tr, fx_index)
    if not okb then return fail(e) end
    if type(input.enabled) ~= "boolean" then return fail("enabled (boolean) required") end
    return with_undo("MCAssistant: track_fx_set_enabled", function()
    reaper.TrackFX_SetEnabled(tr, fx_index, input.enabled)
     return ok({ fx_index = fx_index, enabled = reaper.TrackFX_GetEnabled(tr, fx_index) })
    end)
end

local function tool_track_fx_remove(input)
    local tr, err = resolve_track(input)
    if not tr then return fail(err) end
    local fx_index = tonumber(input.fx_index)
    if not fx_index then return fail("fx_index required") end
    local okb, e = fx_bounds_check(tr, fx_index)
    if not okb then return fail(e) end
    local _, fxname = reaper.TrackFX_GetFXName(tr, fx_index, "")
    return with_undo("MCAssistant: track_fx_remove", function()
        local deleted = reaper.TrackFX_Delete(tr, fx_index)
      if not deleted then return fail("TrackFX_Delete failed") end
   return ok({ removed_index = fx_index, removed_name = fxname })
    end)
end

local function tool_track_fx_load_preset(input)
    local tr, err = resolve_track(input)
    if not tr then return fail(err) end
    local fx_index = tonumber(input.fx_index)
  if not fx_index then return fail("fx_index required") end
    local okb, e = fx_bounds_check(tr, fx_index)
    if not okb then return fail(e) end
    local preset = input.preset_name
    if type(preset) ~= "string" or preset == "" then return fail("preset_name required") end
    return with_undo("MCAssistant: track_fx_load_preset", function()
        local applied = reaper.TrackFX_SetPreset(tr, fx_index, preset)
        if not applied then return fail("preset not found: " .. preset) end
        return ok({ fx_index = fx_index, preset = preset })
 end)
end

-- ---------------------------------------------------------------------------
-- MIDI
-- ---------------------------------------------------------------------------

local function tool_midi_insert_notes(input)
    local n = reaper.CountSelectedTracks(0)
    if n == 0 then return fail("no track selected") end
    local track = reaper.GetSelectedTrack(0, 0)
  local start_time = tonumber(input.start_seconds) or reaper.GetCursorPosition()
local length = tonumber(input.length_seconds)
    if not length or length <= 0 then return fail("length_seconds must be > 0") end
 local notes = input.notes
    if type(notes) ~= "table" or #notes == 0 then
        return fail("notes array required")
    end
    return with_undo("MCAssistant: midi_insert_notes", function()
        local item = reaper.CreateNewMIDIItemInProj(track, start_time, start_time + length, false)
if not item then return fail("CreateNewMIDIItemInProj failed") end
  local take = reaper.GetActiveTake(item)
        if not take then return fail("MIDI take missing") end
  local inserted = 0
        for _, note in ipairs(notes) do
      local pitch  = tonumber(note.pitch)
    local nstart = tonumber(note.start_seconds)
 local nlen = tonumber(note.length_seconds)
        local vel = tonumber(note.velocity) or 96
    if pitch and nstart and nlen and pitch >= 0 and pitch <= 127 then
           local s_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, start_time + nstart)
   local e_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, start_time + nstart + nlen)
     reaper.MIDI_InsertNote(take, false, false, s_ppq, e_ppq, 0, pitch, vel, true)
     inserted = inserted + 1
    end
  end
 reaper.MIDI_Sort(take)
     return ok({ inserted = inserted, item_start = start_time, item_length = length })
  end)
end

local function tool_midi_transpose(input)
    local semis = tonumber(input.semitones)
    if not semis or semis == 0 then return fail("semitones required (non-zero)") end
    local n = reaper.CountSelectedMediaItems(0)
    if n == 0 then return fail("no items selected") end
    return with_undo("MCAssistant: midi_transpose", function()
        local transposed = 0
     for i = 0, n - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
     local take = reaper.GetActiveTake(item)
       if take and reaper.TakeIsMIDI(take) then
   local _, note_cnt = reaper.MIDI_CountEvts(take)
     for k = 0, note_cnt - 1 do
           local _, sel, muted, s, e, ch, pitch, vel = reaper.MIDI_GetNote(take, k)
                local np = math.max(0, math.min(127, pitch + semis))
     reaper.MIDI_SetNote(take, k, sel, muted, s, e, ch, np, vel, true)
      end
     reaper.MIDI_Sort(take)
     transposed = transposed + 1
       end
 end
        return ok({ items_transposed = transposed, semitones = semis })
    end)
end

-- ---------------------------------------------------------------------------
-- Regions & Markers
-- ---------------------------------------------------------------------------

local function parse_color_rgb(c)
 local n = tonumber(c)
    if not n then return nil end
    return reaper.ColorToNative(
        (n >> 16) & 0xFF,
        (n >> 8) & 0xFF,
        n & 0xFF) | 0x01000000
end

local function native_to_rgb_int(native)
    if not native or native == 0 then return 0 end
    local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return (r << 16) | (g << 8) | b
end

local function find_region_by_id(rid)
    local i = 0
    while true do
  local ok_r, isrgn, pos, rgnend, name, markrgnindexnumber, color =
   reaper.EnumProjectMarkers3(0, i)
     if ok_r == 0 then return nil end
        if isrgn and markrgnindexnumber == rid then
   return i, pos, rgnend, name, color
      end
        i = i + 1
    end
end

local function tool_regions_list(input)
    local filter_name = input and input.name_contains
    local i = 0
    local regions = {}
  local markers = {}
    while true do
 local ok_r, isrgn, pos, rgnend, name, idnum, color =
      reaper.EnumProjectMarkers3(0, i)
    if ok_r == 0 then break end
       local matches = true
        if filter_name and filter_name ~= "" then
     matches = name:lower():find(filter_name:lower(), 1, true) ~= nil
    end
        if matches then
      local entry = {
          id = idnum, name = name,
       position = pos,
   color_rgb = native_to_rgb_int(color),
    }
     if isrgn then
   entry["end"] = rgnend
  entry.length = rgnend - pos
     regions[#regions + 1] = entry
  else
    markers[#markers + 1] = entry
     end
        end
        i = i + 1
  end
    local include_markers = input and input.include_markers
    local result = { count = #regions, regions = regions }
    if include_markers then
        result.markers = markers
     result.marker_count = #markers
    end
    return ok(result)
end

local function tool_region_add(input)
    local pos = tonumber(input.position_seconds)
    local rend = tonumber(input.end_seconds)
    if not pos or not rend then return fail("position_seconds and end_seconds required") end
    if rend <= pos then return fail("end_seconds must be > position_seconds") end
    local name = input.name or ""
    local want_id = tonumber(input.wantidx) or -1
    local color = parse_color_rgb(input.color_rgb) or 0
    return with_undo("MCAssistant: region_add", function()
  local new_id = reaper.AddProjectMarker2(0, true, pos, rend, name, want_id, color)
      if new_id == -1 then return fail("AddProjectMarker2 failed") end
        return ok({ id = new_id, name = name,
            position = pos, ["end"] = rend, length = rend - pos })
    end)
end

local function tool_region_update(input)
    local rid = tonumber(input.id)
    if not rid then return fail("id required") end
    local found_idx, cur_pos, cur_end, cur_name, cur_color = find_region_by_id(rid)
    if not found_idx then return fail("region id not found: " .. rid) end

    local new_pos = tonumber(input.position_seconds) or cur_pos
    local new_end = tonumber(input.end_seconds) or cur_end
    if new_end <= new_pos then return fail("end must be > position") end
    local new_name = input.name ~= nil and input.name or cur_name
    local new_color = input.color_rgb ~= nil and (parse_color_rgb(input.color_rgb) or 0) or cur_color

    return with_undo("MCAssistant: region_update", function()
  local applied = reaper.SetProjectMarker4(0, rid, true, new_pos, new_end, new_name, new_color, 0)
    if not applied then return fail("SetProjectMarker4 failed") end
        return ok({ id = rid, name = new_name,
    position = new_pos, ["end"] = new_end, length = new_end - new_pos,
            color_rgb = native_to_rgb_int(new_color) })
    end)
end

local function tool_region_delete(input)
    local rid = tonumber(input.id)
    if not rid then return fail("id required") end
    if not find_region_by_id(rid) then return fail("region id not found: " .. rid) end
    return with_undo("MCAssistant: region_delete", function()
      local deleted = reaper.DeleteProjectMarker(0, rid, true)
      if not deleted then return fail("DeleteProjectMarker failed") end
        return ok({ deleted_id = rid })
 end)
end

-- ---------------------------------------------------------------------------
-- Project
-- ---------------------------------------------------------------------------

local function tool_project_get_state(_input)
    local tempo = reaper.Master_GetTempo()
    local _, tsn, tsd = reaper.TimeMap_GetTimeSigAtTime(0, 0)
    local _, proj_name = reaper.EnumProjects(-1)
    return ok({
        tempo_bpm= tempo,
      time_sig_num      = tsn,
        time_sig_den      = tsd,
 project_path      = proj_name or "",
     cursor_seconds    = reaper.GetCursorPosition(),
 track_count       = reaper.CountTracks(0),
   item_count      = reaper.CountMediaItems(0),
    sel_track_count   = reaper.CountSelectedTracks(0),
sel_item_count    = reaper.CountSelectedMediaItems(0),
      play_state= reaper.GetPlayState(),  -- bitfield
    })
end

local function tool_project_render(input)
    local out_dir = input.output_directory
    if type(out_dir) ~= "string" or out_dir == "" then
        return fail("output_directory required (absolute path)")
    end
    if not is_abs_path(out_dir) then
        return fail("output_directory must be absolute (e.g. C:\\Users\\you\\Desktop\\out)")
    end

    local bounds_str = input.bounds
    local bflag = bounds_str and RENDER_BOUNDS[bounds_str]
    if not bflag then
        return fail("bounds required: entire_project | time_selection | all_regions | selected_items | selected_regions")
    end

    if bflag == RENDER_BOUNDS.selected_items and reaper.CountSelectedMediaItems(0) == 0 then
        return fail("bounds=selected_items but no items are selected")
    end
    if bflag == RENDER_BOUNDS.time_selection then
        local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        if s == e then return fail("bounds=time_selection but no time selection set") end
    end

    local format_str = input.format or "current"
    if format_str ~= "current" and not RENDER_FORMATS[format_str] then
        return fail("format must be one of: wav_16, wav_24, wav_32f, mp3_320, mp3_192, flac, current")
    end

    local pattern = input.filename_pattern
    if not pattern or pattern == "" then
        if bflag == RENDER_BOUNDS.selected_items then
            pattern = "$item"
        elseif bflag == RENDER_BOUNDS.all_regions or bflag == RENDER_BOUNDS.selected_regions then
            pattern = "$region"
        else
            pattern = "$project"
        end
    end

    local tail = tonumber(input.tail_seconds)
    local merge = input.merge == true  -- only meaningful for selected_items

    reaper.RecursiveCreateDirectory(out_dir, 0)

    local function apply_settings()
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE",     out_dir, true)
        reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN",  pattern, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", bflag, true)
        if format_str ~= "current" then
            reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", RENDER_FORMATS[format_str], true)
        end
        if tail and tail > 0 then
            reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0xFF, true)
            reaper.GetSetProjectInfo(0, "RENDER_TAILMS",   tail * 1000, true)
        end
        -- Force master-mix mode so each render produces a single predictable file.
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)
    end

    -- Per-item path: each selected item rendered to its own file, isolated
    -- from the rest of the project by temporarily muting every other item.
    -- Time range is set per-item via bounds=custom + RENDER_STARTPOS/ENDPOS so
    -- there is no ambiguity about what REAPER will include.
    if bflag == RENDER_BOUNDS.selected_items and not merge then
        local saved_sel = {}
        for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
            saved_sel[#saved_sel + 1] = reaper.GetSelectedMediaItem(0, i)
        end

        -- Render-wide settings; pattern + start/end are set per iteration.
        reaper.GetSetProjectInfo_String(0, "RENDER_FILE", out_dir, true)
        if format_str ~= "current" then
            reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", RENDER_FORMATS[format_str], true)
        end
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", RENDER_BOUNDS.custom, true)
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)
        if tail and tail > 0 then
            reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0xFF, true)
            reaper.GetSetProjectInfo(0, "RENDER_TAILMS",   tail * 1000, true)
        else
            reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
            reaper.GetSetProjectInfo(0, "RENDER_TAILMS",   0, true)
        end

        local all_files = {}
        local total_items = reaper.CountMediaItems(0)

        for idx, target in ipairs(saved_sel) do
            -- Snapshot mute on every other media item, then mute them.
            local muted_others = {}
            for j = 0, total_items - 1 do
                local it = reaper.GetMediaItem(0, j)
                if it ~= target then
                    muted_others[#muted_others + 1] = {
                        item = it,
                        prev = reaper.GetMediaItemInfo_Value(it, "B_MUTE"),
                    }
                    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1)
                end
            end
            local target_prev_mute = reaper.GetMediaItemInfo_Value(target, "B_MUTE")
            if target_prev_mute ~= 0 then
                reaper.SetMediaItemInfo_Value(target, "B_MUTE", 0)
            end

            -- Time range = exact item bounds; tail is added separately via RENDER_TAILMS.
            local pos = reaper.GetMediaItemInfo_Value(target, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(target, "D_LENGTH")
            reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", pos,       true)
            reaper.GetSetProjectInfo(0, "RENDER_ENDPOS",   pos + len, true)

            -- Filename = sanitized take name, fallback to item_<idx>.
            local take = reaper.GetActiveTake(target)
            local raw_name = ""
            if take then
                local _, n = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                raw_name = n or ""
            end
            local pat = sanitize_filename(raw_name) or ("item_" .. tostring(idx))
            reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", pat, true)

            -- Force selection to just the target so $item-style wildcards (if any
            -- remain in user-supplied patterns) and RENDER_TARGETS resolve consistently.
            reaper.SelectAllMediaItems(0, false)
            reaper.SetMediaItemSelected(target, true)
            reaper.UpdateArrange()

            reaper.Main_OnCommand(42230, 0)

            local _, written = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
            for f in (written or ""):gmatch("([^;]+)") do
                all_files[#all_files + 1] = f
            end

            -- Restore mute state.
            if target_prev_mute ~= 0 then
                reaper.SetMediaItemInfo_Value(target, "B_MUTE", target_prev_mute)
            end
            for _, m in ipairs(muted_others) do
                reaper.SetMediaItemInfo_Value(m.item, "B_MUTE", m.prev)
            end
        end

        -- Restore original selection.
        reaper.SelectAllMediaItems(0, false)
        for _, it in ipairs(saved_sel) do reaper.SetMediaItemSelected(it, true) end
        reaper.UpdateArrange()

        return ok({
            output_directory = out_dir,
            bounds           = bounds_str,
            format           = format_str,
            merge            = false,
            file_count       = #all_files,
            files            = all_files,
        })
    end

    -- Single-render path: entire_project / time_selection / regions / merged selected_items.
    apply_settings()

    local _, planned = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)

    -- Action 42230: File: Render project, using the most recent render settings.
    -- Synchronous; may briefly show REAPER's render progress dialog.
    reaper.Main_OnCommand(42230, 0)

    local _, written = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)

    local files = {}
    for f in (written or ""):gmatch("([^;]+)") do
        files[#files + 1] = f
    end

    return ok({
        output_directory = out_dir,
        bounds           = bounds_str,
        format           = format_str,
        filename_pattern = pattern,
        merge            = merge,
        file_count       = #files,
        files            = files,
        planned_targets  = planned,
    })
end

-- ---------------------------------------------------------------------------
-- Registry (single source of truth)
-- ---------------------------------------------------------------------------

local empty_object = function() return json.as_object({}) end

local REGISTRY = {
    { name = "me_get_selection",
      description = "Read the file(s) currently selected in REAPER's Media Explorer. Returns absolute paths when resolvable. Use for 'the selected SFX', 'the file I'm previewing'.",
      schema = { type = "object", properties = empty_object(), additionalProperties = false },
      execute = tool_me_get_selection },

    { name = "me_import_to_track",
     description = "Import file(s) currently selected in Media Explorer onto a track as new media items. USE THIS TOOL DIRECTLY when the user asks to import / 导入 / 放进来 / 拖进来 a Media Explorer file — do NOT first query selection state, this tool reads ME selection internally. If a track is selected it imports onto that track; otherwise it creates a new track automatically. Multiple selected ME files are placed end-to-end starting at position_seconds (default: edit cursor).",
      schema = { type = "object",
 properties = {
   position_seconds = { type = "number", description = "Project time to place the first file. Defaults to edit cursor." }
   }, additionalProperties = false },
 execute = tool_me_import_to_track },

    { name = "items_batch_edit",
    description = "Apply volume / pitch / playback-rate to every selected media item. At least one field required. Single Undo step.",
      schema = { type = "object",
     properties = {
  volume_db       = { type = "number", description = "Decibel offset added to current item volume." },
     pitch_semitones = { type = "number", description = "Semitones added to current take pitch (audio only)." },
rate = { type = "number", description = "Absolute playback rate (1.0 = original). Must be > 0." },
      }, additionalProperties = false },
      execute = tool_items_batch_edit },

    { name = "items_set_fades",
description = "Set fade-in and/or fade-out length (seconds) on every selected media item.",
      schema = { type = "object",
   properties = {
            fade_in_seconds  = { type = "number" },
     fade_out_seconds = { type = "number" },
   }, additionalProperties = false },
      execute = tool_items_set_fades },

    { name = "items_split_at_cursor",
    description = "Split every selected media item at the current edit cursor position.",
schema = { type = "object", properties = empty_object(), additionalProperties = false },
  execute = tool_items_split_at_cursor },

    { name = "items_get_info",
      description = "Read-only: report position, length, volume, fades, pitch, rate and take name for every selected item.",
      schema = { type = "object", properties = empty_object(), additionalProperties = false },
      execute = tool_items_get_info },

    { name = "items_get_loudness",
      description = "Read-only: measure each selected audio item's integrated LUFS (EBU R128), integrated RMS, peak, and true peak in dB. MIDI/empty takes are skipped. Use to answer 'how loud are these?' or to inspect before normalising.",
      schema = { type = "object", properties = empty_object(), additionalProperties = false },
      execute = tool_items_get_loudness },

    { name = "items_normalize_loudness",
      description = "Apply per-item gain so each selected audio item hits target_db in the chosen measurement mode. Single Undo step. Modes: lufs_i (integrated LUFS, default), rms_i, peak, true_peak, lufs_m_max, lufs_s_max. Common targets: -23 LUFS broadcast (EBU R128), -16 LUFS streaming/games, -14 LUFS Spotify, -1 dBTP safety. Pick target_db based on user-stated context — confirm with user before calling if context is unclear. MIDI items are skipped.",
      schema = { type = "object",
        properties = {
            target_db = { type = "number", description = "Target level in dB (or LUFS for LUFS modes)." },
            mode      = { type = "string",
                          enum = { "lufs_i", "rms_i", "peak", "true_peak", "lufs_m_max", "lufs_s_max" },
                          description = "Measurement standard. Default: lufs_i." },
        }, required = { "target_db" }, additionalProperties = false },
      execute = tool_items_normalize_loudness },

    { name = "track_add_fx",
   description = "Add an FX plugin by name to every selected track. Use REAPER name format: 'ReaEQ' or 'VST3: Pro-Q 4'.",
      schema = { type = "object",
     properties = { fx_name = { type = "string" } },
       required = { "fx_name" }, additionalProperties = false },
   execute = tool_track_add_fx },

    { name = "track_create",
      description = "Create a new track at the end of the project. Optional name and color.",
      schema = { type = "object",
     properties = {
     name      = { type = "string" },
        color_rgb = { type = "integer", description = "0xRRGGBB integer" },
        }, additionalProperties = false },
execute = tool_track_create },

    { name = "track_set_volume",
      description = "Set absolute volume (in dB) on every selected track.",
      schema = { type = "object",
        properties = { volume_db = { type = "number" } },
        required = { "volume_db" }, additionalProperties = false },
      execute = tool_track_set_volume },

 { name = "track_get_info",
description = "Read-only: report name, volume, pan and FX chain of every selected track.",
 schema = { type = "object", properties = empty_object(), additionalProperties = false },
 execute = tool_track_get_info },

    { name = "track_fx_list",
  description = "List every FX on a track with its index, enabled flag and param count. Use this before calling track_fx_list_params to know which fx_index to target.",
    schema = { type = "object",
 properties = {
 track_index = { type = "integer", description = "0-based track index. Omit to use first selected track." },
   }, additionalProperties = false },
    execute = tool_track_fx_list },

 { name = "track_fx_list_params",
description = "Read-only: list all parameters of one FX — name, index, normalized (0-1) value, formatted (display) value, raw value, min, max. ALWAYS call this before track_fx_set_params so you know the exact parameter names.",
    schema = { type = "object",
        properties = {
            track_index = { type = "integer" },
 fx_index  = { type = "integer" },
      }, required = { "fx_index" }, additionalProperties = false },
      execute = tool_track_fx_list_params },

    { name = "track_fx_set_params",
      description = "Set one or more parameters of a single FX. Each param: identify by 'name' (case-insensitive, as reported by track_fx_list_params) or 'index'. Provide ONE of: value_normalized (0-1), value_raw (plugin-native float), value_text (string like '-6dB' / '440 Hz' — REAPER tries to parse it). Single Undo step.",
      schema = { type = "object",
   properties = {
   track_index = { type = "integer" },
     fx_index    = { type = "integer" },
    params = {
 type = "array",
          items = { type = "object",
   properties = {
       name= { type = "string" },
             index = { type = "integer" },
     value_normalized = { type = "number" },
    value_raw        = { type = "number" },
       value_text       = { type = "string" },
         } },
       },
        }, required = { "fx_index", "params" }, additionalProperties = false },
      execute = tool_track_fx_set_params },

    { name = "track_fx_set_enabled",
      description = "Enable or bypass one FX on a track.",
    schema = { type = "object",
        properties = {
track_index = { type = "integer" },
            fx_index    = { type = "integer" },
   enabled     = { type = "boolean" },
  }, required = { "fx_index", "enabled" }, additionalProperties = false },
      execute = tool_track_fx_set_enabled },

    { name = "track_fx_remove",
      description = "Delete one FX from a track by index.",
      schema = { type = "object",
      properties = {
 track_index = { type = "integer" },
     fx_index    = { type = "integer" },
        }, required = { "fx_index" }, additionalProperties = false },
      execute = tool_track_fx_remove },

    { name = "track_fx_load_preset",
      description = "Load a named preset into one FX. Preset must exist in that plugin's preset list.",
      schema = { type = "object",
     properties = {
  track_index = { type = "integer" },
    fx_index    = { type = "integer" },
    preset_name = { type = "string" },
        }, required = { "fx_index", "preset_name" }, additionalProperties = false },
      execute = tool_track_fx_load_preset },

    { name = "midi_insert_notes",
      description = "Create a new MIDI item on the first selected track and insert notes. Notes are relative to item start.",
      schema = { type = "object",
    properties = {
       start_seconds  = { type = "number", description = "Project time where the item begins. Defaults to edit cursor." },
        length_seconds = { type = "number" },
            notes = {
             type = "array",
       description = "Each: {pitch 0-127, start_seconds (rel to item), length_seconds, velocity? 0-127}",
     items = { type = "object",
           properties = {
       pitch          = { type = "integer" },
      start_seconds  = { type = "number" },
   length_seconds = { type = "number" },
        velocity   = { type = "integer" },
    },
     required = { "pitch", "start_seconds", "length_seconds" } },
      }
 }, required = { "length_seconds", "notes" }, additionalProperties = false },
      execute = tool_midi_insert_notes },

  { name = "midi_transpose",
      description = "Transpose every note in every selected MIDI item by N semitones.",
      schema = { type = "object",
     properties = { semitones = { type = "integer" } },
     required = { "semitones" }, additionalProperties = false },
   execute = tool_midi_transpose },

    { name = "regions_list",
   description = "List all regions in the project. Each: { id, name, position (s), end (s), length (s), color_rgb }. Optional name_contains filters by case-insensitive substring. Optional include_markers also returns plain markers.",
      schema = { type = "object",
      properties = {
 name_contains   = { type = "string" },
     include_markers = { type = "boolean" },
        }, additionalProperties = false },
      execute = tool_regions_list },

    { name = "region_add",
 description = "Create a new region. Returns the assigned id. wantidx is optional preferred id (use -1 or omit for auto).",
      schema = { type = "object",
        properties = {
            position_seconds = { type = "number" },
       end_seconds      = { type = "number" },
            name         = { type = "string" },
    color_rgb = { type = "integer", description = "0xRRGGBB" },
       wantidx          = { type = "integer" },
  }, required = { "position_seconds", "end_seconds" }, additionalProperties = false },
      execute = tool_region_add },

    { name = "region_update",
   description = "Modify a region by id. Any field omitted is left unchanged. Find ids via regions_list first.",
      schema = { type = "object",
        properties = {
 id       = { type = "integer" },
 position_seconds = { type = "number" },
          end_seconds      = { type = "number" },
    name             = { type = "string" },
         color_rgb   = { type = "integer" },
        }, required = { "id" }, additionalProperties = false },
      execute = tool_region_update },

    { name = "region_delete",
      description = "Delete a region by id.",
      schema = { type = "object",
        properties = { id = { type = "integer" } },
        required = { "id" }, additionalProperties = false },
      execute = tool_region_delete },

    { name = "project_get_state",
      description = "Read-only snapshot of project: tempo, time signature, cursor position, track/item counts, play state.",
 schema = { type = "object", properties = empty_object(), additionalProperties = false },
  execute = tool_project_get_state },

    { name = "project_render",
      description = "Render audio to disk via REAPER's Render Project. SYNCHRONOUS — blocks REAPER for the full render duration; mention this to the user before long renders. bounds: entire_project | time_selection | all_regions | selected_items | selected_regions. When bounds=selected_items, EACH selected item is rendered to its own file by default; pass merge=true to mixdown all selected items into a single file (only do this when the user explicitly says 合并 / 混成一个 / combine). format: wav_16 / wav_24 / wav_32f / mp3_320 / mp3_192 / flac / current (use 'current' if a preset blob misbehaves on this REAPER build — the user must have configured File>Render once). For '按原格式导出' (match source format): call items_get_info first, read source_type / source_samplerate / source_channels of the selected items, then pick the closest preset (WAVE → wav_24, MP3 → mp3_320, FLAC → flac). filename_pattern uses REAPER wildcards ($project, $region, $item, $track); defaults are sensible per bounds. tail_seconds optionally adds an FX tail (e.g. 0.5 for items with reverb). Returns the actual file paths written.",
      schema = { type = "object",
        properties = {
            output_directory = { type = "string", description = "Absolute path to output folder (created if missing)." },
            bounds           = { type = "string",
                                 enum = { "entire_project", "time_selection", "all_regions", "selected_items", "selected_regions" } },
            format           = { type = "string",
                                 enum = { "wav_16", "wav_24", "wav_32f", "mp3_320", "mp3_192", "flac", "current" },
                                 description = "Audio format preset, or 'current' to use REAPER's existing Render dialog setting." },
            filename_pattern = { type = "string", description = "REAPER render pattern. Default chosen per bounds." },
            tail_seconds     = { type = "number", description = "Optional FX tail length in seconds." },
            merge            = { type = "boolean", description = "Only relevant when bounds=selected_items. Default false: each selected item rendered to its own file. Set true to mixdown all selected items into one file." },
        }, required = { "output_directory", "bounds", "format" }, additionalProperties = false },
      execute = tool_project_render },
}

M.TOOL_LIST = {}
local DISPATCH = {}

for _, t in ipairs(REGISTRY) do
    M.TOOL_LIST[#M.TOOL_LIST + 1] = {
      name = t.name, description = t.description, input_schema = t.schema,
    }
    DISPATCH[t.name] = t.execute
end

function M.dispatch(name, input)
    local fn = DISPATCH[name]
  if not fn then return fail("unknown tool: " .. tostring(name)) end
    local okc, result = pcall(fn, input or {})
    if not okc then return fail("tool crashed: " .. tostring(result)) end
    return result
end

return M

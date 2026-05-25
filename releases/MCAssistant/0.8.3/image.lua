--
-- image.lua  —  Image helpers for MCAssistant (clipboard paste, MIME, load).
--
-- paste_clipboard()  → temp PNG path | nil
-- infer_mime(path)   → "image/png"|"image/jpeg"|"image/gif"|"image/webp" | nil
-- load_for_send(path)→ { mime, b64, byte_count, path } | nil, err
--

local base64 = require("base64")

local M = {}

local TEMP_DIR = nil

local function ensure_temp_dir()
    if TEMP_DIR then return TEMP_DIR end
    TEMP_DIR = reaper.GetResourcePath() .. "\\Data\\MCAssistant"
    reaper.RecursiveCreateDirectory(TEMP_DIR, 0)
    return TEMP_DIR
end

-- Max pre-base64 byte size (5 MB).
local MAX_BYTES = 5 * 1024 * 1024

-- Extension → MIME. Returns nil for unsupported formats.
local EXT_MIME = {
    [".png"]  = "image/png",
    [".jpg"]  = "image/jpeg",
    [".jpeg"] = "image/jpeg",
    [".gif"]  = "image/gif",
    [".webp"] = "image/webp",
}

function M.infer_mime(path)
    if not path then return nil end
    local ext = path:match("(%.[^%.]+)$")
    if not ext then return nil end
    return EXT_MIME[ext:lower()]
end

--- Read image bytes from the Windows clipboard and save as PNG.
-- Uses PowerShell Get-Clipboard -Format Image. Returns a temp file path
-- or nil if the clipboard contains no image.
function M.paste_clipboard()
    local dir = ensure_temp_dir()
    local ts  = tostring(math.floor(reaper.time_precise() * 1e6))
    local out_path = dir .. "\\paste_" .. ts .. ".png"
    -- PowerShell one-liner: grab bitmap from clipboard, save as PNG.
    -- Redirect stderr to nul so non-image clipboard content doesn't noisy-error.
    local ps_cmd = string.format(
        'powershell -NoProfile -Command "'
        .. '$img = Get-Clipboard -Format Image -ErrorAction SilentlyContinue; '
        .. 'if ($img) { $img.Save(\'%s\', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output \'ok\' }'
        .. '"',
        out_path:gsub("\\", "\\\\"))
    local out = reaper.ExecProcess(ps_cmd, 8000)
    if not out or out == "" then return nil end
    if not out:match("ok") then return nil end
    -- Verify the file was actually written.
    local f = io.open(out_path, "rb")
    if not f then return nil end
    local sz = f:seek("end")
    f:close()
    if not sz or sz == 0 then return nil end
    return out_path
end

--- Load an image file for sending to the API.
-- Reads bytes, base64-encodes, checks size limit. Returns a table
-- { mime, b64, byte_count, path } or nil + error string.
function M.load_for_send(path)
    local mime = M.infer_mime(path)
    if not mime then
        return nil, "不支持的图片格式（仅 PNG/JPG/GIF/WebP）"
    end
    local f = io.open(path, "rb")
    if not f then return nil, "无法打开文件" end
    local bytes = f:read("*a")
    f:close()
    if not bytes or #bytes == 0 then
        return nil, "文件为空"
    end
    if #bytes > MAX_BYTES then
        return nil, ("图片过大（%d KB，最多 5 MB）"):format(math.floor(#bytes / 1024))
    end
    local b64 = base64.encode(bytes)
    return { mime = mime, b64 = b64, byte_count = #bytes, path = path }
end

return M

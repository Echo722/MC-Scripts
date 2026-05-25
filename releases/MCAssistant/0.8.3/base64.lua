--
-- base64.lua  —  Pure-Lua binary → base64 encoder.
-- Uses Lua 5.4 bit ops (<< >> & |). No external dependencies.
--

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function encode(bytes)
    local out = {}
    local n = #bytes
    local i = 1
    while i + 2 <= n do
        local a, b, c = bytes:byte(i, i + 2)
        local tri = (a << 16) | (b << 8) | c
        out[#out + 1] = B64:sub(((tri >> 18) & 0x3F) + 1, ((tri >> 18) & 0x3F) + 1)
        out[#out + 1] = B64:sub(((tri >> 12) & 0x3F) + 1, ((tri >> 12) & 0x3F) + 1)
        out[#out + 1] = B64:sub(((tri >>  6) & 0x3F) + 1, ((tri >>  6) & 0x3F) + 1)
        out[#out + 1] = B64:sub(( tri        & 0x3F) + 1, ( tri        & 0x3F) + 1)
        i = i + 3
    end
    local rem = n - i + 1
    if rem == 2 then
        local a, b = bytes:byte(i, i + 1)
        local tri = (a << 16) | (b << 8)
        out[#out + 1] = B64:sub(((tri >> 18) & 0x3F) + 1, ((tri >> 18) & 0x3F) + 1)
        out[#out + 1] = B64:sub(((tri >> 12) & 0x3F) + 1, ((tri >> 12) & 0x3F) + 1)
        out[#out + 1] = B64:sub(((tri >>  6) & 0x3F) + 1, ((tri >>  6) & 0x3F) + 1)
        out[#out + 1] = "="
    elseif rem == 1 then
        local a = bytes:byte(i)
        local tri = a << 16
        out[#out + 1] = B64:sub(((tri >> 18) & 0x3F) + 1, ((tri >> 18) & 0x3F) + 1)
        out[#out + 1] = B64:sub(((tri >> 12) & 0x3F) + 1, ((tri >> 12) & 0x3F) + 1)
        out[#out + 1] = "="
        out[#out + 1] = "="
    end
    return table.concat(out)
end

return { encode = encode }

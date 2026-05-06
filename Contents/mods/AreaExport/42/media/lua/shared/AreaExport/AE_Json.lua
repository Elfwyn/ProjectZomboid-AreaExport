--[[
    Area Export - Minimal JSON encoder/decoder.
    Supports nested objects, arrays, strings (with basic escapes), numbers, bools, null.
    Sufficient for the AreaExport save format.

    This avoids an external dependency because PZ mod loading cannot assume a JSON
    library is present on both client and dedicated server. Keep it conservative:
    it only needs to parse JSON emitted by this same encoder and the local export
    files, not arbitrary internet JSON.
]]

local AE_Json = {}

-- =========================================================================
-- ENCODE
-- =========================================================================
local encodeValue

local function escapeString(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    s = string.gsub(s, "\t", "\\t")
    return '"' .. s .. '"'
end

-- Lua tables can be array-like or map-like. Heuristic: 1..n integer keys = array;
-- empty tables encode as objects so empty metadata/rule maps stay JSON objects.
local function isArray(t)
    local n = 0
    for k in pairs(t) do
        n = n + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
    end
    if n == 0 then return false end  -- empty: encode as object
    -- Check contiguous 1..n
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local function encodeArray(t, n)
    local parts = {}
    for i = 1, n do parts[i] = encodeValue(t[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encodeObject(t)
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then table.insert(keys, k) end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, escapeString(k) .. ":" .. encodeValue(t[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v)
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif tv == "string" then return escapeString(v)
    elseif tv == "table" then
        local arr, n = isArray(v)
        if arr then return encodeArray(v, n) else return encodeObject(v) end
    else return "null" end
end

function AE_Json.encode(value)
    return encodeValue(value)
end

-- =========================================================================
-- DECODE
-- =========================================================================

local function skipWs(s, i)
    while i <= #s do
        local c = s:sub(i,i)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then return i end
        i = i + 1
    end
    return i
end

local function parseString(s, i)
    assert(s:sub(i,i) == '"', "expected string at " .. i)
    i = i + 1
    local out = {}
    while i <= #s do
        local c = s:sub(i,i)
        if c == '"' then return table.concat(out), i + 1 end
        if c == '\\' then
            local n = s:sub(i+1, i+1)
            if n == 'n' then out[#out+1] = '\n'
            elseif n == 't' then out[#out+1] = '\t'
            elseif n == '"' then out[#out+1] = '"'
            elseif n == '\\' then out[#out+1] = '\\'
            else out[#out+1] = n end
            i = i + 2
        else
            out[#out+1] = c
            i = i + 1
        end
    end
    error("unterminated string")
end

local function parseLiteral(s, i)
    -- number, true, false, null
    local j = i
    while j <= #s do
        local c = s:sub(j,j)
        if c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t' then
            break
        end
        j = j + 1
    end
    local lit = s:sub(i, j-1)
    if lit == "true" then return true, j
    elseif lit == "false" then return false, j
    elseif lit == "null" then return nil, j
    else
        local n = tonumber(lit)
        return n, j
    end
end

local parseValue
local function parseArray(s, i)
    assert(s:sub(i,i) == '[', "expected [")
    i = skipWs(s, i + 1)
    local out = {}
    if s:sub(i,i) == ']' then return out, i + 1 end
    while i <= #s do
        local v
        v, i = parseValue(s, i)
        out[#out+1] = v
        i = skipWs(s, i)
        if s:sub(i,i) == ',' then i = skipWs(s, i + 1)
        elseif s:sub(i,i) == ']' then return out, i + 1
        else error("expected , or ] at " .. i) end
    end
    error("unterminated array")
end

local function parseObject(s, i)
    assert(s:sub(i,i) == '{', "expected {")
    i = skipWs(s, i + 1)
    local out = {}
    if s:sub(i,i) == '}' then return out, i + 1 end
    while i <= #s do
        i = skipWs(s, i)
        local key
        key, i = parseString(s, i)
        i = skipWs(s, i)
        assert(s:sub(i,i) == ':', "expected : at " .. i)
        i = skipWs(s, i + 1)
        local val
        val, i = parseValue(s, i)
        out[key] = val
        i = skipWs(s, i)
        if s:sub(i,i) == ',' then i = skipWs(s, i + 1)
        elseif s:sub(i,i) == '}' then return out, i + 1
        else error("expected , or } at " .. i) end
    end
    error("unterminated object")
end

parseValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i,i)
    if c == '"' then return parseString(s, i)
    elseif c == '{' then return parseObject(s, i)
    elseif c == '[' then return parseArray(s, i)
    else return parseLiteral(s, i) end
end

function AE_Json.decode(s)
    if type(s) ~= "string" then return nil, "expected string" end
    local ok, result = pcall(function()
        local v, _ = parseValue(s, 1)
        return v
    end)
    if ok then return result end
    return nil, tostring(result)
end

return AE_Json

--[[
    Area Export - Minimal JSON encoder/decoder.
    Client-side copy of the shared JSON helper for UI modules that load before or
    outside shared require paths in some PZ contexts.

    It is intentionally small and dependency-free. It supports the Area Export
    payloads we generate ourselves, not every edge case of the full JSON spec
    (for example unicode escape decoding is intentionally omitted).
]]

local AE_Json = {}

local function escapeString(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function isArray(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
        if k > n then n = k end
    end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local encodeValue

local function encodeArray(t, n)
    local out = {}
    for i = 1, n do out[#out + 1] = encodeValue(t[i]) end
    return "[" .. table.concat(out, ",") .. "]"
end

local function encodeObject(t)
    local keys, out = {}, {}
    for k, _ in pairs(t) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = escapeString(k) .. ":" .. encodeValue(t[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

encodeValue = function(v)
    local tv = type(v)
    if tv == "string" then return escapeString(v)
    elseif tv == "number" then return tostring(v)
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "table" then
        local arr, n = isArray(v)
        if arr then return encodeArray(v, n) else return encodeObject(v) end
    else
        return "null"
    end
end

function AE_Json.encode(value)
    return encodeValue(value)
end

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

--[[
    Area Export - File I/O
    Wrappers around getFileWriter/getFileReader. Files live under the Zomboid Lua/
    folder so they survive save reloads and are easy to copy between machines.

    Layout: <Zomboid>/Lua/AreaExport/<filename>.json

    Note: this is the older server-side file path. The public workflow now streams
    exports into client-local AreaExportClient/*.json from AE_MainDialog.lua, but
    these helpers are kept for compatibility with command/file based imports.
]]

local AE_Sa = require("AreaExport/AE_SafeAccess")

local AE_File = {}

local FOLDER = "AreaExport/"

local function safeName(name)
    if not name or name == "" then return "export" end
    -- Strip a trailing .json if present; users may type either base name or file.
    local base = name
    local lower = string.lower(name)
    if string.sub(lower, -5) == ".json" then
        base = string.sub(name, 1, #name - 5)
    end
    -- Strip path separators and shell-sensitive characters. The resulting name
    -- stays inside the AreaExport folder even if a modified client sends input.
    local clean = string.gsub(base, "[^%w_%-]", "_")
    return (clean ~= "" and clean) or "export"
end

local function pathFor(name)
    return FOLDER .. safeName(name) .. ".json"
end

---
-- Write a string to <Zomboid>/Lua/AreaExport/<name>.json
-- Returns true, path on success, false, error on failure.
---
function AE_File.write(name, content)
    local path = pathFor(name)
    local writer = AE_Sa.call("getFileWriter", nil, function()
        return getFileWriter(path, true, false)
    end)
    if not writer then return false, "could not open writer for " .. path end
    AE_Sa.call("write", nil, function() writer:write(content) end)
    AE_Sa.call("close", nil, function() writer:close() end)
    return true, path
end

---
-- Read a file under <Zomboid>/Lua/AreaExport/<name>.json
-- Returns content string on success, nil, error on failure.
---
function AE_File.read(name)
    local path = pathFor(name)
    local reader = AE_Sa.call("getFileReader", nil, function()
        return getFileReader(path, false)
    end)
    if not reader then return nil, "could not open reader for " .. path end
    local lines = {}
    while true do
        local line = AE_Sa.call("readLine", nil, function() return reader:readLine() end)
        if not line then break end
        lines[#lines + 1] = line
    end
    AE_Sa.call("close", nil, function() reader:close() end)
    return table.concat(lines, "\n")
end

---
-- List all available export files (returns sorted array of base names without .json)
---
function AE_File.list()
    -- PZ Lua directory listing is limited and not consistent across contexts.
    -- The modern Import UI uses its own client-local index instead, so this
    -- compatibility hook intentionally returns an empty list.
    return {}
end

function AE_File.path(name)
    return pathFor(name)
end

return AE_File

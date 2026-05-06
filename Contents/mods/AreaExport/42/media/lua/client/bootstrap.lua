--[[
    Area Export - client bootstrap
    Loads the Lua UI modules used by the Build 42 release.
]]

local function safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("[AreaExport] Lua bootstrap error: " .. tostring(err))
    end
end

local function loadClientModules()
    require "AreaExport/AE_Globals"
    require "AreaExport/AE_TilePicker"
    require "AreaExport/AE_MainDialog"
    require "AreaExport/AE_AdminButton"
    require "AreaExport/AE_ServerResponse"
end

safeCall(loadClientModules)

print("[AreaExport] bootstrap.lua loaded")
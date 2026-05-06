--[[
    Area Export - Shared Constants
    Common configuration and constants used across client and server.

    Avoid putting per-save or per-user paths here. Public releases must stay
    portable; server/client storage decisions live in AE_File.lua and
    AE_MainDialog.lua.
]]

local AE_Constants = {}

-- Module identifiers
AE_Constants.MOD_ID = "AreaExport"
AE_Constants.MODULE = "AreaExport"

-- UI / interaction defaults. MIN_RADIUS guards invalid input only; large radii
-- are intentionally allowed because admins may accept long-running exports.
AE_Constants.DEFAULT_RADIUS = 10
AE_Constants.MIN_RADIUS = 1

-- Legacy server-file defaults. Client-local copy storage is defined in
-- AE_MainDialog.lua because it belongs to the admin UI workflow.
AE_Constants.DEFAULT_FILENAME = "area_export"
AE_Constants.EXPORT_DIR = ".Zomboid/saves/area_exports/"

return AE_Constants

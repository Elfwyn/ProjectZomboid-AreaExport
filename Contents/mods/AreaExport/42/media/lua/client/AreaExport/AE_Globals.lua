--[[
    Area Export - Global State
    Shared state and UI references used across the mod.

    Keep this module small. It is only for state that must be shared between the
    picker, dialog and response handler; durable export history lives in the
    client-local JSON index managed by AE_MainDialog.lua.
]]

local AE_Globals = {}

-- UI window instance.
AE_Globals.mainDialog = nil

-- Picked export center in absolute world coordinates.
AE_Globals.pickedCenter = nil  -- {x=..., y=...}

-- Current radius setting. previewRadius is separate so typing in the radius entry
-- does not redraw markers until Preview is clicked.
AE_Globals.radius = 10
AE_Globals.previewRadius = nil

-- Tile picker state.
AE_Globals.pickMode = false

-- Last scan result shown by the Export tab.
AE_Globals.lastScanResult = nil

-- Legacy file state; the modern workflow uses AE_MainDialog.localExports.
AE_Globals.exportFiles = {}

return AE_Globals

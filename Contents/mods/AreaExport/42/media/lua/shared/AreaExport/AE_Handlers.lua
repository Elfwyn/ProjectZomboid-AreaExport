--[[
    Area Export - Handlers
    Maps detected PZ object classes to the attribute definitions that can be exported and restored.

    Unknown classes fall back to default (sprite + name only). That is deliberate:
    the importer can still restore static visuals while validation flags classes
    without a safe constructor as conflicts for admin review.
]]

local AE_AttrMap = require("AreaExport/AE_AttrMap")
local AE_Sa     = require("AreaExport/AE_SafeAccess")

local AE_Handlers = {}

-- Concatenate attribute lists from multiple groups.
local function combine(...)
    local out = {}
    for _, group in ipairs({...}) do
        for _, attr in pairs(group) do
            table.insert(out, attr)
        end
    end
    return out
end

local SPECIAL_SPRITE_ISO_TYPES = {
    IsoBarbecue = true,
    IsoCombinationWasherDryer = true,
    IsoClothingDryer = true,
    IsoClothingWasher = true,
    IsoCompost = true,
    IsoFireplace = true,
    IsoJukebox = true,
    IsoRadio = true,
    IsoStove = true,
    IsoTelevision = true,
    IsoWaveSignal = true,
}

AE_Handlers.byClass = {
    IsoObject       = combine(AE_AttrMap.object_common),
    IsoThumpable    = combine(AE_AttrMap.object_common, AE_AttrMap.thumpable),
    -- Do not mix thumpable attrs into real IsoDoor. B42 sends different network
    -- packets for doors and thumpables; treating a door like a thumpable produced
    -- client-side ClassCastException in SyncThumpablePacket during live imports.
    IsoDoor         = combine(AE_AttrMap.object_common, AE_AttrMap.door),
    IsoWindow       = combine(AE_AttrMap.object_common, AE_AttrMap.window),
    IsoCurtain      = combine(AE_AttrMap.object_common, AE_AttrMap.door),
    IsoLightSwitch  = combine(AE_AttrMap.object_common, AE_AttrMap.lightSwitch),
    IsoBarbecue     = combine(AE_AttrMap.object_common),
    IsoStove        = combine(AE_AttrMap.object_common),
    IsoFireplace    = combine(AE_AttrMap.object_common),
    IsoJukebox      = combine(AE_AttrMap.object_common),
    IsoCompost      = combine(AE_AttrMap.object_common),
    IsoTelevision   = combine(AE_AttrMap.object_common),
    IsoRadio        = combine(AE_AttrMap.object_common),
    IsoWaveSignal   = combine(AE_AttrMap.object_common),
    IsoClothingWasher = combine(AE_AttrMap.object_common),
    IsoClothingDryer = combine(AE_AttrMap.object_common),
    IsoCombinationWasherDryer = combine(AE_AttrMap.object_common),
}

-- Default fallback for unknown subclasses.
AE_Handlers.default = combine(AE_AttrMap.object_common)

---
-- Structural class detection: probe the object for characteristic methods
-- to decide which bucket it falls into. Kahlua-proof (no reflection APIs).
-- Returns the most specific match first.
--
-- The code avoids hard dependence on Java class reflection because PZ/Kahlua can
-- expose different reflection details between client, host and dedicated server.
-- Method probes plus toString() are less elegant but survived the B42 MP tests.
---
local function detectClass(obj)
    local direct = AE_Sa.call("probeSpecialInstance", nil, function(o)
        if not instanceof then return nil end
        local candidates = {
            "IsoBarbecue",
            "IsoCombinationWasherDryer",
            "IsoClothingDryer",
            "IsoClothingWasher",
            "IsoCompost",
            "IsoFireplace",
            "IsoJukebox",
            "IsoTelevision",
            "IsoRadio",
            "IsoWaveSignal",
            "IsoStove",
        }
        for _, name in ipairs(candidates) do
            if instanceof(o, name) then return name end
        end
        return nil
    end, obj)
    if direct then return direct end

    -- IsoDoor: has IsOpen() and isDoor().
    if AE_Sa.call("probeDoor", false, function(o)
        return o.isDoor and o:isDoor() or false
    end, obj) then return "IsoDoor" end

    -- IsoWindow: has isWindow().
    if AE_Sa.call("probeWindow", false, function(o)
        return o.isWindow and o:isWindow() or false
    end, obj) then return "IsoWindow" end

    -- IsoThumpable: player-built objects usually report isPlayerBuild().
    if AE_Sa.call("probeThumpPB", false, function(o)
        return (o.isPlayerBuild and o:isPlayerBuild()) or false
    end, obj) then return "IsoThumpable" end

    local spriteIsoType = AE_Sa.call("probeSpriteIsoType", nil, function(o)
        local sprite = o.getSprite and o:getSprite() or nil
        local props = sprite and sprite:getProperties() or nil
        if props and props:has("IsoType") then return props:get("IsoType") end
        return nil
    end, obj)
    if spriteIsoType and SPECIAL_SPRITE_ISO_TYPES[spriteIsoType] then return spriteIsoType end

    -- Heuristic via Java's toString() which usually contains the class name
    local ts = AE_Sa.call("probeToString", nil, function(o)
        return o:toString()
    end, obj)
    if ts and type(ts) == "string" then
        -- Examples: "zombie.iso.objects.IsoDoor@12abc", "IsoThumpable[...]"
        local candidates = { "IsoBarbecue", "IsoCombinationWasherDryer", "IsoClothingDryer",
                             "IsoClothingWasher", "IsoCompost", "IsoFireplace", "IsoJukebox",
                             "IsoTelevision", "IsoRadio", "IsoWaveSignal", "IsoStove",
                             "IsoDoor", "IsoWindow", "IsoCurtain", "IsoThumpable",
                             "IsoWorldInventoryObject", "IsoFire", "IsoLightSwitch",
                             "IsoGenerator", "IsoMannequin", "IsoObject" }
        for _, name in ipairs(candidates) do
            if string.find(ts, name, 1, true) then return name end
        end
    end

    return "IsoObject"
end

function AE_Handlers.forObject(obj)
    local cls = detectClass(obj)
    local handler = AE_Handlers.byClass[cls] or AE_Handlers.default
    return handler, cls
end

return AE_Handlers

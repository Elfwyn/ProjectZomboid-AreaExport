--[[
    Area Export - AttrMap
    Central registry for every serializable attribute.
    If a PZ method name changes, update the mapping here instead of touching import/export code.

    Entry schema:
      name      = save-key (string used in JSON)
      read      = function(obj) -> value (any)
      write     = function(obj, value)        -- nil = read-only
      default   = value to use if read fails  -- nil OK
      kind      = "string" | "number" | "bool" | "table" -- informational, used for validation
      optional  = true = skip if read returns nil; false = always serialize

    Keep this map intentionally small. Every additional write target must be safe
    on a dedicated server and should be tested after reconnect, because some PZ
    setters update visuals locally but do not persist or synchronize cleanly.
]]

local AE_AttrMap = {}

local function spriteName(value)
    if not value then return nil end
    if type(value) == "string" then return value end
    if value.getName then return value:getName() end
    return nil
end

local function readFirstSpriteName(obj, methods)
    if not obj then return nil end
    for _, methodName in ipairs(methods) do
        local fn = obj[methodName]
        if fn then
            local ok, value = pcall(function() return fn(obj) end)
            if ok then
                local name = spriteName(value)
                if name and name ~= "" then return name end
            end
        end
    end
    return nil
end

local function currentSpriteName(obj)
    local sprite = obj and obj.getSprite and obj:getSprite() or nil
    return spriteName(sprite)
end

local function spriteProperties(spriteNameValue)
    if not spriteNameValue or not getSprite then return nil end
    local sprite = getSprite(spriteNameValue)
    return sprite and sprite:getProperties() or nil
end

local function propHas(props, key)
    if not props or not key then return false end
    local ok, value = pcall(function() return props:has(key) end)
    return ok and value == true
end

local function parseSpriteIndex(spriteNameValue)
    if type(spriteNameValue) ~= "string" then return nil, nil end
    local prefix, index = string.match(spriteNameValue, "^(.*_)(%d+)$")
    if not prefix then return nil, nil end
    return prefix, tonumber(index)
end

local function spriteExists(spriteNameValue)
    return spriteNameValue and getSprite and getSprite(spriteNameValue) ~= nil
end

local function inferDoorSprites(spriteNameValue)
    local prefix, index = parseSpriteIndex(spriteNameValue)
    if not prefix or not index then return nil end
    if string.find(prefix, "fixtures_doors_frames", 1, true) then return nil end

    local props = spriteProperties(spriteNameValue)
    local closedW = propHas(props, "doorW") or propHas(props, IsoFlagType and IsoFlagType.doorW)
    local closedN = propHas(props, "doorN") or propHas(props, IsoFlagType and IsoFlagType.doorN)
    local attachedW = propHas(props, "attachedW")
    local attachedN = propHas(props, "attachedN")

    if closedW or closedN then
        local openSprite = prefix .. tostring(index + 2)
        if spriteExists(openSprite) then
            return { closed = spriteNameValue, open = openSprite, north = closedN, isOpen = false }
        end
        return nil
    end

    local looksLikeDoorTile = string.find(prefix, "fixtures_doors_", 1, true) ~= nil
    if looksLikeDoorTile and index >= 2 and (attachedW or attachedN) then
        local closedSprite = prefix .. tostring(index - 2)
        if spriteExists(closedSprite) then
            return { closed = closedSprite, open = spriteNameValue, north = attachedN, isOpen = true }
        end
    end
    return nil
end

local function readOpenState(obj)
    if not obj then return nil end
    if obj.IsOpen then return obj:IsOpen() end
    if obj.isOpen then return obj:isOpen() end
    local pair = inferDoorSprites(currentSpriteName(obj))
    return pair and pair.isOpen or nil
end

local function readLockedState(obj)
    if not obj then return nil end
    if obj.isLocked then return obj:isLocked() end
    if obj.IsLocked then return obj:IsLocked() end
    return nil
end

local function writeOpenState(obj, value)
    if value == nil or not obj then return end
    local targetOpen = value == true
    local currentOpen = readOpenState(obj)
    if currentOpen == targetOpen then return end
    -- Different interactive objects expose different state transitions. Use the
    -- native silent path where available, then fall back to the object's normal
    -- toggle/setter. Import runs server-side, so player arguments can be nil.
    if obj.ToggleDoorSilent then
        obj:ToggleDoorSilent()
    elseif obj.ToggleWindow then
        local actor = (_G and _G.AE_ImportActor) or (getPlayer and getPlayer() or nil)
        obj:ToggleWindow(actor)
    elseif obj.setOpen then
        obj:setOpen(targetOpen)
    elseif obj.setActive then
        obj:setActive(targetOpen)
    end
end

local function writeLockedState(obj, value)
    if value == nil or not obj then return end
    if obj.setLocked then
        obj:setLocked(value == true)
    elseif obj.setIsLocked then
        obj:setIsLocked(value == true)
    end
end

local function copySimpleTable(src)
    -- Persist only primitive modData. Complex Java/Kahlua objects cannot be
    -- serialized safely to JSON and are not portable across mod sets.
    if type(src) ~= "table" then return nil end
    local out = {}
    local count = 0
    for k, v in pairs(src) do
        local kt = type(k)
        local vt = type(v)
        if (kt == "string" or kt == "number" or kt == "boolean") and
           (vt == "string" or vt == "number" or vt == "boolean") then
            out[k] = v
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return out
end

local function applySimpleTable(dst, data)
    if type(data) ~= "table" then return end
    local md = dst and dst.getModData and dst:getModData() or nil
    if not md then return end
    for k, v in pairs(data) do
        local vt = type(v)
        if vt == "string" or vt == "number" or vt == "boolean" then
            md[k] = v
        end
    end
end

-- =========================================================================
-- TILE / SQUARE attributes
-- =========================================================================
AE_AttrMap.tile = {
    floor_sprite = {
        name = "floor_sprite", kind = "string", optional = true,
        read = function(sq)
            local f = sq:getFloor()
            if not f then return nil end
            local s = f:getSprite()
            return s and s:getName() or nil
        end,
        write = nil,  -- handled by tile builder via createNewGridSquare + sprite
        default = nil,
    },
}

-- =========================================================================
-- OBJECT attributes - Common to all IsoObject subclasses
-- =========================================================================
AE_AttrMap.object_common = {
    sprite = {
        name = "sprite", kind = "string", optional = false,
        read = function(o)
            local s = o:getSprite()
            return s and s:getName() or nil
        end,
        -- write done at construction (sprite passed to factory), no setter needed
        default = nil,
    },
    name = {
        name = "name", kind = "string", optional = true,
        read = function(o) return o:getName() end,
        write = function(o, v) if o.setName then o:setName(v) end end,
    },
    isPlayerBuild = {
        name = "isPlayerBuild", kind = "bool", optional = true,
        read = function(o) return o.isPlayerBuild and o:isPlayerBuild() or false end,
        write = nil,  -- this is implicit in IsoThumpable construction
    },
    north = {
        name = "north", kind = "bool", optional = true,
        read = function(o) return o.getNorth and o:getNorth() or nil end,
        write = nil,
    },
}

-- =========================================================================
-- IsoThumpable (player-built walls/doors/furniture) specific
-- =========================================================================
AE_AttrMap.thumpable = {
    health = {
        name = "health", kind = "number", optional = true,
        read = function(o) return o:getHealth() end,
        write = function(o, v) if o.setHealth then o:setHealth(v) end end,
        default = 0,
    },
    maxHealth = {
        name = "maxHealth", kind = "number", optional = true,
        read = function(o) return o:getMaxHealth() end,
        write = function(o, v) if o.setMaxHealth then o:setMaxHealth(v) end end,
        default = 0,
    },
    isDoor = {
        name = "isDoor", kind = "bool", optional = true,
        read = function(o)
            if o.isDoor and o:isDoor() then return true end
            return inferDoorSprites(currentSpriteName(o)) ~= nil
        end,
        write = nil,
    },
    isWindow = {
        name = "isWindow", kind = "bool", optional = true,
        read = function(o) return o.isWindow and o:isWindow() or false end,
        write = nil,
    },
    closedSprite = {
        name = "closedSprite", kind = "string", optional = true,
        read = function(o)
            local pair = inferDoorSprites(currentSpriteName(o))
            return pair and pair.closed or nil
        end,
        write = nil,
    },
    openSprite = {
        name = "openSprite", kind = "string", optional = true,
        read = function(o)
            local pair = inferDoorSprites(currentSpriteName(o))
            return pair and pair.open or nil
        end,
        write = nil,
    },
    isOpen = {
        name = "isOpen", kind = "bool", optional = true,
        read = readOpenState,
        write = nil,
    },
    isLocked = {
        name = "isLocked", kind = "bool", optional = true,
        read = readLockedState,
        write = writeLockedState,
    },
}

-- =========================================================================
-- IsoDoor / IsoWindow - open/closed/locked state
-- =========================================================================
AE_AttrMap.door = {
    closedSprite = {
        name = "closedSprite", kind = "string", optional = true,
        read = function(o)
            local pair = inferDoorSprites(currentSpriteName(o))
            local value = readFirstSpriteName(o, {
                "getClosedSprite",
                "getClosedSpriteName",
                "getSpriteClosed",
                "getSpriteNameClosed",
            })
            if value and not (pair and pair.isOpen == true and value == currentSpriteName(o)) then return value end
            return pair and pair.closed or nil
        end,
        write = nil,
    },
    openSprite = {
        name = "openSprite", kind = "string", optional = true,
        read = function(o)
            local pair = inferDoorSprites(currentSpriteName(o))
            local value = readFirstSpriteName(o, {
                "getOpenSprite",
                "getOpenSpriteName",
                "getSpriteOpen",
                "getSpriteNameOpen",
            })
            if value and not (pair and pair.isOpen == false and value == currentSpriteName(o)) then return value end
            return pair and pair.open or nil
        end,
        write = nil,
    },
    isOpen = {
        name = "isOpen", kind = "bool", optional = true,
        read = readOpenState,
        write = writeOpenState,
    },
    isLocked = {
        name = "isLocked", kind = "bool", optional = true,
        read = readLockedState,
        write = writeLockedState,
    },
    lockedKeyId = {
        name = "lockedKeyId", kind = "number", optional = true,
        read = function(o) return o.getKeyId and o:getKeyId() end,
        write = function(o, v) if o.setKeyId then o:setKeyId(v) end end,
    },
}

-- =========================================================================
-- IsoWindow - native window state
-- =========================================================================
AE_AttrMap.window = {
    openSprite = {
        name = "openSprite", kind = "string", optional = true,
        read = function(o)
            local value = readFirstSpriteName(o, { "getOpenSprite", "getOpenSpriteName" })
            return value
        end,
        write = function(o, v)
            if o.setOpenSprite and getSprite and v then
                local sprite = getSprite(v)
                if sprite then o:setOpenSprite(sprite) end
            end
        end,
    },
    smashedSprite = {
        name = "smashedSprite", kind = "string", optional = true,
        read = function(o)
            local value = readFirstSpriteName(o, { "getSmashedSprite", "getSmashedSpriteName" })
            return value
        end,
        write = function(o, v)
            if o.setSmashedSprite and getSprite and v then
                local sprite = getSprite(v)
                if sprite then o:setSmashedSprite(sprite) end
            end
        end,
    },
    isOpen = {
        name = "isOpen", kind = "bool", optional = true,
        read = readOpenState,
        write = writeOpenState,
    },
    isLocked = {
        name = "isLocked", kind = "bool", optional = true,
        read = readLockedState,
        write = writeLockedState,
    },
    isSmashed = {
        name = "isSmashed", kind = "bool", optional = true,
        read = function(o) return o.isSmashed and o:isSmashed() or nil end,
        write = function(o, v) if o.setSmashed then o:setSmashed(v == true) end end,
    },
    isGlassRemoved = {
        name = "isGlassRemoved", kind = "bool", optional = true,
        read = function(o) return o.isGlassRemoved and o:isGlassRemoved() or nil end,
        write = function(o, v) if o.setGlassRemoved then o:setGlassRemoved(v == true) end end,
    },
    isPermaLocked = {
        name = "isPermaLocked", kind = "bool", optional = true,
        read = function(o) return o.isPermaLocked and o:isPermaLocked() or nil end,
        write = function(o, v) if o.setPermaLocked then o:setPermaLocked(v == true) end end,
    },
}

-- =========================================================================
-- IsoLightSwitch - native light switch state
-- =========================================================================
AE_AttrMap.lightSwitch = {
    isActivated = {
        name = "isActivated", kind = "bool", optional = true,
        read = function(o) return o.isActivated and o:isActivated() or nil end,
        write = function(o, v)
            if v == nil then return end
            if o.setActivated then o:setActivated(v == true) end
            if o.setActive then o:setActive(v == true) end
        end,
    },
    canBeModified = {
        name = "canBeModified", kind = "bool", optional = true,
        read = function(o) return o.getCanBeModified and o:getCanBeModified() or nil end,
        write = function(o, v) if o.setCanBeModified then o:setCanBeModified(v == true) end end,
    },
    power = {
        name = "power", kind = "number", optional = true,
        read = function(o) return o.getPower and o:getPower() or nil end,
        write = function(o, v) if o.setPower then o:setPower(tonumber(v) or 0) end end,
    },
    delta = {
        name = "delta", kind = "number", optional = true,
        read = function(o) return o.getDelta and o:getDelta() or nil end,
        write = function(o, v) if o.setDelta then o:setDelta(tonumber(v) or 0) end end,
    },
    useBattery = {
        name = "useBattery", kind = "bool", optional = true,
        read = function(o) return o.getUseBattery and o:getUseBattery() or nil end,
        write = function(o, v)
            if o.setUseBatteryDirect then o:setUseBatteryDirect(v == true)
            elseif o.setUseBattery then o:setUseBattery(v == true) end
        end,
    },
    hasBattery = {
        name = "hasBattery", kind = "bool", optional = true,
        read = function(o) return o.getHasBattery and o:getHasBattery() or nil end,
        write = function(o, v)
            if o.setHasBatteryRaw then o:setHasBatteryRaw(v == true)
            elseif o.setHasBattery then o:setHasBattery(v == true) end
        end,
    },
    hasLightBulb = {
        name = "hasLightBulb", kind = "bool", optional = true,
        read = function(o) return o.hasLightBulb and o:hasLightBulb() or nil end,
        write = nil,
    },
    bulbItem = {
        name = "bulbItem", kind = "string", optional = true,
        read = function(o) return o.getBulbItem and o:getBulbItem() or nil end,
        write = function(o, v) if o.setBulbItemRaw and v then o:setBulbItemRaw(v) end end,
    },
    primaryR = {
        name = "primaryR", kind = "number", optional = true,
        read = function(o) return o.getPrimaryR and o:getPrimaryR() or nil end,
        write = function(o, v) if o.setPrimaryR then o:setPrimaryR(tonumber(v) or 0) end end,
    },
    primaryG = {
        name = "primaryG", kind = "number", optional = true,
        read = function(o) return o.getPrimaryG and o:getPrimaryG() or nil end,
        write = function(o, v) if o.setPrimaryG then o:setPrimaryG(tonumber(v) or 0) end end,
    },
    primaryB = {
        name = "primaryB", kind = "number", optional = true,
        read = function(o) return o.getPrimaryB and o:getPrimaryB() or nil end,
        write = function(o, v) if o.setPrimaryB then o:setPrimaryB(tonumber(v) or 0) end end,
    },
}

-- =========================================================================
-- ITEMS in containers - per-item attributes
-- =========================================================================
AE_AttrMap.item = {
    type = {
        name = "type", kind = "string", optional = false,
        read = function(it) return it:getFullType() end,  -- "Base.Hammer"
        -- write done at factory creation
    },
    condition = {
        name = "condition", kind = "number", optional = true,
        read = function(it) return it:getCondition() end,
        write = function(it, v) if it.setCondition then it:setCondition(v) end end,
    },
    count = {
        name = "count", kind = "number", optional = true,
        read = function(it)
            -- For stackable items (drainables, foods with uses, etc)
            if it.getDrainableUsesInt then
                local n = it:getDrainableUsesInt()
                if n and n > 0 then return n end
            end
            return nil
        end,
        write = function(it, v)
            if v and it.setUsedDelta then
                -- Restore drainable usage approximation
                pcall(function() it:setUsedDelta(v / (it:getUseDelta() or 1)) end)
            end
        end,
    },
    age = {
        name = "age", kind = "number", optional = true,
        read = function(it) return it.getAge and it:getAge() or nil end,
        write = function(it, v) if it.setAge then it:setAge(v) end end,
    },
    name = {
        name = "name", kind = "string", optional = true,
        read = function(it) return it.getName and it:getName() or nil end,
        write = function(it, v) if it.setName then it:setName(v) end end,
    },
    recordedMediaIndex = {
        name = "recordedMediaIndex", kind = "number", optional = true,
        read = function(it)
            if it.getRecordedMediaIndexInteger then
                local idx = it:getRecordedMediaIndexInteger()
                if idx and idx >= 0 then return idx end
            end
            return nil
        end,
        write = function(it, v)
            if it.setRecordedMediaIndexInteger then it:setRecordedMediaIndexInteger(v) end
        end,
    },
    modData = {
        name = "modData", kind = "table", optional = true,
        read = function(it)
            return copySimpleTable(it.getModData and it:getModData() or nil)
        end,
        write = function(it, v) applySimpleTable(it, v) end,
    },
}

-- =========================================================================
-- CONTAINER attributes
-- =========================================================================
AE_AttrMap.container = {
    capacity = {
        name = "capacity", kind = "number", optional = true,
        read = function(c) return c:getCapacity() end,
        write = function(c, v) if c.setCapacity then c:setCapacity(v) end end,
    },
    type = {
        name = "type", kind = "string", optional = true,
        read = function(c) return c:getType() end,
    },
}

return AE_AttrMap

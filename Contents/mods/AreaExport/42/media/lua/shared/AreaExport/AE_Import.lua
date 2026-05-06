--[[
    Area Export - Import
    Reads an exported JSON payload and reconstructs tiles, objects, containers,
    container items and loose world items.

    Important project decisions:
    - Import is original-coordinate only. Early versions allowed offset import,
      but that is unsafe for real save restoration because map holes, stairs,
      plumbing, generators and pre-existing map structures are tied to absolute
      world coordinates.
    - The exported radius is the authoritative footprint. Before rebuilding, the
      same circular footprint is cleared at the saved center so removed walls and
      floor openings can be restored instead of being merged with the new save.
    - Loose world items are deliberately conservative. PZ B42 multiplayer can
      leave client-side pickup ghosts if world items are mutated or overwritten
      after creation. See buildWorldItem(), clearSquareState() and the reconcile
      monitor in AE_MainDialog.lua for the client/server cleanup strategy.
    - Linked door groups are cleared as one vanilla object group. Removing only
      the square currently being visited can leave orphaned double-door or
      garage-door pieces at footprint edges.
]]

local AE_Sa       = require("AreaExport/AE_SafeAccess")
local AE_AttrMap  = require("AreaExport/AE_AttrMap")
local AE_Handlers = require("AreaExport/AE_Handlers")
local AE_Json     = require("AreaExport/AE_Json")
local AE_File     = require("AreaExport/AE_File")

local AE_Import = {}
local importStats = {}
local activeRules = {}
local activeActor = nil
-- Used only when validation rules ask to preserve that an item existed but its
-- original type is unavailable in the target mod set.
local PLACEHOLDER_ITEM = "Base.SheetPaper2"

local function resetImportStats()
    importStats = {
        containersSeen = 0,
        containersMissing = 0,
        containersCleared = 0,
        itemsExpected = 0,
        itemsAdded = 0,
        itemsFailed = 0,
        itemsSkipped = 0,
        itemsReplaced = 0,
        itemsPlaceholder = 0,
        containerItemBatches = 0,
        containerItemsQueued = 0,
        containerItemsVerified = 0,
        doorFallbacks = 0,
        specialSeen = 0,
        specialBuilt = 0,
        specialFailed = 0,
        itemFailureLogs = 0,
    }
end

local function ruleKey(kind, id)
    return tostring(kind or "Item") .. ":" .. tostring(id or "")
end

local function normalizeRules(rules)
    -- UI rules are stored per conflict group, e.g. "Item:OldMod.Book". One rule
    -- intentionally applies to every matching item because exports can contain
    -- thousands of instances and per-item decisions would be unusable.
    local map = {}
    if type(rules) ~= "table" then return map end
    for _, rule in ipairs(rules) do
        if type(rule) == "table" and rule.kind and rule.id and rule.action then
            map[ruleKey(rule.kind, rule.id)] = rule
        end
    end
    return map
end

local function cloneItemData(itemData)
    local copy = {}
    if type(itemData) ~= "table" then return copy end
    for k, v in pairs(itemData) do copy[k] = v end
    return copy
end

local function itemExists(fullType)
    if not fullType or fullType == "" then return false end
    return (AE_Sa.call("findItem.getScriptManager", nil, function()
        local sm = getScriptManager and getScriptManager() or nil
        if sm and sm.FindItem then return sm:FindItem(fullType) end
        return nil
    end) or AE_Sa.call("findItem.ScriptManager", nil, function()
        if ScriptManager and ScriptManager.instance and ScriptManager.instance.FindItem then
            return ScriptManager.instance:FindItem(fullType)
        end
        return nil
    end) or AE_Sa.call("findItem.global", nil, function()
        if getItem then return getItem(fullType) end
        return nil
    end)) ~= nil
end

local function applyItemRule(itemData)
    if not itemData or not itemData.type then return itemData, nil end
    local rule = activeRules[ruleKey("Item", itemData.type)]
    if not rule then return itemData, nil end

    if rule.action == "Skip" then
        -- Skipped items still count as expected so import summaries explain why
        -- added/expected differs instead of looking like silent data loss.
        importStats.itemsExpected = importStats.itemsExpected + 1
        importStats.itemsSkipped = importStats.itemsSkipped + 1
        return nil, "skipped"
    end

    if rule.action == "Replace" and rule.replacement and itemExists(rule.replacement) then
        -- Replacement only happens if the selected target type exists now. If a
        -- stale rule points to a missing type, the normal creation path records a
        -- failure instead of creating junk data.
        local copy = cloneItemData(itemData)
        copy.type = rule.replacement
        importStats.itemsReplaced = importStats.itemsReplaced + 1
        return copy, "replaced"
    end

    if rule.action == "Placeholder" then
        -- The placeholder keeps the original missing type in modData so a future
        -- migration tool or maintainer can identify what was lost.
        local copy = {
            type = itemExists(PLACEHOLDER_ITEM) and PLACEHOLDER_ITEM or "Base.Notebook",
            name = "Missing item: " .. tostring(itemData.type),
            modData = {
                AreaExportPlaceholder = true,
                AreaExportOriginalType = tostring(itemData.type),
            },
        }
        importStats.itemsPlaceholder = importStats.itemsPlaceholder + 1
        return copy, "placeholder"
    end

    return itemData, nil
end

local function spriteExists(spriteName)
    if not spriteName or spriteName == "" then return false end
    return AE_Sa.call("getSprite", nil, function()
        return getSprite and getSprite(spriteName) or nil
    end) ~= nil
end

local function isWorldInventoryObject(obj)
    if not obj then return false end
    return AE_Sa.call("object.isWorldInventory", false, function()
        if instanceof and instanceof(obj, "IsoWorldInventoryObject") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoWorldInventoryObject", 1, true) ~= nil
    end)
end

local function isThumpableObject(obj)
    if not obj then return false end
    return AE_Sa.call("object.isThumpable", false, function()
        if instanceof and instanceof(obj, "IsoThumpable") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoThumpable", 1, true) ~= nil
    end)
end

local function isDoorObject(obj)
    if not obj then return false end
    return AE_Sa.call("object.isDoorObject", false, function()
        if instanceof and instanceof(obj, "IsoDoor") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoDoor", 1, true) ~= nil
    end)
end

local function isLightSwitchObject(obj)
    if not obj then return false end
    return AE_Sa.call("object.isLightSwitchObject", false, function()
        if instanceof and instanceof(obj, "IsoLightSwitch") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoLightSwitch", 1, true) ~= nil
    end)
end

local function hasWorldItems(sq)
    if not sq then return false end
    local objects = AE_Sa.call("sq.objectsForWorldItemCheck", nil, function()
        return sq:getObjects()
    end)
    if objects then
        local n = AE_Sa.call("sq.objectsForWorldItemCheck.size", 0, function() return objects:size() end)
        for i = 0, n - 1 do
            local obj = AE_Sa.call("sq.objectsForWorldItemCheck.get", nil, function() return objects:get(i) end)
            if isWorldInventoryObject(obj) then return true end
        end
    end

    local worldObjects = AE_Sa.call("sq.worldObjectsForCheck", nil, function()
        return sq.getWorldObjects and sq:getWorldObjects()
    end)
    if worldObjects then
        local n = AE_Sa.call("sq.worldObjectsForCheck.size", 0, function() return worldObjects:size() end)
        return n > 0
    end
    return false
end

local function countWorldItems(sq)
    if not sq then return 0 end
    local count = 0
    local objects = AE_Sa.call("sq.objectsForWorldItemCount", nil, function()
        return sq:getObjects()
    end)
    if objects then
        local n = AE_Sa.call("sq.objectsForWorldItemCount.size", 0, function() return objects:size() end)
        for i = 0, n - 1 do
            local obj = AE_Sa.call("sq.objectsForWorldItemCount.get", nil, function() return objects:get(i) end)
            if isWorldInventoryObject(obj) then count = count + 1 end
        end
    end

    local worldObjects = AE_Sa.call("sq.worldObjectsForCount", nil, function()
        return sq.getWorldObjects and sq:getWorldObjects()
    end)
    if worldObjects then
        local n = AE_Sa.call("sq.worldObjectsForCount.size", 0, function() return worldObjects:size() end)
        if n > count then count = n end
    end
    return count
end

local function cloneObjectData(objData)
    local copy = {}
    if type(objData) ~= "table" then return copy end
    for k, v in pairs(objData) do copy[k] = v end
    return copy
end

local function spriteProperties(spriteName)
    if not spriteName or not getSprite then return nil end
    return AE_Sa.call("sprite.properties", nil, function()
        local sprite = getSprite(spriteName)
        return sprite and sprite:getProperties() or nil
    end)
end

local function spriteHasFlag(props, flag)
    if not props or not flag then return false end
    return AE_Sa.call("sprite.hasFlag", false, function()
        return props:has(flag)
    end)
end

local function propHas(props, key)
    if not props or not key then return false end
    return AE_Sa.call("sprite.hasProp", false, function()
        return props:has(key)
    end)
end

local function propValue(props, key)
    if not props or not key then return nil end
    return AE_Sa.call("sprite.propValue", nil, function()
        if props:has(key) then return props:get(key) end
        return nil
    end)
end

local function currentSpriteName(obj)
    return AE_Sa.call("object.currentSpriteName", nil, function()
        local sprite = obj and obj.getSprite and obj:getSprite() or nil
        return sprite and sprite:getName() or nil
    end)
end

local function parseSpriteIndex(spriteName)
    if type(spriteName) ~= "string" then return nil, nil end
    local prefix, index = string.match(spriteName, "^(.*_)(%d+)$")
    if not prefix then return nil, nil end
    return prefix, tonumber(index)
end

local SPECIAL_OBJECT_CLASSES = {
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

local function runtimeClassLabel(obj)
    if not obj then return "nil" end
    local direct = AE_Sa.call("object.runtimeClass", nil, function()
        if not instanceof then return nil end
        local candidates = {
            "IsoTelevision",
            "IsoRadio",
            "IsoWaveSignal",
            "IsoStove",
            "IsoCombinationWasherDryer",
            "IsoClothingWasher",
            "IsoClothingDryer",
            "IsoBarbecue",
            "IsoFireplace",
            "IsoJukebox",
            "IsoCompost",
            "IsoDoor",
            "IsoLightSwitch",
            "IsoWindow",
            "IsoThumpable",
            "IsoObject",
        }
        for _, name in ipairs(candidates) do
            if instanceof(obj, name) then return name end
        end
        return nil
    end)
    if direct then return direct end
    return tostring(obj)
end

local function inferSpecialObjectClass(objData)
    if not objData then return nil end
    local className = objData.class
    if SPECIAL_OBJECT_CLASSES[className] then
        if className == "IsoWaveSignal" then
            local props = spriteProperties(objData.sprite)
            local isoType = propValue(props, "IsoType")
            if isoType == "IsoTelevision" or isoType == "IsoRadio" then return isoType end
        end
        return className
    end

    local props = spriteProperties(objData.sprite)
    local isoType = propValue(props, "IsoType")
    if SPECIAL_OBJECT_CLASSES[isoType] then return isoType end

    local containerType = objData.container and objData.container.type or propValue(props, "container")
    if type(containerType) == "string" then containerType = string.lower(containerType) end
    if containerType == "stove" or containerType == "microwave" or containerType == "oven" then return "IsoStove" end
    if containerType == "fireplace" then return "IsoFireplace" end
    if containerType == "clothingdryer" or containerType == "clothingdryerbasic" then return "IsoClothingDryer" end
    if containerType == "clothingwasher" then
        local prefix, index = parseSpriteIndex(objData.sprite)
        if prefix == "appliances_laundry_01_" and index and index >= 0 and index <= 3 then
            return "IsoCombinationWasherDryer"
        end
        return "IsoClothingWasher"
    end

    local prefix, index = parseSpriteIndex(objData.sprite)
    if prefix == "appliances_cooking_01_" then return "IsoStove" end
    if prefix == "appliances_laundry_01_" and index then
        if index >= 0 and index <= 3 then return "IsoCombinationWasherDryer" end
        if index >= 12 and index <= 19 then return "IsoClothingDryer" end
        return "IsoClothingWasher"
    end
    if prefix == "appliances_television_01_" then
        return "IsoTelevision"
    end
    return nil
end

local MOVE_THUMPABLE_SPECIAL_CLASSES = {
    IsoBarbecue = true,
    IsoCombinationWasherDryer = true,
    IsoClothingDryer = true,
    IsoClothingWasher = true,
    IsoCompost = true,
    IsoJukebox = true,
    IsoStove = true,
}

local function specialClassFromData(objData)
    local className = inferSpecialObjectClass(objData)
    if className == "IsoWaveSignal" then
        local props = spriteProperties(objData and objData.sprite)
        local isoType = propValue(props, "IsoType")
        if isoType == "IsoTelevision" or isoType == "IsoRadio" then return isoType end
        if objData and type(objData.sprite) == "string" and string.find(objData.sprite, "appliances_television_01_", 1, true) then
            return "IsoTelevision"
        end
        return "IsoRadio"
    end
    return className
end

local function inferDoorSprites(spriteName)
    local prefix, index = parseSpriteIndex(spriteName)
    if not prefix or not index then return nil end
    if string.find(prefix, "fixtures_doors_frames", 1, true) then return nil end

    local props = spriteProperties(spriteName)
    local closedW = propHas(props, "doorW") or propHas(props, IsoFlagType and IsoFlagType.doorW)
    local closedN = propHas(props, "doorN") or propHas(props, IsoFlagType and IsoFlagType.doorN)
    local attachedW = propHas(props, "attachedW")
    local attachedN = propHas(props, "attachedN")

    if closedW or closedN then
        local openSprite = prefix .. tostring(index + 2)
        if spriteExists(openSprite) then
            return { closed = spriteName, open = openSprite, north = closedN, isOpen = false }
        end
        return nil
    end

    local looksLikeDoorTile = string.find(prefix, "fixtures_doors_", 1, true) ~= nil
    if looksLikeDoorTile and index >= 2 and (attachedW or attachedN) then
        local closedSprite = prefix .. tostring(index - 2)
        if spriteExists(closedSprite) then
            return { closed = closedSprite, open = spriteName, north = attachedN, isOpen = true }
        end
    end

    return nil
end

local function isThumpableDoorObject(obj)
    if not obj then return false end
    return AE_Sa.call("object.isThumpableDoor", false, function()
        return obj.isDoor and obj:isDoor() or false
    end)
end

local function isGarageDoorSprite(spriteName)
    if type(spriteName) ~= "string" then return false end
    local props = spriteProperties(spriteName)
    if propHas(props, "GarageDoor") or propHas(props, IsoPropertyType and IsoPropertyType.GARAGE_DOOR) then
        return true
    end
    local prefix, index = parseSpriteIndex(spriteName)
    return prefix == "walls_garage_01_" and index ~= nil and index >= 0 and index <= 11
end

local function isGarageDoorData(objData)
    if not objData then return false end
    return isGarageDoorSprite(objData.sprite) or
           isGarageDoorSprite(objData.closedSprite) or
           isGarageDoorSprite(objData.openSprite)
end

local function isDoorLikeData(objData)
    if not objData then return false end
    if objData.class == "IsoDoor" then return true end
    if objData.isDoor == true then return true end
    return inferDoorSprites(objData.closedSprite or objData.sprite) ~= nil
end

local function resolveDoorClosedSprite(objData)
    local inferred = inferDoorSprites(objData.sprite)
    if objData.closedSprite and spriteExists(objData.closedSprite) and
       not (inferred and inferred.isOpen == true and objData.closedSprite == objData.sprite and inferred.closed and spriteExists(inferred.closed)) then
        return objData.closedSprite
    end

    if inferred and inferred.closed and spriteExists(inferred.closed) then
        return inferred.closed
    end

    if objData.sprite and objData.isOpen ~= true and spriteExists(objData.sprite) then
        return objData.sprite
    end

    return nil
end

local function resolveDoorOpenSprite(objData)
    local inferred = inferDoorSprites(objData.sprite)
    if objData.openSprite and spriteExists(objData.openSprite) and
       not (inferred and inferred.isOpen == false and objData.openSprite == objData.sprite and inferred.open and spriteExists(inferred.open)) then
        return objData.openSprite
    end

    if inferred and inferred.open and spriteExists(inferred.open) then
        return inferred.open
    end

    local closedSprite = resolveDoorClosedSprite(objData)
    local closedPair = inferDoorSprites(closedSprite)
    if closedPair and closedPair.open and spriteExists(closedPair.open) then
        return closedPair.open
    end

    return nil
end

local function resolveDoorNorth(objData)
    if objData.north ~= nil then return objData.north == true end
    local inferred = inferDoorSprites(objData.sprite) or inferDoorSprites(objData.closedSprite)
    if inferred and inferred.north ~= nil then return inferred.north == true end
    local props = spriteProperties(resolveDoorClosedSprite(objData))
    return propHas(props, "doorN") or propHas(props, IsoFlagType and IsoFlagType.doorN)
end

local function resolveDoorIsOpen(objData)
    if objData.isOpen ~= nil then return objData.isOpen == true end
    local inferred = inferDoorSprites(objData.sprite)
    if inferred and inferred.isOpen ~= nil then return inferred.isOpen == true end
    return nil
end

local function setDoorOpenState(obj, targetOpen)
    if not obj or targetOpen == nil then return true end
    local wanted = targetOpen == true
    local current = AE_Sa.call("door.currentOpen", false, function()
        return obj.IsOpen and obj:IsOpen() or false
    end)
    if current == wanted then return true end

    local changed = AE_Sa.call("door.toggleSilent", false, function()
        if obj.ToggleDoorSilent then
            obj:ToggleDoorSilent()
            return true
        end
        if obj.setOpen then
            obj:setOpen(wanted)
            return true
        end
        return false
    end)
    if not changed then return false end

    return AE_Sa.call("door.verifyOpen", false, function()
        return obj.IsOpen and obj:IsOpen() == wanted
    end)
end

local function restoreDoorState(obj, objData)
    if not obj or not objData then return end
    if isGarageDoorData(objData) then
        -- Garage doors are multi-object IsoDoor groups. Replaying lock/open
        -- state per part can desynchronize live MP object ids. Rebuild the
        -- closed linked sprite group and let vanilla manage the group state.
        return
    end
    AE_Sa.call("door.setKeyId", nil, function()
        if objData.lockedKeyId ~= nil and obj.setKeyId then obj:setKeyId(objData.lockedKeyId) end
    end)
    AE_Sa.call("door.setLocked", nil, function()
        if objData.isLocked ~= nil and obj.setLocked then obj:setLocked(objData.isLocked == true) end
    end)
    if objData.name ~= nil then
        AE_Sa.call("door.setName", nil, function()
            if obj.setName then obj:setName(objData.name) end
        end)
    end
    local targetOpen = resolveDoorIsOpen(objData)
    setDoorOpenState(obj, targetOpen)
end

local function insertIndexBeforeWorldItems(sq)
    local objects = AE_Sa.call("sq.objectsForInsert", nil, function()
        return sq and sq:getObjects() or nil
    end)
    if not objects then return -1 end

    local size = AE_Sa.call("sq.objectsForInsert.size", 0, function() return objects:size() end)
    local insertIndex = size
    for i = size, 1, -1 do
        local obj = AE_Sa.call("sq.objectsForInsert.get", nil, function() return objects:get(i - 1) end)
        if not isWorldInventoryObject(obj) then
            insertIndex = i
            break
        end
    end
    return insertIndex
end

local function shouldUseSpecialObject(obj, objData)
    if not obj then return false end
    if isDoorObject(obj) or isThumpableObject(obj) then return true end
    if isLightSwitchObject(obj) then return true end
    if specialClassFromData(objData) then return true end
    if objData and (objData.class == "IsoWindow" or objData.class == "IsoWindowFrame" or objData.class == "IsoCurtain" or objData.class == "IsoLightSwitch") then return true end

    local props = spriteProperties(objData and objData.sprite)
    if not props then return false end
    if AE_Sa.call("sprite.isMoveable", false, function() return props:has("IsMoveAble") end) then return true end
    if AE_Sa.call("sprite.hasContainer", false, function() return props:has("container") end) then return true end
    if spriteHasFlag(props, IsoFlagType and (IsoFlagType.doorN or IsoFlagType.DoorWallN)) then return true end
    if spriteHasFlag(props, IsoFlagType and IsoFlagType.doorW) then return true end
    if spriteHasFlag(props, IsoFlagType and IsoFlagType.windowN) then return true end
    if spriteHasFlag(props, IsoFlagType and IsoFlagType.windowW) then return true end
    if spriteHasFlag(props, IsoFlagType and IsoFlagType.WindowN) then return true end
    if spriteHasFlag(props, IsoFlagType and IsoFlagType.WindowW) then return true end
    return false
end

local function addObjectToSquare(sq, obj, objData)
    if not sq or not obj then return false end
    local index = insertIndexBeforeWorldItems(sq)
    local useSpecial = shouldUseSpecialObject(obj, objData)

    return AE_Sa.call("sq.addObject", false, function()
        if useSpecial and sq.AddSpecialObject then
            if index >= 0 then sq:AddSpecialObject(obj, index) else sq:AddSpecialObject(obj) end
        else
            if index >= 0 then sq:AddTileObject(obj, index) else sq:AddTileObject(obj) end
        end
        return true
    end)
end

local function preparePlacedObject(obj, objData)
    if not obj then return end
    -- B42 uses entity/components on several interactive fixtures. Vanilla
    -- moveable placement initializes those before inserting the object into the
    -- square; otherwise the object can persist correctly but lack live-session
    -- interaction controls until the chunk is loaded again.
    AE_Sa.call("obj.createIsoEntityFromCellLoading", nil, function()
        local needsEntityInit = instanceof and (
            instanceof(obj, "IsoCombinationWasherDryer") or
            instanceof(obj, "IsoClothingDryer") or
            instanceof(obj, "IsoClothingWasher") or
            instanceof(obj, "IsoStove") or
            instanceof(obj, "IsoRadio") or
            instanceof(obj, "IsoTelevision") or
            instanceof(obj, "IsoWaveSignal")
        )
        if needsEntityInit and GameEntityFactory and GameEntityFactory.CreateIsoEntityFromCellLoading then
            GameEntityFactory.CreateIsoEntityFromCellLoading(obj)
        end
    end)
    -- Vanilla moveable placement creates containers from sprite properties before
    -- transmitting the object. Without this, cabinets/shelves can look restored
    -- but their server-side container transaction state remains incomplete.
    AE_Sa.call("obj.createContainersFromSpriteProperties", nil, function()
        if obj.createContainersFromSpriteProperties then
            obj:createContainersFromSpriteProperties()
        end
    end)
    AE_Sa.call("obj.markMovedThumpable", nil, function()
        if instanceof and (instanceof(obj, "IsoRadio") or instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoWaveSignal")) then
            return
        end
        local props = spriteProperties(objData and objData.sprite)
        local solid = props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)) or false
        if solid and obj.setMovedThumpable and not isThumpableObject(obj) then
            obj:setMovedThumpable(true)
        end
    end)
end

local function markContainerDirty(container, target)
    AE_Sa.call("container.sync", nil, function()
        if container.setDrawDirty then container:setDrawDirty(true) end
        if container.setDirty then container:setDirty(true) end
        if container.dirty then container:dirty() end
    end)
    AE_Sa.call("container.overlay", nil, function()
        if ItemPicker and ItemPicker.updateOverlaySprite then
            ItemPicker.updateOverlaySprite(container:getParent() or target)
        end
    end)
end

local function ensureContainerAuthority(container, target)
    if not container or not target then return end
    local sq = AE_Sa.call("container.parentSquare", nil, function()
        return target.getSquare and target:getSquare() or nil
    end)
    AE_Sa.call("container.setParent", nil, function()
        if container.setParent then container:setParent(target) end
    end)
    AE_Sa.call("container.setSourceGrid", nil, function()
        if sq and container.setSourceGrid then container:setSourceGrid(sq) end
    end)
end

local function transmitContainerDefinition(target, container)
    if not target or not container then return end
    AE_Sa.call("container.objectChange", nil, function()
        if isServer and isServer() and target.sendObjectChange and IsoObjectChange and IsoObjectChange.CONTAINERS then
            target:sendObjectChange(IsoObjectChange.CONTAINERS)
        end
    end)
end

local function transmitContainerItem(container, item)
    if not container or not item then return false end
    if not isServer or not isServer() then return true end
    if not sendAddItemToContainer then return false end
    return AE_Sa.call("container.sendAddItemToContainer", false, function()
        sendAddItemToContainer(container, item)
        return true
    end)
end

local containerHasItem

local function logContainerItemFailure(reason, itemData, target)
    importStats.itemFailureLogs = (importStats.itemFailureLogs or 0) + 1
    if importStats.itemFailureLogs <= 30 then
        print(string.format("[AreaExport] container item restore failed reason=%s type=%s parent=%s",
            tostring(reason),
            tostring(itemData and itemData.type or nil),
            tostring(target)))
    elseif importStats.itemFailureLogs == 31 then
        print("[AreaExport] additional container item restore failures suppressed")
    end
end

local function createInventoryItem(fullType)
    if not fullType or fullType == "" then return nil end
    return AE_Sa.call("item.instanceItem", nil, function()
        if instanceItem then return instanceItem(fullType) end
        return nil
    end) or AE_Sa.call("item.InventoryItemFactory", nil, function()
        if InventoryItemFactory and InventoryItemFactory.CreateItem then
            return InventoryItemFactory.CreateItem(fullType)
        end
        return nil
    end)
end

local function addItemTypeToContainer(container, fullType)
    if not container or not fullType or fullType == "" then return nil end
    return AE_Sa.call("container.AddItemType", nil, function()
        if container.AddItem then return container:AddItem(fullType) end
        return nil
    end) or AE_Sa.call("container.SpawnItemType", nil, function()
        if container.SpawnItem then return container:SpawnItem(fullType) end
        return nil
    end)
end

local function addExistingItemToContainer(container, item)
    if not container or not item then return false end
    if containerHasItem(container, item) then return true end
    AE_Sa.call("container.AddItemObject", nil, function()
        if container.AddItem then container:AddItem(item) end
    end)
    if containerHasItem(container, item) then return true end
    AE_Sa.call("container.DoAddItem", nil, function()
        if container.DoAddItem then container:DoAddItem(item) end
    end)
    if containerHasItem(container, item) then return true end
    AE_Sa.call("container.addItem", nil, function()
        if container.addItem then container:addItem(item) end
    end)
    if containerHasItem(container, item) then return true end
    AE_Sa.call("container.DoAddItemBlind", nil, function()
        if container.DoAddItemBlind then container:DoAddItemBlind(item) end
    end)
    return containerHasItem(container, item)
end

local function queueContainerItems(context, target, container, items)
    if type(items) ~= "table" or #items == 0 then return end
    context = context or {}
    context.pendingContainers = context.pendingContainers or {}
    context.pendingContainers[#context.pendingContainers + 1] = {
        target = target,
        container = container,
        items = items,
    }
    importStats.containerItemBatches = importStats.containerItemBatches + 1
    importStats.containerItemsQueued = importStats.containerItemsQueued + #items
end

local function finalizePlacedObject(obj, restoredContainer)
    if not obj then return end
    if isDoorObject(obj) then
        AE_Sa.call("door.recalcSquare", nil, function()
            local sq = obj.getSquare and obj:getSquare() or nil
            if sq and sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
            if sq and sq.RecalcProperties then sq:RecalcProperties() end
        end)
        AE_Sa.call("door.transmitComplete", nil, function()
            if isServer and isServer() and obj.transmitCompleteItemToClients then
                obj:transmitCompleteItemToClients()
            elseif isClient and isClient() and obj.transmitCompleteItemToServer then
                obj:transmitCompleteItemToServer()
            end
        end)
        AE_Sa.call("door.onObjectAdded", nil, function()
            if triggerEvent then triggerEvent("OnObjectAdded", obj) end
        end)
        return
    end
    if isLightSwitchObject(obj) then
        AE_Sa.call("light.recalcSquare", nil, function()
            local sq = obj.getSquare and obj:getSquare() or nil
            if sq and sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
            if sq and sq.RecalcProperties then sq:RecalcProperties() end
        end)
        AE_Sa.call("light.transmitComplete", nil, function()
            if isServer and isServer() and obj.transmitCompleteItemToClients then
                obj:transmitCompleteItemToClients()
            end
        end)
        AE_Sa.call("light.onObjectAdded", nil, function()
            if triggerEvent then triggerEvent("OnObjectAdded", obj) end
        end)
        return
    end
    AE_Sa.call("obj.recalcSquare", nil, function()
        local sq = obj.getSquare and obj:getSquare() or nil
        if sq and sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
        if sq and sq.RecalcProperties then sq:RecalcProperties() end
    end)
    AE_Sa.call("obj.transmitComplete", nil, function()
        if isServer and isServer() and obj.transmitCompleteItemToClients then
            obj:transmitCompleteItemToClients()
        elseif isClient and isClient() and obj.transmitCompleteItemToServer then
            obj:transmitCompleteItemToServer()
        end
    end)
    AE_Sa.call("obj.transmitContainers", nil, function()
        local hasContainer = restoredContainer ~= nil
        if hasContainer and isServer and isServer() and obj.sendObjectChange and IsoObjectChange and IsoObjectChange.CONTAINERS then
            obj:sendObjectChange(IsoObjectChange.CONTAINERS)
        end
    end)
    AE_Sa.call("obj.transmitState", nil, function()
        if isServer and isServer() and obj.sendObjectChange and IsoObjectChange then
            if IsoObjectChange.STATE then obj:sendObjectChange(IsoObjectChange.STATE) end
            if instanceof and instanceof(obj, "IsoClothingWasher") and IsoObjectChange.WASHER_STATE then
                obj:sendObjectChange(IsoObjectChange.WASHER_STATE)
            end
            if instanceof and instanceof(obj, "IsoClothingDryer") and IsoObjectChange.DRYER_STATE then
                obj:sendObjectChange(IsoObjectChange.DRYER_STATE)
            end
            if instanceof and instanceof(obj, "IsoCombinationWasherDryer") then
                if IsoObjectChange.MODE then obj:sendObjectChange(IsoObjectChange.MODE) end
                if obj.isModeWasher and obj:isModeWasher() and IsoObjectChange.WASHER_STATE then
                    obj:sendObjectChange(IsoObjectChange.WASHER_STATE)
                elseif IsoObjectChange.DRYER_STATE then
                    obj:sendObjectChange(IsoObjectChange.DRYER_STATE)
                end
            end
            if instanceof and instanceof(obj, "IsoStove") and IsoObjectChange.CONTAINER_CUSTOM_TEMPERATURE then
                obj:sendObjectChange(IsoObjectChange.CONTAINER_CUSTOM_TEMPERATURE)
            end
        end
    end)
    AE_Sa.call("obj.onObjectAdded", nil, function()
        if triggerEvent then triggerEvent("OnObjectAdded", obj) end
    end)
    AE_Sa.call("obj.containerUpdateEvent", nil, function()
        if triggerEvent then triggerEvent("OnContainerUpdate") end
    end)
end

local function applyObjectRules(objData)
    if not objData then return nil end
    -- Legacy exports could contain IsoWorldInventoryObject in the object list.
    -- Current exports store those as tile.worldItems, so object-level instances
    -- are skipped to avoid rebuilding the same loose item twice.
    if objData.class == "IsoWorldInventoryObject" then return nil end
    local classRule = activeRules[ruleKey("Object", objData.class or "IsoObject")]
    if classRule and classRule.action == "Skip" then return nil end

    local spriteRule = activeRules[ruleKey("Sprite", objData.sprite)]
    if spriteRule then
        if spriteRule.action == "Skip" then return nil end
        if spriteRule.action == "Replace" and spriteRule.replacement and spriteExists(spriteRule.replacement) then
            local copy = cloneObjectData(objData)
            copy.sprite = spriteRule.replacement
            return copy
        end
    end
    return objData
end

local function ensureSquare(cell, x, y, z)
    local sq = AE_Sa.call("getSquare", nil, function() return cell:getGridSquare(x, y, z) end)
    if sq then return sq end
    -- try to create
    sq = AE_Sa.call("createNewSquare", nil, function()
        if cell.createNewGridSquare then
            return cell:createNewGridSquare(x, y, z, true)
        end
        return nil
    end)
    return sq
end

local function applyAttrs(target, attrs, data)
    for _, attr in ipairs(attrs) do
        if attr.write and data[attr.name] ~= nil then
            AE_Sa.write(target, attr, data[attr.name])
        end
    end
end

containerHasItem = function(container, item)
    if not container or not item then return false end
    local contains = AE_Sa.call("container.contains", false, function()
        if container.contains then return container:contains(item) end
        return false
    end)
    if contains then return true end
    local items = AE_Sa.call("container.itemsForVerify", nil, function()
        return container:getItems()
    end)
    if not items then return false end
    contains = AE_Sa.call("container.itemsForVerify.contains", false, function()
        if items.contains then return items:contains(item) end
        return false
    end)
    if contains then return true end
    local n = AE_Sa.call("container.itemsForVerify.size", 0, function() return items:size() end)
    for i = 0, n - 1 do
        local candidate = AE_Sa.call("container.itemsForVerify.get", nil, function() return items:get(i) end)
        if candidate == item then return true end
    end
    return false
end

local function buildItem(itemData, container, target)
    if not itemData or not itemData.type then return nil end
    itemData = applyItemRule(itemData)
    if not itemData then return nil end
    importStats.itemsExpected = importStats.itemsExpected + 1

    ensureContainerAuthority(container, target)
    local item = createInventoryItem(itemData.type)
    local added = false
    if not item then
        item = addItemTypeToContainer(container, itemData.type)
        added = item ~= nil
    end
    if not item then
        importStats.itemsFailed = importStats.itemsFailed + 1
        logContainerItemFailure("create", itemData, target)
        return nil
    end

    -- apply optional attrs
    for _, attr in pairs(AE_AttrMap.item) do
        if attr.name ~= "type" and attr.write and itemData[attr.name] ~= nil then
            AE_Sa.write(item, attr, itemData[attr.name])
        end
    end

    AE_Sa.call("item.clearWorldItem", nil, function()
        if item.setWorldItem then item:setWorldItem(nil) end
    end)

    if container and not added then
        added = addExistingItemToContainer(container, item)
    end

    if container and item.getContainer and item:getContainer() ~= container then
        AE_Sa.call("item.setContainerFallback", nil, function()
            if item.setContainer then item:setContainer(container) end
        end)
    end

    local inContainer = containerHasItem(container, item)
    local parentOk = true
    if item.getContainer then parentOk = item:getContainer() == container end
    local verified = added and inContainer and parentOk
    if verified then
        importStats.itemsAdded = importStats.itemsAdded + 1
        importStats.containerItemsVerified = importStats.containerItemsVerified + 1
        transmitContainerItem(container, item)
        AE_Sa.call("container.sendItemStats", nil, function()
            if isServer and isServer() and sendItemStats then sendItemStats(item) end
        end)
    else
        importStats.itemsFailed = importStats.itemsFailed + 1
        logContainerItemFailure(string.format("add added=%s inContainer=%s parentOk=%s",
            tostring(added),
            tostring(inContainer),
            tostring(parentOk)), itemData, target)
    end

    return item
end

local function buildContainer(target, contData, context)
    if not contData then return end
    importStats.containersSeen = importStats.containersSeen + 1
    local container = AE_Sa.call("getContainer", nil, function()
        return target.getContainer and target:getContainer()
    end)
    if not container then
        importStats.containersMissing = importStats.containersMissing + 1
        return
    end
    -- Newly-created map containers often receive procedural loot. The export
    -- data is authoritative, so clear the generated contents before restoring.
    AE_Sa.call("container.clear", nil, function()
        if container.removeAllItems then
            container:removeAllItems()
            return
        end
        if container.RemoveAllItems then
            container:RemoveAllItems()
            return
        end
        local items = container:getItems()
        if items and items.clear then items:clear() end
    end)
    importStats.containersCleared = importStats.containersCleared + 1
    AE_Sa.call("container.setExplored", nil, function()
        -- Marking explored/filled is what makes shelves and cabinets visually
        -- reflect restored contents after reload instead of showing the default
        -- "empty/unsearched" exterior state.
        if container.setExplored then container:setExplored(true) end
        if container.setHasBeenLooted then container:setHasBeenLooted(true) end
    end)
    ensureContainerAuthority(container, target)
    if contData.capacity and AE_AttrMap.container.capacity.write then
        AE_Sa.write(container, AE_AttrMap.container.capacity, contData.capacity)
    end
    queueContainerItems(context, target, container, contData.items)
    markContainerDirty(container, target)
    return container
end

local function processPendingContainers(context)
    local queue = context and context.pendingContainers or nil
    if type(queue) ~= "table" or #queue == 0 then return end
    for _, entry in ipairs(queue) do
        local target = entry.target
        local container = AE_Sa.call("pendingContainer.resolve", entry.container, function()
            return target and target.getContainer and target:getContainer() or entry.container
        end)
        if not container then
            importStats.containersMissing = importStats.containersMissing + 1
        else
            ensureContainerAuthority(container, target)
            for _, itemData in ipairs(entry.items or {}) do
                buildItem(itemData, container, target)
            end
            markContainerDirty(container, target)
            transmitContainerDefinition(target, container)
            print(string.format("[AreaExport] restored container batch items=%d verified=%d parent=%s",
                #(entry.items or {}),
                importStats.containerItemsVerified or 0,
                tostring(target)))
        end
    end
    context.pendingContainers = {}
end

local function applyItemAttrs(item, itemData)
    -- Kept for container/inventory items. Do not use this for loose world items
    -- unless the B42 pickup-ghost problem is revisited and retested.
    for _, attr in pairs(AE_AttrMap.item) do
        if attr.name ~= "type" and attr.write and itemData[attr.name] ~= nil then
            AE_Sa.write(item, attr, itemData[attr.name])
        end
    end
    AE_Sa.call("item.worldXRotation", nil, function()
        if item.setWorldXRotation and itemData.worldXRotation ~= nil then item:setWorldXRotation(itemData.worldXRotation) end
    end)
    AE_Sa.call("item.worldYRotation", nil, function()
        if item.setWorldYRotation and itemData.worldYRotation ~= nil then item:setWorldYRotation(itemData.worldYRotation) end
    end)
    AE_Sa.call("item.worldZRotation", nil, function()
        if item.setWorldZRotation and itemData.worldZRotation ~= nil then item:setWorldZRotation(itemData.worldZRotation) end
    end)
end

local function buildWorldItem(sq, itemData)
    if not sq or not itemData or not itemData.type then return nil end
    itemData = applyItemRule(itemData)
    if not itemData then return nil end
    importStats.itemsExpected = importStats.itemsExpected + 1

    local worldItem = AE_Sa.call("sq.AddWorldInventoryItem", nil, function()
        return sq:AddWorldInventoryItem(itemData.type, tonumber(itemData.offX or 0) or 0, tonumber(itemData.offY or 0) or 0, tonumber(itemData.offZ or 0) or 0, false)
    end)
    if worldItem then
        -- For loose ground items, keep creation close to PZ's vanilla server
        -- path. Any post-create mutation here can desync the server-side
        -- world-item id and leave a pickup ghost behind.
        importStats.itemsAdded = importStats.itemsAdded + 1
        return worldItem
    end

    importStats.itemsFailed = importStats.itemsFailed + 1
    return nil
end

-- Try several approaches to instantiate an object on a square based on saved data.
-- Returns the created object or nil.
local function buildThumpableDoor(sq, objData)
    local closedSprite = resolveDoorClosedSprite(objData)
    local openSprite = resolveDoorOpenSprite(objData)
    if not closedSprite or not openSprite then return nil end
    local north = resolveDoorNorth(objData)

    local obj = AE_Sa.call("buildThumpableDoor", nil, function()
        local IsoThumpable = _G.IsoThumpable
        if not IsoThumpable or not IsoThumpable.new then return nil end
        local t = IsoThumpable.new(sq:getCell(), sq, closedSprite, openSprite, north or false, {})
        if t.setIsDoor then t:setIsDoor(true) end
        if t.setIsThumpable then t:setIsThumpable(true) end
        if t.setCanBarricade then t:setCanBarricade(true) end
        if t.setCanPassThrough then t:setCanPassThrough(false) end
        if t.setThumpDmg then t:setThumpDmg(5) end
        if t.setBreakSound then t:setBreakSound("BreakDoor") end
        if t.setName then t:setName(objData.name or "Door") end
        if objData.maxHealth and t.setMaxHealth then t:setMaxHealth(objData.maxHealth) end
        if objData.health and t.setHealth then t:setHealth(objData.health) end
        return t
    end)

    if obj then
        addObjectToSquare(sq, obj, objData)
        print(string.format("[AreaExport] thumpable door built sprite=%s closed=%s open=%s north=%s isDoor=%s",
            tostring(objData.sprite),
            tostring(closedSprite),
            tostring(openSprite),
            tostring(north),
            tostring(isThumpableDoorObject(obj))))
    end
    return obj
end

local function ensureWaveSignalDeviceData(obj, objData, className)
    if not obj or not objData then return end
    if className ~= "IsoRadio" and className ~= "IsoTelevision" then return end
    if not obj.getDeviceData or not obj.setDeviceData then return end

    local props = spriteProperties(objData.sprite)
    local customItem = propValue(props, "CustomItem")
    if not customItem or customItem == "" then
        if className == "IsoTelevision" then
            local prefix, index = parseSpriteIndex(objData.sprite)
            if prefix == "appliances_television_01_" and index then
                if index >= 0 and index <= 3 then
                    customItem = "Base.TvWideScreen"
                elseif index >= 8 and index <= 11 then
                    customItem = "Base.TvAntique"
                else
                    customItem = "Base.TvBlack"
                end
            else
                customItem = "Base.TvBlack"
            end
        else
            customItem = "Base.RadioBlack"
        end
    end
    local item = createInventoryItem(customItem)
    local deviceData = AE_Sa.call("waveSignal.itemDeviceData", nil, function()
        return item and item.getDeviceData and item:getDeviceData() or nil
    end)
    if not deviceData then
        print(string.format("[AreaExport] wave signal restore missing DeviceData class=%s sprite=%s item=%s",
            tostring(className), tostring(objData.sprite), tostring(customItem)))
        return
    end
    -- Always use the script-backed CustomItem device data. Constructors can
    -- leave a placeholder device on rebuilt TVs/radios, which persists but does
    -- not open the real radio/TV UI after reload.
    AE_Sa.call("waveSignal.turnOffBeforePlacement", nil, function()
        if deviceData.setIsTurnedOn and deviceData.getIsTurnedOn then
            deviceData:setIsTurnedOn(deviceData:getIsTurnedOn())
        elseif deviceData.setIsTurnedOn then
            deviceData:setIsTurnedOn(false)
        end
    end)
    AE_Sa.call("waveSignal.setDeviceData", nil, function()
        obj:setDeviceData(deviceData)
    end)
    AE_Sa.call("waveSignal.deviceParent", nil, function()
        if deviceData.setParent then deviceData:setParent(obj) end
    end)
    AE_Sa.call("waveSignal.clearPortableRadioLink", nil, function()
        local md = obj.getModData and obj:getModData() or nil
        if md then md.RadioItemID = nil end
    end)
    print(string.format("[AreaExport] wave signal restore class=%s sprite=%s item=%s deviceData=true",
        tostring(className), tostring(objData.sprite), tostring(customItem)))
end

local function buildSpecialIsoObject(sq, objData, className)
    if not sq or not objData or not className then return nil end
    importStats.specialSeen = (importStats.specialSeen or 0) + 1
    local spriteName = objData.sprite
    if not spriteName then return nil end
    local obj = AE_Sa.call("buildSpecial." .. tostring(className), nil, function()
        local cls = _G and _G[className] or nil
        if not cls or not cls.new then return nil end
        local isoSpr = getSprite(spriteName)
        if not isoSpr then return nil end
        local built = cls.new(sq:getCell(), sq, isoSpr)
        if built and MOVE_THUMPABLE_SPECIAL_CLASSES[className] and built.setMovedThumpable then
            built:setMovedThumpable(true)
        end
        return built
    end)
    if obj then
        preparePlacedObject(obj, objData)
        ensureWaveSignalDeviceData(obj, objData, className)
        addObjectToSquare(sq, obj, objData)
        if className == "IsoRadio" or className == "IsoTelevision" then
            AE_Sa.call("waveSignal.transmitModDataAfterAdd", nil, function()
                if isServer and isServer() and obj.transmitModData then obj:transmitModData() end
            end)
        end
        importStats.specialBuilt = (importStats.specialBuilt or 0) + 1
        local deviceReady = AE_Sa.call("special.deviceReady", nil, function()
            if obj.getDeviceData then return obj:getDeviceData() ~= nil end
            return nil
        end)
        print(string.format("[AreaExport] special object rebuilt class=%s runtime=%s sprite=%s container=%s deviceData=%s",
            tostring(className),
            runtimeClassLabel(obj),
            tostring(spriteName),
            tostring(objData.container and objData.container.type or nil),
            tostring(deviceReady)))
    end
    if not obj then
        importStats.specialFailed = (importStats.specialFailed or 0) + 1
        print(string.format("[AreaExport] special object rebuild failed class=%s sprite=%s",
            tostring(className), tostring(spriteName)))
    end
    return obj
end

local function buildObject(sq, objData)
    local specialClass = specialClassFromData(objData)
    if specialClass and objData.class ~= specialClass then
        objData = cloneObjectData(objData)
        objData.class = specialClass
    end

    local sprite = objData.sprite
    if not sprite then return nil end
    if objData.class == "IsoDoor" then
        local obj = AE_Sa.call("buildDoor", nil, function()
            local closedSprite = resolveDoorClosedSprite(objData)
            if not closedSprite then return nil end
            local north = resolveDoorNorth(objData)
            if _G.IsoDoor and _G.IsoDoor.new then
                -- Always construct from the closed sprite. Constructing an open
                -- exported sprite as the base sprite can create a door whose next
                -- interaction snaps back because its sprite pair is reversed.
                local isoSpr = getSprite(closedSprite)
                if not isoSpr then return nil end
                return _G.IsoDoor.new(sq:getCell(), sq, isoSpr, north)
            end
            return nil
        end)
        if obj then
            addObjectToSquare(sq, obj, objData)
            return obj
        end

        -- If a real door snapshot is incomplete, fall back to a static visual
        -- instead of creating an interactive object with corrupt state.
        importStats.doorFallbacks = importStats.doorFallbacks + 1
        objData.class = "IsoObject"
    end
    if isDoorLikeData(objData) and objData.class ~= "IsoDoor" then
        local obj = buildThumpableDoor(sq, objData)
        if obj then return obj end
        importStats.doorFallbacks = importStats.doorFallbacks + 1
    end
    if objData.class == "IsoLightSwitch" then
        local obj = AE_Sa.call("buildLightSwitch", nil, function()
            local isoSpr = getSprite(sprite)
            if not isoSpr then return nil end
            if _G.IsoLightSwitch and _G.IsoLightSwitch.new then
                local roomId = sq.getRoomID and sq:getRoomID() or 0
                local light = _G.IsoLightSwitch.new(sq:getCell(), sq, isoSpr, roomId)
                if light and light.addLightSourceFromSprite then light:addLightSourceFromSprite() end
                return light
            end
            return nil
        end)
        if obj then
            preparePlacedObject(obj, objData)
            addObjectToSquare(sq, obj, objData)
            return obj
        end
    end
    if objData.class == "IsoWindow" or objData.class == "IsoWindowFrame" then
        local obj = AE_Sa.call("buildWindowFrame", nil, function()
            local isoSpr = getSprite(sprite)
            if not isoSpr then return nil end
            local north = objData.north
            if north == nil then
                local props = spriteProperties(sprite)
                north = spriteHasFlag(props, IsoFlagType and (IsoFlagType.windowN or IsoFlagType.WindowN)) or
                        spriteHasFlag(props, IsoFlagType and IsoFlagType.WindowN)
            end
            if objData.class == "IsoWindow" and _G.IsoWindow and _G.IsoWindow.new then
                return _G.IsoWindow.new(sq:getCell(), sq, isoSpr, north)
            end
            if _G.IsoWindowFrame and _G.IsoWindowFrame.new then
                return _G.IsoWindowFrame.new(sq:getCell(), sq, isoSpr, north)
            end
            return nil
        end)
        if obj then
            preparePlacedObject(obj, objData)
            addObjectToSquare(sq, obj, objData)
            return obj
        end
    end
    if specialClass then
        local obj = buildSpecialIsoObject(sq, objData, specialClass)
        if obj then return obj end
    end
    -- Strategy 1: IsoThumpable for player builds (walls, doors, furniture)
    if objData.isPlayerBuild or objData.class == "IsoThumpable" then
        local obj = AE_Sa.call("buildThumpable", nil, function()
            local IsoSprite = _G.IsoSprite
            local isoSpr = IsoSprite.new()
            isoSpr:LoadFramesNoDirPageSimple(sprite)
            local IsoThumpable = _G.IsoThumpable
            local cell = sq:getCell()
            local north = objData.north
            if north == nil then
                local props = spriteProperties(sprite)
                north = spriteHasFlag(props, IsoFlagType and IsoFlagType.WallN)
            end
            local t = IsoThumpable.new(cell, sq, sprite, north or false, {})
            return t
        end)
        if obj then
            preparePlacedObject(obj, objData)
            addObjectToSquare(sq, obj, objData)
            return obj
        end
    end
    -- Strategy 2: plain IsoObject for static decoration
    local obj = AE_Sa.call("buildIsoObject", nil, function()
        local IsoObject = _G.IsoObject
        return IsoObject.new(sq:getCell(), sq, sprite)
    end)
    if obj then
        preparePlacedObject(obj, objData)
        addObjectToSquare(sq, obj, objData)
        return obj
    end
    return nil
end

local function recalcSquare(sq)
    if not sq then return end
    AE_Sa.call("sq.RecalcAllWithNeighbours", nil, function()
        if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
    end)
    AE_Sa.call("sq.RecalcProperties", nil, function()
        if sq.RecalcProperties then sq:RecalcProperties() end
    end)
end

local function addRemovalObject(toRemove, seen, obj, floor, removeWorldItems)
    if not obj or obj == floor or seen[obj] then return end
    if not removeWorldItems and isWorldInventoryObject(obj) then return end
    seen[obj] = true
    toRemove[#toRemove + 1] = obj
end

local function objectSpriteName(obj)
    return AE_Sa.call("object.spriteNameForImport", nil, function()
        local sprite = obj and obj.getSprite and obj:getSprite() or nil
        return sprite and sprite.getName and sprite:getName() or nil
    end)
end

local function isGarageDoorObject(obj)
    if not obj then return false end
    if isGarageDoorSprite(objectSpriteName(obj)) then return true end
    return AE_Sa.call("door.isGarageDoorObject", false, function()
        local IsoDoorClass = _G.IsoDoor or IsoDoor
        return IsoDoorClass and IsoDoorClass.getGarageDoorIndex and IsoDoorClass.getGarageDoorIndex(obj) ~= -1
    end)
end

local function collectLinkedDoorObjects(toRemove, seen, obj, floor, removeWorldItems)
    local IsoDoorClass = _G.IsoDoor or IsoDoor
    if not IsoDoorClass then return end

    AE_Sa.call("door.doubleDoorObjects", nil, function()
        if not IsoDoorClass.getDoubleDoorObject then return end
        for i = 1, 4 do
            addRemovalObject(toRemove, seen, IsoDoorClass.getDoubleDoorObject(obj, i), floor, removeWorldItems)
        end
    end)

    AE_Sa.call("door.garageDoorObjects", nil, function()
        if not IsoDoorClass.getGarageDoorIndex or IsoDoorClass.getGarageDoorIndex(obj) == -1 then return end
        local linkedSeen = {}
        local function addLinked(part)
            if not part or linkedSeen[part] then return false end
            linkedSeen[part] = true
            addRemovalObject(toRemove, seen, part, floor, removeWorldItems)
            return true
        end

        addLinked(obj)
        if IsoDoorClass.getGarageDoorPrev then
            local prev = IsoDoorClass.getGarageDoorPrev(obj)
            local guard = 0
            while prev and guard < 32 and addLinked(prev) do
                prev = IsoDoorClass.getGarageDoorPrev(prev)
                guard = guard + 1
            end
        end
        if IsoDoorClass.getGarageDoorNext then
            local nextObj = IsoDoorClass.getGarageDoorNext(obj)
            local guard = 0
            while nextObj and guard < 32 and addLinked(nextObj) do
                nextObj = IsoDoorClass.getGarageDoorNext(nextObj)
                guard = guard + 1
            end
        end
    end)
end

local function collectGarageDoorSpriteGroup(toRemove, seen, obj, floor, removeWorldItems)
    if not isGarageDoorObject(obj) then return end
    local startSq = AE_Sa.call("garageDoor.startSquare", nil, function()
        return obj.getSquare and obj:getSquare() or nil
    end)
    local cell = getCell and getCell() or nil
    if not startSq or not cell then return end

    local startX = startSq:getX()
    local startY = startSq:getY()
    local z = startSq:getZ()
    local queue = { startSq }
    local seenSquares = {}
    local cursor = 1

    while queue[cursor] do
        local sq = queue[cursor]
        cursor = cursor + 1
        local key = tostring(sq:getX()) .. ":" .. tostring(sq:getY()) .. ":" .. tostring(sq:getZ())
        if not seenSquares[key] then
            seenSquares[key] = true
            local foundPart = false
            local objects = AE_Sa.call("garageDoor.squareObjects", nil, function() return sq:getObjects() end)
            if objects then
                local n = AE_Sa.call("garageDoor.squareObjects.size", 0, function() return objects:size() end)
                for i = 0, n - 1 do
                    local part = AE_Sa.call("garageDoor.squareObjects.get", nil, function() return objects:get(i) end)
                    if part and isGarageDoorObject(part) then
                        foundPart = true
                        addRemovalObject(toRemove, seen, part, floor, removeWorldItems)
                        collectLinkedDoorObjects(toRemove, seen, part, floor, removeWorldItems)
                    end
                end
            end

            if foundPart then
                local neighbors = {
                    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
                }
                for _, delta in ipairs(neighbors) do
                    local nx = sq:getX() + delta[1]
                    local ny = sq:getY() + delta[2]
                    if math.abs(nx - startX) <= 8 and math.abs(ny - startY) <= 8 then
                        local nextSq = AE_Sa.call("garageDoor.neighborSquare", nil, function()
                            return cell:getGridSquare(nx, ny, z)
                        end)
                        if nextSq then queue[#queue + 1] = nextSq end
                    end
                end
            end
        end
    end
end

local function removeTileObject(obj, fallbackSq, extraRecalcSquares)
    if not obj then return end
    local objSq = AE_Sa.call("object.getSquareForRemoval", fallbackSq, function()
        return obj.getSquare and obj:getSquare() or fallbackSq
    end) or fallbackSq
    if not objSq then return end

    AE_Sa.call("sq.RemoveTileObject", nil, function()
        -- Keep the client object list in the same order as the server.
        -- If clients keep a stale furniture tile while the server inserts
        -- a new world item at that index, picking up the item can remove
        -- the furniture sprite client-side. Vanilla server-side moveable
        -- code uses transmitRemoveItemFromSquareOnClients() + RemoveTileObject().
        if isServer and isServer() and objSq.transmitRemoveItemFromSquareOnClients and not isWorldInventoryObject(obj) then
            objSq:transmitRemoveItemFromSquareOnClients(obj)
        elseif objSq.transmitRemoveItemFromSquare and (isWorldInventoryObject(obj) or not isDoorObject(obj)) then
            objSq:transmitRemoveItemFromSquare(obj)
        end
        if isWorldInventoryObject(obj) then
            if obj.removeFromWorld then obj:removeFromWorld() end
            if obj.removeFromSquare then obj:removeFromSquare() end
        end
        objSq:RemoveTileObject(obj)
    end)

    if objSq ~= fallbackSq then
        extraRecalcSquares[#extraRecalcSquares + 1] = objSq
    end
end

---
-- Remove all non-floor map objects from a square.
-- The floor is kept because replacing floor sprites cleanly is non-trivial
-- and usually the auto-generated floor is visually close.
-- Existing loose world items are intentionally preserved. Removing them from
-- Lua can leave stale server-side world item ids, which makes the visual item
-- remain on the ground but impossible to pick up afterwards.
---
local function clearSquareState(sq, options)
    options = options or {}
    local removeWorldItems = options.removeWorldItems == true
    local floor = AE_Sa.call("sq.getFloor", nil, function() return sq:getFloor() end)
    local hadWorldItems = hasWorldItems(sq)

    -- Collect removal list first - mutating the collection during iteration is undefined.
    local objs = AE_Sa.call("sq.objects", nil, function() return sq:getObjects() end)
    if objs then
        local toRemove = {}
        local seen = {}
        local n = AE_Sa.call("sq.objects.size", 0, function() return objs:size() end)
        for i = 0, n - 1 do
            local o = AE_Sa.call("sq.objects.get", nil, function() return objs:get(i) end)
            if o and o ~= floor then
                if removeWorldItems or not isWorldInventoryObject(o) then
                    addRemovalObject(toRemove, seen, o, floor, removeWorldItems)
                    collectLinkedDoorObjects(toRemove, seen, o, floor, removeWorldItems)
                    collectGarageDoorSpriteGroup(toRemove, seen, o, floor, removeWorldItems)
                end
            end
        end
        local extraRecalcSquares = {}
        for _, o in ipairs(toRemove) do
            removeTileObject(o, sq, extraRecalcSquares)
        end
        for _, extraSq in ipairs(extraRecalcSquares) do
            recalcSquare(extraSq)
        end
    end
    if removeWorldItems then
        local worldObjects = AE_Sa.call("sq.worldObjectsForRemoval", nil, function()
            return sq.getWorldObjects and sq:getWorldObjects()
        end)
        if worldObjects then
            local toRemove = {}
            local n = AE_Sa.call("sq.worldObjectsForRemoval.size", 0, function() return worldObjects:size() end)
            for i = 0, n - 1 do
                local o = AE_Sa.call("sq.worldObjectsForRemoval.get", nil, function() return worldObjects:get(i) end)
                if o then toRemove[#toRemove + 1] = o end
            end
            for _, o in ipairs(toRemove) do
                AE_Sa.call("sq.RemoveWorldObject", nil, function()
                    if sq.removeWorldObject then sq:removeWorldObject(o) end
                    if sq.RemoveWorldObject then sq:RemoveWorldObject(o) end
                    if sq.transmitRemoveItemFromSquare then sq:transmitRemoveItemFromSquare(o) end
                end)
            end
        end
    end
    recalcSquare(sq)
    return hadWorldItems
end

local function rebuildTile(tileData, dx, dy, skipWorldItemImport, context)
    local cell = getCell()
    if not cell then return false end
    local x = tileData.x + dx
    local y = tileData.y + dy
    local z = tileData.z
    local sq = ensureSquare(cell, x, y, z)
    if not sq then return false end

    -- Idempotency: clear whatever is there (except the floor) before rebuilding.
    -- Without this, re-running the same import would duplicate every object.
    local hadWorldItems = clearSquareState(sq)

    if tileData.hasFloor == false then
        -- This restores deliberate holes in upper floors, for example player-built
        -- stair openings. Fresh generated saves often have a floor here unless we
        -- remove it explicitly.
        local floor = AE_Sa.call("sq.getFloorForRemoval", nil, function() return sq:getFloor() end)
        if floor then
            AE_Sa.call("sq.RemoveFloor", nil, function() sq:RemoveTileObject(floor) end)
        end
    end
    -- Floor sprite replacement skipped for now (auto-generated floor remains
    -- when the export says a floor exists).

    if tileData.objects then
        for _, objData in ipairs(tileData.objects) do
            objData = applyObjectRules(objData)
            if not objData then
                -- skipped by an explicit validation rule
            else
                local obj = buildObject(sq, objData)
                if obj then
                    if isDoorObject(obj) then
                        restoreDoorState(obj, objData)
                    elseif isThumpableDoorObject(obj) then
                        local attrs = AE_Handlers.byClass[objData.class] or AE_Handlers.default
                        applyAttrs(obj, attrs, objData)
                        restoreDoorState(obj, objData)
                    else
                        local attrs = AE_Handlers.byClass[objData.class] or AE_Handlers.default
                        applyAttrs(obj, attrs, objData)
                    end
                    local restoredContainer = nil
                    if objData.container then
                        restoredContainer = buildContainer(obj, objData.container, context)
                    end
                    finalizePlacedObject(obj, restoredContainer)
                end
            end
        end
    end
    local hasImportedWorldItems = tileData.worldItems and #tileData.worldItems > 0
    if hasImportedWorldItems then
        recalcSquare(sq)
    end

    if tileData.worldItems and (hadWorldItems or skipWorldItemImport) then
        -- Do not overwrite existing loose items. Repeated imports over an item
        -- already visible on the ground were the main source of unpickupable
        -- client ghosts during testing. Map objects are still rebuilt normally.
        for _ in ipairs(tileData.worldItems) do
            importStats.itemsExpected = importStats.itemsExpected + 1
            importStats.itemsSkipped = importStats.itemsSkipped + 1
        end
    elseif tileData.worldItems then
        for _, itemData in ipairs(tileData.worldItems) do
            buildWorldItem(sq, itemData)
        end
    end
    if not hasImportedWorldItems then
        recalcSquare(sq)
    end
    return true
end

local function clearExportFootprint(center, radius)
    -- Clear by radius instead of by saved tile list. The saved list omits empty
    -- squares, but an empty square inside the footprint may still mean "remove
    -- whatever the target save currently has here".
    if not center or not center.x or not center.y or not radius then return end
    local cell = getCell()
    if not cell then return end

    local r2 = radius * radius
    for dy = -radius, radius do
        for dx = -radius, radius do
            if dx * dx + dy * dy <= r2 then
                for z = 0, 7 do
                    local sq = AE_Sa.call("footprint.getSquare", nil, function()
                        return cell:getGridSquare(center.x + dx, center.y + dy, z)
                    end)
                    if sq then clearSquareState(sq, { removeWorldItems = true }) end
                end
            end
        end
    end
end

local function countTargetWorldItems(payload, dx, dy)
    -- Preflight check used to make loose world-item imports idempotent. If any
    -- target square already has world items, the import skips the loose item
    -- layer and reports skipped counts instead of stacking duplicates.
    local cell = getCell()
    if not cell or not payload or not payload.tiles then return 0 end
    local count = 0
    for _, tileData in ipairs(payload.tiles) do
        if tileData.worldItems and #tileData.worldItems > 0 then
            local sq = AE_Sa.call("targetWorldItems.getSquare", nil, function()
                return cell:getGridSquare((tileData.x or 0) + dx, (tileData.y or 0) + dy, tileData.z or 0)
            end)
            count = count + countWorldItems(sq)
        end
    end
    return count
end

local function collectTargetWorldItemSquares(payload, dx, dy, limit)
    -- The client cannot fully trust its local world-item collections after an
    -- import. Return candidate squares so the UI can ask the server for the
    -- authoritative count and remove only local ghosts when the server is empty.
    local cell = getCell()
    local squares = {}
    local total = 0
    if not cell or not payload or not payload.tiles then return squares, total end
    limit = tonumber(limit or 256) or 256
    for _, tileData in ipairs(payload.tiles) do
        if tileData.worldItems and #tileData.worldItems > 0 then
            total = total + 1
            if #squares < limit then
                local x = (tileData.x or 0) + dx
                local y = (tileData.y or 0) + dy
                local z = tileData.z or 0
                local sq = AE_Sa.call("targetWorldItemSquares.getSquare", nil, function()
                    return cell:getGridSquare(x, y, z)
                end)
                squares[#squares + 1] = {
                    x = x,
                    y = y,
                    z = z,
                    expected = #tileData.worldItems,
                    serverWorldItems = countWorldItems(sq),
                }
            end
        end
    end
    return squares, total
end

---
-- Import a saved area at its original world coordinates.
---
local function importPayload(payload, sourceName, options)
    AE_Sa.reset()
    resetImportStats()
    activeRules = normalizeRules(options and options.rules or nil)
    activeActor = options and options.actor or nil
    _G.AE_ImportActor = activeActor
    if payload.format_version and payload.format_version > 1 then
        return { success = false, error = "unsupported format_version " .. tostring(payload.format_version) }
    end

    local dx = 0
    local dy = 0
    -- dx/dy are intentionally fixed at zero. Keeping the variables makes the old
    -- relative-import math visible, but this release restores only the original
    -- coordinates saved in the export.
    local savedCenter = payload.metadata and payload.metadata.center or nil
    local savedRadius = payload.metadata and tonumber(payload.metadata.radius) or nil
    local existingTargetWorldItems = countTargetWorldItems(payload, dx, dy)
    local skipWorldItemImport = existingTargetWorldItems > 0

    -- The export radius defines the authoritative footprint. Clear that same
    -- footprint at the original coordinates before restoring saved tiles.
    clearExportFootprint(savedCenter, savedRadius)

    local importContext = { pendingContainers = {} }
    local processed, failed = 0, 0
    local importsWorldItems = false
    if payload.tiles then
        for _, tileData in ipairs(payload.tiles) do
            if tileData.worldItems and #tileData.worldItems > 0 then
                importsWorldItems = true
            end
            if rebuildTile(tileData, dx, dy, skipWorldItemImport, importContext) then
                processed = processed + 1
            else
                failed = failed + 1
            end
        end
    end
    processPendingContainers(importContext)

    -- Mark map-only imports dirty so they re-render. Do not do this for imports
    -- containing loose world items; on B42 dedicated servers it can leave a
    -- client-side pickup ghost whose server-side world-item id is already gone.
    if not importsWorldItems then
        AE_Sa.call("dirtyAllChunks", nil, function()
            local c = getCell()
            if c.DirtyAllChunks then c:DirtyAllChunks()
            elseif c.setAllChunksDirty then c:setAllChunksDirty() end
        end)
        AE_Sa.call("isoRegionsReset", nil, function()
            if IsoRegions and IsoRegions.ResetAllDataDebug then IsoRegions.ResetAllDataDebug() end
        end)
    end

    local summary = AE_Sa.summary()
    if summary ~= "" then print("[AreaExport] import " .. summary) end
    if skipWorldItemImport then
        print(string.format("[AreaExport] skipped loose world-item import because %d target world item(s) already exist", existingTargetWorldItems))
    end
    local worldItemSquares, worldItemSquareTotal = collectTargetWorldItemSquares(payload, dx, dy, 256)
    print(string.format("[AreaExport] import containers: seen=%d missing=%d cleared=%d items=%d/%d failed=%d skipped=%d replaced=%d placeholders=%d",
        importStats.containersSeen or 0,
        importStats.containersMissing or 0,
        importStats.containersCleared or 0,
        importStats.itemsAdded or 0,
        importStats.itemsExpected or 0,
        importStats.itemsFailed or 0,
        importStats.itemsSkipped or 0,
        importStats.itemsReplaced or 0,
        importStats.itemsPlaceholder or 0))
    print(string.format("[AreaExport] import authority: containerBatches=%d queued=%d verified=%d doorFallbacks=%d",
        importStats.containerItemBatches or 0,
        importStats.containerItemsQueued or 0,
        importStats.containerItemsVerified or 0,
        importStats.doorFallbacks or 0))
    print(string.format("[AreaExport] import special objects: seen=%d built=%d failed=%d",
        importStats.specialSeen or 0,
        importStats.specialBuilt or 0,
        importStats.specialFailed or 0))
    print(string.format("[AreaExport] imported %d tiles (%d failed) from %s",
        processed, failed, sourceName or "export data"))

    return {
        success = true,
        squaresProcessed = processed, squaresFailed = failed,
        containersSeen = importStats.containersSeen,
        containersMissing = importStats.containersMissing,
        itemsExpected = importStats.itemsExpected,
        itemsAdded = importStats.itemsAdded,
        itemsFailed = importStats.itemsFailed,
        itemsSkipped = importStats.itemsSkipped,
        itemsReplaced = importStats.itemsReplaced,
        itemsPlaceholder = importStats.itemsPlaceholder,
        containerItemBatches = importStats.containerItemBatches,
        containerItemsQueued = importStats.containerItemsQueued,
        containerItemsVerified = importStats.containerItemsVerified,
        doorFallbacks = importStats.doorFallbacks,
        specialSeen = importStats.specialSeen,
        specialBuilt = importStats.specialBuilt,
        specialFailed = importStats.specialFailed,
        originalCoordinates = true,
        radius = savedRadius,
        offset = { dx = 0, dy = 0 },
        worldItemSquares = worldItemSquares,
        worldItemSquareTotal = worldItemSquareTotal,
        worldItemMonitorSeconds = 120,
        skippedWorldItemImport = skipWorldItemImport,
        existingTargetWorldItems = existingTargetWorldItems,
    }
end

local function packageResult(state)
    local summary = AE_Sa.summary()
    if summary ~= "" then print("[AreaExport] import " .. summary) end
    print(string.format("[AreaExport] package import containers: seen=%d missing=%d cleared=%d items=%d/%d failed=%d skipped=%d replaced=%d placeholders=%d",
        importStats.containersSeen or 0,
        importStats.containersMissing or 0,
        importStats.containersCleared or 0,
        importStats.itemsAdded or 0,
        importStats.itemsExpected or 0,
        importStats.itemsFailed or 0,
        importStats.itemsSkipped or 0,
        importStats.itemsReplaced or 0,
        importStats.itemsPlaceholder or 0))
    print(string.format("[AreaExport] package import authority: containerBatches=%d queued=%d verified=%d doorFallbacks=%d",
        importStats.containerItemBatches or 0,
        importStats.containerItemsQueued or 0,
        importStats.containerItemsVerified or 0,
        importStats.doorFallbacks or 0))
    print(string.format("[AreaExport] package import special objects: seen=%d built=%d failed=%d",
        importStats.specialSeen or 0,
        importStats.specialBuilt or 0,
        importStats.specialFailed or 0))

    return {
        success = true,
        squaresProcessed = state.processed or 0,
        squaresFailed = state.failed or 0,
        totalTiles = state.totalTiles or 0,
        clearVisited = state.clearVisited or 0,
        clearTotal = state.clearTotal or 0,
        containersSeen = importStats.containersSeen,
        containersMissing = importStats.containersMissing,
        itemsExpected = importStats.itemsExpected,
        itemsAdded = importStats.itemsAdded,
        itemsFailed = importStats.itemsFailed,
        itemsSkipped = importStats.itemsSkipped,
        itemsReplaced = importStats.itemsReplaced,
        itemsPlaceholder = importStats.itemsPlaceholder,
        containerItemBatches = importStats.containerItemBatches,
        containerItemsQueued = importStats.containerItemsQueued,
        containerItemsVerified = importStats.containerItemsVerified,
        doorFallbacks = importStats.doorFallbacks,
        specialSeen = importStats.specialSeen,
        specialBuilt = importStats.specialBuilt,
        specialFailed = importStats.specialFailed,
        originalCoordinates = true,
        radius = state.radius,
        offset = { dx = 0, dy = 0 },
        worldItemSquares = state.worldItemSquares or {},
        worldItemSquareTotal = state.worldItemSquareTotal or 0,
        worldItemMonitorSeconds = 120,
        streamingPackage = true,
    }
end

function AE_Import.startPackage(manifest, options)
    AE_Sa.reset()
    resetImportStats()
    activeRules = normalizeRules(options and options.rules or nil)
    activeActor = options and options.actor or nil
    _G.AE_ImportActor = activeActor
    manifest = manifest or {}
    local metadata = manifest.metadata or {}
    local center = metadata.center or {}
    local radius = tonumber(metadata.radius or manifest.radius or 0) or 0
    radius = math.floor(radius)
    if not center.x or not center.y or radius < 1 then
        return nil, "package manifest is missing center/radius"
    end
    local clearSpan = (radius * 2) + 1

    return {
        manifest = manifest,
        center = { x = tonumber(center.x) or 0, y = tonumber(center.y) or 0 },
        radius = radius,
        r2 = radius * radius,
        clearDx = -radius,
        clearDy = -radius,
        clearZ = 0,
        clearDone = false,
        clearVisited = 0,
        clearTotal = clearSpan * clearSpan * 8,
        totalTiles = tonumber(manifest.tileCount or manifest.tiles or 0) or 0,
        processed = 0,
        failed = 0,
        importsWorldItems = false,
        worldItemSquares = {},
        worldItemSquareTotal = 0,
        pendingContainers = {},
        actor = activeActor,
    }
end

local function advanceClearCursor(state)
    state.clearZ = (state.clearZ or 0) + 1
    if state.clearZ <= 7 then return end
    state.clearZ = 0
    state.clearDx = (state.clearDx or -state.radius) + 1
    if state.clearDx <= state.radius then return end
    state.clearDx = -state.radius
    state.clearDy = (state.clearDy or -state.radius) + 1
    if state.clearDy > state.radius then state.clearDone = true end
end

function AE_Import.clearPackageStep(state, budget)
    if not state then return false, "missing import state" end
    if state.clearDone then return true end
    local cell = getCell()
    if not cell then return false, "no cell loaded" end
    budget = math.max(1, tonumber(budget or 2000) or 2000)
    local worked = 0
    while not state.clearDone and worked < budget do
        local dx, dy, z = state.clearDx, state.clearDy, state.clearZ
        if dx * dx + dy * dy <= state.r2 then
            local sq = AE_Sa.call("packageClear.getSquare", nil, function()
                return cell:getGridSquare(state.center.x + dx, state.center.y + dy, z)
            end)
            if sq then clearSquareState(sq, { removeWorldItems = true }) end
        end
        worked = worked + 1
        state.clearVisited = math.min(state.clearTotal or 0, (state.clearVisited or 0) + 1)
        advanceClearCursor(state)
    end
    return state.clearDone
end

function AE_Import.importPackageLine(state, line)
    if not state then return false, "missing import state" end
    activeActor = state.actor
    _G.AE_ImportActor = activeActor
    if not line or line == "" then return true end
    local tileData, err = AE_Json.decode(line)
    if not tileData then
        state.failed = (state.failed or 0) + 1
        return false, "tile decode failed: " .. tostring(err)
    end
    if tileData.worldItems and #tileData.worldItems > 0 then
        state.importsWorldItems = true
        state.worldItemSquareTotal = (state.worldItemSquareTotal or 0) + 1
    end
    if rebuildTile(tileData, 0, 0, false, state) then
        state.processed = (state.processed or 0) + 1
        if tileData.worldItems and #tileData.worldItems > 0 and #(state.worldItemSquares or {}) < 256 then
            local sq = AE_Sa.call("packageWorldItemSquare.getSquare", nil, function()
                local cell = getCell()
                return cell and cell:getGridSquare(tileData.x or 0, tileData.y or 0, tileData.z or 0)
            end)
            state.worldItemSquares[#state.worldItemSquares + 1] = {
                x = tileData.x or 0,
                y = tileData.y or 0,
                z = tileData.z or 0,
                expected = #tileData.worldItems,
                serverWorldItems = countWorldItems(sq),
            }
        end
    else
        state.failed = (state.failed or 0) + 1
    end
    return true
end

function AE_Import.finishPackage(state)
    if not state then return { success = false, error = "missing import state" } end
    processPendingContainers(state)
    -- After a package import the client may still have stale object ids for
    -- removed/rebuilt furniture and containers. Dirtying chunks here is safer
    -- than trying to send a generic sync packet for every object type; generic
    -- sync caused IsoDoor/SyncThumpable cast errors in B42.
    AE_Sa.call("dirtyAllChunks", nil, function()
        local c = getCell()
        if c.DirtyAllChunks then c:DirtyAllChunks()
        elseif c.setAllChunksDirty then c:setAllChunksDirty() end
    end)
    AE_Sa.call("isoRegionsReset", nil, function()
        if IsoRegions and IsoRegions.ResetAllDataDebug then IsoRegions.ResetAllDataDebug() end
    end)
    return packageResult(state)
end

function AE_Import.runContent(content, sourceName, options)
    AE_Sa.reset()
    resetImportStats()
    if not content or content == "" then return { success = false, error = "empty JSON" } end

    local payload, perr = AE_Json.decode(content)
    if not payload then return { success = false, error = "decode failed: " .. tostring(perr) } end
    return importPayload(payload, sourceName or "local copy", options)
end

function AE_Import.run(filename, options)
    local content, err = AE_File.read(filename)
    if not content then return { success = false, error = err or "no file" } end
    return AE_Import.runContent(content, filename, options)
end

return AE_Import

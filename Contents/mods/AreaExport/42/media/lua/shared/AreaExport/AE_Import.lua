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
]]

local AE_Sa       = require("AreaExport/AE_SafeAccess")
local AE_AttrMap  = require("AreaExport/AE_AttrMap")
local AE_Handlers = require("AreaExport/AE_Handlers")
local AE_Json     = require("AreaExport/AE_Json")
local AE_File     = require("AreaExport/AE_File")

local AE_Import = {}
local importStats = {}
local activeRules = {}
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

local function buildItem(itemData, container)
    if not itemData or not itemData.type then return nil end
    itemData = applyItemRule(itemData)
    if not itemData then return nil end
    importStats.itemsExpected = importStats.itemsExpected + 1

    -- Prefer the container API so the item is born inside that container and
    -- PZ registers ownership/persistence correctly. Creating first and moving
    -- later worked visually but could leave container state unsynced until reload.
    local item = AE_Sa.call("container.AddItemType", nil, function()
        if container and container.AddItem then return container:AddItem(itemData.type) end
        return nil
    end)
    if not item then
        item = AE_Sa.call("createItem", nil, function()
            return InventoryItemFactory and InventoryItemFactory.CreateItem(itemData.type)
        end)
    end
    if not item then
        importStats.itemsFailed = importStats.itemsFailed + 1
        return nil
    end

    -- apply optional attrs
    for _, attr in pairs(AE_AttrMap.item) do
        if attr.name ~= "type" and attr.write and itemData[attr.name] ~= nil then
            AE_Sa.write(item, attr, itemData[attr.name])
        end
    end

    if container and item:getContainer() ~= container then
        AE_Sa.call("container.AddItemObject", nil, function() container:AddItem(item) end)
    end
    if item:getContainer() == container then
        importStats.itemsAdded = importStats.itemsAdded + 1
    else
        importStats.itemsFailed = importStats.itemsFailed + 1
    end

    return item
end

local function buildContainer(target, contData)
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
    end)
    if contData.capacity and AE_AttrMap.container.capacity.write then
        AE_Sa.write(container, AE_AttrMap.container.capacity, contData.capacity)
    end
    if contData.items then
        for _, itemData in ipairs(contData.items) do
            buildItem(itemData, container)
        end
    end
    AE_Sa.call("container.sync", nil, function()
        if container.sendContentsToRemoteContainer then
            container:sendContentsToRemoteContainer()
        end
    end)
    AE_Sa.call("container.overlay", nil, function()
        if ItemPicker and ItemPicker.updateOverlaySprite then
            ItemPicker.updateOverlaySprite(container:getParent() or target)
        end
    end)
    AE_Sa.call("container.parentSync", nil, function()
        local parent = container:getParent() or target
        if parent.sendSyncEntity then parent:sendSyncEntity(nil) end
        if parent.transmitUpdatedSpriteToClients then parent:transmitUpdatedSpriteToClients() end
    end)
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
local function buildObject(sq, objData)
    local sprite = objData.sprite
    if not sprite then return nil end
    if objData.class == "IsoWindow" or objData.class == "IsoWindowFrame" then
        local obj = AE_Sa.call("buildWindowFrame", nil, function()
            local isoSpr = getSprite(sprite)
            if not isoSpr then return nil end
            local north = objData.north
            if north == nil then
                local props = isoSpr:getProperties()
                north = props and props:has(IsoFlagType.WindowN) or false
            end
            return _G.IsoWindowFrame.new(sq:getCell(), sq, isoSpr, north)
        end)
        if obj then
            sq:AddTileObject(obj)
            AE_Sa.call("obj.transmitAdd", nil, function()
                if sq.transmitAddObjectToSquare then sq:transmitAddObjectToSquare(obj, -1) end
            end)
            return obj
        end
    end
    -- Strategy 1: IsoThumpable for player builds (walls, doors, furniture)
    if objData.isPlayerBuild or objData.class == "IsoThumpable" or objData.class == "IsoDoor" then
        local obj = AE_Sa.call("buildThumpable", nil, function()
            local IsoSprite = _G.IsoSprite
            local isoSpr = IsoSprite.new()
            isoSpr:LoadFramesNoDirPageSimple(sprite)
            local IsoThumpable = _G.IsoThumpable
            local cell = sq:getCell()
            local t = IsoThumpable.new(cell, sq, sprite, false, nil)
            return t
        end)
        if obj then
            sq:AddTileObject(obj)
            AE_Sa.call("obj.transmitAdd", nil, function()
                if sq.transmitAddObjectToSquare then sq:transmitAddObjectToSquare(obj, -1) end
            end)
            return obj
        end
    end
    -- Strategy 2: plain IsoObject for static decoration
    local obj = AE_Sa.call("buildIsoObject", nil, function()
        local IsoObject = _G.IsoObject
        return IsoObject.new(sq:getCell(), sq, sprite)
    end)
    if obj then
        AE_Sa.call("addTileObject", nil, function() sq:AddTileObject(obj) end)
        AE_Sa.call("obj.transmitAdd", nil, function()
            if sq.transmitAddObjectToSquare then sq:transmitAddObjectToSquare(obj, -1) end
        end)
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

---
-- Remove all non-floor map objects from a square.
-- The floor is kept because replacing floor sprites cleanly is non-trivial
-- and usually the auto-generated floor is visually close.
-- Existing loose world items are intentionally preserved. Removing them from
-- Lua can leave stale server-side world item ids, which makes the visual item
-- remain on the ground but impossible to pick up afterwards.
---
local function clearSquareState(sq)
    local floor = AE_Sa.call("sq.getFloor", nil, function() return sq:getFloor() end)
    local hadWorldItems = hasWorldItems(sq)

    -- Collect removal list first - mutating the collection during iteration is undefined.
    local objs = AE_Sa.call("sq.objects", nil, function() return sq:getObjects() end)
    if objs then
        local toRemove = {}
        local n = AE_Sa.call("sq.objects.size", 0, function() return objs:size() end)
        for i = 0, n - 1 do
            local o = AE_Sa.call("sq.objects.get", nil, function() return objs:get(i) end)
            if o and o ~= floor then
                if not isWorldInventoryObject(o) then
                    toRemove[#toRemove + 1] = o
                end
            end
        end
        for _, o in ipairs(toRemove) do
            AE_Sa.call("sq.RemoveTileObject", nil, function()
                sq:RemoveTileObject(o)
                if sq.transmitRemoveItemFromSquare then sq:transmitRemoveItemFromSquare(o) end
            end)
        end
    end
    recalcSquare(sq)
    return hadWorldItems
end

local function rebuildTile(tileData, dx, dy, skipWorldItemImport)
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
                    local attrs = AE_Handlers.byClass[objData.class] or AE_Handlers.default
                    applyAttrs(obj, attrs, objData)
                    if objData.container then
                        buildContainer(obj, objData.container)
                    end
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
                    if sq then clearSquareState(sq) end
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

    local processed, failed = 0, 0
    local importsWorldItems = false
    if payload.tiles then
        for _, tileData in ipairs(payload.tiles) do
            if tileData.worldItems and #tileData.worldItems > 0 then
                importsWorldItems = true
            end
            if rebuildTile(tileData, dx, dy, skipWorldItemImport) then
                processed = processed + 1
            else
                failed = failed + 1
            end
        end
    end

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

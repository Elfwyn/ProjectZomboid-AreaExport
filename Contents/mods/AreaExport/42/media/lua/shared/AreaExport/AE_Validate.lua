--[[
    Area Export - Import validation / dry run.
    Reads export JSON without mutating the world and groups conflicts by type.

    The validation UI is a planning step, not a repair by itself. It scans the
    selected local export against the currently loaded mod set and creates grouped
    conflicts:
    - missing item types can be skipped, replaced, or converted to placeholders;
    - missing sprites can be skipped or mapped to a replacement sprite name;
    - unsupported object classes are reviewed/skipped because there is no generic
      safe constructor for every IsoObject subclass.

    Grouping is deliberate. Large area exports can contain thousands of items, so
    one rule per missing type is the only practical workflow.
]]

local AE_Json = require("AreaExport/AE_Json")
local AE_File = require("AreaExport/AE_File")
local AE_Sa   = require("AreaExport/AE_SafeAccess")

local AE_Validate = {}

local SUPPORTED_CLASSES = {
    IsoObject = true,
    IsoThumpable = true,
    IsoDoor = true,
    IsoWindow = true,
    IsoWindowFrame = true,
    IsoCurtain = true,
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
    IsoLightSwitch = true,
}

local DEFAULT_OBJECT_ACTIONS = {
    -- Legacy/bad exports may list loose ground items as ordinary objects. Current
    -- exports place them in tile.worldItems, so the safe default is to skip this
    -- object conflict rather than duplicating loose items during import.
    IsoWorldInventoryObject = "Skip",
}

local function ruleKey(kind, id)
    return tostring(kind or "Item") .. ":" .. tostring(id or "")
end

local function buildRuleMap(rules)
    local map = {}
    if type(rules) ~= "table" then return map end
    for _, rule in ipairs(rules) do
        if type(rule) == "table" and rule.kind and rule.id and rule.action then
            map[ruleKey(rule.kind, rule.id)] = rule
        end
    end
    return map
end

local function scriptItem(fullType)
    -- PZ has exposed item lookups through different globals across versions and
    -- contexts. Try all known paths so validation continues to work on clients,
    -- dedicated servers and future B42 point releases.
    if not fullType or fullType == "" then return nil end
    return AE_Sa.call("findItem.getScriptManager", nil, function()
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
    end)
end

local function itemExists(fullType)
    return scriptItem(fullType) ~= nil
end

local function spriteExists(spriteName)
    if not spriteName or spriteName == "" then return false end
    return AE_Sa.call("getSprite", nil, function()
        return getSprite and getSprite(spriteName) or nil
    end) ~= nil
end

local function inc(map, id, amount)
    if not id or id == "" then return end
    map[id] = (map[id] or 0) + (amount or 1)
end

local function conflictMessage(kind, id)
    if kind == "Item" then
        return "Missing item type. Choose Replace, Skip, or Placeholder before import if you want deterministic item handling."
    end
    if kind == "Sprite" then
        return "Sprite lookup warning. Use Original keeps the exported sprite name; replace or skip only when the target server really lacks this sprite."
    end
    if kind == "Object" and id == "IsoDoorMissingClosedSprite" then
        return "Incomplete legacy door data. Re-export with the current version when possible; otherwise review before import."
    end
    if kind == "Object" then
        return "Unsupported object class. Skip prevents the importer from rebuilding that object automatically."
    end
    return "Review this conflict before importing."
end

local function defaultConflictAction(kind, id, rule)
    if rule and rule.action then return rule.action end
    if kind == "Sprite" then return "Use Original" end
    if kind == "Object" and DEFAULT_OBJECT_ACTIONS[id] then return DEFAULT_OBJECT_ACTIONS[id] end
    return "Review"
end

local function addConflict(out, kind, id, count, rule, severity)
    -- The saved action shown in the list is the rule that import will apply.
    -- "Review" means no correction exists yet and the user should decide before
    -- importing if preserving that data matters.
    local action = defaultConflictAction(kind, id, rule)
    local replacement = rule and rule.replacement or nil
    out[#out + 1] = {
        kind = kind,
        id = id,
        count = count,
        action = action,
        replacement = replacement,
        severity = severity or (action == "Review" and "red" or "amber"),
        message = conflictMessage(kind, id),
    }
end

local function scanContainer(containerData, stats, missingItems)
    if not containerData or type(containerData.items) ~= "table" then return end
    for _, itemData in ipairs(containerData.items) do
        stats.totalItems = stats.totalItems + 1
        local fullType = itemData and itemData.type or nil
        if fullType and itemExists(fullType) then
            stats.okItems = stats.okItems + 1
        else
            inc(missingItems, fullType or "<missing item type>")
        end
    end
end

local function scanItemData(itemData, stats, missingItems)
    stats.totalItems = stats.totalItems + 1
    local fullType = itemData and itemData.type or nil
    if fullType and itemExists(fullType) then
        stats.okItems = stats.okItems + 1
    else
        inc(missingItems, fullType or "<missing item type>")
    end
end

local function newScanState(rules)
    -- This function must stay read-only. It intentionally never creates squares,
    -- objects or items, so admins can run Dry Run on a live target save without
    -- changing the map before they accept the conflict rules.
    return {
        stats = {
            totalItems = 0,
            okItems = 0,
            missingItems = 0,
            missingItemGroups = 0,
            missingSprites = 0,
            missingSpriteGroups = 0,
            unsupportedObjects = 0,
            unsupportedObjectGroups = 0,
            incompleteDoors = 0,
            incompleteDoorGroups = 0,
        },
        missingItems = {},
        missingSprites = {},
        unsupportedObjects = {},
        incompleteDoors = {},
        rules = rules,
        tilesScanned = 0,
    }
end

local function scanTile(state, tile)
    if type(tile) ~= "table" then return end
    local stats = state.stats
    state.tilesScanned = (state.tilesScanned or 0) + 1
    if tile.floor_sprite and not spriteExists(tile.floor_sprite) then
        inc(state.missingSprites, tile.floor_sprite)
    end
    for _, obj in ipairs(tile.objects or {}) do
        if obj.sprite and not spriteExists(obj.sprite) then
            inc(state.missingSprites, obj.sprite)
        end
        if obj.closedSprite and not spriteExists(obj.closedSprite) then
            inc(state.missingSprites, obj.closedSprite)
        end
        if obj.openSprite and not spriteExists(obj.openSprite) then
            inc(state.missingSprites, obj.openSprite)
        end
        local className = obj.class or "IsoObject"
        if not SUPPORTED_CLASSES[className] then
            inc(state.unsupportedObjects, className)
        end
        if className == "IsoDoor" and obj.isOpen == true and not obj.closedSprite then
            inc(state.incompleteDoors, "IsoDoorMissingClosedSprite")
        end
        scanContainer(obj.container, stats, state.missingItems)
    end
    for _, itemData in ipairs(tile.worldItems or {}) do
        scanItemData(itemData, stats, state.missingItems)
    end
end

local function finishScan(state)
    local stats = state.stats
    local conflicts = {}
    local ruleMap = buildRuleMap(state.rules)
    for id, count in pairs(state.missingItems) do
        stats.missingItems = stats.missingItems + count
        stats.missingItemGroups = stats.missingItemGroups + 1
        local rule = ruleMap[ruleKey("Item", id)]
        local severity = "red"
        if rule then
            if rule.action == "Skip" or rule.action == "Placeholder" then
                severity = "amber"
            elseif rule.action == "Replace" and itemExists(rule.replacement) then
                severity = "amber"
            end
        end
        addConflict(conflicts, "Item", id, count, rule, severity)
    end
    for id, count in pairs(state.missingSprites) do
        stats.missingSprites = stats.missingSprites + count
        stats.missingSpriteGroups = stats.missingSpriteGroups + 1
        local rule = ruleMap[ruleKey("Sprite", id)]
        local severity = "amber"
        if rule and rule.action == "Replace" and not spriteExists(rule.replacement) then severity = "red" end
        addConflict(conflicts, "Sprite", id, count, rule, severity)
    end
    for id, count in pairs(state.unsupportedObjects) do
        stats.unsupportedObjects = stats.unsupportedObjects + count
        stats.unsupportedObjectGroups = stats.unsupportedObjectGroups + 1
        local rule = ruleMap[ruleKey("Object", id)]
        local defaultAction = DEFAULT_OBJECT_ACTIONS[id]
        addConflict(conflicts, "Object", id, count, rule, (rule and rule.action == "Skip" or defaultAction == "Skip") and "amber" or "red")
    end
    for id, count in pairs(state.incompleteDoors) do
        stats.incompleteDoors = stats.incompleteDoors + count
        stats.incompleteDoorGroups = stats.incompleteDoorGroups + 1
        local rule = ruleMap[ruleKey("Object", id)]
        addConflict(conflicts, "Object", id, count, rule, "red")
    end

    table.sort(conflicts, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return tostring(a.id) < tostring(b.id)
    end)

    return {
        success = true,
        okItems = stats.okItems,
        totalItems = stats.totalItems,
        missingItems = stats.missingItems,
        missingItemGroups = stats.missingItemGroups,
        missingSprites = stats.missingSprites,
        missingSpriteGroups = stats.missingSpriteGroups,
        unsupportedObjects = stats.unsupportedObjects,
        unsupportedObjectGroups = stats.unsupportedObjectGroups,
        incompleteDoors = stats.incompleteDoors,
        incompleteDoorGroups = stats.incompleteDoorGroups,
        conflicts = conflicts,
        tilesScanned = state.tilesScanned or 0,
    }
end

local function scanPayload(payload, rules)
    local state = newScanState(rules)
    for _, tile in ipairs(payload.tiles or {}) do
        scanTile(state, tile)
    end
    return finishScan(state)
end

function AE_Validate.startPackage(rules)
    AE_Sa.reset()
    return newScanState(rules)
end

function AE_Validate.scanPackageLine(state, line)
    if not state then return false, "missing validation state" end
    if not line or line == "" then return true end
    local tile, err = AE_Json.decode(line)
    if not tile then return false, "tile decode failed: " .. tostring(err) end
    scanTile(state, tile)
    return true
end

function AE_Validate.finishPackage(state)
    if not state then return { success = false, error = "missing validation state" } end
    return finishScan(state)
end

function AE_Validate.runContent(content, rules)
    AE_Sa.reset()
    if not content or content == "" then return { success = false, error = "empty JSON" } end
    local payload, err = AE_Json.decode(content)
    if not payload then return { success = false, error = "decode failed: " .. tostring(err) } end
    if payload.format_version and payload.format_version > 1 then
        return { success = false, error = "unsupported format_version " .. tostring(payload.format_version) }
    end
    return scanPayload(payload, rules)
end

function AE_Validate.run(filename, rules)
    local content, err = AE_File.read(filename)
    if not content then return { success = false, error = err or "no file" } end
    return AE_Validate.runContent(content, rules)
end

function AE_Validate.searchItems(query, limit)
    -- Replacement search is backed by the game's script item database. This lets
    -- users map an old/missing item type to any currently available type without
    -- hardcoding knowledge of base game or mod item IDs in Area Export.
    query = string.lower(tostring(query or ""))
    limit = tonumber(limit or 40) or 40
    local result = {}
    local allItems = AE_Sa.call("getAllItems", nil, function()
        return getAllItems and getAllItems() or nil
    end)
    if not allItems then return { success = false, error = "item database unavailable" } end
    local size = AE_Sa.call("items.size", 0, function() return allItems:size() end)
    for i = 0, size - 1 do
        local item = AE_Sa.call("items.get", nil, function() return allItems:get(i) end)
        if item and not (item.getObsolete and item:getObsolete()) and not (item.isHidden and item:isHidden()) then
            local fullType = AE_Sa.call("item.full", "", function() return item:getFullName() end)
            local display = AE_Sa.call("item.display", fullType, function() return item:getDisplayName() end)
            local haystack = string.lower(tostring(fullType) .. " " .. tostring(display))
            if query == "" or string.find(haystack, query, 1, true) then
                result[#result + 1] = { type = fullType, name = display }
                if #result >= limit then break end
            end
        end
    end
    return { success = true, items = result, query = query }
end

return AE_Validate

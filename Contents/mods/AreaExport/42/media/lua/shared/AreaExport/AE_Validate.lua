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
    IsoGenerator = true,
    IsoStove = true,
    IsoMannequin = true,
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

local function addConflict(out, kind, id, count, rule, severity)
    -- The saved action shown in the list is the rule that import will apply.
    -- "Review" means no correction exists yet and the user should decide before
    -- importing if preserving that data matters.
    local action = rule and rule.action or (kind == "Object" and DEFAULT_OBJECT_ACTIONS[id]) or "Review"
    local replacement = rule and rule.replacement or nil
    out[#out + 1] = {
        kind = kind,
        id = id,
        count = count,
        action = action,
        replacement = replacement,
        severity = severity or (action == "Review" and "red" or "amber"),
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

local function scanPayload(payload, rules)
    -- This function must stay read-only. It intentionally never creates squares,
    -- objects or items, so admins can run Dry Run on a live target save without
    -- changing the map before they accept the conflict rules.
    local stats = {
        totalItems = 0,
        okItems = 0,
        missingItems = 0,
        missingItemGroups = 0,
        missingSprites = 0,
        missingSpriteGroups = 0,
        unsupportedObjects = 0,
        unsupportedObjectGroups = 0,
    }
    local missingItems, missingSprites, unsupportedObjects = {}, {}, {}

    for _, tile in ipairs(payload.tiles or {}) do
        if tile.floor_sprite and not spriteExists(tile.floor_sprite) then
            inc(missingSprites, tile.floor_sprite)
        end
        for _, obj in ipairs(tile.objects or {}) do
            if obj.sprite and not spriteExists(obj.sprite) then
                inc(missingSprites, obj.sprite)
            end
            local className = obj.class or "IsoObject"
            if not SUPPORTED_CLASSES[className] then
                inc(unsupportedObjects, className)
            end
            scanContainer(obj.container, stats, missingItems)
        end
        for _, itemData in ipairs(tile.worldItems or {}) do
            scanItemData(itemData, stats, missingItems)
        end
    end

    local conflicts = {}
    local ruleMap = buildRuleMap(rules)
    for id, count in pairs(missingItems) do
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
    for id, count in pairs(missingSprites) do
        stats.missingSprites = stats.missingSprites + count
        stats.missingSpriteGroups = stats.missingSpriteGroups + 1
        local rule = ruleMap[ruleKey("Sprite", id)]
        local severity = "amber"
        if rule and rule.action == "Replace" and not spriteExists(rule.replacement) then severity = "red" end
        addConflict(conflicts, "Sprite", id, count, rule, severity)
    end
    for id, count in pairs(unsupportedObjects) do
        stats.unsupportedObjects = stats.unsupportedObjects + count
        stats.unsupportedObjectGroups = stats.unsupportedObjectGroups + 1
        local rule = ruleMap[ruleKey("Object", id)]
        local defaultAction = DEFAULT_OBJECT_ACTIONS[id]
        addConflict(conflicts, "Object", id, count, rule, (rule and rule.action == "Skip" or defaultAction == "Skip") and "amber" or "red")
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
        conflicts = conflicts,
    }
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

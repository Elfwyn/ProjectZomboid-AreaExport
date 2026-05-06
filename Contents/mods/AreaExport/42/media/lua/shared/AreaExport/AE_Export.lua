--[[
    Area Export - Export
    Iterates squares within the picked circle, serializes each tile + objects + items
    to a Lua table, and encodes it as JSON.

    Design notes for maintainers:
    - Saved coordinates are absolute world coordinates. Import restores the area
      at the same location, using the exported center/radius as the authoritative
      footprint.
    - Loose ground items are stored in tile.worldItems, not tile.objects. PZ keeps
      IsoWorldInventoryObject in several object collections, and treating it like
      normal furniture caused duplicate/ghost pickups in B42 multiplayer tests.
    - Floorless upper-level squares are written explicitly. This preserves player
      made stair/roof openings that otherwise look like ordinary generated floors
      after a fresh save is imported.
]]

local AE_Sa       = require("AreaExport/AE_SafeAccess")
local AE_AttrMap  = require("AreaExport/AE_AttrMap")
local AE_Handlers = require("AreaExport/AE_Handlers")
local AE_Json     = require("AreaExport/AE_Json")
local AE_File     = require("AreaExport/AE_File")

local AE_Export = {}

local FORMAT_VERSION = 1
local STREAM_FORMAT_VERSION = 2

local function countFootprintPositions(radius)
    local count = 0
    local r2 = radius * radius
    for dy = -radius, radius do
        for dx = -radius, radius do
            if dx * dx + dy * dy <= r2 then count = count + 1 end
        end
    end
    return count * 8
end

local function serializeAttrs(target, attrs)
    local data = {}
    for _, attr in ipairs(attrs) do
        local v = AE_Sa.read(target, attr)
        if v ~= nil or not attr.optional then
            data[attr.name] = v
        end
    end
    return data
end

local function serializeItem(item)
    local data = {}
    for _, attr in pairs(AE_AttrMap.item) do
        local v = AE_Sa.read(item, attr)
        if v ~= nil or not attr.optional then
            data[attr.name] = v
        end
    end
    local xRot = AE_Sa.call("item.worldXRotation", nil, function()
        return item.getWorldXRotation and item:getWorldXRotation() or nil
    end)
    local yRot = AE_Sa.call("item.worldYRotation", nil, function()
        return item.getWorldYRotation and item:getWorldYRotation() or nil
    end)
    local zRot = AE_Sa.call("item.worldZRotation", nil, function()
        return item.getWorldZRotation and item:getWorldZRotation() or nil
    end)
    if xRot ~= nil then data.worldXRotation = xRot end
    if yRot ~= nil then data.worldYRotation = yRot end
    if zRot ~= nil then data.worldZRotation = zRot end
    return data
end

local function serializeWorldItem(worldObj)
    -- Store only item data plus placement offsets exposed by PZ. Import uses
    -- AddWorldInventoryItem and avoids deeper mutation because server/client item
    -- identity is fragile for loose world items in B42 multiplayer.
    local item = AE_Sa.call("worldItem.item", nil, function()
        if worldObj.getItem then return worldObj:getItem() end
        if worldObj.getWorldItem then return worldObj:getWorldItem() end
        return nil
    end)
    if not item then return nil end
    local data = serializeItem(item)
    data.offX = AE_Sa.call("worldItem.offX", 0, function()
        return worldObj.getOffX and worldObj:getOffX() or 0
    end)
    data.offY = AE_Sa.call("worldItem.offY", 0, function()
        return worldObj.getOffY and worldObj:getOffY() or 0
    end)
    data.offZ = AE_Sa.call("worldItem.offZ", 0, function()
        return worldObj.getOffZ and worldObj:getOffZ() or 0
    end)
    data.extendedPlacement = AE_Sa.call("worldItem.extendedPlacement", nil, function()
        return worldObj.isExtendedPlacement and worldObj:isExtendedPlacement() or nil
    end)
    return data
end

local function isWorldInventoryObject(obj)
    return AE_Sa.call("object.isWorldInventory", false, function()
        return instanceof and instanceof(obj, "IsoWorldInventoryObject") or false
    end)
end

local function serializeContainer(container)
    if not container then return nil end
    local data = serializeAttrs(container, {AE_AttrMap.container.capacity, AE_AttrMap.container.type})
    local items = AE_Sa.call("container.items", nil, function()
        return container:getItems()
    end)
    if items then
        local arr = {}
        local n = AE_Sa.call("container.items.size", 0, function() return items:size() end)
        for i = 0, n - 1 do
            local it = AE_Sa.call("container.items.get", nil, function() return items:get(i) end)
            if it then arr[#arr + 1] = serializeItem(it) end
        end
        data.items = arr
    end
    return data
end

local function serializeObject(obj)
    local attrs, className = AE_Handlers.forObject(obj)
    local data = serializeAttrs(obj, attrs)
    data.class = className
    local container = AE_Sa.call("object.container", nil, function()
        return obj.getContainer and obj:getContainer() or nil
    end)
    if container then
        data.container = serializeContainer(container)
    end
    return data
end

local function serializeTile(sq)
    local objects = AE_Sa.call("sq.objects", nil, function() return sq:getObjects() end)
    local floor = AE_Sa.call("sq.floor", nil, function() return sq:getFloor() end)
    local objArr = {}
    local worldItems = {}
    if objects then
        local n = AE_Sa.call("sq.objects.size", 0, function() return objects:size() end)
        for i = 0, n - 1 do
            local o = AE_Sa.call("sq.objects.get", nil, function() return objects:get(i) end)
            if o and o ~= floor then
                local attrs, className = AE_Handlers.forObject(o)
                -- World inventory objects are visual/physical wrappers around
                -- loose items. Keep them out of the normal object rebuild path so
                -- validation can also treat old exports with such objects as a
                -- known, skippable conflict.
                if isWorldInventoryObject(o) or className == "IsoWorldInventoryObject" then
                    local worldItem = serializeWorldItem(o)
                    if worldItem then worldItems[#worldItems + 1] = worldItem end
                else
                    objArr[#objArr + 1] = serializeObject(o)
                end
            end
        end
    end
    local floor_sprite = AE_Sa.read(sq, AE_AttrMap.tile.floor_sprite)
    local data = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), hasFloor = floor ~= nil }
    if floor_sprite then data.floor_sprite = floor_sprite end
    if #objArr > 0 then data.objects = objArr end
    if #worldItems > 0 then data.worldItems = worldItems end
    return data
end

function AE_Export.build(centerX, centerY, radius)
    AE_Sa.reset()
    local cell = getCell()
    if not cell then return { success = false, error = "no cell loaded" } end

    local r2 = radius * radius
    local tiles = {}
    local objCount = 0

    for dy = -radius, radius do
        for dx = -radius, radius do
            if dx*dx + dy*dy <= r2 then
                for z = 0, 7 do
                    local sq = cell:getGridSquare(centerX + dx, centerY + dy, z)
                    if sq then
                        local t = serializeTile(sq)
                        -- Include explicit floorless upper-level squares so stair/roof
                        -- openings survive import instead of being filled by mapgen.
                        if t.floor_sprite or t.objects or t.worldItems or (t.z > 0 and t.hasFloor == false) then
                            tiles[#tiles + 1] = t
                            objCount = objCount + (t.objects and #t.objects or 0)
                        end
                    end
                end
            end
        end
    end

    local metadata = {
        exported_at = getTimestampMs and getTimestampMs() or 0,
        exporter_version = "1.0.0",
        -- Import ignores the player's current position and uses this center plus
        -- radius to clear/rebuild the original map footprint.
        center = { x = centerX, y = centerY },
        radius = radius,
    }
    local payload = {
        format_version = FORMAT_VERSION,
        metadata = metadata,
        tiles = tiles,
    }

    local json = AE_Json.encode(payload)
    local summary = AE_Sa.summary()
    if summary ~= "" then print("[AreaExport] export " .. summary) end

    return {
        success = true,
        content = json,
        bytes = #json,
        tileCount = #tiles,
        objectCount = objCount,
        metadata = metadata,
    }
end

function AE_Export.startStream(centerX, centerY, radius)
    AE_Sa.reset()
    local cell = getCell()
    if not cell then return nil, "no cell loaded" end

    radius = math.floor(tonumber(radius or 0) or 0)
    local metadata = {
        exported_at = getTimestampMs and getTimestampMs() or 0,
        exporter_version = "1.0.0",
        center = { x = centerX, y = centerY },
        radius = radius,
    }

    return {
        cell = cell,
        centerX = centerX,
        centerY = centerY,
        radius = radius,
        r2 = radius * radius,
        dx = -radius,
        dy = -radius,
        z = 0,
        done = false,
        tileCount = 0,
        objectCount = 0,
        visitedPositions = 0,
        totalPositions = countFootprintPositions(radius),
        bytes = 0,
        metadata = metadata,
        format_version = STREAM_FORMAT_VERSION,
    }
end

local function advanceStreamCursor(state)
    state.z = (state.z or 0) + 1
    if state.z <= 7 then return end
    state.z = 0
    state.dx = (state.dx or -state.radius) + 1
    if state.dx <= state.radius then return end
    state.dx = -state.radius
    state.dy = (state.dy or -state.radius) + 1
    if state.dy > state.radius then state.done = true end
end

function AE_Export.nextStreamLines(state, maxLines, maxBytes, maxVisited)
    if not state or state.done then return {}, true end
    maxLines = math.max(1, tonumber(maxLines or 100) or 100)
    maxBytes = math.max(1024, tonumber(maxBytes or 65536) or 65536)
    maxVisited = math.max(64, tonumber(maxVisited or 2000) or 2000)
    local lines = {}
    local bytes = 0
    local visited = 0

    while not state.done and #lines < maxLines and visited < maxVisited do
        local dx, dy, z = state.dx, state.dy, state.z
        visited = visited + 1
        if dx * dx + dy * dy <= state.r2 then
            local sq = state.cell:getGridSquare(state.centerX + dx, state.centerY + dy, z)
            if sq then
                local t = serializeTile(sq)
                if t.floor_sprite or t.objects or t.worldItems or (t.z > 0 and t.hasFloor == false) then
                    local line = AE_Json.encode(t)
                    if #lines > 0 and bytes + #line > maxBytes then
                        return lines, false
                    end
                    lines[#lines + 1] = line
                    bytes = bytes + #line + 1
                    state.tileCount = state.tileCount + 1
                    state.objectCount = state.objectCount + (t.objects and #t.objects or 0)
                    state.bytes = state.bytes + #line + 1
                end
            end
            state.visitedPositions = (state.visitedPositions or 0) + 1
        end
        advanceStreamCursor(state)
    end

    return lines, state.done
end

function AE_Export.streamManifest(state, filename)
    return {
        format_version = STREAM_FORMAT_VERSION,
        kind = "AreaExportPackage",
        filename = filename,
        metadata = state and state.metadata or {},
        tileCount = state and state.tileCount or 0,
        objectCount = state and state.objectCount or 0,
        visitedPositions = state and state.visitedPositions or 0,
        totalPositions = state and state.totalPositions or 0,
        bytes = state and state.bytes or 0,
        files = {
            tiles = tostring(filename or "export") .. ".tiles.jsonl",
            manifest = tostring(filename or "export") .. ".manifest.json",
        },
    }
end

function AE_Export.run(centerX, centerY, radius, filename)
    local built = AE_Export.build(centerX, centerY, radius)
    if not built.success then return built end

    local ok, path = AE_File.write(filename, built.content)
    if not ok then return { success = false, error = path } end

    print(string.format("[AreaExport] exported %d tiles, %d objects, %d bytes -> %s",
        built.tileCount or 0, built.objectCount or 0, built.bytes or 0, path))

    return {
        success = true,
        path = path,
        bytes = built.bytes,
        tileCount = built.tileCount,
        objectCount = built.objectCount,
        metadata = built.metadata,
    }
end

return AE_Export

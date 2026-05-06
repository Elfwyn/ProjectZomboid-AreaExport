--[[
    Area Export - Server Command Handler (Pure Lua)
    All scan/export/import logic lives in shared/AreaExport/* modules.
    This file validates admin access, dispatches commands from the client and
    wraps long text transfers.

    Security/operations notes:
    - Every command requires Admin access. The UI button can appear client-side,
      but the server is the trust boundary.
    - Local-copy import/validation uploads are chunked and capped to avoid a
      malicious or accidental huge command consuming server memory.
    - World-item reconcile is read-only on the server. It reports authoritative
      counts so the client can remove only visual ghosts that no longer exist
      server-side.
]]

local AE_Sa     = require("AreaExport/AE_SafeAccess")
local AE_Json   = require("AreaExport/AE_Json")
local AE_Export = require("AreaExport/AE_Export")
local AE_Import = require("AreaExport/AE_Import")
local AE_Validate = require("AreaExport/AE_Validate")
local AE_File   = require("AreaExport/AE_File")

local MODULE = "AreaExport"
local HANDLED = "__AreaExport_Handled__"
local TEXT_CHUNK_SIZE = 6000
-- Server-to-client file downloads are intentionally slow. Large exports are an
-- admin/off-hours workflow, and throttling avoids flooding the client command
-- queue immediately after the expensive server-side export finished.
local SERVER_TEXT_CHUNKS_PER_TICK = 2
-- 64 MB is deliberately generous for large radius exports but finite. The server
-- stores upload chunks in memory until Finish, so this protects public servers
-- from unbounded admin mistakes or crafted client commands.
local MAX_TEXT_TRANSFER_BYTES = 64 * 1024 * 1024
local MAX_TEXT_TRANSFER_CHUNKS = math.ceil(MAX_TEXT_TRANSFER_BYTES / TEXT_CHUNK_SIZE) + 1
local importTextSessions = {}
local validateTextSessions = {}
local outboundTextStreams = {}

local function parseRadius(value)
    local n = tonumber(value) or 10
    if n < 1 then n = 1 end
    return math.floor(n)
end

local function respond(player, cmd, jsonString)
    sendServerCommand(player, MODULE, cmd .. "Result", { json = jsonString })
end

local function encodeResponse(t)
    return AE_Json.encode(t or { success = false, error = "empty response" })
end

local function decodeRules(args)
    -- Validation/import rules are sent as JSON inside the Start command. Keeping
    -- them with the transfer session guarantees the final import uses the same
    -- decisions the admin saw during Dry Run.
    local json = args and args.rulesJson or nil
    if not json or json == "" then return {} end
    local rules = AE_Json.decode(tostring(json))
    if type(rules) ~= "table" then return {} end
    return rules
end

local function isAdmin(player)
    -- Do not rely on client UI visibility for security. Dedicated servers may
    -- receive commands from a modified client, so the server checks access level
    -- before every handler.
    if not player then return false end
    local access = AE_Sa.call("player.accessLevel", "", function()
        return player.getAccessLevel and player:getAccessLevel() or ""
    end)
    return string.lower(tostring(access or "")) == "admin"
end

local dispatch = {}

local function makeSessionId()
    return tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" ..
        tostring(ZombRand and ZombRand(1000000) or 0)
end

local function queueOutboundTextStream(player, commandPrefix, sessionId, filename, content, extra)
    table.insert(outboundTextStreams, {
        player = player,
        commandPrefix = commandPrefix,
        sessionId = sessionId,
        filename = filename,
        content = content or "",
        totalChunks = math.ceil(#(content or "") / TEXT_CHUNK_SIZE),
        sent = 0,
        extra = extra or {},
    })
end

local function processOutboundTextStreams()
    if #outboundTextStreams == 0 then return end

    local budget = SERVER_TEXT_CHUNKS_PER_TICK
    local i = 1
    while i <= #outboundTextStreams and budget > 0 do
        local stream = outboundTextStreams[i]
        local nextIndex = stream.sent + 1

        if nextIndex <= stream.totalChunks then
            local startAt = ((nextIndex - 1) * TEXT_CHUNK_SIZE) + 1
            respond(stream.player, stream.commandPrefix .. "Chunk", encodeResponse({
                success = true,
                sessionId = stream.sessionId,
                filename = stream.filename,
                index = nextIndex,
                totalChunks = stream.totalChunks,
                chunk = string.sub(stream.content, startAt, startAt + TEXT_CHUNK_SIZE - 1),
            }))
            stream.sent = nextIndex
            budget = budget - 1
            i = i + 1
        else
            respond(stream.player, stream.commandPrefix .. "Done", encodeResponse({
                success = true,
                sessionId = stream.sessionId,
                filename = stream.filename,
                bytes = #stream.content,
                totalChunks = stream.totalChunks,
                tileCount = stream.extra.tileCount,
                objectCount = stream.extra.objectCount,
                metadata = stream.extra.metadata,
            }))
            table.remove(outboundTextStreams, i)
        end
    end
end

local function streamText(player, commandPrefix, sessionId, filename, content, extra)
    -- Server-to-client JSON stream used by "Export Local Copy". It avoids asking
    -- admins to fetch files from the server filesystem after export. Start is
    -- sent immediately so the UI can open its local writer; chunks are queued
    -- and delivered gradually on later ticks.
    content = content or ""
    extra = extra or {}
    local totalChunks = math.ceil(#content / TEXT_CHUNK_SIZE)
    respond(player, commandPrefix .. "Start", encodeResponse({
        success = true,
        sessionId = sessionId,
        filename = filename,
        bytes = #content,
        totalChunks = totalChunks,
        tileCount = extra.tileCount,
        objectCount = extra.objectCount,
        metadata = extra.metadata,
    }))
    queueOutboundTextStream(player, commandPrefix, sessionId, filename, content, extra)
end

local function scanAreaLua(centerX, centerY, radius)
    local cell = getCell()
    if not cell then return { success = false, error = "no cell loaded" } end
    local r2 = radius * radius
    local squareCount, floorCount, objectCount = 0, 0, 0
    local containerCount, worldItemCount, playerBuildCount = 0, 0, 0
    local totalItemsInContainers = 0

    for dy = -radius, radius do
        for dx = -radius, radius do
            if dx*dx + dy*dy <= r2 then
                for z = 0, 7 do
                    local sq = cell:getGridSquare(centerX + dx, centerY + dy, z)
                    if sq then
                        squareCount = squareCount + 1
                        if AE_Sa.call("hasFloor", false, function() return sq:getFloor() ~= nil end) then
                            floorCount = floorCount + 1
                        end
                        local objs = AE_Sa.call("objects", nil, function() return sq:getObjects() end)
                        if objs then
                            local n = AE_Sa.call("objects.size", 0, function() return objs:size() end)
                            for i = 0, n - 1 do
                                local o = AE_Sa.call("objects.get", nil, function() return objs:get(i) end)
                                if o then
                                    objectCount = objectCount + 1
                                    if AE_Sa.call("isPB", false, function()
                                        return o.isPlayerBuild and o:isPlayerBuild() or false
                                    end) then
                                        playerBuildCount = playerBuildCount + 1
                                    end
                                    local cont = AE_Sa.call("getCont", nil, function()
                                        return o.getContainer and o:getContainer() or nil
                                    end)
                                    if cont then
                                        containerCount = containerCount + 1
                                        local items = AE_Sa.call("cont.items", nil, function()
                                            return cont:getItems()
                                        end)
                                        if items then
                                            totalItemsInContainers = totalItemsInContainers +
                                                AE_Sa.call("items.size", 0, function() return items:size() end)
                                        end
                                    end
                                end
                            end
                        end
                        local wItems = AE_Sa.call("worldObjs", nil, function()
                            return sq.getWorldObjects and sq:getWorldObjects()
                        end)
                        if wItems then
                            worldItemCount = worldItemCount +
                                AE_Sa.call("worldObjs.size", 0, function() return wItems:size() end)
                        end
                    end
                end
            end
        end
    end

    return {
        success = true,
        squareCount = squareCount, floorCount = floorCount, objectCount = objectCount,
        containerCount = containerCount, worldItemCount = worldItemCount,
        playerBuildCount = playerBuildCount, totalItemsInContainers = totalItemsInContainers,
        backend = "lua",
    }
end

local function isWorldInventoryObject(obj)
    if not obj then return false end
    return AE_Sa.call("worldItem.isWorldInventory", false, function()
        if instanceof and instanceof(obj, "IsoWorldInventoryObject") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoWorldInventoryObject", 1, true) ~= nil
    end)
end

local function inspectSquareWorldItems(sq)
    -- Inspect both object collections PZ may use for loose ground items. During
    -- testing one collection could be stale on the client while the server had
    -- already removed the authoritative item after pickup.
    local result = {
        objectCount = 0,
        worldInventoryObjects = 0,
        worldObjectCount = 0,
        itemBackRefs = 0,
        firstType = nil,
        firstObject = nil,
    }

    local objects = AE_Sa.call("worldItem.objects", nil, function() return sq:getObjects() end)
    if objects then
        local n = AE_Sa.call("worldItem.objects.size", 0, function() return objects:size() end)
        result.objectCount = n
        for i = 0, n - 1 do
            local obj = AE_Sa.call("worldItem.objects.get", nil, function() return objects:get(i) end)
            if isWorldInventoryObject(obj) then
                result.worldInventoryObjects = result.worldInventoryObjects + 1
                if not result.firstObject then result.firstObject = tostring(obj) end
                local item = AE_Sa.call("worldItem.worldObj.item", nil, function()
                    if obj.getItem then return obj:getItem() end
                    if obj.getWorldItem then return obj:getWorldItem() end
                    return nil
                end)
                if item then
                    result.itemBackRefs = result.itemBackRefs + 1
                    if not result.firstType then
                        result.firstType = AE_Sa.call("worldItem.worldObj.itemType", nil, function()
                            return item.getFullType and item:getFullType() or tostring(item)
                        end)
                    end
                end
            end
        end
    end

    local worldObjects = AE_Sa.call("worldItem.worldObjects", nil, function()
        return sq.getWorldObjects and sq:getWorldObjects()
    end)
    if worldObjects then
        result.worldObjectCount = AE_Sa.call("worldItem.worldObjects.size", 0, function() return worldObjects:size() end)
    end

    return result
end

local function getSquareFromClientArgs(args)
    local cell = getCell()
    if not cell then return nil, "no cell" end
    local x = tonumber(args and args.x)
    local y = tonumber(args and args.y)
    local z = tonumber(args and args.z) or 0
    if not x or not y then return nil, "missing client square coordinates" end
    local sq = AE_Sa.call("worldItem.clientArgs.getSquare", nil, function()
        return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    end)
    if not sq then return nil, "server square is not loaded" end
    return sq, nil, math.floor(x), math.floor(y), math.floor(z)
end

function dispatch.scan(player, args)
    AE_Sa.reset()
    local result = scanAreaLua(
        tonumber(args.centerX) or 0,
        tonumber(args.centerY) or 0,
        parseRadius(args.radius))
    return AE_Json.encode(result)
end

function dispatch.reconcileWorldItemSquare(player, args)
    -- Read-only compare endpoint. The server never deletes here; it only tells
    -- the client whether client-visible world items are ghosts and may be removed
    -- locally.
    AE_Sa.reset()
    local sq, err, x, y, z = getSquareFromClientArgs(args)
    if not sq then return AE_Json.encode({ success = false, error = err }) end

    local state = inspectSquareWorldItems(sq)
    local clientWorldInv = tonumber(args.clientWorldInv or 0) or 0
    local clientWorldObjects = tonumber(args.clientWorldObjects or 0) or 0
    local serverWorldInv = state.worldInventoryObjects or 0
    local serverWorldObjects = state.worldObjectCount or 0
    local verdict = "MATCH"
    if clientWorldInv ~= serverWorldInv or clientWorldObjects ~= serverWorldObjects then
        verdict = "MISMATCH"
    end
    local repairClient = verdict == "MISMATCH" and serverWorldInv == 0 and serverWorldObjects == 0 and (clientWorldInv > 0 or clientWorldObjects > 0)
    if verdict == "MISMATCH" then
        print(string.format("[AreaExport] reconcile %s square=%d/%d/%d client=%d/%d server=%d/%d repairClient=%s",
            verdict, x, y, z, clientWorldInv, clientWorldObjects, serverWorldInv, serverWorldObjects, tostring(repairClient)))
    end
    return AE_Json.encode({
        success = true,
        verdict = verdict,
        x = x, y = y, z = z,
        clientWorldInv = clientWorldInv,
        clientWorldObjects = clientWorldObjects,
        serverWorldInv = serverWorldInv,
        serverWorldObjects = serverWorldObjects,
        repairClient = repairClient,
    })
end

dispatch.reconcileworlditemsquare = dispatch.reconcileWorldItemSquare

function dispatch.export(player, args)
    local filename = tostring(args.filename or "export")
    local result = AE_Export.run(
        tonumber(args.centerX) or 0,
        tonumber(args.centerY) or 0,
        parseRadius(args.radius),
        filename)
    if type(result) == "table" then
        result.filename = filename
    end
    return AE_Json.encode(result)
end

function dispatch.exportLocal(player, args)
    -- Preferred public workflow: create the export on the source server, then
    -- stream it into a client-local file that can be selected on any target save.
    local filename = tostring(args.filename or "export")
    local built = AE_Export.build(
        tonumber(args.centerX) or 0,
        tonumber(args.centerY) or 0,
        parseRadius(args.radius))
    if not built.success then
        respond(player, "exportTextStart", encodeResponse(built))
        return HANDLED
    end
    local sessionId = makeSessionId()
    streamText(player, "exportText", sessionId, filename, built.content, {
        tileCount = built.tileCount,
        objectCount = built.objectCount,
        metadata = built.metadata,
    })
    print(string.format("[AreaExport] streamed local export %d tiles, %d objects, %d bytes -> client:%s",
        built.tileCount or 0, built.objectCount or 0, built.bytes or 0, filename))
    return HANDLED
end

function dispatch.import(player, args)
    local result = AE_Import.run(
        tostring(args.filename or ""),
        { rules = decodeRules(args) })
    return AE_Json.encode(result)
end

function dispatch.validate(player, args)
    local result = AE_Validate.run(
        tostring(args.filename or ""),
        decodeRules(args))
    return AE_Json.encode(result)
end

function dispatch.searchItems(player, args)
    local result = AE_Validate.searchItems(
        tostring(args.query or ""),
        tonumber(args.limit or 40) or 40)
    return AE_Json.encode(result)
end

function dispatch.exportText(player, args)
    local filename = tostring(args.filename or "")
    local content, err = AE_File.read(filename)
    if not content then
        respond(player, "exportTextStart", encodeResponse({ success = false, error = err or "could not read export" }))
        return HANDLED
    end

    local sessionId = makeSessionId()
    streamText(player, "exportText", sessionId, filename, content, {})
    return HANDLED
end

function dispatch.importTextStart(player, args)
    -- Start/chunk/finish sessions prevent one giant client command and give the
    -- UI progress information for very large local exports.
    local sessionId = tostring(args.sessionId or "")
    if sessionId == "" then
        return encodeResponse({ success = false, error = "missing import text session id" })
    end
    local totalChunks = tonumber(args.totalChunks or 0) or 0
    local bytes = tonumber(args.bytes or 0) or 0
    if totalChunks < 1 or totalChunks > MAX_TEXT_TRANSFER_CHUNKS or bytes < 1 or bytes > MAX_TEXT_TRANSFER_BYTES then
        return encodeResponse({ success = false, error = "local copy is too large or invalid" })
    end
    importTextSessions[sessionId] = {
        totalChunks = totalChunks,
        bytes = bytes,
        rules = decodeRules(args),
        chunks = {},
    }
    return encodeResponse({ success = true, sessionId = sessionId })
end

function dispatch.importTextChunk(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = importTextSessions[sessionId]
    if not session then
        return encodeResponse({ success = false, error = "unknown import text session" })
    end
    local index = tonumber(args.index or 0) or 0
    if index < 1 then
        return encodeResponse({ success = false, error = "invalid import text chunk index" })
    end
    if index > session.totalChunks then
        return encodeResponse({ success = false, error = "import text chunk index exceeds transfer size" })
    end
    session.chunks[index] = tostring(args.chunk or "")
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        index = index,
        totalChunks = session.totalChunks,
        bytes = session.bytes,
    })
end

function dispatch.importTextFinish(player, args)
    -- Only concatenate once all chunks are present. Missing chunks are treated as
    -- transfer failure, not partial imports.
    local sessionId = tostring(args.sessionId or "")
    local session = importTextSessions[sessionId]
    if not session then
        return encodeResponse({ success = false, error = "unknown import text session" })
    end

    for i = 1, session.totalChunks do
        if session.chunks[i] == nil then
            importTextSessions[sessionId] = nil
            return encodeResponse({ success = false, error = "missing local copy chunk " .. tostring(i) })
        end
    end

    local content = table.concat(session.chunks, "")
    importTextSessions[sessionId] = nil
    local result = AE_Import.runContent(content, "local copy", { rules = session.rules })
    result.importedFromText = true
    return AE_Json.encode(result)
end

function dispatch.validateTextStart(player, args)
    -- Dry Run uses the same upload guardrails as import because it receives the
    -- same potentially multi-megabyte local export JSON.
    local sessionId = tostring(args.sessionId or "")
    if sessionId == "" then
        return encodeResponse({ success = false, error = "missing validate text session id" })
    end
    local totalChunks = tonumber(args.totalChunks or 0) or 0
    local bytes = tonumber(args.bytes or 0) or 0
    if totalChunks < 1 or totalChunks > MAX_TEXT_TRANSFER_CHUNKS or bytes < 1 or bytes > MAX_TEXT_TRANSFER_BYTES then
        return encodeResponse({ success = false, error = "local copy is too large or invalid" })
    end
    validateTextSessions[sessionId] = {
        totalChunks = totalChunks,
        bytes = bytes,
        rules = decodeRules(args),
        chunks = {},
    }
    return encodeResponse({ success = true, sessionId = sessionId })
end

function dispatch.validateTextChunk(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = validateTextSessions[sessionId]
    if not session then
        return encodeResponse({ success = false, error = "unknown validate text session" })
    end
    local index = tonumber(args.index or 0) or 0
    if index < 1 then
        return encodeResponse({ success = false, error = "invalid validate text chunk index" })
    end
    if index > session.totalChunks then
        return encodeResponse({ success = false, error = "validate text chunk index exceeds transfer size" })
    end
    session.chunks[index] = tostring(args.chunk or "")
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        index = index,
        totalChunks = session.totalChunks,
        bytes = session.bytes,
    })
end

function dispatch.validateTextFinish(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = validateTextSessions[sessionId]
    if not session then
        return encodeResponse({ success = false, error = "unknown validate text session" })
    end
    for i = 1, session.totalChunks do
        if session.chunks[i] == nil then
            validateTextSessions[sessionId] = nil
            return encodeResponse({ success = false, error = "missing validate local copy chunk " .. tostring(i) })
        end
    end
    local content = table.concat(session.chunks, "")
    validateTextSessions[sessionId] = nil
    local result = AE_Validate.runContent(content, session.rules)
    result.validatedFromText = true
    return AE_Json.encode(result)
end

function dispatch.listFiles(player, args)
    -- Directory listing is handled client-side through the local export index.
    return AE_Json.encode({ success = true, files = {} })
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if not isAdmin(player) then
        respond(player, command, AE_Json.encode({ success = false, error = "Admin access required" }))
        return
    end
    local handler = dispatch[command]
    if not handler then
        respond(player, command, AE_Json.encode({ success = false, error = "Unknown command: " .. tostring(command) }))
        return
    end
    local ok, result = pcall(handler, player, args or {})
    if not ok then
        print("[AreaExport] Server handler error: " .. tostring(result))
        respond(player, command, AE_Json.encode({ success = false, error = tostring(result) }))
        return
    end
    if result == HANDLED then return end
    respond(player, command, result or AE_Json.encode({ success = false, error = "empty response" }))
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(processOutboundTextStreams)

print("[AreaExport] Server command handler registered (pure-Lua backend)")

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
local PACKAGE_EXPORT_LINES_PER_TICK = 25
local PACKAGE_CHUNK_BYTE_TARGET = 4 * 1024
local PACKAGE_EXPORT_VISIT_BUDGET = 2000
local PACKAGE_IMPORT_CLEAR_BUDGET = 2000
local PACKAGE_IMPORT_LINES_PER_TICK = 25
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
local outboundPackageExports = {}
local validatePackageSessions = {}
local importPackageSessions = {}

local function parseRadius(value)
    local n = tonumber(value) or 10
    if n < 1 then n = 1 end
    return math.floor(n)
end

local function respond(player, cmd, jsonString)
    sendServerCommand(player, MODULE, cmd .. "Result", { json = jsonString })
end

local function respondRaw(player, cmd, fields)
    sendServerCommand(player, MODULE, cmd .. "Result", fields or {})
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

local function nowMs()
    return getTimestampMs and getTimestampMs() or ((os.time and os.time() or 0) * 1000)
end

local function packageTempPath(sessionId)
    local clean = string.gsub(tostring(sessionId or "session"), "[^%w_%-]", "_")
    return "AreaExport/package_import_" .. clean .. ".tiles.jsonl"
end

local function decodeJsonArg(args, key)
    local json = args and args[key] or nil
    if not json or json == "" then return nil end
    local decoded = AE_Json.decode(tostring(json))
    if type(decoded) ~= "table" then return nil end
    return decoded
end

local function eachLine(text, fn)
    text = tostring(text or "")
    for line in string.gmatch(text, "([^\n]+)") do
        fn(line)
    end
end

local function queueTextParts(queue, text)
    text = tostring(text or "")
    local i = 1
    while i <= #text do
        queue[#queue + 1] = string.sub(text, i, i + PACKAGE_CHUNK_BYTE_TARGET - 1)
        i = i + PACKAGE_CHUNK_BYTE_TARGET
    end
end

local function scanCompleteLines(session, chunk, fn)
    local text = tostring(chunk or "")
    if text == "" then return true end
    text = tostring(session.pendingText or "") .. text
    local start = 1
    while true do
        local nl = string.find(text, "\n", start, true)
        if not nl then break end
        local line = string.sub(text, start, nl - 1)
        if line ~= "" then
            local ok, err = fn(line)
            if not ok then
                session.pendingText = nil
                return false, err
            end
        end
        start = nl + 1
    end
    session.pendingText = string.sub(text, start)
    return true
end

local function flushPendingLine(session, fn)
    local line = session and session.pendingText or nil
    session.pendingText = nil
    if line and line ~= "" then
        return fn(line)
    end
    return true
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

local function exportProgressFields(stream)
    local state = stream and stream.state or {}
    local total = tonumber(state.totalPositions or 0) or 0
    local visited = tonumber(state.visitedPositions or 0) or 0
    local percent = total > 0 and math.floor((visited * 100) / total) or 0
    if percent > 100 then percent = 100 end
    return {
        success = true,
        sessionId = stream and stream.sessionId or nil,
        filename = stream and stream.filename or nil,
        transferParts = stream and (stream.chunkIndex or 0) or 0,
        visitedPositions = visited,
        totalPositions = total,
        progressPercent = percent,
        bytes = state.bytes or 0,
        tileCount = state.tileCount or 0,
        objectCount = state.objectCount or 0,
    }
end

local function percentDone(done, total)
    done = tonumber(done or 0) or 0
    total = tonumber(total or 0) or 0
    if total <= 0 then return 0 end
    local percent = math.floor((done * 100) / total)
    if percent < 0 then return 0 end
    if percent > 100 then return 100 end
    return percent
end

local function importProgressFields(sessionId, session, phase)
    local state = session and session.state or {}
    phase = phase or (session and session.phase) or "uploading"
    local totalLines = tonumber(state.totalTiles or (session and session.totalLines) or 0) or 0
    if totalLines <= 0 then
        totalLines = tonumber(session and session.uploadLines or 0) or 0
    end
    local clearVisited = tonumber(state.clearVisited or 0) or 0
    local clearTotal = tonumber(state.clearTotal or 0) or 0
    local importedLines = tonumber(session and session.importedLines or session and session.lines or 0) or 0
    local progress = 0
    if phase == "clearing" then
        progress = percentDone(clearVisited, clearTotal)
    elseif phase == "importing" then
        progress = percentDone(importedLines, totalLines)
    else
        progress = percentDone(session and session.uploadLines or session and session.lines or 0, totalLines)
    end
    return {
        success = true,
        sessionId = sessionId,
        phase = phase,
        clearVisited = clearVisited,
        clearTotal = clearTotal,
        lines = importedLines,
        importedLines = importedLines,
        totalLines = totalLines,
        progressPercent = progress,
    }
end

local function sendImportProgress(sessionId, session, phase, force)
    local now = nowMs()
    if not force and session.lastProgressAt and now - session.lastProgressAt < 1000 then return end
    session.lastProgressAt = now
    respond(session.player, "importPackageProgress", encodeResponse(importProgressFields(sessionId, session, phase)))
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

local function processOutboundPackageExports()
    if #outboundPackageExports == 0 then return end
    local i = 1
    while i <= #outboundPackageExports do
        local stream = outboundPackageExports[i]
        stream.pendingParts = stream.pendingParts or {}
        if #stream.pendingParts == 0 then
            local lines, done = AE_Export.nextStreamLines(stream.state, PACKAGE_EXPORT_LINES_PER_TICK, PACKAGE_CHUNK_BYTE_TARGET, PACKAGE_EXPORT_VISIT_BUDGET)
            if #lines > 0 then
                queueTextParts(stream.pendingParts, table.concat(lines, "\n") .. "\n")
            elseif done then
                local manifest = AE_Export.streamManifest(stream.state, stream.filename)
                respond(stream.player, "exportPackageDone", encodeResponse({
                    success = true,
                    sessionId = stream.sessionId,
                    filename = stream.filename,
                    manifest = manifest,
                    manifestJson = AE_Json.encode(manifest),
                    totalChunks = stream.chunkIndex or 0,
                    bytes = manifest.bytes or 0,
                    tileCount = manifest.tileCount or 0,
                    objectCount = manifest.objectCount or 0,
                    visitedPositions = manifest.visitedPositions or 0,
                    totalPositions = manifest.totalPositions or 0,
                    progressPercent = 100,
                    metadata = manifest.metadata,
                }))
                table.remove(outboundPackageExports, i)
                stream = nil
            else
                local now = nowMs()
                if not stream.lastProgressAt or now - stream.lastProgressAt >= 1000 then
                    stream.lastProgressAt = now
                    respond(stream.player, "exportPackageProgress", encodeResponse(exportProgressFields(stream)))
                end
            end
        end
        if stream and #stream.pendingParts > 0 then
            stream.chunkIndex = (stream.chunkIndex or 0) + 1
            local chunk = table.remove(stream.pendingParts, 1)
            respondRaw(stream.player, "exportPackageChunk", {
                success = true,
                sessionId = stream.sessionId,
                filename = stream.filename,
                index = stream.chunkIndex,
                chunk = chunk,
                bytes = stream.state.bytes,
                tileCount = stream.state.tileCount,
                objectCount = stream.state.objectCount,
                visitedPositions = stream.state.visitedPositions or 0,
                totalPositions = stream.state.totalPositions or 0,
                progressPercent = exportProgressFields(stream).progressPercent,
            })
            i = i + 1
        elseif stream then
            i = i + 1
        end
    end
end

local function processImportPackageSessions()
    for sessionId, session in pairs(importPackageSessions) do
        if session.phase == "clearing" then
            local done, err = AE_Import.clearPackageStep(session.state, PACKAGE_IMPORT_CLEAR_BUDGET)
            if err then
                respond(session.player, "importPackageFinish", encodeResponse({
                    success = false,
                    sessionId = sessionId,
                    error = err,
                }))
                importPackageSessions[sessionId] = nil
            elseif done then
                sendImportProgress(sessionId, session, "clearing", true)
                local reader = AE_Sa.call("importPackage.getFileReader", nil, function()
                    return getFileReader(session.tempPath, false)
                end)
                if not reader then
                    respond(session.player, "importPackageFinish", encodeResponse({
                        success = false,
                        sessionId = sessionId,
                        error = "could not reopen uploaded package",
                    }))
                    importPackageSessions[sessionId] = nil
                else
                    session.reader = reader
                    session.phase = "importing"
                    session.importedLines = 0
                    session.lines = 0
                    sendImportProgress(sessionId, session, "importing", true)
                end
            else
                sendImportProgress(sessionId, session, "clearing", false)
            end
        elseif session.phase == "importing" then
            local count = 0
            local ok, err = true, nil
            while count < PACKAGE_IMPORT_LINES_PER_TICK do
                local line = AE_Sa.call("importPackage.readLine", nil, function()
                    return session.reader:readLine()
                end)
                if not line then break end
                if line ~= "" then
                    ok, err = AE_Import.importPackageLine(session.state, line)
                    if not ok then break end
                    session.importedLines = (session.importedLines or 0) + 1
                    session.lines = session.importedLines
                end
                count = count + 1
            end
            if not ok then
                AE_Sa.call("importPackage.closeReader", nil, function() session.reader:close() end)
                respond(session.player, "importPackageFinish", encodeResponse({
                    success = false,
                    sessionId = sessionId,
                    error = err or "package import failed",
                }))
                importPackageSessions[sessionId] = nil
            elseif count == 0 then
                AE_Sa.call("importPackage.closeReader", nil, function() session.reader:close() end)
                local result = AE_Import.finishPackage(session.state)
                result.importedFromPackage = true
                result.sessionId = sessionId
                result.lines = session.importedLines or session.lines or 0
                result.totalLines = session.totalLines or result.totalTiles or 0
                respond(session.player, "importPackageFinish", AE_Json.encode(result))
                importPackageSessions[sessionId] = nil
            else
                sendImportProgress(sessionId, session, "importing", false)
            end
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
    return AE_Json.encode({
        success = false,
        error = "legacy export command is disabled; use streaming package export",
    })
end

function dispatch.exportPackage(player, args)
    local filename = tostring(args.filename or "export")
    local stream, err = AE_Export.startStream(
        tonumber(args.centerX) or 0,
        tonumber(args.centerY) or 0,
        parseRadius(args.radius))
    if not stream then
        respond(player, "exportPackageStart", encodeResponse({ success = false, error = err or "could not start export" }))
        return HANDLED
    end
    local sessionId = makeSessionId()
    outboundPackageExports[#outboundPackageExports + 1] = {
        player = player,
        filename = filename,
        sessionId = sessionId,
        state = stream,
        chunkIndex = 0,
    }
    respond(player, "exportPackageStart", encodeResponse({
        success = true,
        sessionId = sessionId,
        filename = filename,
        metadata = stream.metadata,
        format_version = stream.format_version,
        visitedPositions = stream.visitedPositions or 0,
        totalPositions = stream.totalPositions or 0,
        progressPercent = 0,
    }))
    return HANDLED
end

function dispatch.exportLocal(player, args)
    respond(player, "exportTextStart", encodeResponse({
        success = false,
        error = "legacy local-copy export is disabled; use streaming package export",
    }))
    return HANDLED
end

function dispatch.import(player, args)
    return AE_Json.encode({
        success = false,
        error = "legacy server-file import is disabled; use local package import",
    })
end

function dispatch.validate(player, args)
    return AE_Json.encode({
        success = false,
        error = "legacy server-file validation is disabled; use local package validation",
    })
end

function dispatch.searchItems(player, args)
    local result = AE_Validate.searchItems(
        tostring(args.query or ""),
        tonumber(args.limit or 40) or 40)
    return AE_Json.encode(result)
end

function dispatch.exportText(player, args)
    respond(player, "exportTextStart", encodeResponse({
        success = false,
        error = "legacy server JSON download is disabled; export creates a local package directly",
    }))
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
    local result = AE_Import.runContent(content, "local copy", { rules = session.rules, actor = player })
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

function dispatch.validatePackageStart(player, args)
    local sessionId = tostring(args.sessionId or "")
    if sessionId == "" then return encodeResponse({ success = false, error = "missing validate package session id" }) end
    local manifest = decodeJsonArg(args, "manifestJson") or {}
    validatePackageSessions[sessionId] = {
        manifest = manifest,
        state = AE_Validate.startPackage(decodeRules(args)),
        chunks = 0,
        lines = 0,
        pendingText = "",
    }
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        totalLines = tonumber(manifest.tileCount or manifest.tiles or 0) or 0,
        progressPercent = 0,
    })
end

function dispatch.validatePackageChunk(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = validatePackageSessions[sessionId]
    if not session then return encodeResponse({ success = false, error = "unknown validate package session" }) end
    local ok, err = scanCompleteLines(session, args.chunk, function(line)
        session.lines = (session.lines or 0) + 1
        return AE_Validate.scanPackageLine(session.state, line)
    end)
    if not ok then
        validatePackageSessions[sessionId] = nil
        return encodeResponse({ success = false, error = err or "validate package chunk failed" })
    end
    session.chunks = (session.chunks or 0) + 1
    local totalLines = tonumber(session.manifest and (session.manifest.tileCount or session.manifest.tiles) or 0) or 0
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        index = tonumber(args.index or session.chunks) or session.chunks,
        lines = session.lines,
        totalLines = totalLines,
        progressPercent = percentDone(session.lines, totalLines),
    })
end

function dispatch.validatePackageFinish(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = validatePackageSessions[sessionId]
    if not session then return encodeResponse({ success = false, error = "unknown validate package session" }) end
    local ok, err = flushPendingLine(session, function(line)
        session.lines = (session.lines or 0) + 1
        return AE_Validate.scanPackageLine(session.state, line)
    end)
    if not ok then
        validatePackageSessions[sessionId] = nil
        return encodeResponse({ success = false, sessionId = sessionId, error = err or "validate package finish failed" })
    end
    validatePackageSessions[sessionId] = nil
    local result = AE_Validate.finishPackage(session.state)
    result.validatedFromPackage = true
    result.totalLines = tonumber(session.manifest and (session.manifest.tileCount or session.manifest.tiles) or 0) or 0
    result.progressPercent = 100
    return AE_Json.encode(result)
end

function dispatch.importPackageStart(player, args)
    local sessionId = tostring(args.sessionId or "")
    if sessionId == "" then return encodeResponse({ success = false, error = "missing import package session id" }) end
    local manifest = decodeJsonArg(args, "manifestJson") or {}
    local tempPath = packageTempPath(sessionId)
    local writer = AE_Sa.call("importPackage.getFileWriter", nil, function()
        return getFileWriter(tempPath, true, false)
    end)
    if not writer then return encodeResponse({ success = false, error = "could not open server package buffer" }) end
    importPackageSessions[sessionId] = {
        player = player,
        manifest = manifest,
        rules = decodeRules(args),
        writer = writer,
        tempPath = tempPath,
        phase = "uploading",
        chunks = 0,
        lines = 0,
        uploadLines = 0,
        importedLines = 0,
        totalLines = tonumber(manifest.tileCount or manifest.tiles or 0) or 0,
        pendingText = "",
    }
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        phase = "upload",
        totalLines = tonumber(manifest.tileCount or manifest.tiles or 0) or 0,
        progressPercent = 0,
    })
end

function dispatch.importPackageChunk(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = importPackageSessions[sessionId]
    if not session then return encodeResponse({ success = false, error = "unknown import package session" }) end
    if session.phase ~= "uploading" then
        return encodeResponse({ success = false, error = "import package upload is already closed" })
    end
    local chunk = tostring(args.chunk or "")
    local ok, err = pcall(function()
        session.writer:write(chunk)
    end)
    if not ok then
        AE_Sa.call("importPackage.closeWriter", nil, function() session.writer:close() end)
        importPackageSessions[sessionId] = nil
        return encodeResponse({ success = false, error = err or "could not write uploaded package" })
    end
    scanCompleteLines(session, chunk, function(_line)
        session.uploadLines = (session.uploadLines or 0) + 1
        session.lines = session.uploadLines
        return true
    end)
    session.chunks = (session.chunks or 0) + 1
    return encodeResponse({
        success = true,
        sessionId = sessionId,
        index = tonumber(args.index or session.chunks) or session.chunks,
        lines = session.uploadLines or session.lines,
        totalLines = session.totalLines or 0,
        progressPercent = percentDone(session.uploadLines or session.lines, session.totalLines),
    })
end

function dispatch.importPackageFinish(player, args)
    local sessionId = tostring(args.sessionId or "")
    local session = importPackageSessions[sessionId]
    if not session then return encodeResponse({ success = false, error = "unknown import package session" }) end
    if session.phase ~= "uploading" then return HANDLED end
    flushPendingLine(session, function(_line)
        session.uploadLines = (session.uploadLines or 0) + 1
        session.lines = session.uploadLines
        return true
    end)
    AE_Sa.call("importPackage.closeWriter", nil, function() session.writer:close() end)
    session.writer = nil
    local state, err = AE_Import.startPackage(session.manifest, { rules = session.rules, actor = player })
    if not state then
        importPackageSessions[sessionId] = nil
        respond(player, "importPackageFinish", encodeResponse({ success = false, sessionId = sessionId, error = err or "could not start package import" }))
        return HANDLED
    end
    session.state = state
    session.phase = "clearing"
    session.totalLines = tonumber(state.totalTiles or session.totalLines or session.uploadLines or 0) or 0
    session.importedLines = 0
    session.lines = 0
    sendImportProgress(sessionId, session, "clearing", true)
    return HANDLED
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
Events.OnTick.Add(processOutboundPackageExports)
Events.OnTick.Add(processImportPackageSessions)

print("[AreaExport] Server command handler registered (pure-Lua backend)")

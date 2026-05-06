--[[
    Area Export - Server Response Handler
    Receives OnServerCommand, parses JSON payload, and forwards results to the
    currently open dialog.

    This file intentionally stays thin. Server commands can complete in multiple
    phases (text transfer start/chunk/finish, export stream chunks, reconcile
    checks), but all UI state lives in AE_MainDialog.lua so response handling does
    not duplicate layout or workflow decisions.
]]

local AE_Json = require "AreaExport/AE_Json"
local AE_Globals = require "AreaExport/AE_Globals"

local MODULE = "AreaExport"

local function getDialog()
    return _G.AE_MainDialog and _G.AE_MainDialog.instance or nil
end

local function parseResult(args)
    -- Most responses are JSON encoded. Large package chunks are sent as raw
    -- fields so tile JSON does not get escaped into a much larger JSON string.
    if not args then
        return { success = false, error = "empty response" }
    end
    if not args.json then
        return args
    end
    local parsed, err = AE_Json.decode(args.json)
    if not parsed then
        return { success = false, error = "JSON parse failed: " .. tostring(err) }
    end
    return parsed
end

local function handleScan(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setScanResult then
        dlg:setScanResult(r)
        if dlg.statusLabel then dlg.statusLabel:setName("") end
        print("[AreaExport] scan result handled by main dialog")
        return
    end
    if dlg.statusLabel then dlg.statusLabel:setName("") end  -- clear "Scanning..."
    if not r.success then
        if dlg.statsLabel then dlg.statsLabel:setName("Error: " .. tostring(r.error or "unknown")) end
        print("[AreaExport] scan error from server: " .. tostring(r.error))
        return
    end
    local s = string.format(
        "Map tiles: %d  Map objects: %d  Containers: %d  Container items: %d  Loose floor items: %d  Player-built: %d",
        r.squareCount or 0, r.objectCount or 0, r.containerCount or 0,
        r.totalItemsInContainers or 0, r.worldItemCount or 0, r.playerBuildCount or 0)
    if dlg.statsLabel and not dlg.setScanResult then
        dlg.statsLabel:setName(s)
    elseif dlg.statsLabel then
        dlg.statsLabel:setName(string.format("Preview complete. World items: %d  Player-built: %d",
            r.worldItemCount or 0, r.playerBuildCount or 0))
    end
    print("[AreaExport] scan result: " .. s)
end

local function handleExport(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setExportResult then
        dlg:setExportResult(r)
        return
    end
    if not r.success then
        if dlg.statusLabel then dlg.statusLabel:setName("Export failed: " .. tostring(r.error or "unknown")) end
        return
    end
    if dlg.statusLabel and not dlg.setExportResult then
        dlg.statusLabel:setName(string.format("Exported %d tiles, %d objects, %d bytes -> %s",
            r.tileCount or 0, r.objectCount or 0, r.bytes or 0,
            tostring(r.path or r.filepath or "?")))
    end
    print("[AreaExport] export: " .. tostring(r.path) .. " (" .. tostring(r.bytes) .. " bytes)")
end

local function handleImport(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setImportResult then
        dlg:setImportResult(r)
        return
    end
    if not r.success then
        if dlg.importStatusLabel then dlg.importStatusLabel:setName("Import failed: " .. tostring(r.error or "unknown")) end
        return
    end
    if dlg.importStatusLabel and not dlg.setImportResult then
        dlg.importStatusLabel:setName(string.format("Imported %d squares (%d failed), items %d/%d",
            r.squaresProcessed or 0, r.squaresFailed or 0,
            r.itemsAdded or 0, r.itemsExpected or 0))
    end
    print(string.format("[AreaExport] import result: squares=%d failed=%d containers=%d missing=%d items=%d/%d itemFailed=%d skipped=%d replaced=%d placeholders=%d",
        r.squaresProcessed or 0, r.squaresFailed or 0,
        r.containersSeen or 0, r.containersMissing or 0,
        r.itemsAdded or 0, r.itemsExpected or 0, r.itemsFailed or 0,
        r.itemsSkipped or 0, r.itemsReplaced or 0, r.itemsPlaceholder or 0))
end

local function handleExportTextStart(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.startExportText then dlg:startExportText(r) end
end

local function handleExportTextChunk(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.addExportTextChunk then dlg:addExportTextChunk(r) end
end

local function handleExportTextDone(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.finishExportText then dlg:finishExportText(r) end
end

local function handleExportPackageStart(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.startExportPackage then dlg:startExportPackage(r) end
end

local function handleExportPackageChunk(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.addExportPackageChunk then dlg:addExportPackageChunk(r) end
end

local function handleExportPackageProgress(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.updateExportPackageProgress then dlg:updateExportPackageProgress(r) end
end

local function handleExportPackageDone(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.finishExportPackage then dlg:finishExportPackage(r) end
end

local function handleListFiles(r)
    local dlg = getDialog(); if not dlg then return end
    if not r.success then
        if dlg.importFileListLabel then dlg.importFileListLabel:setName("Error: " .. tostring(r.error)) end
        return
    end
    AE_Globals.availableFiles = r.files or {}
    if dlg.refreshFileList then dlg:refreshFileList() end
end

local function handleValidate(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setValidationResult then dlg:setValidationResult(r) end
end

local function handleTextTransferStart(prefix, r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onTextTransferStart then dlg:onTextTransferStart(prefix, r) end
end

local function handleTextTransferChunk(prefix, r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onTextTransferChunk then dlg:onTextTransferChunk(prefix, r) end
end

local function handlePackageTransferStart(prefix, r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onPackageTransferStart then dlg:onPackageTransferStart(prefix, r) end
end

local function handlePackageTransferChunk(prefix, r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onPackageTransferChunk then dlg:onPackageTransferChunk(prefix, r) end
end

local function handleImportPackageReady(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onImportPackageReady then dlg:onImportPackageReady(r) end
end

local function handleImportPackageProgress(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.onImportPackageProgress then dlg:onImportPackageProgress(r) end
end

local function handleSearchItems(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setReplacementResults then dlg:setReplacementResults(r) end
end

local function handleWorldItemReconcile(r)
    local dlg = getDialog(); if not dlg then return end
    if dlg.setWorldItemReconcileResult then dlg:setWorldItemReconcileResult(r) end
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    local r = parseResult(args)
    -- Both spellings are accepted for reconcile because early local test builds
    -- accidentally lowercased the command name on one path. Keeping the alias is
    -- harmless and avoids breaking anyone who tested that build.
    if command == "scanResult"       then handleScan(r)
    elseif command == "exportResult" then handleExport(r)
    elseif command == "importResult" then handleImport(r)
    elseif command == "importTextStartResult" then handleTextTransferStart("importText", r)
    elseif command == "importTextChunkResult" then handleTextTransferChunk("importText", r)
    elseif command == "importTextFinishResult" then handleImport(r)
    elseif command == "exportTextStartResult" then handleExportTextStart(r)
    elseif command == "exportTextChunkResult" then handleExportTextChunk(r)
    elseif command == "exportTextDoneResult" then handleExportTextDone(r)
    elseif command == "exportPackageStartResult" then handleExportPackageStart(r)
    elseif command == "exportPackageChunkResult" then handleExportPackageChunk(r)
    elseif command == "exportPackageProgressResult" then handleExportPackageProgress(r)
    elseif command == "exportPackageDoneResult" then handleExportPackageDone(r)
    elseif command == "listFilesResult" then handleListFiles(r)
    elseif command == "validateResult" then handleValidate(r)
    elseif command == "validateTextStartResult" then handleTextTransferStart("validateText", r)
    elseif command == "validateTextChunkResult" then handleTextTransferChunk("validateText", r)
    elseif command == "validateTextFinishResult" then handleValidate(r)
    elseif command == "validatePackageStartResult" then handlePackageTransferStart("validatePackage", r)
    elseif command == "validatePackageChunkResult" then handlePackageTransferChunk("validatePackage", r)
    elseif command == "validatePackageFinishResult" then handleValidate(r)
    elseif command == "importPackageStartResult" then handlePackageTransferStart("importPackage", r)
    elseif command == "importPackageReadyResult" then handleImportPackageReady(r)
    elseif command == "importPackageProgressResult" then handleImportPackageProgress(r)
    elseif command == "importPackageChunkResult" then handlePackageTransferChunk("importPackage", r)
    elseif command == "importPackageFinishResult" then handleImport(r)
    elseif command == "searchItemsResult" then handleSearchItems(r)
    elseif command == "reconcileWorldItemSquareResult" then handleWorldItemReconcile(r)
    elseif command == "reconcileworlditemsquareResult" then handleWorldItemReconcile(r)
    end
end

Events.OnServerCommand.Add(onServerCommand)
print("[AreaExport] Server response handler registered")

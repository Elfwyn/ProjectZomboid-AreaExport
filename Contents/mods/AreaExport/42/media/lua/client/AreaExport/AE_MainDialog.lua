--[[
    Area Export - Main Dialog
    Tabbed admin UI for export, import, validation and help.

    UX decisions captured here:
    - The mod uses a local-client package workflow. Export streams tile JSON lines
      from server to client and writes AreaExportClient/*.tiles.jsonl plus a small
      *.manifest.json. The list UI reads only metadata, never the multi-megabyte
      tile stream.
    - Dry Run and Import stream package lines back to the server in bounded
      commands. Import first uploads the complete package into a temporary server
      buffer, then clears/rebuilds over later ticks so a failed upload does not
      leave a half-cleared target footprint.
    - After imports with loose world items, the dialog starts a reconcile monitor
      that compares client-visible ground items with server-authoritative state and
      removes only client-side ghosts.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTickBox"
require "ISUI/ISRichTextPanel"

local AE_Constants = require("AE_Constants")
local AE_Globals = require("AreaExport/AE_Globals")
local AE_TilePicker = require("AreaExport/AE_TilePicker")
local AE_Json = require("AreaExport/AE_Json")

AE_MainDialog = ISCollapsableWindow:derive("AE_MainDialog")

local ICON_PATH = "media/ui/AreaExport/icons/ae_icon_%s_128.png"
local ICON_CACHE = {}
local JSON_CHUNK_SIZE = 6000
-- Client-local save area for portable exports. This is intentionally outside the
-- server-side save directory so the same file can be imported on another server
-- without manual server file access.
local CLIENT_TRANSFER_DIR = "AreaExportClient/"
local CLIENT_TRANSFER_INDEX = CLIENT_TRANSFER_DIR .. "index.json"
local WINDOW_W = 980
local WINDOW_H = 620
local EXPORT_LEFT_TEXT_W = 304
local EXPORT_RIGHT_TEXT_W = 360
local IMPORT_LEFT_TEXT_W = 388
local IMPORT_RIGHT_TEXT_W = 450
local VALIDATE_STATUS_W = 520
local VALIDATE_RULE_W = 326
local TEXT_CHUNKS_PER_UPDATE = 16
local PACKAGE_LINES_PER_UPDATE = 25
local PACKAGE_CHUNK_BYTE_TARGET = 4 * 1024
local LEGACY_LARGE_FILE_LIMIT = 3 * 1024 * 1024

local THEME = {
    bg = {r=0.06, g=0.07, b=0.08, a=0.94},
    bg2 = {r=0.09, g=0.10, b=0.11, a=0.96},
    panel = {r=0.12, g=0.13, b=0.14, a=0.92},
    panel2 = {r=0.16, g=0.17, b=0.18, a=0.88},
    border = {r=0.35, g=0.38, b=0.38, a=0.55},
    borderHot = {r=0.90, g=0.70, b=0.22, a=0.85},
    text = {r=0.88, g=0.90, b=0.88, a=1.00},
    muted = {r=0.58, g=0.62, b=0.62, a=1.00},
    green = {r=0.28, g=0.72, b=0.42, a=1.00},
    amber = {r=0.92, g=0.66, b=0.24, a=1.00},
    red = {r=0.86, g=0.28, b=0.24, a=1.00},
    blue = {r=0.28, g=0.56, b=0.76, a=1.00},
}

local function applyButtonStyle(btn, mode)
    btn.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=THEME.border.a}
    btn.backgroundColor = {r=0.10, g=0.11, b=0.12, a=0.90}
    btn.backgroundColorMouseOver = {r=0.20, g=0.22, b=0.23, a=1.00}
    btn.textColor = {r=THEME.text.r, g=THEME.text.g, b=THEME.text.b, a=1.00}
    if mode == "primary" then
        btn.borderColor = {r=THEME.green.r, g=THEME.green.g, b=THEME.green.b, a=0.90}
        btn.backgroundColor = {r=0.10, g=0.20, b=0.14, a=0.95}
        btn.backgroundColorMouseOver = {r=0.16, g=0.32, b=0.20, a=1.00}
    elseif mode == "warning" then
        btn.borderColor = {r=THEME.amber.r, g=THEME.amber.g, b=THEME.amber.b, a=0.90}
        btn.backgroundColor = {r=0.22, g=0.16, b=0.07, a=0.95}
        btn.backgroundColorMouseOver = {r=0.34, g=0.24, b=0.10, a=1.00}
    elseif mode == "danger" then
        btn.borderColor = {r=THEME.red.r, g=THEME.red.g, b=THEME.red.b, a=0.90}
        btn.backgroundColor = {r=0.22, g=0.08, b=0.08, a=0.95}
        btn.backgroundColorMouseOver = {r=0.35, g=0.10, b=0.10, a=1.00}
    end
    btn:setDisplayBackground(true)
end

local function getIcon(name)
    if not name then return nil end
    if ICON_CACHE[name] ~= nil then return ICON_CACHE[name] end
    ICON_CACHE[name] = getTexture(string.format(ICON_PATH, name))
    return ICON_CACHE[name]
end

local function applyButtonIcon(btn, iconName, size)
    local tex = getIcon(iconName)
    if not tex then return end
    btn.aeIconTexture = tex
    btn.aeIconSize = size or 16
    btn.iconTexture = nil
end

local function renderButton(btn)
    ISButton.render(btn)
    if not btn.aeIconTexture then return end
    local h = btn.height or 24
    local size = math.min(btn.aeIconSize or 16, math.max(10, h - 8))
    local x = 8
    local y = math.floor((h - size) / 2)
    local alpha = btn.enable == false and 0.35 or 1.0
    btn:drawTextureScaled(btn.aeIconTexture, x, y, size, size, alpha, 1, 1, 1)
end

local function applyEntryStyle(entry)
    entry.backgroundColor = {r=0.04, g=0.05, b=0.055, a=0.95}
    entry.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=0.80}
end

local function makeLabel(x, y, text, font, color)
    color = color or THEME.text
    return ISLabel:new(x, y, 18, text, color.r, color.g, color.b, color.a, font or UIFont.Small, true)
end

local function measureText(font, text)
    return getTextManager():MeasureStringX(font or UIFont.Small, tostring(text or ""))
end

local function truncateText(font, text, maxWidth)
    text = tostring(text or "")
    if measureText(font, text) <= maxWidth then return text end
    local suffix = "..."
    local limit = math.max(1, maxWidth - measureText(font, suffix))
    while #text > 1 and measureText(font, text) > limit do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. suffix
end

local function setClippedLabel(label, text, maxWidth, font)
    if not label then return end
    if maxWidth then
        label:setName(truncateText(font or UIFont.Small, text or "", maxWidth))
    else
        label:setName(tostring(text or ""))
    end
end

local function splitChunks(text, size)
    local chunks = {}
    text = text or ""
    size = size or JSON_CHUNK_SIZE
    local len = #text
    if len == 0 then return chunks end
    for i = 1, len, size do
        chunks[#chunks + 1] = string.sub(text, i, i + size - 1)
    end
    return chunks
end

local function nowMs()
    return getTimestampMs and getTimestampMs() or ((os.time and os.time() or 0) * 1000)
end

local function elapsedSeconds(startMs)
    return math.max(0, math.floor((nowMs() - (startMs or nowMs())) / 1000))
end

local function formatKb(bytes)
    return tostring(math.floor(((tonumber(bytes) or 0) + 1023) / 1024)) .. " KB"
end

local function clampPercent(value)
    local n = tonumber(value or 0) or 0
    if n < 0 then return 0 end
    if n > 100 then return 100 end
    return math.floor(n)
end

local function timestampSuffix()
    if os and os.date then
        local ok, value = pcall(function() return os.date("%Y%m%d_%H%M%S") end)
        if ok and value then return value end
    end
    return tostring(nowMs())
end

local function displayTime()
    if os and os.date then
        local ok, value = pcall(function() return os.date("%H:%M:%S") end)
        if ok and value then return value end
    end
    return tostring(nowMs())
end

local function isInteractiveImportObject(obj)
    if not obj or not instanceof then return false end
    return instanceof(obj, "IsoCombinationWasherDryer") or
           instanceof(obj, "IsoClothingDryer") or
           instanceof(obj, "IsoClothingWasher") or
           instanceof(obj, "IsoRadio") or
           instanceof(obj, "IsoStove") or
           instanceof(obj, "IsoTelevision") or
           instanceof(obj, "IsoWaveSignal")
end

local function refreshClientSquareInteractions(sq)
    if not sq then return 0 end
    local touched = 0
    pcall(function()
        if sq.RecalcProperties then sq:RecalcProperties() end
        if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
    end)
    local objects = sq.getObjects and sq:getObjects() or nil
    if objects then
        local n = objects:size()
        for i = 0, n - 1 do
            local obj = objects:get(i)
            if isInteractiveImportObject(obj) then
                touched = touched + 1
                pcall(function()
                    local container = obj.getContainer and obj:getContainer() or nil
                    if container then
                        if container.setDrawDirty then container:setDrawDirty(true) end
                        if container.setDirty then container:setDirty(true) end
                    end
                    if triggerEvent then triggerEvent("OnObjectAdded", obj) end
                end)
            end
        end
    end
    return touched
end

local function safeTransferName(name)
    if not name or name == "" then return AE_Constants.DEFAULT_FILENAME end
    local base = tostring(name)
    local lower = string.lower(base)
    if string.sub(lower, -5) == ".json" then
        base = string.sub(base, 1, #base - 5)
    end
    local clean = string.gsub(base, "[^%w_%-]", "_")
    return (clean ~= "" and clean) or AE_Constants.DEFAULT_FILENAME
end

local function clientTransferPath(name)
    return CLIENT_TRANSFER_DIR .. safeTransferName(name) .. ".json"
end

local function clientTransferManifestPath(name)
    return CLIENT_TRANSFER_DIR .. safeTransferName(name) .. ".manifest.json"
end

local function clientTransferTilesPath(name)
    return CLIENT_TRANSFER_DIR .. safeTransferName(name) .. ".tiles.jsonl"
end

local function clientTransferMetaPath(name)
    return CLIENT_TRANSFER_DIR .. safeTransferName(name) .. ".meta.json"
end

local function readClientFile(path)
    local reader = getFileReader(path, false)
    if not reader then return nil, "could not open " .. path end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    return table.concat(lines, "\n"), path
end

local function writeClientFile(path, content)
    local ok, writerOrErr = pcall(function()
        return getFileWriter(path, true, false)
    end)
    if not ok or not writerOrErr then return false, "could not open " .. path end
    local writer = writerOrErr
    ok = pcall(function() writer:write(content or "") end)
    pcall(function() writer:close() end)
    if not ok then return false, "could not write " .. path end
    return true, path
end

local function deleteClientFile(path)
    -- B42 Lua availability differs between host/client contexts. Deletion is
    -- best-effort: if the file API is missing, removeLocalExport still deletes
    -- the index entry so stale exports disappear from the UI.
    local attempts = {
        function()
            if deleteFile then return deleteFile(path) end
            return nil
        end,
        function()
            if removeFile then return removeFile(path) end
            return nil
        end,
        function()
            if getFileSystem then
                local fs = getFileSystem()
                if fs and fs.deleteFile then return fs:deleteFile(path) end
                if fs and fs.removeFile then return fs:removeFile(path) end
            end
            return nil
        end,
    }
    for _, attempt in ipairs(attempts) do
        local ok, result = pcall(attempt)
        if ok and result ~= nil then return result ~= false, path end
    end
    return false, "delete API unavailable"
end

local function readClientTransferFile(name)
    return readClientFile(clientTransferPath(name))
end

local normalizeExportEntry

local function readClientTransferMeta(name)
    local text = readClientFile(clientTransferManifestPath(name))
    if not text or text == "" then
        text = readClientFile(clientTransferMetaPath(name))
    end
    if not text or text == "" then return nil end
    local decoded = AE_Json.decode(text)
    if type(decoded) ~= "table" then return nil end
    return normalizeExportEntry(decoded)
end

local function writeClientTransferManifest(entry)
    entry = normalizeExportEntry(entry)
    if not entry then return false, "invalid package manifest" end
    return writeClientFile(clientTransferManifestPath(entry.filename), AE_Json.encode(entry))
end

local function writeClientTransferMeta(entry)
    entry = normalizeExportEntry(entry)
    if not entry then return false, "invalid metadata" end
    return writeClientFile(clientTransferMetaPath(entry.filename), AE_Json.encode(entry))
end

local function parseExportMetadataFromText(content)
    -- Some early local exports did not have a complete index entry. Recover the
    -- important display fields from JSON text so old local copies still appear
    -- usable in Import/Validate instead of showing radius "?" forever.
    content = tostring(content or "")
    local radius = tonumber(string.match(content, '"radius"%s*:%s*(%d+)') or 0) or 0
    local centerX, centerY = string.match(content, '"center"%s*:%s*{%s*"x"%s*:%s*(-?%d+)%s*,%s*"y"%s*:%s*(-?%d+)')
    local tileCount = 0
    if content ~= "" then
        local _, count = string.gsub(content, '"hasFloor"', "")
        tileCount = count or 0
    end
    return {
        radius = radius,
        centerX = tonumber(centerX or 0) or 0,
        centerY = tonumber(centerY or 0) or 0,
        tileCount = tileCount,
    }
end

local function enrichExportEntryFromContent(entry, content)
    if type(entry) ~= "table" or not content or content == "" then return entry end
    if (entry.radius or 0) > 0 and (entry.tileCount or 0) > 0 and (entry.objectCount or 0) > 0 then
        return entry
    end

    local metadata = parseExportMetadataFromText(content)
    if (entry.radius or 0) <= 0 then entry.radius = metadata.radius end
    if (entry.centerX or 0) == 0 then entry.centerX = metadata.centerX end
    if (entry.centerY or 0) == 0 then entry.centerY = metadata.centerY end
    if (entry.tileCount or 0) <= 0 then entry.tileCount = metadata.tileCount end
    return entry
end

function normalizeExportEntry(entry)
    if type(entry) ~= "table" then return nil end
    local name = safeTransferName(entry.name or entry.filename or AE_Constants.DEFAULT_FILENAME)
    local metadata = entry.metadata or {}
    local center = metadata.center or entry.center or {}
    entry.name = name
    entry.filename = name
    entry.formatVersion = tonumber(entry.formatVersion or entry.format_version or 1) or 1
    entry.format_version = entry.formatVersion
    entry.package = entry.package or entry.kind == "AreaExportPackage" or entry.formatVersion >= 2
    entry.path = clientTransferPath(name)
    entry.manifestPath = clientTransferManifestPath(name)
    entry.tilesPath = clientTransferTilesPath(name)
    entry.bytes = tonumber(entry.bytes or 0) or 0
    entry.tileCount = tonumber(entry.tileCount or 0) or 0
    entry.objectCount = tonumber(entry.objectCount or 0) or 0
    entry.radius = tonumber(entry.radius or metadata.radius or 0) or 0
    entry.centerX = tonumber(entry.centerX or center.x or 0) or 0
    entry.centerY = tonumber(entry.centerY or center.y or 0) or 0
    entry.metadata = metadata
    entry.createdAt = tonumber(entry.createdAt or metadata.exported_at or 0) or 0
    entry.kind = entry.package and "AreaExportPackage" or entry.kind
    return entry
end

local function sortExportEntries(entries)
    table.sort(entries, function(a, b)
        return (a.createdAt or 0) > (b.createdAt or 0)
    end)
end

local function readLocalExportIndex()
    -- The index is the user's export picker. It can survive multiple local test
    -- servers and makes the workflow "export here, join target, import there".
    -- Keep this function strictly metadata-only. Current exports store their
    -- large tile data in *.tiles.jsonl; older exports may be one giant *.json
    -- line. Refresh/open/select must never sniff those large files.
    local entries = {}
    local text = readClientFile(CLIENT_TRANSFER_INDEX)
    if text and text ~= "" then
        local decoded = AE_Json.decode(text)
        local raw = decoded and (decoded.exports or decoded) or nil
        if type(raw) == "table" then
            for _, entry in pairs(raw) do
                local normalized = normalizeExportEntry(entry)
                if normalized then
                    if (normalized.radius or 0) <= 0 or (normalized.tileCount or 0) <= 0 then
                        local meta = readClientTransferMeta(normalized.filename)
                        if meta then normalized = meta end
                    end
                    -- Do not list incomplete large exports. Older builds sometimes
                    -- produced an index entry before a valid local package/meta pair
                    -- existed. Selecting those entries led admins into broken
                    -- refresh/validate paths and made heap failures look like UI
                    -- clicks. A valid export must have complete small metadata.
                    if (normalized.radius or 0) > 0 and (normalized.tileCount or 0) > 0 then
                        entries[#entries + 1] = normalized
                    end
                end
            end
        end
    end

    sortExportEntries(entries)
    return entries
end

local function writeLocalExportIndex(entries)
    entries = entries or {}
    sortExportEntries(entries)
    return writeClientFile(CLIENT_TRANSFER_INDEX, AE_Json.encode({ version = 1, exports = entries }))
end

local function upsertLocalExport(entry)
    -- Newest export wins by filename and is moved to the top. Keep a bounded
    -- history so repeated test exports do not grow the index without limit.
    entry = normalizeExportEntry(entry)
    if not entry then return false, "invalid export entry" end
    local entries = readLocalExportIndex()
    local nextEntries = { entry }
    for _, existing in ipairs(entries) do
        if existing.filename ~= entry.filename then
            nextEntries[#nextEntries + 1] = existing
        end
    end
    while #nextEntries > 50 do table.remove(nextEntries) end
    local indexOk, indexErr = writeLocalExportIndex(nextEntries)
    if not indexOk then return false, indexErr end
    if entry.package then
        writeClientTransferManifest(entry)
    end
    writeClientTransferMeta(entry)
    return true
end

local function removeLocalExport(name)
    -- Delete is intentionally two-part: update the index first, then try to
    -- remove the JSON file. This avoids a broken UI if PZ exposes no delete API.
    name = safeTransferName(name or "")
    if name == "" then return false, "no export selected" end
    local entries = readLocalExportIndex()
    local nextEntries = {}
    local removed = false
    for _, existing in ipairs(entries) do
        if existing.filename == name then
            removed = true
        else
            nextEntries[#nextEntries + 1] = existing
        end
    end
    if not removed then return false, "export not found in index" end
    local ok, err = writeLocalExportIndex(nextEntries)
    if not ok then return false, err or "could not update export index" end

    local deleted, deleteErr = deleteClientFile(clientTransferPath(name))
    local deletedMeta = deleteClientFile(clientTransferMetaPath(name))
    local deletedManifest = deleteClientFile(clientTransferManifestPath(name))
    local deletedTiles = deleteClientFile(clientTransferTilesPath(name))
    local anyDeleted = deleted or deletedMeta or deletedManifest or deletedTiles
    return true, anyDeleted and "deleted" or tostring(deleteErr or "removed from list")
end

local function parseRadiusValue(value)
    local n = tonumber(value) or AE_Constants.DEFAULT_RADIUS
    if n < AE_Constants.MIN_RADIUS then n = AE_Constants.MIN_RADIUS end
    return math.floor(n)
end

local function actionColor(action)
    if action == "Skip" then return THEME.red end
    if action == "Replace" then return THEME.amber end
    if action == "Placeholder" then return THEME.blue end
    if action == "Use Original" then return THEME.green end
    return THEME.muted
end

local function conflictRuleKey(row)
    if not row then return nil end
    return tostring(row.kind or "Item") .. ":" .. tostring(row.id or "unknown")
end

local AE_ConflictList = ISScrollingListBox:derive("AE_ConflictList")

function AE_ConflictList:doDrawItem(y, item, alt)
    if not item.height then item.height = self.itemheight end
    local data = item.item or {}
    local rowH = item.height
    local selected = self.selected == item.index
    local hover = self.mouseoverselected == item.index and self:isMouseOver()
    local bg = alt and {r=0.10, g=0.11, b=0.12, a=0.45} or {r=0.08, g=0.09, b=0.10, a=0.45}
    if selected then bg = {r=0.18, g=0.24, b=0.20, a=0.92}
    elseif hover then bg = {r=0.15, g=0.16, b=0.17, a=0.78} end

    self:drawRect(0, y, self:getWidth(), rowH - 1, bg.a, bg.r, bg.g, bg.b)
    self:drawRectBorder(0, y, self:getWidth(), rowH, 0.35, THEME.border.r, THEME.border.g, THEME.border.b)

    local sev = data.severity or "amber"
    local chip = THEME.amber
    if sev == "red" then chip = THEME.red elseif sev == "green" then chip = THEME.green end
    self:drawRect(8, y + 8, 8, rowH - 16, 0.95, chip.r, chip.g, chip.b)

    self:drawText(data.kind or "Item", 24, y + 7, THEME.text.r, THEME.text.g, THEME.text.b, 1, UIFont.Small)
    self:drawText(truncateText(UIFont.Small, data.id or "unknown", self:getWidth() - 258), 94, y + 7, THEME.text.r, THEME.text.g, THEME.text.b, 1, UIFont.Small)
    self:drawTextRight(tostring(data.count or 0), self:getWidth() - 108, y + 7, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
    local action = data.action or "Review"
    local ac = actionColor(action)
    self:drawText(truncateText(UIFont.Small, action, 72), self:getWidth() - 86, y + 7, ac.r, ac.g, ac.b, 1, UIFont.Small)
    return y + rowH
end

local AE_ReplacementList = ISScrollingListBox:derive("AE_ReplacementList")

function AE_ReplacementList:doDrawItem(y, item, alt)
    local rowH = item.height or self.itemheight
    local selected = self.selected == item.index
    local bg = selected and {r=0.18, g=0.24, b=0.20, a=0.92}
        or (alt and {r=0.10, g=0.11, b=0.12, a=0.55} or {r=0.07, g=0.08, b=0.09, a=0.55})
    self:drawRect(0, y, self:getWidth(), rowH - 1, bg.a, bg.r, bg.g, bg.b)
    self:drawText(truncateText(UIFont.Small, item.text or "", self:getWidth() - 14), 8, y + 5, THEME.text.r, THEME.text.g, THEME.text.b, 1, UIFont.Small)
    return y + rowH
end

local AE_LocalExportList = ISScrollingListBox:derive("AE_LocalExportList")

function AE_LocalExportList:doDrawItem(y, item, alt)
    local rowH = item.height or self.itemheight
    local data = item.item or {}
    local selected = self.selected == item.index
    local hover = self.mouseoverselected == item.index and self:isMouseOver()
    local bg = alt and {r=0.10, g=0.11, b=0.12, a=0.45} or {r=0.08, g=0.09, b=0.10, a=0.45}
    if selected then bg = {r=0.18, g=0.24, b=0.20, a=0.92}
    elseif hover then bg = {r=0.15, g=0.16, b=0.17, a=0.78} end

    self:drawRect(0, y, self:getWidth(), rowH - 1, bg.a, bg.r, bg.g, bg.b)
    self:drawRectBorder(0, y, self:getWidth(), rowH, 0.35, THEME.border.r, THEME.border.g, THEME.border.b)
    self:drawRect(8, y + 8, 8, rowH - 16, 0.95, THEME.blue.r, THEME.blue.g, THEME.blue.b)

    local title = truncateText(UIFont.Small, data.name or data.filename or "export", self:getWidth() - 42)
    local kind = data.package and "package" or "legacy"
    local detail = string.format("%s  %s  radius %s  %d tiles",
        formatKb(data.bytes or 0),
        kind,
        tostring(data.radius and data.radius > 0 and data.radius or "?"),
        data.tileCount or 0)
    self:drawText(title, 24, y + 6, THEME.text.r, THEME.text.g, THEME.text.b, 1, UIFont.Small)
    self:drawText(truncateText(UIFont.Small, detail, self:getWidth() - 34), 24, y + 26,
        THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
    return y + rowH
end

function AE_MainDialog:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.title = "Area Export - Admin Tool"
    o.resizable = false
    o.minimumWidth = WINDOW_W
    o.minimumHeight = WINDOW_H
    o.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=0.9}
    o.activeTab = "export"
    o.tabControls = { export = {}, import = {}, validate = {}, help = {} }
    o.scanResult = nil
    o.importResult = nil
    o.exportResult = nil
    o.selectedConflict = nil
    o.mappingRules = {}
    o.exportTextSession = nil
    o.exportTextWriter = nil
    o.exportTextChunks = nil
    o.exportTextSeen = nil
    o.exportTextNextIndex = 1
    o.exportTextMetadataSample = ""
    o.exportTextReceived = 0
    o.exportTextBytes = 0
    o.exportTextPath = nil
    o.exportPackageSession = nil
    o.exportPackageWriter = nil
    o.exportPackageChunks = nil
    o.exportPackageSeen = nil
    o.exportPackageNextIndex = 1
    o.exportPackageReceived = 0
    o.exportPackageBytes = 0
    o.exportPackageWroteAny = false
    o.exportPackageProgress = nil
    o.textTransfers = {}
    o.outboundTextTransfers = {}
    o.packageTransfers = {}
    o.localExports = {}
    o.selectedExport = nil
    o.pendingExportEntry = nil
    o.pendingLocalExportName = nil
    o.lastServerExportName = nil
    o.currentImportName = nil
    return o
end

function AE_MainDialog:initialise()
    ISCollapsableWindow.initialise(self)
end

function AE_MainDialog:addToTab(tab, child)
    self:addChild(child)
    table.insert(self.tabControls[tab], child)
    return child
end

function AE_MainDialog:addButton(tab, x, y, w, h, title, fn, mode, iconName)
    local btn = ISButton:new(x, y, w, h, title, self, fn)
    btn:initialise()
    applyButtonStyle(btn, mode)
    applyButtonIcon(btn, iconName)
    btn.render = renderButton
    return self:addToTab(tab, btn)
end

function AE_MainDialog:addEntry(tab, x, y, w, h, text, numbersOnly, multiline, maxLines)
    local entry = ISTextEntryBox:new(text or "", x, y, w, h)
    entry:initialise()
    entry:instantiate()
    if numbersOnly then entry:setOnlyNumbers(true) end
    if multiline then
        entry:setMultipleLine(true)
        entry:setMaxLines(maxLines or 2000)
    end
    applyEntryStyle(entry)
    return self:addToTab(tab, entry)
end

function AE_MainDialog:addLabel(tab, x, y, text, font, color)
    return self:addToTab(tab, makeLabel(x, y, text, font, color))
end

function AE_MainDialog:addRichText(tab, x, y, w, h, text)
    local panel = ISRichTextPanel:new(x, y, w, h)
    panel:initialise()
    panel:instantiate()
    panel.background = false
    panel.autosetheight = false
    panel.clip = true
    panel:setMargins(12, 10, 12, 10)
    panel:setText(text or "")
    panel:paginate()
    return self:addToTab(tab, panel)
end

function AE_MainDialog:addChildLabel(parent, x, y, text, font, color)
    color = color or THEME.text
    local label = makeLabel(x, y, text, font, color)
    label:initialise()
    parent:addChild(label)
    return label
end

function AE_MainDialog:createScrollPanel(tab, x, y, w, h)
    local panel = ISPanel:new(x, y, w, h)
    panel:initialise()
    panel:instantiate()
    panel:noBackground()
    panel:setScrollChildren(true)
    panel:addScrollBars()
    panel.vscroll.doRepaintStencil = true
    panel.prerender = function(_self)
        ISPanel.prerender(_self)
        _self:setStencilRect(0, 0, _self:getWidth(), _self:getHeight())
    end
    panel.onMouseWheel = function(_self, del)
        if _self:getScrollHeight() > _self:getHeight() then
            _self:setYScroll(_self:getYScroll() - (del * 40))
            return true
        end
        return false
    end
    panel.render = function(_self)
        ISPanel.render(_self)
        _self:clearStencilRect()
    end
    return self:addToTab(tab, panel)
end

function AE_MainDialog:createTabButton(tab, x, title, iconName, w)
    local btn = ISButton:new(x, 42, w or 116, 30, title, self, function(target)
        target:setActiveTab(tab)
    end)
    btn:initialise()
    applyButtonStyle(btn)
    applyButtonIcon(btn, iconName or tab)
    btn.render = renderButton
    self:addChild(btn)
    self.tabs[tab] = btn
end

function AE_MainDialog:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.tabs = {}

    self:createTabButton("export", 18, "Export")
    self:createTabButton("import", 140, "Import")
    self:createTabButton("validate", 262, "Validate")
    self:createTabButton("help", self.width - 140, "Help", "file", 116)

    self:createExportTab()
    self:createImportTab()
    self:createValidateTab()
    self:createHelpTab()
    self:refreshLocalExports()
    self:setActiveTab(self.activeTab)
end

function AE_MainDialog:createExportTab()
    self:addLabel("export", 38, 112, "Export Area", UIFont.Medium, THEME.text)
    self:addLabel("export", 38, 142, "Export writes a local package on this PC.", UIFont.Small, THEME.muted)
    self.pickCenterBtn = self:addButton("export", 38, 180, 132, 28, "Pick Center", AE_MainDialog.onPickCenter, "warning", "center")
    self.previewBtn = self:addButton("export", 178, 180, 108, 28, "Preview", AE_MainDialog.onPreview, nil, "preview")

    self.centerLabel = self:addLabel("export", 38, 224, "Center: (none)", UIFont.Small, THEME.text)
    self:addLabel("export", 38, 268, "Radius", UIFont.Small, THEME.muted)
    self.radiusBox = self:addEntry("export", 112, 262, 82, 26, tostring(AE_Globals.radius or AE_Constants.DEFAULT_RADIUS), true)

    self:addLabel("export", 38, 310, "Name / prefix", UIFont.Small, THEME.muted)
    self.exportFilenameBox = self:addEntry("export", 112, 304, 196, 26, AE_Constants.DEFAULT_FILENAME, false)
    self.filenameBox = self.exportFilenameBox
    self.exportBtn = self:addButton("export", 38, 356, 164, 30, "Export to This PC", AE_MainDialog.onExport, "primary", "export")
    self.statusLabel = self:addLabel("export", 38, 404, "Ready.", UIFont.Small, THEME.green)

    self:addLabel("export", 434, 112, "Preview & Local Package", UIFont.Medium, THEME.text)
    self:addLabel("export", 434, 142, "Export streams directly to this PC.", UIFont.Small, THEME.muted)
    self.scanSquareValue = self:addLabel("export", 454, 192, "0", UIFont.Medium, THEME.text)
    self.scanObjectValue = self:addLabel("export", 584, 192, "0", UIFont.Medium, THEME.text)
    self.scanContainerValue = self:addLabel("export", 454, 276, "0", UIFont.Medium, THEME.text)
    self.scanItemValue = self:addLabel("export", 584, 276, "0", UIFont.Medium, THEME.text)
    self.statsLabel = self:addLabel("export", 434, 342, "No preview run yet.", UIFont.Small, THEME.muted)
    self.statsDetailLabel = self:addLabel("export", 434, 364, "Run Preview to estimate export contents.", UIFont.Small, THEME.muted)

    self.saveLocalCopyBtn = self:addButton("export", 434, 392, 190, 30, "Local Save: Automatic", AE_MainDialog.onLoadExportText, nil, "save")
    if self.saveLocalCopyBtn.setEnable then self.saveLocalCopyBtn:setEnable(false) end
    self.exportTextStatusLabel = self:addLabel("export", 434, 434, "Export creates a local package automatically.", UIFont.Small, THEME.muted)
    self.exportLocalCopyHint = self:addLabel("export", 434, 462, "No FTP, clipboard or server file download is needed.", UIFont.Small, THEME.muted)
    self.exportLocalCopyHint2 = self:addLabel("export", 434, 484, "Local path: Zomboid/Lua/AreaExportClient/.", UIFont.Small, THEME.muted)
end

function AE_MainDialog:createImportTab()
    self:addLabel("import", 38, 112, "Import Area", UIFont.Medium, THEME.text)
    self:addLabel("import", 38, 142, "Select a local export saved on this PC.", UIFont.Small, THEME.muted)

    self:addLabel("import", 38, 186, "Local Exports", UIFont.Small, THEME.text)
    self.exportList = AE_LocalExportList:new(38, 214, 388, 248)
    self.exportList:initialise()
    self.exportList:instantiate()
    self.exportList.itemheight = 52
    self.exportList.font = UIFont.Small
    self.exportList.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=0.55}
    self.exportList.backgroundColor = {r=0.05, g=0.06, b=0.065, a=0.85}
    self.exportList:setOnMouseDownFunction(self, AE_MainDialog.onLocalExportSelected)
    self:addToTab("import", self.exportList)

    self.refreshExportsBtn = self:addButton("import", 38, 476, 88, 30, "Refresh", AE_MainDialog.onRefreshExports, nil, "preview")
    self.validateLocalBtn = self:addButton("import", 134, 476, 98, 30, "Validate", AE_MainDialog.onValidate, "warning", "validate")
    self.importPasteBtn = self:addButton("import", 240, 476, 96, 30, "Import", AE_MainDialog.onImportPastedText, "primary", "import")
    self.deleteExportBtn = self:addButton("import", 344, 476, 82, 30, "Delete", AE_MainDialog.onDeleteLocalExport, "danger", "skip")
    self.importStatusLabel = self:addLabel("import", 38, 526, "Select a local export.", UIFont.Small, THEME.green)

    self:addLabel("import", 474, 112, "Selected Export", UIFont.Medium, THEME.text)
    self.selectedExportLabel = self:addLabel("import", 474, 148, "None selected", UIFont.Small, THEME.text)
    self.selectedExportDetailLabel = self:addLabel("import", 474, 172, "Create an export first or refresh the list.", UIFont.Small, THEME.muted)
    self.pasteStatusLabel = self:addLabel("import", 474, 216, "Validate checks the selected export first.", UIFont.Small, THEME.muted)

    self.lastImportTitleLabel = self:addLabel("import", 474, 438, "Last Import Result", UIFont.Small, THEME.text)
    self.addedItemsValue = self:addLabel("import", 494, 480, "0 / 0", UIFont.Medium, THEME.text)
    self.importedSquaresValue = self:addLabel("import", 630, 480, "0", UIFont.Medium, THEME.text)
    self.failedSquaresValue = self:addLabel("import", 766, 480, "0", UIFont.Medium, THEME.text)
    self.missingContainersValue = self:addLabel("import", 872, 480, "0", UIFont.Medium, THEME.text)
    self:refreshLocalExports()
end

function AE_MainDialog:createValidateTab()
    self:addLabel("validate", 38, 92, "Import Validation", UIFont.Medium, THEME.text)
    self:addLabel("validate", 38, 120, "Dry-run checks the selected local export before changing save data.", UIFont.Small, THEME.muted)

    self.validateFileLabel = self:addLabel("validate", 38, 158, "Selected export: none", UIFont.Small, THEME.text)
    self.okItemValue = self:addLabel("validate", 52, 206, "18102", UIFont.Medium, THEME.green)
    self.missingItemValue = self:addLabel("validate", 184, 206, "6", UIFont.Medium, THEME.amber)
    self.missingSpriteValue = self:addLabel("validate", 316, 206, "3", UIFont.Medium, THEME.amber)
    self.unsupportedValue = self:addLabel("validate", 448, 206, "1", UIFont.Medium, THEME.red)

    self:addLabel("validate", 38, 260, "Grouped Conflicts", UIFont.Small, THEME.text)
    self.conflictList = AE_ConflictList:new(38, 288, 500, 226)
    self.conflictList:initialise()
    self.conflictList:instantiate()
    self.conflictList.itemheight = 32
    self.conflictList.font = UIFont.Small
    self.conflictList.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=0.55}
    self.conflictList.backgroundColor = {r=0.05, g=0.06, b=0.065, a=0.85}
    self.conflictList:setOnMouseDownFunction(self, AE_MainDialog.onConflictSelected)
    self:addToTab("validate", self.conflictList)

    self:addLabel("validate", 584, 104, "Selected Rule", UIFont.Medium, THEME.text)
    self.selectedConflictLabel = self:addLabel("validate", 584, 136, "No conflict selected", UIFont.Small, THEME.text)
    self.selectedActionLabel = self:addLabel("validate", 584, 156, "Run Dry Run first.", UIFont.Small, THEME.muted)
    self.addActionSkip = self:addButton("validate", 584, 176, 74, 26, "Skip", AE_MainDialog.onMappingAction, "danger", "skip")
    self.addActionReplace = self:addButton("validate", 666, 176, 104, 26, "Replace", AE_MainDialog.onMappingAction, "warning", "replace")
    self.addActionOriginal = self:addButton("validate", 778, 176, 132, 26, "Use Original", AE_MainDialog.onMappingAction, nil, "file")
    self.addActionPlaceholder = self:addButton("validate", 584, 210, 326, 26, "Keep Placeholder", AE_MainDialog.onMappingAction, nil, "file")
    self.addActionSkip.ruleAction = "Skip"
    self.addActionReplace.ruleAction = "Replace"
    self.addActionOriginal.ruleAction = "Use Original"
    self.addActionPlaceholder.ruleAction = "Placeholder"
    self.selectedReasonLabel = self:addLabel("validate", 584, 242, "Details appear after Dry Run.", UIFont.Small, THEME.muted)

    self:addLabel("validate", 584, 266, "Replacement Search", UIFont.Small, THEME.muted)
    self.replacementSearchBox = self:addEntry("validate", 584, 284, 202, 26, "vhs", false)
    self.searchItemsBtn = self:addButton("validate", 796, 284, 114, 26, "Search", AE_MainDialog.onSearchItems, nil, nil)
    self.replacementList = AE_ReplacementList:new(584, 320, 326, 174)
    self.replacementList:initialise()
    self.replacementList:instantiate()
    self.replacementList.itemheight = 24
    self.replacementList:addItem("Base.VHS_Retail", {type="Base.VHS_Retail"})
    self.replacementList:addItem("Base.VHS_Home", {type="Base.VHS_Home"})
    self.replacementList:addItem("Base.VideoStoreTape", {type="Base.VideoStoreTape"})
    self.replacementList.selected = 1
    self.replacementList:setOnMouseDownFunction(self, AE_MainDialog.onReplacementSelected)
    self:addToTab("validate", self.replacementList)

    self.validateStatusLabel = self:addLabel("validate", 38, 534, "No save data is changed by Dry Run.", UIFont.Small, THEME.green)
    self:addButton("validate", 584, 534, 124, 28, "Save Rules", AE_MainDialog.onSaveRules, nil, "mapping")
    self:addButton("validate", 718, 534, 124, 28, "Dry Run", AE_MainDialog.onValidate, "warning", "validate")
    self.conflictList:clear()
    self.conflictList:setScrollHeight(0)
    self.okItemValue:setName("0")
    self.missingItemValue:setName("0")
    self.missingSpriteValue:setName("0")
    self.unsupportedValue:setName("0")
end

function AE_MainDialog:createHelpTab()
    -- Help text is rendered into a scroll panel with manual wrapping. ISRichText
    -- and raw labels clipped or overlapped long German/English text in testing,
    -- so this page avoids relying on automatic layout.
    local scroll = self:createScrollPanel("help", 38, 104, 820, 430)

    local function addWrappedText(x, y, text, maxWidth, font, color, gapAfter)
        font = font or UIFont.Small
        color = color or THEME.muted
        gapAfter = gapAfter or 4

        local line = ""
        local lineH = getTextManager():getFontHeight(font) + 4
        for word in tostring(text or ""):gmatch("%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if line ~= "" and measureText(font, candidate) > maxWidth then
                self:addChildLabel(scroll, x, y, line, font, color)
                y = y + lineH
                line = word
            else
                line = candidate
            end
        end
        if line ~= "" then
            self:addChildLabel(scroll, x, y, line, font, color)
            y = y + lineH
        end
        return y + gapAfter
    end

    local function addSection(x, y, title, lines, maxWidth)
        self:addChildLabel(scroll, x, y, title, UIFont.Medium, THEME.text)
        y = y + 34
        for _, line in ipairs(lines) do
            y = addWrappedText(x, y, line, maxWidth, UIFont.Small, THEME.muted, 5)
        end
        return y
    end

    self:addChildLabel(scroll, 16, 14, "Help", UIFont.Medium, THEME.text)
    self:addChildLabel(scroll, 16, 42, "Detailed workflow for moving an area from one save to another.", UIFont.Small, THEME.muted)

    local leftX, rightX = 30, 430
    local leftW, rightW = 350, 350

    local leftY = 88
    leftY = addSection(leftX, leftY, "Alpha Warning", {
        "Area Export is a first public alpha version and can still contain bugs.",
        "It can change or damage world data if an import hits an unsupported Project Zomboid object state.",
        "Always back up the target save and test migrations on a local or disposable server before using a live server.",
    }, leftW)

    leftY = leftY + 16
    leftY = addSection(leftX, leftY, "Export", {
        "1. Click Pick Center and then click the tile that should be the exact middle of the exported area.",
        "2. Enter the radius. The radius is stored in the export and will be used again during import.",
        "3. Click Preview to draw the footprint and count map tiles, map objects, containers, container items and loose floor items. Preview does not change the save.",
        "4. Enter a name prefix and click Export. A local package is saved on this PC with a timestamp.",
        "5. Every successful export is added to Local Exports in the Import tab.",
    }, leftW)

    leftY = leftY + 16
    leftY = addSection(leftX, leftY, "Import", {
        "Select one entry from Local Exports.",
        "Validate checks that selected local export without changing the save.",
        "Import restores the selected local export at the original world coordinates and uses the original export radius. You do not pick a new center.",
        "Package import progress has separate phases for client upload, target footprint clearing, and server tile rebuild.",
        "During clearing, linked double-door and garage-door tiles are removed as one group so partial door objects do not survive at footprint edges.",
        "Interactive vanilla fixtures are rebuilt with their real object classes when known: TV, radio, stove, microwave, washer, dryer, BBQ, fireplace, jukebox and composter.",
        "Older packages can still recover many of those classes from sprite IsoType or container type during import.",
        "B42 live imports use targeted entity/component setup for stoves, laundry machines, TVs and radios, while TV/radio DeviceData is restored after object initialization.",
        "After updating the mod on a dedicated server, restart the server process before testing an import; a client reconnect does not reload server-side Lua.",
        "Door live sync avoids generic sync packets because B42 can reject freshly rebuilt door indexes; garage doors are restored as closed linked groups.",
        "State-heavy objects such as generators, mannequins and feeding troughs are shown as Dry Run object conflicts until their full state can be mapped.",
        "Import is destructive inside the exported footprint. Back up the target save before using it on a real server.",
    }, leftW)

    leftY = leftY + 16
    leftY = addSection(leftX, leftY, "Local Export List", {
        "The list is stored in Zomboid/Lua/AreaExportClient/index.json.",
        "Each current export has a small manifest file and a tiles JSONL file beside the index.",
        "Refresh reloads only the index/manifest metadata. It does not read the large tile file.",
        "Delete removes the selected entry from the list and tries to delete its manifest, tile file and legacy JSON file.",
        "To move an export to another PC, copy index.json plus the selected .manifest.json and .tiles.jsonl files into the same AreaExportClient folder on the target PC.",
    }, leftW)

    local rightY = 88
    rightY = addSection(rightX, rightY, "Conflict Resolution", {
        "Dry Run streams the selected package before import and does not change the save.",
        "Conflicts are grouped by type: missing items, sprite lookup warnings, unsupported object classes, and incomplete legacy door data.",
        "Missing or renamed item types are grouped by their old item ID, so one decision applies to all matching items.",
        "Replace maps every item of the missing type to a selected existing type.",
        "Skip drops every item of that missing type during import.",
        "Placeholder keeps a marker item so the conflict stays visible after import.",
        "Sprite warnings default to Use Original. Keep that when source and target use the same mods; replace or skip only if the target really lacks that sprite.",
        "Save Rules stages explicit decisions for the next import in this dialog session. Use Original clears a saved sprite rule and preserves the exported sprite name.",
    }, rightW)

    rightY = rightY + 16
    rightY = addSection(rightX, rightY, "After Import", {
        "The mod automatically compares imported loose floor-item squares against the server for a short time.",
        "If the server says an item is gone but the client still shows a local ghost, that local ghost is removed automatically.",
        "Project Zomboid may still not redraw every changed chunk immediately. If walls or furniture look stale, reconnect or restart the client.",
    }, rightW)

    rightY = rightY + 16
    rightY = addSection(rightX, rightY, "Memory And Large Exports", {
        "Export, Dry Run and Import use small transfer parts instead of one giant JSON string.",
        "Export progress shows scanned map positions out of the known footprint, transfer parts received by the client and saved package tiles.",
        "Dry Run progress shows package tiles checked by the server while the client uploads the package.",
        "The Import button uploads the whole package into a temporary server buffer first. Only after that upload succeeds does the server clear and rebuild the target footprint over multiple ticks. The progress bar resets for each phase.",
        "Very large areas can still take time and may briefly stall while individual tiles with many objects or items are processed.",
        "Old legacy JSON exports above the safety limit are refused by the UI. Re-export them with the current package format.",
    }, rightW)

    rightY = rightY + 16
    rightY = addSection(rightX, rightY, "Open Source", {
        "Source code: https://github.com/Elfwyn/ProjectZomboid-AreaExport/",
        "Using the public code for your own mods, forks, variants or compatibility patches is explicitly allowed and encouraged.",
    }, rightW)

    rightY = rightY + 16
    rightY = addSection(rightX, rightY, "Safety", {
        "Use this as an admin-only migration tool, not as a live building editor.",
        "Do not import while players are active in the target footprint.",
        "For large areas, test on a local or disposable server first and give the import time to finish.",
    }, rightW)

    scroll:setScrollHeight(math.max(leftY, rightY) + 34)
end

function AE_MainDialog:setActiveTab(tab)
    self.activeTab = tab
    for name, controls in pairs(self.tabControls) do
        local visible = name == tab
        for _, child in ipairs(controls) do
            child:setVisible(visible)
        end
    end
    for name, btn in pairs(self.tabs or {}) do
        if name == tab then
            btn.borderColor = {r=THEME.borderHot.r, g=THEME.borderHot.g, b=THEME.borderHot.b, a=0.95}
            btn.backgroundColor = {r=0.20, g=0.16, b=0.07, a=0.96}
        else
            btn.borderColor = {r=THEME.border.r, g=THEME.border.g, b=THEME.border.b, a=0.55}
            btn.backgroundColor = {r=0.09, g=0.10, b=0.11, a=0.90}
        end
    end
end

function AE_MainDialog:drawPanel(x, y, w, h, title)
    self:drawRect(x, y, w, h, THEME.panel.a, THEME.panel.r, THEME.panel.g, THEME.panel.b)
    self:drawRectBorder(x, y, w, h, THEME.border.a, THEME.border.r, THEME.border.g, THEME.border.b)
    if title then
        self:drawText(title, x + 14, y + 12, THEME.text.r, THEME.text.g, THEME.text.b, 1, UIFont.Small)
    end
end

function AE_MainDialog:drawMetricCard(x, y, w, h, label, color)
    self:drawRect(x, y, w, h, THEME.panel2.a, THEME.panel2.r, THEME.panel2.g, THEME.panel2.b)
    self:drawRectBorder(x, y, w, h, 0.45, color.r, color.g, color.b)
    self:drawRect(x, y, 5, h, 0.9, color.r, color.g, color.b)
    self:drawText(label, x + 14, y + 42, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
end

function AE_MainDialog:drawProgressBar(x, y, w, h, percent, color)
    percent = clampPercent(percent)
    color = color or THEME.green
    self:drawRect(x, y, w, h, 0.85, 0.045, 0.05, 0.055)
    self:drawRect(x, y, math.floor(w * percent / 100), h, 0.90, color.r, color.g, color.b)
    self:drawRectBorder(x, y, w, h, 0.55, THEME.border.r, THEME.border.g, THEME.border.b)
end

function AE_MainDialog:drawValidateBadge(x, y, w, label, color)
    self:drawRect(x, y, w, 66, THEME.panel2.a, THEME.panel2.r, THEME.panel2.g, THEME.panel2.b)
    self:drawRectBorder(x, y, w, 66, 0.45, color.r, color.g, color.b)
    self:drawText(label, x + 14, y + 42, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
end

function AE_MainDialog:prerender()
    ISCollapsableWindow.prerender(self)
    self:drawRect(8, 28, self.width - 16, self.height - 36, THEME.bg.a, THEME.bg.r, THEME.bg.g, THEME.bg.b)
    self:drawRect(8, 28, self.width - 16, 48, THEME.bg2.a, THEME.bg2.r, THEME.bg2.g, THEME.bg2.b)
    self:drawRectBorder(8, 28, self.width - 16, self.height - 36, THEME.border.a, THEME.border.r, THEME.border.g, THEME.border.b)

    if self.activeTab == "export" then
        self:drawPanel(24, 88, 346, 378)
        self:drawPanel(414, 88, 400, 458)
        self:drawMetricCard(434, 176, 120, 72, "Map tiles", THEME.green)
        self:drawMetricCard(564, 176, 120, 72, "Map objects", THEME.blue)
        self:drawMetricCard(434, 260, 120, 72, "Containers", THEME.amber)
        self:drawMetricCard(564, 260, 120, 72, "Container items", THEME.green)
        if self.exportPackageProgress then
            self:drawProgressBar(434, 516, 360, 14, self.exportPackageProgress.percent or 0, THEME.green)
        end
    elseif self.activeTab == "import" then
        self:drawPanel(24, 88, 430, 458)
        self:drawPanel(464, 88, 482, 458)
        local importTransfer = self.packageTransfers and self.packageTransfers.importPackage
        if importTransfer then
            self:drawProgressBar(474, 248, 450, 14, self:getPackageTransferPercent("importPackage"), THEME.blue)
        end
        self:drawMetricCard(474, 466, 126, 64, "Items", THEME.green)
        self:drawMetricCard(610, 466, 126, 64, "Squares", THEME.blue)
        self:drawMetricCard(746, 466, 96, 64, "Failed", THEME.red)
        self:drawMetricCard(852, 466, 96, 64, "Missing", THEME.amber)
    elseif self.activeTab == "validate" then
        self:drawPanel(24, 84, 530, 430)
        self:drawPanel(566, 84, 370, 430)
        self:drawValidateBadge(38, 182, 118, "OK items", THEME.green)
        self:drawValidateBadge(170, 182, 118, "Missing items", THEME.amber)
        self:drawValidateBadge(302, 182, 118, "Sprite warnings", THEME.amber)
        self:drawValidateBadge(434, 182, 94, "Objects", THEME.red)
        self:drawRect(38, 280, 500, 24, 0.85, 0.05, 0.055, 0.06)
        self:drawText("Type", 62, 286, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
        self:drawText("Conflict ID", 132, 286, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
        self:drawTextRight("Count", 428, 286, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
        self:drawText("Action", 452, 286, THEME.muted.r, THEME.muted.g, THEME.muted.b, 1, UIFont.Small)
        local validateTransfer = self.packageTransfers and self.packageTransfers.validatePackage
        if validateTransfer then
            self:drawProgressBar(38, 518, 500, 10, self:getPackageTransferPercent("validatePackage"), THEME.amber)
        end
    elseif self.activeTab == "help" then
        self:drawPanel(24, 88, 850, 458)
    end
end

function AE_MainDialog:getRadius()
    local n = parseRadiusValue(self.radiusBox and self.radiusBox:getText() or nil)
    AE_Globals.radius = n
    return n
end

function AE_MainDialog:getExportFilename()
    local filename = self.exportFilenameBox and self.exportFilenameBox:getText() or ""
    if not filename or filename == "" then filename = AE_Constants.DEFAULT_FILENAME end
    return filename
end

function AE_MainDialog:getNewLocalExportFilename()
    return safeTransferName(self:getExportFilename()) .. "_" .. timestampSuffix()
end

function AE_MainDialog:getImportFilename()
    local selected = self:getSelectedLocalExport()
    local filename = selected and selected.filename or ""
    if not filename or filename == "" then filename = AE_Constants.DEFAULT_FILENAME end
    return filename
end

function AE_MainDialog:getSelectedLocalExport()
    if self.selectedExport then return self.selectedExport end
    if self.localExports and #self.localExports > 0 then
        self.selectedExport = self.localExports[1]
        return self.selectedExport
    end
    return nil
end

function AE_MainDialog:updateSelectedExportLabels()
    local selected = self:getSelectedLocalExport()
    if not selected then
        setClippedLabel(self.selectedExportLabel, "None selected", IMPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.selectedExportDetailLabel, "Create an export first or refresh the list.", IMPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.validateFileLabel, "Selected export: none", VALIDATE_STATUS_W, UIFont.Small)
        return
    end

    local objectText = selected.objectCount and selected.objectCount > 0 and (", " .. tostring(selected.objectCount) .. " objects") or ""
    local kind = selected.package and "package" or "legacy JSON"
    local detail = string.format("%s, %s, radius %s, center %d/%d, %d tiles%s",
        formatKb(selected.bytes or 0),
        kind,
        tostring(selected.radius and selected.radius > 0 and selected.radius or "?"),
        selected.centerX or 0,
        selected.centerY or 0,
        selected.tileCount or 0,
        objectText)
    setClippedLabel(self.selectedExportLabel, selected.filename .. (selected.package and ".manifest.json" or ".json"), IMPORT_RIGHT_TEXT_W, UIFont.Small)
    setClippedLabel(self.selectedExportDetailLabel, detail, IMPORT_RIGHT_TEXT_W, UIFont.Small)
    setClippedLabel(self.validateFileLabel, "Selected export: " .. selected.filename .. (selected.package and " package" or ".json"), VALIDATE_STATUS_W, UIFont.Small)
end

function AE_MainDialog:refreshLocalExports(preferredName)
    preferredName = preferredName or (self.selectedExport and self.selectedExport.filename)
    self.localExports = readLocalExportIndex()
    self.selectedExport = nil

    if self.exportList then
        self.exportList:clear()
        self.exportList:setScrollHeight(0)
        for _, entry in ipairs(self.localExports) do
            self.exportList:addItem(entry.filename, entry)
        end
    end

    local selectedIndex = 1
    for i, entry in ipairs(self.localExports) do
        if preferredName and entry.filename == preferredName then
            selectedIndex = i
            break
        end
    end
    if #self.localExports > 0 then
        self.selectedExport = self.localExports[selectedIndex]
        if self.exportList then self.exportList.selected = selectedIndex end
        setClippedLabel(self.importStatusLabel, "Selected local export is ready.", IMPORT_LEFT_TEXT_W, UIFont.Small)
    elseif self.importStatusLabel then
        setClippedLabel(self.importStatusLabel, "No local exports found.", IMPORT_LEFT_TEXT_W, UIFont.Small)
    end
    self:updateSelectedExportLabels()
end

function AE_MainDialog:onLocalExportSelected(row)
    row = row and (row.filename and row or row.item)
    if not row then return end
    self.selectedExport = row
    self.pendingDeleteExport = nil
    self:updateSelectedExportLabels()
    setClippedLabel(self.importStatusLabel, "Selected " .. tostring(row.filename or row.name or "export") .. ".", IMPORT_LEFT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:onRefreshExports()
    self.pendingDeleteExport = nil
    self:refreshLocalExports()
end

function AE_MainDialog:onDeleteLocalExport()
    -- Two-click confirmation without a modal: the first click arms deletion for
    -- the selected export, the second click on the same export removes it.
    local selected = self:getSelectedLocalExport()
    if not selected then
        setClippedLabel(self.importStatusLabel, "Select a local export before deleting.", IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local name = selected.filename or selected.name
    if self.pendingDeleteExport ~= name then
        self.pendingDeleteExport = name
        setClippedLabel(self.importStatusLabel, "Click Delete again to remove " .. tostring(name) .. ".", IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local ok, detail = removeLocalExport(name)
    self.pendingDeleteExport = nil
    if not ok then
        setClippedLabel(self.importStatusLabel, "Delete failed: " .. tostring(detail or "unknown"), IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    self:refreshLocalExports()
    setClippedLabel(self.importStatusLabel, "Removed " .. tostring(name) .. " (" .. tostring(detail) .. ").", IMPORT_LEFT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:update()
    ISCollapsableWindow.update(self)
    if AE_Globals.pickedCenter then
        setClippedLabel(self.centerLabel, string.format("Center: (%d, %d, z=%d)",
            AE_Globals.pickedCenter.x, AE_Globals.pickedCenter.y, AE_Globals.pickedCenter.z or 0), EXPORT_LEFT_TEXT_W, UIFont.Small)
    else
        setClippedLabel(self.centerLabel, "Center: (none)", EXPORT_LEFT_TEXT_W, UIFont.Small)
    end
    self:processOutboundTransfers()
    self:processPackageTransfers()
    self:updateActiveTransfers()
    self:processWorldItemMonitor()
end

function AE_MainDialog:setScanResult(r)
    self.scanResult = r
    if not r.success then
        setClippedLabel(self.statsLabel, "Error: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        return
    end
    self.scanSquareValue:setName(tostring(r.squareCount or 0))
    self.scanObjectValue:setName(tostring(r.objectCount or 0))
    self.scanContainerValue:setName(tostring(r.containerCount or 0))
    self.scanItemValue:setName(tostring(r.totalItemsInContainers or 0))
    local containerItems = tonumber(r.totalItemsInContainers or 0) or 0
    local worldItems = tonumber(r.worldItemCount or 0) or 0
    setClippedLabel(self.statsLabel, string.format("Loose floor items: %d  Player-built map objects: %d",
        r.worldItemCount or 0, r.playerBuildCount or 0), EXPORT_RIGHT_TEXT_W, UIFont.Small)
    setClippedLabel(self.statsDetailLabel, string.format("Total item records: %d (%d container + %d loose floor).",
        containerItems + worldItems, containerItems, worldItems), EXPORT_RIGHT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:setExportResult(r)
    self.exportResult = r
    if not r.success then
        setClippedLabel(self.statusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    local filename = safeTransferName(r.filename or self.pendingLocalExportName or self:getExportFilename())
    self.lastServerExportName = filename
    self.pendingLocalExportName = filename
    setClippedLabel(self.statusLabel, string.format("Exported %d tiles, %d objects, %d bytes.",
        r.tileCount or 0, r.objectCount or 0, r.bytes or 0), EXPORT_LEFT_TEXT_W, UIFont.Small)
    if self.exportTextStatusLabel then
        setClippedLabel(self.exportTextStatusLabel, "Legacy server export finished.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
    end
end

function AE_MainDialog:refreshImportInteractionState(r)
    local player = getPlayer and getPlayer() or nil
    local cell = getCell and getCell() or nil
    if not player or not cell then return 0 end
    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = math.floor(player:getZ())
    local radius = tonumber(r and r.radius or 0) or 0
    local scanRadius = math.min(math.max(radius, 24), 48)
    local touched = 0
    local r2 = scanRadius * scanRadius
    for dy = -scanRadius, scanRadius do
        for dx = -scanRadius, scanRadius do
            if dx * dx + dy * dy <= r2 then
                for z = math.max(0, pz - 1), math.min(7, pz + 1) do
                    local sq = cell:getGridSquare(px + dx, py + dy, z)
                    if sq then touched = touched + refreshClientSquareInteractions(sq) end
                end
            end
        end
    end
    pcall(function()
        if triggerEvent then triggerEvent("OnContainerUpdate") end
    end)
    return touched
end

function AE_MainDialog:setImportResult(r)
    self.importResult = r
    self:finishTextTransfer("importText")
    self:finishPackageTransfer("importPackage")
    if not r.success then
        setClippedLabel(self.importStatusLabel, "Import failed: " .. tostring(r.error or "unknown"), IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    self.importedSquaresValue:setName(tostring(r.squaresProcessed or 0))
    self.failedSquaresValue:setName(tostring(r.squaresFailed or 0))
    self.addedItemsValue:setName(string.format("%d / %d", r.itemsAdded or 0, r.itemsExpected or 0))
    self.missingContainersValue:setName(tostring(r.containersMissing or 0))
    local importName = self.currentImportName or self:getImportFilename()
    setClippedLabel(self.lastImportTitleLabel, "Last Import: " .. tostring(importName), IMPORT_RIGHT_TEXT_W, UIFont.Small)
    local refreshed = self:refreshImportInteractionState(r)
    local monitored = self:startWorldItemMonitor(r)
    if monitored > 0 then
        setClippedLabel(self.importStatusLabel, string.format("Import completed. Reconcile checks %d item square(s).", monitored), IMPORT_LEFT_TEXT_W, UIFont.Small)
    elseif refreshed > 0 then
        setClippedLabel(self.importStatusLabel, string.format("Import completed. Refreshed %d interactive object(s).", refreshed), IMPORT_LEFT_TEXT_W, UIFont.Small)
    else
        setClippedLabel(self.importStatusLabel, "Import completed. Reconnect to verify.", IMPORT_LEFT_TEXT_W, UIFont.Small)
    end
    setClippedLabel(self.pasteStatusLabel, "Imported " .. tostring(importName) .. " at " .. displayTime() .. ".", IMPORT_RIGHT_TEXT_W, UIFont.Small)
    self.currentImportName = nil
end

function AE_MainDialog:setValidationResult(r)
    self:finishTextTransfer("validateText")
    self:finishPackageTransfer("validatePackage")
    if not r.success then
        setClippedLabel(self.validateStatusLabel, "Dry Run failed: " .. tostring(r.error or "unknown"), VALIDATE_STATUS_W, UIFont.Small)
        return
    end

    self.okItemValue:setName(tostring(r.okItems or 0))
    self.missingItemValue:setName(tostring(r.missingItemGroups or 0))
    self.missingSpriteValue:setName(tostring(r.missingSpriteGroups or 0))
    self.unsupportedValue:setName(tostring(r.unsupportedObjectGroups or 0))

    self.conflictList:clear()
    self.conflictList:setScrollHeight(0)
    local conflicts = r.conflicts or {}
    for _, row in ipairs(conflicts) do
        local key = conflictRuleKey(row)
        local saved = key and self.mappingRules[key] or nil
        if saved then
            row.action = saved.action
            row.replacement = saved.replacement
        end
        self.conflictList:addItem(row.id or "unknown", row)
    end

    if #conflicts > 0 then
        self.conflictList.selected = 1
        self.selectedConflict = conflicts[1]
        self:updateSelectedConflictPanel(conflicts[1])
        setClippedLabel(self.validateStatusLabel, string.format("Dry Run found %d grouped conflict(s).", #conflicts), VALIDATE_STATUS_W, UIFont.Small)
    else
        self.selectedConflict = nil
        setClippedLabel(self.selectedConflictLabel, "No conflicts found", VALIDATE_RULE_W, UIFont.Small)
        setClippedLabel(self.selectedActionLabel, "Import can use the original data.", VALIDATE_RULE_W, UIFont.Small)
        setClippedLabel(self.selectedReasonLabel, "No correction rules are needed.", VALIDATE_RULE_W, UIFont.Small)
        self:updateRuleButtons("Review")
        setClippedLabel(self.validateStatusLabel, "Dry Run complete. No grouped conflicts found.", VALIDATE_STATUS_W, UIFont.Small)
    end
end

function AE_MainDialog:setReplacementResults(r)
    if not r.success then
        setClippedLabel(self.validateStatusLabel, "Item search failed: " .. tostring(r.error or "unknown"), VALIDATE_STATUS_W, UIFont.Small)
        return
    end
    self.replacementList:clear()
    self.replacementList:setScrollHeight(0)
    local items = r.items or {}
    for _, item in ipairs(items) do
        self.replacementList:addItem(item.type or "unknown", { type = item.type, name = item.name })
    end
    if #items > 0 then
        self.replacementList.selected = 1
        setClippedLabel(self.validateStatusLabel, string.format("Found %d replacement candidate(s).", #items), VALIDATE_STATUS_W, UIFont.Small)
    elseif self.validateStatusLabel then
        setClippedLabel(self.validateStatusLabel, "No replacement candidates found.", VALIDATE_STATUS_W, UIFont.Small)
    end
end

function AE_MainDialog:startExportText(r)
    if not r.success then
        if self.exportTextWriter then pcall(function() self.exportTextWriter:close() end) end
        self.exportTextWriter = nil
        self.exportTextChunks = nil
        self.exportTextSeen = nil
        setClippedLabel(self.exportTextStatusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    if self.exportTextWriter then pcall(function() self.exportTextWriter:close() end) end
    self.exportTextSession = r.sessionId
    local filename = safeTransferName(r.filename or self:getExportFilename())
    self.exportTextPath = clientTransferPath(filename)
    self.exportTextExpected = tonumber(r.totalChunks or 0) or 0
    self.exportTextChunks = {}
    self.exportTextSeen = {}
    self.exportTextNextIndex = 1
    self.exportTextMetadataSample = ""
    self.exportTextReceived = 0
    self.exportTextBytes = 0
    local exportResult = self.exportResult or {}
    local exportMetadata = r.metadata or exportResult.metadata
    self.pendingExportEntry = {
        filename = filename,
        bytes = tonumber(r.bytes or exportResult.bytes or 0) or 0,
        tileCount = tonumber(r.tileCount or exportResult.tileCount or 0) or 0,
        objectCount = tonumber(r.objectCount or exportResult.objectCount or 0) or 0,
        metadata = exportMetadata,
    }

    local ok, writerOrErr = pcall(function()
        return getFileWriter(self.exportTextPath, true, false)
    end)
    if not ok or not writerOrErr then
        self.exportTextChunks = nil
        self.exportTextSeen = nil
        self.exportTextWriter = nil
        setClippedLabel(self.exportTextStatusLabel, "Could not write local export.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
        return
    end
    self.exportTextWriter = writerOrErr
    setClippedLabel(self.exportTextStatusLabel, string.format("Receiving %d chunks from source server...", self.exportTextExpected), EXPORT_RIGHT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:flushExportTextChunks()
    if not self.exportTextWriter or not self.exportTextChunks then return true end
    while self.exportTextChunks[self.exportTextNextIndex or 1] ~= nil do
        local index = self.exportTextNextIndex or 1
        local chunk = self.exportTextChunks[index]
        self.exportTextChunks[index] = nil
        local ok = pcall(function() self.exportTextWriter:write(chunk) end)
        if not ok then
            pcall(function() self.exportTextWriter:close() end)
            self.exportTextWriter = nil
            self.exportTextChunks = nil
            self.exportTextSeen = nil
            setClippedLabel(self.exportTextStatusLabel, "Local export write failed.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
            return false
        end
        self.exportTextNextIndex = index + 1
    end
    return true
end

function AE_MainDialog:addExportTextChunk(r)
    if not self.exportTextWriter or not self.exportTextChunks or r.sessionId ~= self.exportTextSession then return end
    local index = tonumber(r.index or 0) or 0
    if index < 1 or (self.exportTextExpected and index > self.exportTextExpected) then
        setClippedLabel(self.exportTextStatusLabel, "Local export download failed: invalid chunk index.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
        pcall(function() self.exportTextWriter:close() end)
        self.exportTextWriter = nil
        self.exportTextChunks = nil
        self.exportTextSeen = nil
        return
    end
    local chunk = tostring(r.chunk or "")
    if not self.exportTextSeen[index] then
        self.exportTextSeen[index] = true
        self.exportTextReceived = (self.exportTextReceived or 0) + 1
        self.exportTextBytes = (self.exportTextBytes or 0) + #chunk
        if #(self.exportTextMetadataSample or "") < 65536 then
            self.exportTextMetadataSample = (self.exportTextMetadataSample or "") .. chunk
            if #self.exportTextMetadataSample > 65536 then
                self.exportTextMetadataSample = string.sub(self.exportTextMetadataSample, 1, 65536)
            end
        end
        self.exportTextChunks[index] = chunk
        if not self:flushExportTextChunks() then return end
        if self.exportTextStatusLabel and self.exportTextReceived % 10 == 0 then
            setClippedLabel(self.exportTextStatusLabel, string.format("Received %d / %d chunks...", self.exportTextReceived, self.exportTextExpected or 0), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        end
    end
end

function AE_MainDialog:finishExportText(r)
    if not r.success then
        setClippedLabel(self.exportTextStatusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    if not self.exportTextWriter or not self.exportTextChunks or r.sessionId ~= self.exportTextSession then return end
    if self.exportTextStatusLabel then
        local expected = tonumber(r.totalChunks or self.exportTextExpected or 0) or 0
        if self.exportTextReceived ~= expected or (self.exportTextNextIndex or 1) ~= expected + 1 then
            local missing = self.exportTextNextIndex or (self.exportTextReceived + 1)
            pcall(function() self.exportTextWriter:close() end)
            self.exportTextWriter = nil
            self.exportTextChunks = nil
            self.exportTextSeen = nil
            self.pendingExportEntry = nil
            setClippedLabel(self.exportTextStatusLabel, "Local export incomplete: missing chunk " .. tostring(missing) .. ".", EXPORT_RIGHT_TEXT_W, UIFont.Small)
            return
        end

        local expectedBytes = tonumber(r.bytes or 0) or 0
        if expectedBytes > 0 and self.exportTextBytes ~= expectedBytes then
            pcall(function() self.exportTextWriter:close() end)
            self.exportTextWriter = nil
            self.exportTextChunks = nil
            self.exportTextSeen = nil
            self.pendingExportEntry = nil
            setClippedLabel(self.exportTextStatusLabel, string.format("Local export incomplete: %d/%d bytes.", self.exportTextBytes, expectedBytes), EXPORT_RIGHT_TEXT_W, UIFont.Small)
            return
        end

        local ok, err = pcall(function() self.exportTextWriter:close() end)
        self.exportTextWriter = nil
        if ok then
            local pending = self.pendingExportEntry or {}
            local metadata = r.metadata or pending.metadata or parseExportMetadataFromText(self.exportTextMetadataSample or "")
            local center = metadata.center or { x = metadata.centerX, y = metadata.centerY }
            local filename = safeTransferName(r.filename or pending.filename or self:getExportFilename())
            local exportResult = self.exportResult or {}
            local entry = {
                name = filename,
                filename = filename,
                bytes = tonumber(r.bytes or pending.bytes or exportResult.bytes or self.exportTextBytes or 0) or 0,
                tileCount = tonumber(r.tileCount or pending.tileCount or exportResult.tileCount or metadata.tileCount or 0) or 0,
                objectCount = tonumber(r.objectCount or pending.objectCount or exportResult.objectCount or 0) or 0,
                radius = tonumber(metadata.radius or 0) or 0,
                centerX = tonumber(center.x or 0) or 0,
                centerY = tonumber(center.y or 0) or 0,
                createdAt = nowMs(),
            }
            local indexOk, indexErr = upsertLocalExport(entry)
            if indexOk then
                self:refreshLocalExports(filename)
                setClippedLabel(self.exportTextStatusLabel, string.format("Saved %s (%s).", filename, formatKb(entry.bytes)), EXPORT_RIGHT_TEXT_W, UIFont.Small)
                setClippedLabel(self.statusLabel, "Local export saved.", EXPORT_LEFT_TEXT_W, UIFont.Small)
                self.pendingLocalExportName = nil
            else
                setClippedLabel(self.exportTextStatusLabel, "Saved JSON, but index update failed: " .. tostring(indexErr), EXPORT_RIGHT_TEXT_W, UIFont.Small)
            end
        else
            setClippedLabel(self.exportTextStatusLabel, "Local export close failed: " .. tostring(err), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        end
    end
    self.exportTextWriter = nil
    self.exportTextChunks = nil
    self.exportTextSeen = nil
    self.exportTextMetadataSample = ""
    self.pendingExportEntry = nil
end

function AE_MainDialog:resetExportPackageState()
    if self.exportPackageWriter then pcall(function() self.exportPackageWriter:close() end) end
    self.exportPackageSession = nil
    self.exportPackageWriter = nil
    self.exportPackageChunks = nil
    self.exportPackageSeen = nil
    self.exportPackageNextIndex = 1
    self.exportPackageReceived = 0
    self.exportPackageBytes = 0
    self.exportPackageWroteAny = false
    self.exportPackageProgress = nil
    self.pendingExportEntry = nil
end

function AE_MainDialog:startExportPackage(r)
    if not r.success then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    self:resetExportPackageState()
    local filename = safeTransferName(r.filename or self.pendingLocalExportName or self:getExportFilename())
    self.exportPackageSession = r.sessionId
    self.exportPackageChunks = {}
    self.exportPackageSeen = {}
    self.exportPackageNextIndex = 1
    self.exportPackageReceived = 0
    self.exportPackageBytes = 0
    self.exportPackageWroteAny = false
    self.exportPackageProgress = {
        visited = tonumber(r.visitedPositions or 0) or 0,
        total = tonumber(r.totalPositions or 0) or 0,
        percent = clampPercent(r.progressPercent or 0),
        tileCount = 0,
        transferParts = 0,
    }
    self.pendingExportEntry = {
        filename = filename,
        metadata = r.metadata,
        formatVersion = tonumber(r.format_version or 2) or 2,
        package = true,
    }

    local ok, writerOrErr = pcall(function()
        return getFileWriter(clientTransferTilesPath(filename), true, false)
    end)
    if not ok or not writerOrErr then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Could not open package tile file.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export could not start local save.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    self.exportPackageWriter = writerOrErr
    setClippedLabel(self.exportTextStatusLabel, string.format("Export scan: 0/%d map positions, 0 transfer parts.",
        self.exportPackageProgress.total or 0), EXPORT_RIGHT_TEXT_W, UIFont.Small)
    setClippedLabel(self.statusLabel, "Streaming export package...", EXPORT_LEFT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:updateExportPackageProgress(r)
    if r and r.sessionId and self.exportPackageSession and r.sessionId ~= self.exportPackageSession then return end
    local total = tonumber(r and r.totalPositions or (self.exportPackageProgress and self.exportPackageProgress.total) or 0) or 0
    local visited = tonumber(r and r.visitedPositions or (self.exportPackageProgress and self.exportPackageProgress.visited) or 0) or 0
    local percent = clampPercent(r and r.progressPercent or (total > 0 and (visited * 100 / total) or 0))
    local transferParts = tonumber(r and (r.transferParts or r.index) or self.exportPackageReceived or 0) or 0
    local tileCount = tonumber(r and r.tileCount or (self.exportPackageProgress and self.exportPackageProgress.tileCount) or 0) or 0
    self.exportPackageProgress = {
        visited = visited,
        total = total,
        percent = percent,
        transferParts = transferParts,
        tileCount = tileCount,
    }
    setClippedLabel(self.exportTextStatusLabel,
        string.format("Export scan: %d/%d map positions (%d%%), %d transfer parts, %d saved tiles.",
            visited, total, percent, transferParts, tileCount),
        EXPORT_RIGHT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:flushExportPackageChunks()
    if not self.exportPackageWriter or not self.exportPackageChunks then return true end
    while self.exportPackageChunks[self.exportPackageNextIndex or 1] ~= nil do
        local index = self.exportPackageNextIndex or 1
        local chunk = self.exportPackageChunks[index]
        self.exportPackageChunks[index] = nil
        local ok = pcall(function()
            self.exportPackageWriter:write(chunk)
        end)
        if not ok then
            self:resetExportPackageState()
            setClippedLabel(self.exportTextStatusLabel, "Local package write failed.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
            setClippedLabel(self.statusLabel, "Export failed while saving locally.", EXPORT_LEFT_TEXT_W, UIFont.Small)
            return false
        end
        self.exportPackageWroteAny = true
        self.exportPackageNextIndex = index + 1
    end
    return true
end

function AE_MainDialog:addExportPackageChunk(r)
    if not self.exportPackageWriter or not self.exportPackageChunks or r.sessionId ~= self.exportPackageSession then return end
    if not r.success then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Export stream failed: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    local index = tonumber(r.index or 0) or 0
    if index < 1 then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Export stream failed: invalid chunk index.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
        return
    end
    if not self.exportPackageSeen[index] then
        self.exportPackageSeen[index] = true
        self.exportPackageChunks[index] = tostring(r.chunk or "")
        self.exportPackageReceived = (self.exportPackageReceived or 0) + 1
        self.exportPackageBytes = tonumber(r.bytes or self.exportPackageBytes or 0) or 0
        if not self:flushExportPackageChunks() then return end
        self:updateExportPackageProgress(r)
    end
end

function AE_MainDialog:finishExportPackage(r)
    if not r.success then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Export failed: " .. tostring(r.error or "unknown"), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end
    if not self.exportPackageWriter or r.sessionId ~= self.exportPackageSession then return end
    if not self:flushExportPackageChunks() then return end

    local expected = tonumber(r.totalChunks or self.exportPackageReceived or 0) or 0
    if self.exportPackageReceived ~= expected or (self.exportPackageNextIndex or 1) ~= expected + 1 then
        local missing = self.exportPackageNextIndex or (self.exportPackageReceived + 1)
        local received = self.exportPackageReceived or 0
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, string.format("Local package incomplete: received %d/%d transfer parts; missing part %d.",
            received, expected, missing), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export package incomplete.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local ok, err = pcall(function() self.exportPackageWriter:close() end)
    self.exportPackageWriter = nil
    if not ok then
        self:resetExportPackageState()
        setClippedLabel(self.exportTextStatusLabel, "Local package close failed: " .. tostring(err), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export package close failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local pending = self.pendingExportEntry or {}
    local filename = safeTransferName(r.filename or pending.filename or self:getExportFilename())
    local manifest = r.manifest or {}
    manifest.name = filename
    manifest.filename = filename
    manifest.formatVersion = tonumber(manifest.formatVersion or manifest.format_version or 2) or 2
    manifest.format_version = manifest.formatVersion
    manifest.package = true
    manifest.kind = "AreaExportPackage"
    manifest.bytes = tonumber(r.bytes or manifest.bytes or self.exportPackageBytes or 0) or 0
    manifest.tileCount = tonumber(r.tileCount or manifest.tileCount or 0) or 0
    manifest.objectCount = tonumber(r.objectCount or manifest.objectCount or 0) or 0
    manifest.visitedPositions = tonumber(r.visitedPositions or manifest.visitedPositions or 0) or 0
    manifest.totalPositions = tonumber(r.totalPositions or manifest.totalPositions or 0) or 0
    manifest.metadata = manifest.metadata or r.metadata or pending.metadata or {}
    local center = manifest.metadata.center or {}
    manifest.radius = tonumber(manifest.metadata.radius or manifest.radius or 0) or 0
    manifest.centerX = tonumber(center.x or manifest.centerX or 0) or 0
    manifest.centerY = tonumber(center.y or manifest.centerY or 0) or 0
    manifest.createdAt = nowMs()

    local manifestOk, manifestErr = writeClientTransferManifest(manifest)
    local indexOk, indexErr = false, nil
    if manifestOk then
        indexOk, indexErr = upsertLocalExport(manifest)
    end
    if manifestOk and indexOk then
        self.lastServerExportName = nil
        self.pendingLocalExportName = nil
        self:refreshLocalExports(filename)
        setClippedLabel(self.exportTextStatusLabel, string.format("Saved %s: %d package tiles, %d transfer parts, %s.",
            filename, manifest.tileCount or 0, expected, formatKb(manifest.bytes)), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, string.format("Exported %d package tiles locally.", manifest.tileCount or 0), EXPORT_LEFT_TEXT_W, UIFont.Small)
    else
        setClippedLabel(self.exportTextStatusLabel, "Package saved, but metadata failed: " .. tostring(manifestErr or indexErr), EXPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.statusLabel, "Export metadata failed.", EXPORT_LEFT_TEXT_W, UIFont.Small)
    end
    self:resetExportPackageState()
end

function AE_MainDialog:onPickCenter()
    AE_TilePicker.activate()
    setClippedLabel(self.statusLabel, "Click a tile in the world to set the center.", EXPORT_LEFT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:onPreview()
    if not AE_Globals.pickedCenter then
        setClippedLabel(self.statusLabel, "Pick a center first.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local radius = self:getRadius()
    local centerX = AE_Globals.pickedCenter.x
    local centerY = AE_Globals.pickedCenter.y
    AE_TilePicker.setPreviewRadius(radius)
    setClippedLabel(self.statusLabel, "Scanning area...", EXPORT_LEFT_TEXT_W, UIFont.Small)

    sendClientCommand(getPlayer(), AE_Constants.MODULE, "scan", {
        centerX = centerX,
        centerY = centerY,
        radius = radius,
    })
end

function AE_MainDialog:onExport()
    if not AE_Globals.pickedCenter then
        setClippedLabel(self.statusLabel, "Pick a center first.", EXPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local radius = self:getRadius()
    local filename = self:getNewLocalExportFilename()
    self.pendingLocalExportName = filename
    self.lastServerExportName = nil
    self:resetExportPackageState()
    setClippedLabel(self.statusLabel, "Starting streaming package export...", EXPORT_LEFT_TEXT_W, UIFont.Small)
    setClippedLabel(self.exportTextStatusLabel, "Preparing local package writer...", EXPORT_RIGHT_TEXT_W, UIFont.Small)

    print("[AreaExport] requested export " .. tostring(filename))
    sendClientCommand(getPlayer(), AE_Constants.MODULE, "exportPackage", {
        centerX = AE_Globals.pickedCenter.x,
        centerY = AE_Globals.pickedCenter.y,
        radius = radius,
        filename = filename,
    })
end

function AE_MainDialog:onLoadExportText()
    setClippedLabel(self.exportTextStatusLabel, "Current exports are saved locally during Export automatically.", EXPORT_RIGHT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:onImport()
    setClippedLabel(self.importStatusLabel, "Importing original coordinates/radius...", IMPORT_LEFT_TEXT_W, UIFont.Small)
    sendClientCommand(getPlayer(), AE_Constants.MODULE, "import", {
        filename = self:getImportFilename(),
        rulesJson = self:getRulesJson(),
    })
end

function AE_MainDialog:onImportPastedText()
    local selected = self:getSelectedLocalExport()
    local selectedName = selected and selected.filename or self:getImportFilename()
    self.currentImportName = selectedName
    setClippedLabel(self.lastImportTitleLabel, "Last Import: running " .. tostring(selectedName), IMPORT_RIGHT_TEXT_W, UIFont.Small)
    self.importedSquaresValue:setName("0")
    self.failedSquaresValue:setName("0")
    self.addedItemsValue:setName("0 / 0")
    self.missingContainersValue:setName("0")

    if selected and selected.package then
        local ok, err = self:startPackageTransfer("importPackage", selected)
        if ok then
            setClippedLabel(self.importStatusLabel, "Importing selected package...", IMPORT_LEFT_TEXT_W, UIFont.Small)
            return
        end
        setClippedLabel(self.pasteStatusLabel, "Import could not start: " .. tostring(err), IMPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.importStatusLabel, "Import could not start.", IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    if selected and (selected.bytes or 0) > LEGACY_LARGE_FILE_LIMIT then
        setClippedLabel(self.pasteStatusLabel, "Legacy JSON is too large. Re-export with the current package format.", IMPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.importStatusLabel, "Import refused to protect the client heap.", IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local text = readClientTransferFile(selectedName)
    if not text or text == "" then
        setClippedLabel(self.pasteStatusLabel, "Selected export file is empty or missing.", IMPORT_RIGHT_TEXT_W, UIFont.Small)
        setClippedLabel(self.importStatusLabel, "Import could not start.", IMPORT_LEFT_TEXT_W, UIFont.Small)
        return
    end

    local chunks = splitChunks(text, JSON_CHUNK_SIZE)
    setClippedLabel(self.pasteStatusLabel, string.format("Import upload: 0/%d chunks queued.", #chunks), IMPORT_RIGHT_TEXT_W, UIFont.Small)
    setClippedLabel(self.importStatusLabel, "Importing selected local export...", IMPORT_LEFT_TEXT_W, UIFont.Small)
    self:sendChunkedTextCommand("importText", text)
end

function AE_MainDialog:onClearPastedText()
    setClippedLabel(self.pasteStatusLabel, "Local export import is ready.", IMPORT_RIGHT_TEXT_W, UIFont.Small)
end

function AE_MainDialog:getRulesArray()
    local rules = {}
    for _, rule in pairs(self.mappingRules or {}) do
        if rule.kind and rule.id and rule.action then
            rules[#rules + 1] = {
                kind = rule.kind,
                id = rule.id,
                action = rule.action,
                replacement = rule.replacement,
            }
        end
    end
    return rules
end

function AE_MainDialog:getRulesJson()
    return AE_Json.encode(self:getRulesArray())
end

function AE_MainDialog:getTransferLabel(prefix)
    if prefix == "validateText" then return self.validateStatusLabel, 520 end
    if prefix == "importText" then return self.pasteStatusLabel or self.importStatusLabel, 380 end
    return nil, 500
end

function AE_MainDialog:getTransferName(prefix)
    if prefix == "validateText" then return "Dry Run" end
    if prefix == "importText" then return "Import" end
    return "Transfer"
end

function AE_MainDialog:setTransferStatus(prefix, message)
    local label, maxWidth = self:getTransferLabel(prefix)
    if label then label:setName(truncateText(UIFont.Small, message, maxWidth or 500)) end
end

function AE_MainDialog:startTextTransfer(prefix, sessionId, totalChunks, bytes)
    -- Track long-running uploads separately for Import and Dry Run. The status
    -- label is not just cosmetic: it tells admins whether the client is uploading,
    -- the server is processing, or the dialog is waiting for the final result.
    self.textTransfers = self.textTransfers or {}
    self.textTransfers[prefix] = {
        sessionId = sessionId,
        totalChunks = tonumber(totalChunks or 0) or 0,
        bytes = tonumber(bytes or 0) or 0,
        confirmedChunks = 0,
        phase = "upload",
        startedAt = nowMs(),
        lastStatusAt = 0,
    }
    self:setTransferStatus(prefix, string.format("%s upload: 0/%d chunks (%s).",
        self:getTransferName(prefix), totalChunks or 0, formatKb(bytes)))
end

function AE_MainDialog:updateTextTransferStatus(prefix, force)
    local state = self.textTransfers and self.textTransfers[prefix]
    if not state then return end

    local now = nowMs()
    if not force and state.lastStatusAt and now - state.lastStatusAt < 900 then return end
    state.lastStatusAt = now

    local total = state.totalChunks or 0
    local confirmed = state.confirmedChunks or 0
    local elapsed = elapsedSeconds(state.startedAt)
    if state.phase == "processing" then
        self:setTransferStatus(prefix, string.format("%s: server processing %s after %d/%d chunks (%ds).",
            self:getTransferName(prefix), formatKb(state.bytes), confirmed, total, elapsed))
    elseif state.phase == "waiting" then
        self:setTransferStatus(prefix, string.format("%s: waiting for server response (%ds).",
            self:getTransferName(prefix), elapsed))
    else
        self:setTransferStatus(prefix, string.format("%s upload: %d/%d chunks confirmed (%s, %ds).",
            self:getTransferName(prefix), confirmed, total, formatKb(state.bytes), elapsed))
    end
end

function AE_MainDialog:updateActiveTransfers()
    if not self.textTransfers then return end
    for prefix, state in pairs(self.textTransfers) do
        if state and (state.phase == "processing" or state.phase == "waiting") then
            self:updateTextTransferStatus(prefix, false)
        end
    end
end

function AE_MainDialog:processOutboundTransfers()
    -- Legacy v1 JSON support. The public package workflow uses
    -- processPackageTransfers below so large exports are never split from a
    -- preloaded client string.
    if not self.outboundTextTransfers then return end
    for prefix, transfer in pairs(self.outboundTextTransfers) do
        if transfer and not transfer.finishSent then
            local chunks = transfer.chunks or {}
            local sent = transfer.sentChunks or 0
            local maxSend = math.min(#chunks, sent + TEXT_CHUNKS_PER_UPDATE)
            for i = sent + 1, maxSend do
                sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Chunk", {
                    sessionId = transfer.sessionId,
                    index = i,
                    chunk = chunks[i],
                })
            end
            transfer.sentChunks = maxSend
            if maxSend >= #chunks then
                transfer.finishSent = true
                local state = self.textTransfers and self.textTransfers[prefix]
                if state then
                    state.phase = "waiting"
                    self:updateTextTransferStatus(prefix, true)
                end
                sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Finish", {
                    sessionId = transfer.sessionId,
                })
            end
        end
    end
end

function AE_MainDialog:onTextTransferStart(prefix, r)
    local state = self.textTransfers and self.textTransfers[prefix]
    if not r.success then
        self:setTransferStatus(prefix, self:getTransferName(prefix) .. " failed to start: " .. tostring(r.error or "unknown"))
        if state then self.textTransfers[prefix] = nil end
        if self.outboundTextTransfers then self.outboundTextTransfers[prefix] = nil end
        return
    end
    if not state then
        self:startTextTransfer(prefix, r.sessionId, r.totalChunks or 0, r.bytes or 0)
    end
    self:updateTextTransferStatus(prefix, true)
end

function AE_MainDialog:onTextTransferChunk(prefix, r)
    local state = self.textTransfers and self.textTransfers[prefix]
    if not r.success then
        self:setTransferStatus(prefix, self:getTransferName(prefix) .. " upload failed: " .. tostring(r.error or "unknown"))
        if state then self.textTransfers[prefix] = nil end
        if self.outboundTextTransfers then self.outboundTextTransfers[prefix] = nil end
        return
    end
    if not state then
        self:startTextTransfer(prefix, r.sessionId, r.totalChunks or 0, r.bytes or 0)
        state = self.textTransfers[prefix]
    end
    state.confirmedChunks = math.max(state.confirmedChunks or 0, tonumber(r.index or 0) or 0)
    if r.totalChunks then state.totalChunks = tonumber(r.totalChunks) or state.totalChunks end
    if r.bytes then state.bytes = tonumber(r.bytes) or state.bytes end
    if state.totalChunks > 0 and state.confirmedChunks >= state.totalChunks then
        state.phase = "processing"
        self:updateTextTransferStatus(prefix, true)
    else
        state.phase = "upload"
        self:updateTextTransferStatus(prefix, false)
    end
end

function AE_MainDialog:finishTextTransfer(prefix)
    if self.textTransfers then self.textTransfers[prefix] = nil end
    if self.outboundTextTransfers then self.outboundTextTransfers[prefix] = nil end
end

function AE_MainDialog:sendChunkedTextCommand(prefix, text)
    -- Import/Validate use the same chunk protocol. Rules are sent with the Start
    -- command so the server applies exactly the decisions visible in the UI.
    local chunks = splitChunks(text, JSON_CHUNK_SIZE)
    local sessionId = tostring(nowMs()) .. "-" .. tostring(ZombRand and ZombRand(1000000) or math.random(1000000))
    self:startTextTransfer(prefix, sessionId, #chunks, #text)
    self.outboundTextTransfers = self.outboundTextTransfers or {}
    self.outboundTextTransfers[prefix] = {
        sessionId = sessionId,
        chunks = chunks,
        sentChunks = 0,
        finishSent = false,
    }
    sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Start", {
        sessionId = sessionId,
        totalChunks = #chunks,
        bytes = #text,
        rulesJson = self:getRulesJson(),
    })
end

function AE_MainDialog:getPackageTransferLabel(prefix)
    if prefix == "validatePackage" then return self.validateStatusLabel, VALIDATE_STATUS_W end
    if prefix == "importPackage" then return self.pasteStatusLabel or self.importStatusLabel, IMPORT_RIGHT_TEXT_W end
    return nil, 500
end

function AE_MainDialog:getPackageTransferName(prefix)
    if prefix == "validatePackage" then return "Dry Run" end
    if prefix == "importPackage" then return "Import" end
    return "Package"
end

function AE_MainDialog:setPackageTransferStatus(prefix, message)
    local label, maxWidth = self:getPackageTransferLabel(prefix)
    if label then setClippedLabel(label, message, maxWidth or 500, UIFont.Small) end
end

function AE_MainDialog:finishPackageTransfer(prefix)
    if not self.packageTransfers then return end
    local state = self.packageTransfers[prefix]
    if state and state.reader then pcall(function() state.reader:close() end) end
    self.packageTransfers[prefix] = nil
end

function AE_MainDialog:getPackageTransferPercent(prefix)
    local state = self.packageTransfers and self.packageTransfers[prefix]
    if not state then return 0 end
    if state.phase == "clearing" then
        local total = tonumber(state.clearTotal or 0) or 0
        if total > 0 then return clampPercent(((tonumber(state.clearVisited or 0) or 0) * 100) / total) end
    elseif state.phase == "importing" then
        local total = tonumber(state.totalLines or 0) or 0
        if total > 0 then return clampPercent(((tonumber(state.importedLines or 0) or 0) * 100) / total) end
    else
        local total = tonumber(state.totalLines or 0) or 0
        if total > 0 then return clampPercent(((tonumber(state.confirmedLines or 0) or 0) * 100) / total) end
    end
    if state.progressPercent then return clampPercent(state.progressPercent) end
    return 0
end

function AE_MainDialog:updatePackageTransferStatus(prefix, force)
    local state = self.packageTransfers and self.packageTransfers[prefix]
    if not state then return end
    local now = nowMs()
    if not force and state.lastStatusAt and now - state.lastStatusAt < 900 then return end
    state.lastStatusAt = now

    local elapsed = elapsedSeconds(state.startedAt)
    local name = self:getPackageTransferName(prefix)
    local totalLines = tonumber(state.totalLines or 0) or 0
    local percent = self:getPackageTransferPercent(prefix)
    if state.phase == "starting" then
        self:setPackageTransferStatus(prefix, string.format("%s: opening package session (%ds).", name, elapsed))
    elseif state.phase == "clearing" then
        self:setPackageTransferStatus(prefix, string.format("%s clearing target: %d/%d positions (%d%%, %ds).",
            name, state.clearVisited or 0, state.clearTotal or 0, percent, elapsed))
    elseif state.phase == "importing" then
        self:setPackageTransferStatus(prefix, string.format("%s rebuild: %d/%d package tiles (%d%%, %ds).",
            name, state.importedLines or state.confirmedLines or 0, totalLines, percent, elapsed))
    elseif state.phase == "waiting" then
        self:setPackageTransferStatus(prefix, string.format("%s: waiting for server result after %d/%d package tiles (%ds).",
            name, state.confirmedLines or 0, totalLines, elapsed))
    elseif prefix == "validatePackage" then
        self:setPackageTransferStatus(prefix, string.format("%s scan: %d/%d package tiles checked in %d transfer parts (%d%%, %ds).",
            name, state.confirmedLines or 0, totalLines, state.confirmedChunks or 0, percent, elapsed))
    else
        self:setPackageTransferStatus(prefix, string.format("%s upload: %d/%d package tiles in %d transfer parts (%d%%, %ds).",
            name, state.confirmedLines or 0, totalLines, state.confirmedChunks or 0, percent, elapsed))
    end
end

function AE_MainDialog:startPackageTransfer(prefix, selected)
    selected = selected or self:getSelectedLocalExport()
    if not selected or not selected.package then return false, "selected export is not a package" end

    local manifestText = readClientFile(clientTransferManifestPath(selected.filename))
    if not manifestText or manifestText == "" then
        manifestText = AE_Json.encode(normalizeExportEntry(selected))
    end
    local ok, readerOrErr = pcall(function()
        return getFileReader(clientTransferTilesPath(selected.filename), false)
    end)
    if not ok or not readerOrErr then
        return false, "could not open package tile file"
    end

    local sessionId = tostring(nowMs()) .. "-" .. tostring(ZombRand and ZombRand(1000000) or math.random(1000000))
    self.packageTransfers = self.packageTransfers or {}
    self.packageTransfers[prefix] = {
        sessionId = sessionId,
        reader = readerOrErr,
        phase = "starting",
        selectedName = selected.filename,
        sentChunks = 0,
        confirmedChunks = 0,
        sentLines = 0,
        confirmedLines = 0,
        importedLines = 0,
        totalLines = tonumber(selected.tileCount or selected.tiles or 0) or 0,
        progressPercent = 0,
        pendingLine = nil,
        pendingPayload = "",
        waitingChunk = false,
        finishSent = false,
        startedAt = nowMs(),
        lastStatusAt = 0,
    }
    self:updatePackageTransferStatus(prefix, true)
    sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Start", {
        sessionId = sessionId,
        manifestJson = manifestText,
        rulesJson = self:getRulesJson(),
    })
    return true
end

function AE_MainDialog:processPackageTransfers()
    if not self.packageTransfers then return end
    for prefix, state in pairs(self.packageTransfers) do
        if state then
            self:updatePackageTransferStatus(prefix, false)
            if state.phase == "upload" and not state.waitingChunk and not state.finishSent then
                local payload = tostring(state.pendingPayload or "")
                state.pendingPayload = ""
                local readOk, readErr = true, nil
                if payload == "" then
                    for _ = 1, PACKAGE_LINES_PER_UPDATE do
                        local line = state.pendingLine
                        state.pendingLine = nil
                        if line == nil then
                            local ok, readLine = pcall(function() return state.reader:readLine() end)
                            if not ok then
                                readOk = false
                                readErr = readLine
                                break
                            end
                            line = readLine
                        end
                        if not line then break end
                        if line ~= "" then
                            payload = payload .. line .. "\n"
                            state.sentLines = (state.sentLines or 0) + 1
                            if #payload >= PACKAGE_CHUNK_BYTE_TARGET then break end
                        end
                    end
                end

                if not readOk then
                    self:setPackageTransferStatus(prefix, self:getPackageTransferName(prefix) .. " failed while reading package: " .. tostring(readErr))
                    self:finishPackageTransfer(prefix)
                elseif payload ~= "" then
                    local chunk = payload
                    if #chunk > PACKAGE_CHUNK_BYTE_TARGET then
                        chunk = string.sub(payload, 1, PACKAGE_CHUNK_BYTE_TARGET)
                        state.pendingPayload = string.sub(payload, PACKAGE_CHUNK_BYTE_TARGET + 1)
                    end
                    state.sentChunks = (state.sentChunks or 0) + 1
                    state.waitingChunk = true
                    sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Chunk", {
                        sessionId = state.sessionId,
                        index = state.sentChunks,
                        chunk = chunk,
                    })
                else
                    state.finishSent = true
                    state.phase = "waiting"
                    pcall(function() state.reader:close() end)
                    state.reader = nil
                    self:updatePackageTransferStatus(prefix, true)
                    sendClientCommand(getPlayer(), AE_Constants.MODULE, prefix .. "Finish", {
                        sessionId = state.sessionId,
                    })
                end
            end
        end
    end
end

function AE_MainDialog:onPackageTransferStart(prefix, r)
    local state = self.packageTransfers and self.packageTransfers[prefix]
    if not r.success then
        self:setPackageTransferStatus(prefix, self:getPackageTransferName(prefix) .. " failed to start: " .. tostring(r.error or "unknown"))
        self:finishPackageTransfer(prefix)
        return
    end
    if not state then return end
    if prefix == "importPackage" and r.phase == "clearing" then
        state.phase = "clearing"
    else
        state.phase = "upload"
    end
    if r.totalLines then state.totalLines = tonumber(r.totalLines) or state.totalLines end
    state.progressPercent = tonumber(r.progressPercent or state.progressPercent or 0) or 0
    self:updatePackageTransferStatus(prefix, true)
end

function AE_MainDialog:onImportPackageReady(r)
    local state = self.packageTransfers and self.packageTransfers.importPackage
    if not r.success then
        self:setPackageTransferStatus("importPackage", "Import failed while clearing footprint: " .. tostring(r.error or "unknown"))
        self:finishPackageTransfer("importPackage")
        return
    end
    if not state or state.sessionId ~= r.sessionId then return end
    state.phase = "upload"
    self:updatePackageTransferStatus("importPackage", true)
end

function AE_MainDialog:onImportPackageProgress(r)
    local state = self.packageTransfers and self.packageTransfers.importPackage
    if not r.success then
        self:setPackageTransferStatus("importPackage", "Import failed while processing package: " .. tostring(r.error or "unknown"))
        self:finishPackageTransfer("importPackage")
        return
    end
    if not state or state.sessionId ~= r.sessionId then return end
    state.phase = r.phase or state.phase
    state.clearVisited = tonumber(r.clearVisited or state.clearVisited or 0) or 0
    state.clearTotal = tonumber(r.clearTotal or state.clearTotal or 0) or 0
    state.importedLines = tonumber(r.importedLines or r.lines or state.importedLines or 0) or 0
    state.totalLines = tonumber(r.totalLines or state.totalLines or 0) or 0
    state.progressPercent = tonumber(r.progressPercent or state.progressPercent or 0) or 0
    self:updatePackageTransferStatus("importPackage", true)
end

function AE_MainDialog:onPackageTransferChunk(prefix, r)
    local state = self.packageTransfers and self.packageTransfers[prefix]
    if not r.success then
        self:setPackageTransferStatus(prefix, self:getPackageTransferName(prefix) .. " upload failed: " .. tostring(r.error or "unknown"))
        self:finishPackageTransfer(prefix)
        return
    end
    if not state or state.sessionId ~= r.sessionId then return end
    state.confirmedChunks = math.max(state.confirmedChunks or 0, tonumber(r.index or 0) or 0)
    state.confirmedLines = tonumber(r.lines or state.confirmedLines or 0) or 0
    if r.totalLines then state.totalLines = tonumber(r.totalLines) or state.totalLines end
    state.progressPercent = tonumber(r.progressPercent or state.progressPercent or 0) or 0
    state.waitingChunk = false
    state.phase = "upload"
    self:updatePackageTransferStatus(prefix, true)
end

function AE_MainDialog:getSelectedReplacementType()
    local typed = self.replacementSearchBox and self.replacementSearchBox:getText() or ""
    if self.selectedConflict and self.selectedConflict.kind ~= "Item" and typed and typed ~= "" then return typed end
    if typed and string.find(typed, ".", 1, true) then return typed end
    if not self.replacementList or not self.replacementList.items then return nil end
    local item = self.replacementList.items[self.replacementList.selected or 1]
    if not item or not item.item then return nil end
    return item.item.type
end

function AE_MainDialog:updateRuleButtons(action)
    local function setButtonState(btn, mode, active)
        if not btn then return end
        applyButtonStyle(btn, mode)
        if active then
            btn.borderColor = {r=THEME.borderHot.r, g=THEME.borderHot.g, b=THEME.borderHot.b, a=1.0}
            btn.backgroundColor = {r=0.22, g=0.18, b=0.08, a=1.0}
        end
    end
    setButtonState(self.addActionSkip, "danger", action == "Skip")
    setButtonState(self.addActionReplace, "warning", action == "Replace")
    setButtonState(self.addActionOriginal, nil, action == "Use Original")
    setButtonState(self.addActionPlaceholder, nil, action == "Placeholder")
end

function AE_MainDialog:updateSelectedConflictPanel(row)
    if not row then return end
    setClippedLabel(self.selectedConflictLabel, (row.kind or "Item") .. ": " .. tostring(row.id or "unknown"), VALIDATE_RULE_W, UIFont.Small)
    if self.selectedActionLabel then
        local action = row.action or "Review"
        local text = "Action: " .. action
        if action == "Replace" and row.replacement then
            text = text .. " -> " .. tostring(row.replacement)
        end
        setClippedLabel(self.selectedActionLabel, text, VALIDATE_RULE_W, UIFont.Small)
    end
    if self.selectedReasonLabel then
        setClippedLabel(self.selectedReasonLabel, row.message or "Review this conflict before importing.", VALIDATE_RULE_W, UIFont.Small)
    end
    self:updateRuleButtons(row.action or "Review")
end

function AE_MainDialog:forgetRule(row)
    local key = conflictRuleKey(row)
    if key and self.mappingRules then self.mappingRules[key] = nil end
end

function AE_MainDialog:rememberRule(row)
    local key = conflictRuleKey(row)
    if not key then return end
    if row.action == "Use Original" or row.action == "Review" then
        self:forgetRule(row)
        return
    end
    self.mappingRules[key] = {
        kind = row.kind,
        id = row.id,
        action = row.action,
        replacement = row.replacement,
    }
end

function AE_MainDialog:applyRuleToSelected(action)
    local row = self.selectedConflict
    if not row then
        setClippedLabel(self.validateStatusLabel, "Select a conflict first.", VALIDATE_STATUS_W, UIFont.Small)
        return
    end
    if row.kind == "Object" and action == "Replace" then
        setClippedLabel(self.validateStatusLabel, "Object conflicts can be skipped, but not replaced automatically.", VALIDATE_STATUS_W, UIFont.Small)
        return
    end
    if row.kind ~= "Item" and action == "Placeholder" then
        setClippedLabel(self.validateStatusLabel, "Placeholders are only available for item conflicts.", VALIDATE_STATUS_W, UIFont.Small)
        return
    end
    if action == "Use Original" and row.kind ~= "Sprite" then
        setClippedLabel(self.validateStatusLabel, "Use Original is only available for sprite lookup warnings.", VALIDATE_STATUS_W, UIFont.Small)
        return
    end

    row.action = action
    if action == "Replace" then
        row.replacement = self:getSelectedReplacementType() or row.replacement or "Base.VHS_Retail"
    else
        row.replacement = nil
    end

    if action == "Use Original" then
        self:forgetRule(row)
    else
        self:rememberRule(row)
    end
    self:updateSelectedConflictPanel(row)
    local detail = row.action
    if row.replacement then detail = detail .. " -> " .. tostring(row.replacement) end
    setClippedLabel(self.validateStatusLabel, "Rule updated for " .. tostring(row.id or "selected conflict") .. ": " .. detail, VALIDATE_STATUS_W, UIFont.Small)
end

function AE_MainDialog:onValidate()
    self:setActiveTab("validate")
    setClippedLabel(self.validateStatusLabel, "Running Dry Run...", VALIDATE_STATUS_W, UIFont.Small)

    local selected = self:getSelectedLocalExport()
    if selected and selected.package then
        local ok, err = self:startPackageTransfer("validatePackage", selected)
        if ok then return end
        setClippedLabel(self.validateStatusLabel, "Dry Run could not start: " .. tostring(err), VALIDATE_STATUS_W, UIFont.Small)
        return
    end

    if selected and (selected.bytes or 0) > LEGACY_LARGE_FILE_LIMIT then
        setClippedLabel(self.validateStatusLabel, "Legacy JSON is too large. Re-export with the current package format.", VALIDATE_STATUS_W, UIFont.Small)
        return
    end

    local text = readClientTransferFile(self:getImportFilename())
    if text and text ~= "" then
        setClippedLabel(self.validateStatusLabel, "Dry Run upload starting...", VALIDATE_STATUS_W, UIFont.Small)
        self:sendChunkedTextCommand("validateText", text)
        return
    end

    setClippedLabel(self.validateStatusLabel, "Selected local export is missing. Create an export or refresh the list.", VALIDATE_STATUS_W, UIFont.Small)
end

function AE_MainDialog:onConflictSelected(row)
    self.selectedConflict = row
    self:updateSelectedConflictPanel(row)
end

function AE_MainDialog:onReplacementSelected(row)
    if not row or not self.selectedConflict then return end
    if self.selectedConflict.action == "Replace" then
        self.selectedConflict.replacement = row.type
        self:rememberRule(self.selectedConflict)
        self:updateSelectedConflictPanel(self.selectedConflict)
        setClippedLabel(self.validateStatusLabel, "Replacement updated to " .. tostring(row.type) .. ".", VALIDATE_STATUS_W, UIFont.Small)
    end
end

function AE_MainDialog:onSearchItems()
    local query = self.replacementSearchBox and self.replacementSearchBox:getText() or ""
    setClippedLabel(self.validateStatusLabel, "Searching item database...", VALIDATE_STATUS_W, UIFont.Small)
    sendClientCommand(getPlayer(), AE_Constants.MODULE, "searchItems", {
        query = query,
        limit = 40,
    })
end

local function getClientSquareAt(x, y, z)
    local cell = getCell and getCell() or nil
    if not cell then return nil end
    x = tonumber(x)
    y = tonumber(y)
    z = tonumber(z) or 0
    if not x or not y then return nil end
    local ok, sq = pcall(function()
        return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    end)
    if ok then return sq end
    return nil
end

local function isClientWorldInventoryObject(obj)
    if not obj then return false end
    local ok, value = pcall(function()
        if instanceof and instanceof(obj, "IsoWorldInventoryObject") then return true end
        local text = obj.toString and obj:toString() or ""
        return type(text) == "string" and string.find(text, "IsoWorldInventoryObject", 1, true) ~= nil
    end)
    return ok and value or false
end

local function countClientWorldItems(sq)
    if not sq then return 0, 0 end
    local objectCount, worldCount = 0, 0
    local ok, objects = pcall(function() return sq:getObjects() end)
    if ok and objects then
        local n = objects:size()
        for i = 0, n - 1 do
            local obj = objects:get(i)
            if isClientWorldInventoryObject(obj) then objectCount = objectCount + 1 end
        end
    end
    ok, objects = pcall(function() return sq.getWorldObjects and sq:getWorldObjects() or nil end)
    if ok and objects then worldCount = objects:size() end
    return objectCount, worldCount
end

local function removeLocalWorldItems(sq)
    -- Client-only cleanup for visual ghosts. The server decides when this is safe;
    -- the client removes local objects only when reconcileWorldItemSquare reports
    -- zero authoritative server world items on that square.
    if not sq then return 0 end
    local removed = 0
    local ok, worldObjects = pcall(function() return sq.getWorldObjects and sq:getWorldObjects() or nil end)
    if ok and worldObjects then
        local toRemove = {}
        for i = 0, worldObjects:size() - 1 do
            toRemove[#toRemove + 1] = worldObjects:get(i)
        end
        for _, obj in ipairs(toRemove) do
            pcall(function()
                if sq.removeWorldObject then sq:removeWorldObject(obj) end
                if sq.RemoveWorldObject then sq:RemoveWorldObject(obj) end
            end)
            removed = removed + 1
        end
    end
    pcall(function()
        if sq.RecalcProperties then sq:RecalcProperties() end
        if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
    end)
    return removed
end

function AE_MainDialog:startWorldItemMonitor(r)
    -- Import returns candidate squares containing loose world items. Monitor them
    -- for a short period because B42 clients can receive delayed map/item updates
    -- after the import command has technically finished.
    local squares = r and r.worldItemSquares
    if type(squares) ~= "table" or #squares == 0 then
        self.worldItemMonitor = nil
        return 0
    end
    local seconds = tonumber(r.worldItemMonitorSeconds or 120) or 120
    self.worldItemMonitor = {
        squares = squares,
        total = tonumber(r.worldItemSquareTotal or #squares) or #squares,
        index = 1,
        pending = false,
        checked = 0,
        repaired = 0,
        mismatches = 0,
        untilMs = nowMs() + seconds * 1000,
        nextAt = nowMs() + 1200,
    }
    return #squares
end

function AE_MainDialog:processWorldItemMonitor()
    -- Compare one loaded square at a time against the server. This avoids scanning
    -- the whole export every frame and prevents accidental client-side deletion
    -- when the server still owns real world items on the square.
    local monitor = self.worldItemMonitor
    if not monitor or monitor.pending then return end
    local now = nowMs()
    if monitor.nextAt and now < monitor.nextAt then return end
    if now > (monitor.untilMs or 0) then
        setClippedLabel(self.importStatusLabel,
            string.format("Import completed. Reconcile done: %d checked, %d repaired.", monitor.checked or 0, monitor.repaired or 0),
            IMPORT_LEFT_TEXT_W, UIFont.Small)
        self.worldItemMonitor = nil
        return
    end

    local squares = monitor.squares or {}
    local count = #squares
    if count == 0 then
        self.worldItemMonitor = nil
        return
    end
    local attempts = 0
    while attempts < count do
        local row = squares[monitor.index]
        monitor.index = (monitor.index % count) + 1
        attempts = attempts + 1
        local sq = getClientSquareAt(row.x, row.y, row.z)
        if sq then
            local clientWorldInv, clientWorldObjects = countClientWorldItems(sq)
            monitor.pending = true
            monitor.pendingSquare = row
            sendClientCommand(getPlayer(), AE_Constants.MODULE, "reconcileWorldItemSquare", {
                x = row.x,
                y = row.y,
                z = row.z,
                clientWorldInv = clientWorldInv,
                clientWorldObjects = clientWorldObjects,
            })
            return
        end
    end
    monitor.nextAt = now + 2500
end

function AE_MainDialog:setWorldItemReconcileResult(r)
    -- A mismatch is only repaired in the narrow case where the server says there
    -- are no world items but the client still renders some. If the server still
    -- has items, the client leaves them alone because the server is authoritative.
    local monitor = self.worldItemMonitor
    if not monitor then return end
    monitor.pending = false
    monitor.checked = (monitor.checked or 0) + 1
    monitor.nextAt = nowMs() + 1200

    if not r.success then
        monitor.mismatches = (monitor.mismatches or 0) + 1
        return
    end
    if r.verdict == "MISMATCH" then
        monitor.mismatches = (monitor.mismatches or 0) + 1
    end
    if r.repairClient == true then
        local sq = getClientSquareAt(r.x, r.y, r.z)
        local removed = removeLocalWorldItems(sq)
        monitor.repaired = (monitor.repaired or 0) + removed
        if removed > 0 then
            setClippedLabel(self.importStatusLabel,
                string.format("Import completed. Reconcile removed %d local ghost item(s).", monitor.repaired),
                IMPORT_LEFT_TEXT_W, UIFont.Small)
        end
    end
end

function AE_MainDialog:onMappingAction(button)
    if button and button.ruleAction then
        self:applyRuleToSelected(button.ruleAction)
        return
    end
    setClippedLabel(self.validateStatusLabel, "Select Skip, Replace or Keep Placeholder for the selected conflict.", VALIDATE_STATUS_W, UIFont.Small)
end

function AE_MainDialog:onSaveRules()
    local count = 0
    for _ in pairs(self.mappingRules or {}) do count = count + 1 end
    setClippedLabel(self.validateStatusLabel, string.format("Saved %d rule decision(s) for the next import in this session.", count), VALIDATE_STATUS_W, UIFont.Small)
end

function AE_MainDialog.toggle()
    if AE_MainDialog.instance and AE_MainDialog.instance:getIsVisible() then
        AE_MainDialog.instance:setVisible(false)
        AE_MainDialog.instance:removeFromUIManager()
        AE_MainDialog.instance = nil
    else
        local screenW = getCore():getScreenWidth()
        local screenH = getCore():getScreenHeight()
        local w = AE_MainDialog:new(math.floor(math.max(40, (screenW - WINDOW_W) / 2)), math.floor(math.max(40, (screenH - WINDOW_H) / 2)), WINDOW_W, WINDOW_H)
        w:initialise()
        w:addToUIManager()
        AE_MainDialog.instance = w
    end
end

return AE_MainDialog

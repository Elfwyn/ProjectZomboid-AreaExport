--[[
    Area Export - Tile Picker
    Picks the export center and draws preview highlights only on demand.

    Center selection and preview are deliberately separated. Typing a radius used
    to repaint highlights on every key press, which was confusing and could freeze
    the client for large values. Now Pick Center marks only the yellow center, and
    Preview draws the radius footprint when the admin explicitly asks for it.
]]

local AE_Constants = require("AE_Constants")
local AE_Globals = require("AreaExport/AE_Globals")

local AE_TilePicker = {}

local pickerActive = false
local previewMarker = nil
local centerMarker = nil
local previewObjects = {}
local centerObject = nil

local function getPlayerNum()
    local player = getPlayer()
    if player and player.getPlayerNum then return player:getPlayerNum() end
    if player and player.getIndex then return player:getIndex() end
    return 0
end

local function makeColor(r, g, b, a)
    if ColorInfo and ColorInfo.new then
        local ok, color = pcall(function()
            return ColorInfo.new(r, g, b, a or 1.0)
        end)
        if ok then return color end
    end
    return nil
end

local function rememberPreviewObject(obj)
    if not obj then return end
    previewObjects[#previewObjects + 1] = obj
end

local function setObjectHighlightColor(obj, r, g, b, a)
    if not obj or not obj.setHighlightColor then return end

    local playerNum = getPlayerNum()
    local color = makeColor(r, g, b, a)
    if color then
        pcall(function() obj:setHighlightColor(playerNum, color) end)
        pcall(function() obj:setHighlightColor(color) end)
    end
    pcall(function() obj:setHighlightColor(playerNum, r, g, b, a or 1.0) end)
    pcall(function() obj:setHighlightColor(r, g, b, a or 1.0) end)
end

local function setObjectHighlighted(obj, enabled)
    if not obj or not obj.setHighlighted then return end

    local playerNum = getPlayerNum()
    if pcall(function() obj:setHighlighted(playerNum, enabled, false) end) then return end
    if pcall(function() obj:setHighlighted(enabled, false) end) then return end
    pcall(function() obj:setHighlighted(enabled) end)
end

local function clearObject(obj)
    setObjectHighlighted(obj, false)
end

local function removeMarker(marker)
    if marker and marker.remove then
        pcall(function() marker:remove() end)
    end
end

local function clearPreviewHighlights()
    -- Radius previews must be fully removed before drawing a new one; otherwise
    -- old highlighted tiles remain visible after changing the radius.
    removeMarker(previewMarker)
    previewMarker = nil
    for i = 1, #previewObjects do
        clearObject(previewObjects[i])
    end
    previewObjects = {}
end

local function clearCenterHighlight()
    removeMarker(centerMarker)
    centerMarker = nil
    clearObject(centerObject)
    centerObject = nil
end

local function addGridMarker(sq, r, g, b, size, scaleCircle)
    if not sq or not getWorldMarkers then return nil end
    local markers = getWorldMarkers()
    if not markers or not markers.addGridSquareMarker then return nil end

    local ok, marker = pcall(function()
        return markers:addGridSquareMarker(sq, r, g, b, true, size or 1)
    end)
    if not ok or not marker then return nil end
    if marker.setScaleCircleTexture then
        pcall(function() marker:setScaleCircleTexture(scaleCircle and true or false) end)
    end
    return marker
end

local function getSquareObject(sq)
    if not sq then return nil end
    local obj = sq:getFloor()
    if not obj then
        local objs = sq:getObjects()
        if objs and objs:size() > 0 then obj = objs:get(0) end
    end
    return obj
end

local function highlightSquareObject(sq, r, g, b, a, asCenter)
    local obj = getSquareObject(sq)
    if obj and obj.setHighlighted then
        setObjectHighlightColor(obj, r, g, b, a)
        setObjectHighlighted(obj, true)
        if asCenter then
            centerObject = obj
        else
            rememberPreviewObject(obj)
        end
    end
end

function AE_TilePicker.renderCenter()
    local center = AE_Globals.pickedCenter
    if not center then return end
    local cell = getCell()
    if not cell then return end

    clearCenterHighlight()
    local square = cell:getGridSquare(center.x, center.y, center.z or 0)
    centerMarker = addGridMarker(square, 1.0, 0.85, 0.05, 1, false)
    if not centerMarker then
        highlightSquareObject(square, 1.0, 1.0, 0.0, 1.0, true)
    end
end

function AE_TilePicker.setPreviewRadius(radius)
    local center = AE_Globals.pickedCenter
    if not center then return end

    clearPreviewHighlights()

    radius = tonumber(radius) or AE_Constants.DEFAULT_RADIUS
    if radius < AE_Constants.MIN_RADIUS then radius = AE_Constants.MIN_RADIUS end
    radius = math.floor(radius)

    AE_Globals.previewRadius = radius
    AE_Globals.radius = radius

    local cell = getCell()
    if not cell then return end
    local z = center.z or 0
    local centerSquare = cell:getGridSquare(center.x, center.y, z)

    previewMarker = addGridMarker(centerSquare, 0.2, 1.0, 0.2, radius, true)
    AE_TilePicker.renderCenter()
    if previewMarker then return end

    -- Fallback for builds/contexts where circle markers are unavailable: mark a
    -- ring of floor objects around the radius. It is less precise, but it avoids
    -- silently giving no preview.
    local segments = math.max(48, math.min(128, math.floor(radius * 2)))
    for i = 0, segments - 1 do
        local angle = (math.pi * 2 * i) / segments
        local x = center.x + math.floor(math.cos(angle) * radius + 0.5)
        local y = center.y + math.floor(math.sin(angle) * radius + 0.5)
        highlightSquareObject(cell:getGridSquare(x, y, z), 0.2, 1.0, 0.2, 0.9, false)
    end
end

function AE_TilePicker.activate()
    clearPreviewHighlights()
    clearCenterHighlight()
    AE_Globals.previewRadius = nil

    if pickerActive then return end
    pickerActive = true
    print("[AreaExport] Tile picker activated. Click to select center, ESC to cancel.")
    Events.OnMouseDown.Add(AE_TilePicker.onMouseDown)
    Events.OnKeyPressed.Add(AE_TilePicker.onKeyPressed)
end

function AE_TilePicker.deactivate()
    pickerActive = false
    print("[AreaExport] Tile picker deactivated.")
    Events.OnMouseDown.Remove(AE_TilePicker.onMouseDown)
    Events.OnKeyPressed.Remove(AE_TilePicker.onKeyPressed)
end

function AE_TilePicker.onMouseDown(x, y)
    if not pickerActive then return end

    local player = getPlayer()
    if not player then return end

    local playerIndex = player:getIndex()
    local z = player:getZ()
    local worldX = screenToIsoX(playerIndex, x, y, z)
    local worldY = screenToIsoY(playerIndex, x, y, z)
    if not worldX or not worldY then return end

    local centerX = math.floor(worldX)
    local centerY = math.floor(worldY)

    AE_Globals.pickedCenter = {x = centerX, y = centerY, z = z}
    AE_Globals.previewRadius = nil

    print(string.format("[AreaExport] Center picked: (%d, %d, z=%d)", centerX, centerY, z))
    if HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(player, string.format("Center: (%d,%d)", centerX, centerY))
    end

    AE_TilePicker.renderCenter()
    AE_TilePicker.deactivate()
end

function AE_TilePicker.onKeyPressed(key)
    if not pickerActive then return end
    if key == Keyboard.KEY_ESCAPE then
        AE_TilePicker.deactivate()
        print("[AreaExport] Tile picker cancelled.")
    end
end

return AE_TilePicker

--[[
    Area Export - Admin Button
    Shows a draggable floating button for admins/coop hosts and provides ALT+E as
    a keyboard shortcut.

    The button is only a convenience gate. Real security is enforced again on the
    server in AE_ServerCommands.lua because a modified client could still send
    commands without this UI.
]]

require "ISUI/ISPanel"

local AE_AdminButton = {}
AE_AdminButton.instance = nil

local POSITION_FILE = "AreaExport/button_position.txt"

local AE_DraggableAdminButton = ISPanel:derive("AE_DraggableAdminButton")

local function clampButtonPosition(x, y, w, h)
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x > screenW - w then x = screenW - w end
    if y > screenH - h then y = screenH - h end
    return x, y
end

local function readSavedPosition(w, h)
    -- Position is client-local quality-of-life state. It is clamped every load so
    -- changing resolution cannot strand the button off-screen.
    local reader = getFileReader(POSITION_FILE, true)
    if not reader then return nil end

    local line = reader:readLine()
    reader:close()
    if not line then return nil end

    local x, y = string.match(line, "x=([%-%.%d]+)%s+y=([%-%.%d]+)")
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return nil end
    x, y = clampButtonPosition(math.floor(x), math.floor(y), w, h)
    return x, y
end

local function writeSavedPosition(x, y)
    local writer = getFileWriter(POSITION_FILE, true, false)
    if not writer then return end
    writer:write(string.format("x=%d y=%d\r\n", math.floor(x), math.floor(y)))
    writer:close()
end

function AE_DraggableAdminButton:new(x, y, width, height, title, clicktarget, onclick)
    local o = ISPanel.new(self, x, y, width, height)
    o.title = title
    o.target = clicktarget
    o.onclick = onclick
    o.font = UIFont.Small
    o.background = false
    o.backgroundColor = {r=0, g=0, b=0, a=0.62}
    o.backgroundColorMouseOver = {r=0.30, g=0.25, b=0.05, a=0.88}
    o.borderColor = {r=0.90, g=0.70, b=0.20, a=0.72}
    o.textColor = {r=1.00, g=1.00, b=1.00, a=1.00}
    o.mouseOver = false
    o.enable = true
    o.dragging = false
    o.dragMoved = false
    o.dragTotalX = 0
    o.dragTotalY = 0
    return o
end

function AE_DraggableAdminButton:prerender()
    local bg = self.mouseOver and self.backgroundColorMouseOver or self.backgroundColor
    self:drawRect(0, 0, self.width, self.height, bg.a, bg.r, bg.g, bg.b)
    self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
end

function AE_DraggableAdminButton:render()
    local textW = getTextManager():MeasureStringX(self.font, self.title)
    local textH = getTextManager():MeasureStringY(self.font, self.title)
    local x = math.floor((self.width - textW) / 2)
    local y = math.floor((self.height - textH) / 2)
    self:drawText(self.title, x, y, self.textColor.r, self.textColor.g, self.textColor.b, self.textColor.a, self.font)
end

function AE_DraggableAdminButton:onMouseDown(x, y)
    if not self:getIsVisible() then return end
    self.mouseOver = true
    self.dragging = true
    self.dragMoved = false
    self.dragTotalX = 0
    self.dragTotalY = 0
    self:bringToTop()
    if self.setCapture then self:setCapture(true) end
    return true
end

function AE_DraggableAdminButton:moveBy(dx, dy)
    if dx == 0 and dy == 0 then return end
    self.dragTotalX = self.dragTotalX + dx
    self.dragTotalY = self.dragTotalY + dy
    if math.abs(self.dragTotalX) >= 4 or math.abs(self.dragTotalY) >= 4 then
        self.dragMoved = true
    end
    local x, y = clampButtonPosition(self.x + dx, self.y + dy, self.width, self.height)
    self:setX(x)
    self:setY(y)
end

function AE_DraggableAdminButton:onMouseMove(dx, dy)
    self.mouseOver = true
    if not self.dragging then return end
    self:moveBy(dx, dy)
end

function AE_DraggableAdminButton:onMouseMoveOutside(dx, dy)
    if self.dragging then
        self:moveBy(dx, dy)
        return
    end
    self.mouseOver = false
end

function AE_DraggableAdminButton:onMouseUp(x, y)
    if not self:getIsVisible() then return end
    local wasDragging = self.dragging
    local wasMoved = self.dragMoved
    self.dragging = false
    self.dragMoved = false
    if self.setCapture then self:setCapture(false) end

    if wasDragging and wasMoved then
        -- Dragging moves the button only; clicking without meaningful movement
        -- opens the admin dialog. The threshold prevents accidental opens while
        -- repositioning over crowded UI.
        writeSavedPosition(self.x, self.y)
        return
    end
    if self.onclick and self.enable then
        getSoundManager():playUISound("UIActivateButton")
        self.onclick(self.target, self)
    end
end

function AE_DraggableAdminButton:onMouseUpOutside(x, y)
    if self.dragging and self.dragMoved then
        writeSavedPosition(self.x, self.y)
    end
    self.dragging = false
    self.dragMoved = false
    if self.setCapture then self:setCapture(false) end
end

local function isAdminPlayer()
    local p = getPlayer()
    if not p then return false end
    local ok, al = pcall(function() return p:getAccessLevel() end)
    if ok and al and string.lower(tostring(al)) == "admin" then return true end

    -- Steam-hosted servers can mark the local player as host before the client
    -- access-level string has synced. Treat the coop host as allowed client-side;
    -- dedicated server commands still perform their own Admin check.
    local hostOk, isHost = pcall(function()
        return isCoopHost and isCoopHost()
    end)
    if hostOk and isHost then return true end

    return false
end

---
-- Creates the floating button in the top-right corner.
---
function AE_AdminButton.create()
    if AE_AdminButton.instance then return end

    local w, h = 120, 26
    local screenW = getCore():getScreenWidth()
    local x = screenW - w - 12
    local y = 8
    local savedX, savedY = readSavedPosition(w, h)
    if savedX and savedY then
        x, y = savedX, savedY
    end

    local btn = AE_DraggableAdminButton:new(x, y, w, h, "Area Export", nil, function()
        -- guard against live access-level changes
        if not isAdminPlayer() then return end
        if _G.AE_MainDialog and _G.AE_MainDialog.toggle then
            _G.AE_MainDialog.toggle()
        end
    end)
    btn:initialise()
    btn:addToUIManager()
    btn:setVisible(true)
    AE_AdminButton.instance = btn
end

function AE_AdminButton.destroy()
    if AE_AdminButton.instance then
        AE_AdminButton.instance:setVisible(false)
        AE_AdminButton.instance:removeFromUIManager()
        AE_AdminButton.instance = nil
    end
end

---
-- On game start, create button if player is admin.
-- In MP, access-level may sync slightly after OnGameStart, so we retry via a tick-poll
-- for a short window until admin is detected (button self-creates on first true).
---
local adminPollTicks = 0
local function adminPoll()
    adminPollTicks = adminPollTicks + 1
    if AE_AdminButton.instance then
        Events.OnTick.Remove(adminPoll)
        return
    end
    if isAdminPlayer() then
        AE_AdminButton.create()
        print("[AreaExport] Admin button shown (access level = admin, after " .. adminPollTicks .. " ticks)")
        Events.OnTick.Remove(adminPoll)
        return
    end
    if adminPollTicks % 600 == 0 then
        print("[AreaExport] Admin button still waiting for admin/host access after " .. adminPollTicks .. " ticks")
    end
end

local function onGameStart()
    if isAdminPlayer() then
        AE_AdminButton.create()
        print("[AreaExport] Admin button shown (access level = admin at start)")
    else
        Events.OnTick.Add(adminPoll)
    end
end

-- ALT+E shortcut as alternative to finding the floating button.
local function onKeyPressed(key)
    if key == Keyboard.KEY_E and (isKeyDown(Keyboard.KEY_LALT) or isKeyDown(Keyboard.KEY_RALT)) then
        if not isAdminPlayer() then
            print("[AreaExport] ALT+E ignored: player is not admin/host on client")
            return
        end
        -- Ensure button is shown now that we've confirmed admin (MP access-level syncs after OnGameStart)
        if not AE_AdminButton.instance then
            AE_AdminButton.create()
        end
        if _G.AE_MainDialog and _G.AE_MainDialog.toggle then
            _G.AE_MainDialog.toggle()
        end
    end
end

-- Cleanup on death / disconnect
local function onPlayerDeath()
    AE_AdminButton.destroy()
end

Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnPlayerDeath.Add(onPlayerDeath)

return AE_AdminButton

--[[
    Area Export - AttrMap
    Central registry for every serializable attribute.
    If a PZ method name changes, update the mapping here instead of touching import/export code.

    Entry schema:
      name      = save-key (string used in JSON)
      read      = function(obj) -> value (any)
      write     = function(obj, value)        -- nil = read-only
      default   = value to use if read fails  -- nil OK
      kind      = "string" | "number" | "bool" | "table" -- informational, used for validation
      optional  = true = skip if read returns nil; false = always serialize

    Keep this map intentionally small. Every additional write target must be safe
    on a dedicated server and should be tested after reconnect, because some PZ
    setters update visuals locally but do not persist or synchronize cleanly.
]]

local AE_AttrMap = {}

local function copySimpleTable(src)
    -- Persist only primitive modData. Complex Java/Kahlua objects cannot be
    -- serialized safely to JSON and are not portable across mod sets.
    if type(src) ~= "table" then return nil end
    local out = {}
    local count = 0
    for k, v in pairs(src) do
        local kt = type(k)
        local vt = type(v)
        if (kt == "string" or kt == "number" or kt == "boolean") and
           (vt == "string" or vt == "number" or vt == "boolean") then
            out[k] = v
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return out
end

local function applySimpleTable(dst, data)
    if type(data) ~= "table" then return end
    local md = dst and dst.getModData and dst:getModData() or nil
    if not md then return end
    for k, v in pairs(data) do
        local vt = type(v)
        if vt == "string" or vt == "number" or vt == "boolean" then
            md[k] = v
        end
    end
end

-- =========================================================================
-- TILE / SQUARE attributes
-- =========================================================================
AE_AttrMap.tile = {
    floor_sprite = {
        name = "floor_sprite", kind = "string", optional = true,
        read = function(sq)
            local f = sq:getFloor()
            if not f then return nil end
            local s = f:getSprite()
            return s and s:getName() or nil
        end,
        write = nil,  -- handled by tile builder via createNewGridSquare + sprite
        default = nil,
    },
}

-- =========================================================================
-- OBJECT attributes - Common to all IsoObject subclasses
-- =========================================================================
AE_AttrMap.object_common = {
    sprite = {
        name = "sprite", kind = "string", optional = false,
        read = function(o)
            local s = o:getSprite()
            return s and s:getName() or nil
        end,
        -- write done at construction (sprite passed to factory), no setter needed
        default = nil,
    },
    name = {
        name = "name", kind = "string", optional = true,
        read = function(o) return o:getName() end,
        write = function(o, v) if o.setName then o:setName(v) end end,
    },
    isPlayerBuild = {
        name = "isPlayerBuild", kind = "bool", optional = true,
        read = function(o) return o.isPlayerBuild and o:isPlayerBuild() or false end,
        write = nil,  -- this is implicit in IsoThumpable construction
    },
    north = {
        name = "north", kind = "bool", optional = true,
        read = function(o) return o.getNorth and o:getNorth() or nil end,
        write = nil,
    },
}

-- =========================================================================
-- IsoThumpable (player-built walls/doors/furniture) specific
-- =========================================================================
AE_AttrMap.thumpable = {
    health = {
        name = "health", kind = "number", optional = true,
        read = function(o) return o:getHealth() end,
        write = function(o, v) if o.setHealth then o:setHealth(v) end end,
        default = 0,
    },
    maxHealth = {
        name = "maxHealth", kind = "number", optional = true,
        read = function(o) return o:getMaxHealth() end,
        write = function(o, v) if o.setMaxHealth then o:setMaxHealth(v) end end,
        default = 0,
    },
    isDoor = {
        name = "isDoor", kind = "bool", optional = true,
        read = function(o) return o:isDoor() end,
        write = nil,
    },
    isWindow = {
        name = "isWindow", kind = "bool", optional = true,
        read = function(o) return o:isWindow() end,
        write = nil,
    },
    isLocked = {
        name = "isLocked", kind = "bool", optional = true,
        read = function(o) return o:isLocked() end,
        write = function(o, v) if o.setLocked then o:setLocked(v) end end,
    },
}

-- =========================================================================
-- IsoDoor / IsoWindow - open/closed/locked state
-- =========================================================================
AE_AttrMap.door = {
    isOpen = {
        name = "isOpen", kind = "bool", optional = true,
        read = function(o) return o:IsOpen() end,
        write = function(o, v) if o.ToggleDoor and v then o:ToggleDoor(getPlayer()) end end,
    },
    isLocked = {
        name = "isLocked", kind = "bool", optional = true,
        read = function(o) return o:isLocked() end,
        write = function(o, v) if o.setLocked then o:setLocked(v) end end,
    },
    lockedKeyId = {
        name = "lockedKeyId", kind = "number", optional = true,
        read = function(o) return o.getKeyId and o:getKeyId() end,
        write = function(o, v) if o.setKeyId then o:setKeyId(v) end end,
    },
}

-- =========================================================================
-- ITEMS in containers - per-item attributes
-- =========================================================================
AE_AttrMap.item = {
    type = {
        name = "type", kind = "string", optional = false,
        read = function(it) return it:getFullType() end,  -- "Base.Hammer"
        -- write done at factory creation
    },
    condition = {
        name = "condition", kind = "number", optional = true,
        read = function(it) return it:getCondition() end,
        write = function(it, v) if it.setCondition then it:setCondition(v) end end,
    },
    count = {
        name = "count", kind = "number", optional = true,
        read = function(it)
            -- For stackable items (drainables, foods with uses, etc)
            if it.getDrainableUsesInt then
                local n = it:getDrainableUsesInt()
                if n and n > 0 then return n end
            end
            return nil
        end,
        write = function(it, v)
            if v and it.setUsedDelta then
                -- Restore drainable usage approximation
                pcall(function() it:setUsedDelta(v / (it:getUseDelta() or 1)) end)
            end
        end,
    },
    age = {
        name = "age", kind = "number", optional = true,
        read = function(it) return it.getAge and it:getAge() or nil end,
        write = function(it, v) if it.setAge then it:setAge(v) end end,
    },
    name = {
        name = "name", kind = "string", optional = true,
        read = function(it) return it.getName and it:getName() or nil end,
        write = function(it, v) if it.setName then it:setName(v) end end,
    },
    recordedMediaIndex = {
        name = "recordedMediaIndex", kind = "number", optional = true,
        read = function(it)
            if it.getRecordedMediaIndexInteger then
                local idx = it:getRecordedMediaIndexInteger()
                if idx and idx >= 0 then return idx end
            end
            return nil
        end,
        write = function(it, v)
            if it.setRecordedMediaIndexInteger then it:setRecordedMediaIndexInteger(v) end
        end,
    },
    modData = {
        name = "modData", kind = "table", optional = true,
        read = function(it)
            return copySimpleTable(it.getModData and it:getModData() or nil)
        end,
        write = function(it, v) applySimpleTable(it, v) end,
    },
}

-- =========================================================================
-- CONTAINER attributes
-- =========================================================================
AE_AttrMap.container = {
    capacity = {
        name = "capacity", kind = "number", optional = true,
        read = function(c) return c:getCapacity() end,
        write = function(c, v) if c.setCapacity then c:setCapacity(v) end end,
    },
    type = {
        name = "type", kind = "string", optional = true,
        read = function(c) return c:getType() end,
    },
}

return AE_AttrMap

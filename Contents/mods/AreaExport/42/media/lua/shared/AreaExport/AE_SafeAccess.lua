--[[
    Area Export - SafeAccess
    pcall wrapper around all PZ API calls. A failed method must not abort export
    or import. Instead, failures are counted by stable key and summarized at the
    end of the operation.

    This is defensive by design. Project Zomboid exposes slightly different Lua
    method surfaces depending on object class, build, client/server context and
    loaded mods. Exporting one odd object should not destroy the whole run.
]]

local AE_SafeAccess = {}

AE_SafeAccess.failures = {}   -- counter: { ["read:sprite"] = 5, ... }
AE_SafeAccess.verbose  = false  -- if true, every failure prints; else aggregated at flush

local MAX_VERBOSE_LOGS_PER_KEY = 3
local logCount = {}

local function bumpFailure(key, err)
    AE_SafeAccess.failures[key] = (AE_SafeAccess.failures[key] or 0) + 1
    if AE_SafeAccess.verbose then
        logCount[key] = (logCount[key] or 0) + 1
        if logCount[key] <= MAX_VERBOSE_LOGS_PER_KEY then
            print("[AreaExport] " .. key .. " failed: " .. tostring(err))
        end
    end
end

---
-- Calls fn(...) under pcall. Returns the result on success, default on failure.
-- key is a stable identifier for the operation, used in failure counters.
---
function AE_SafeAccess.call(key, default, fn, ...)
    if type(fn) ~= "function" then
        bumpFailure(key, "not a function")
        return default
    end
    local ok, val = pcall(fn, ...)
    if not ok then
        bumpFailure(key, val)
        return default
    end
    return val
end

---
-- Convenience: read an attribute from an object via attr_def.
-- attr_def = { name = "sprite", read = function(o) ... end, default = ... }
---
function AE_SafeAccess.read(obj, attr_def)
    if not obj or not attr_def then return attr_def and attr_def.default or nil end
    return AE_SafeAccess.call("read:" .. (attr_def.name or "?"),
        attr_def.default, attr_def.read, obj)
end

---
-- Convenience: write an attribute to an object via attr_def.
-- val == nil -> no-op (default is already in place from object construction)
---
function AE_SafeAccess.write(obj, attr_def, val)
    if not obj or not attr_def or val == nil or not attr_def.write then return end
    AE_SafeAccess.call("write:" .. (attr_def.name or "?"),
        nil, attr_def.write, obj, val)
end

---
-- Reset all counters (call at start of each export/import session).
---
function AE_SafeAccess.reset()
    AE_SafeAccess.failures = {}
    logCount = {}
end

---
-- Returns a one-line summary of failure counters for logging.
-- Empty string if no failures.
---
function AE_SafeAccess.summary()
    local parts = {}
    for k, v in pairs(AE_SafeAccess.failures) do
        table.insert(parts, k .. "=" .. v)
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    return "failures: " .. table.concat(parts, ", ")
end

return AE_SafeAccess

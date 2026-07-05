local addonName, ID = ...

-- =========================================================================
-- StackManager: creates/destroys one Stack instance per kind="unit" stack
-- config (1:1 -- a fixed unit token always maps to at most one instance),
-- and owns each instance's UNIT_AURA event frame. Anchoring is delegated to
-- FrameAnchor.lua.
-- =========================================================================

local StackManager = {}
ID.StackManager = StackManager

-- live[stackID] = { stack = Stack, unit = "unit token it was built with",
--   filter = "filter it was built with" } -- filter is tracked alongside unit
-- because it decides which event the entry is registered for (UNIT_AURA vs
-- UNIT_SPELLCAST_SUCCEEDED); an edit to either needs a full rebuild.
local live = {}

local function DestroyEntry(id)
    local e = live[id]
    if not e then return end
    ID.FrameAnchor.Unwatch(e.stack)
    e.stack:Destroy()
    live[id] = nil
end

-- CAST-filter stacks track spell casts rather than aura presence: there is no
-- per-unit "cast" event filter like RegisterUnitEvent gives UNIT_AURA, so this
-- registers the global event and filters by unit token in Lua (a plain string
-- compare -- the spellID payload is untouched and may still be secret).
local function CreateEntry(id, sdb)
    local stack = ID.Stack.New(sdb, UIParent)
    stack:EnableDragging()
    ID.FrameAnchor.Watch(stack)

    local ev = CreateFrame("Frame")
    if sdb.filter == "CAST" then
        ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        ev:SetScript("OnEvent", function(_, _, unit, _, spellID)
            if unit == sdb.unit then stack:OnCast(spellID) end
        end)
    else
        ev:RegisterUnitEvent("UNIT_AURA", sdb.unit)
        ev:SetScript("OnEvent", function() stack:Scan() end)
    end
    stack.eventFrame = ev

    live[id] = { stack = stack, unit = sdb.unit, filter = sdb.filter }
    if sdb.filter ~= "CAST" then
        stack:Scan()
    end
end

-- Create/destroy instances to match current config. Call after any change to
-- profile.stacks (add/remove/enable/disable/kind change/unit change/filter
-- change).
function StackManager.Rebuild()
    local stacks = ID.db.profile.stacks
    for id, e in pairs(live) do
        local sdb = stacks[id]
        if not sdb or sdb.kind ~= "unit" or not sdb.enabled
            or e.unit ~= sdb.unit or e.filter ~= sdb.filter then
            DestroyEntry(id)
        end
    end
    for id, sdb in pairs(stacks) do
        if sdb.kind == "unit" and sdb.enabled and not live[id] then
            CreateEntry(id, sdb)
        end
    end
end

function StackManager.Get(id)
    local e = live[id]
    return e and e.stack
end

function StackManager.ForEach(fn)
    for _, e in pairs(live) do fn(e.stack) end
end

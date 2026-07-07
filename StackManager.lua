local addonName, ID = ...

-- =========================================================================
-- StackManager: creates/destroys Stack instances for kind="unit" stack
-- configs. One config fans out to ONE INSTANCE PER TOKEN in sdb.units (Next
-- Features #12 -- e.g. units={"player","party1","party2"} shows the same
-- tracked spells over three frames), each instance owning its own event
-- frame. Anchoring is delegated to FrameAnchor.lua: frame-attached instances
-- follow their own unit's frame; free-floating instances share the stack's
-- one saved point, offset vertically by instance index (only instance 1 is
-- draggable -- dragging moves the whole column).
-- =========================================================================

local StackManager = {}
ID.StackManager = StackManager

-- live[stackID] = { sig = "units|filter signature the entry was built with",
--   instances = { Stack, ... } (parallel to sdb.units) }. The signature
-- covers everything that decides event registration, so an edit to the unit
-- list or the filter tears the whole entry down and recreates it.
local live = {}

local function Sig(sdb)
    return table.concat(sdb.units or {}, ",") .. "|" .. (sdb.filter or "")
end

local function DestroyEntry(id)
    local e = live[id]
    if not e then return end
    for _, stack in ipairs(e.instances) do
        ID.FrameAnchor.Unwatch(stack)
        stack:Destroy()
    end
    live[id] = nil
end

-- CAST-filter stacks track spell casts rather than aura presence: there is no
-- per-unit "cast" event filter like RegisterUnitEvent gives UNIT_AURA, so this
-- registers the global event and filters by unit token in Lua (a plain string
-- compare -- the spellID payload is untouched and may still be secret).
local function CreateEntry(id, sdb)
    local instances = {}
    for idx, unit in ipairs(sdb.units or {}) do
        local stack = ID.Stack.New(sdb, UIParent)
        stack.unitToken = unit
        stack.freeIndex = idx
        if idx == 1 then
            stack:EnableDragging()
        end
        ID.FrameAnchor.Watch(stack)

        local ev = CreateFrame("Frame")
        if sdb.filter == "CAST" then
            ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            ev:SetScript("OnEvent", function(_, _, u, _, spellID)
                if u == unit then
                    -- %d on the (possibly secret) spellID is safe, see dprintf.
                    ID.dprintf("UNIT_SPELLCAST_SUCCEEDED u=%s spell=%d secret=%s", u,
                        spellID, tostring(issecretvalue and issecretvalue(spellID)))
                    stack:OnCast(spellID)
                end
            end)
        else
            ev:RegisterUnitEvent("UNIT_AURA", unit)
            ev:SetScript("OnEvent", function() stack:Scan() end)
        end
        stack.eventFrame = ev

        instances[#instances + 1] = stack
        if sdb.filter ~= "CAST" then
            stack:Scan()
        end
    end
    -- Stamp the fan-out size so FrameAnchor's free-float layout can center the
    -- column/row (needs the total count, not just each instance's index).
    for _, stack in ipairs(instances) do stack.freeCount = #instances end
    live[id] = { sig = Sig(sdb), instances = instances }
end

-- Create/destroy instances to match current config. Call after any change to
-- profile.stacks (add/remove/enable/disable/kind change/units change/filter
-- change).
function StackManager.Rebuild()
    local stacks = ID.db.profile.stacks
    for id, e in pairs(live) do
        local sdb = stacks[id]
        if not sdb or sdb.kind ~= "unit" or not sdb.enabled or e.sig ~= Sig(sdb) then
            DestroyEntry(id)
        end
    end
    for id, sdb in pairs(stacks) do
        if sdb.kind == "unit" and sdb.enabled and not live[id] then
            CreateEntry(id, sdb)
        end
    end
end

function StackManager.ForEach(fn)
    for _, e in pairs(live) do
        for _, stack in ipairs(e.instances) do fn(stack) end
    end
end

-- Run fn over every live instance of ONE stack id (used by Preview).
function StackManager.ForStack(id, fn)
    local e = live[id]
    if not e then return end
    for _, stack in ipairs(e.instances) do fn(stack) end
end

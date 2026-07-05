local addonName, ID = ...

-- =========================================================================
-- NameplateStackManager: kind="nameplate" stacks always follow the player's
-- CURRENT TARGET's nameplate -- no library needed, since C_NamePlate.
-- GetNamePlateForUnit("target") resolves it directly (the same plain
-- Blizzard API LibGetFrame-1.0 itself uses internally for its own nameplate
-- health-bar resolution). One live instance per stack id at most (a player
-- has at most one target), destroyed/recreated whenever the resolved plate
-- FRAME OBJECT changes identity (target changed, or the plate recycled while
-- still targeted) and destroyed outright when there's no plate to anchor to
-- (no target, or the target's nameplate isn't currently on screen).
--
-- Previously this fanned out across hostile/friendly/all/named-player plates
-- via the vendored LibNameplateRegistry-1.0, keyed by GUID to survive plate
-- recycling. That library's own internal bookkeeping does a plain `==`
-- string compare against a nameplate unit's name, and WoW now returns a
-- SECRET string from UnitName() for nameplate tokens -- the same class of
-- restriction this addon works around for aura spellIDs (see CLAUDE.md),
-- just extended to names -- so the library errors on load. Rather than fork
-- and patch a library whose core assumption (plate names are plain
-- comparable strings) no longer holds, the fan-out scopes were dropped;
-- target-only doesn't need to enumerate or classify plates at all.
--
-- Nameplate stacks have no free-float fallback and no lock/drag: their home
-- is always the target's plate.
-- =========================================================================

local NameplateStackManager = {}
ID.NameplateStackManager = NameplateStackManager

-- live[id] = { stack = Stack, plate = the NamePlate frame it's parented to,
--   filter = "filter it was built with" } -- filter is tracked because it
-- decides which event the instance's event frame is registered for; a
-- filter edit tears the instance down and RepositionAll immediately rebuilds
-- it against the same (still-current) plate.
local live = {}
local watchFrame

local function ResolveTargetPlate()
    if not UnitExists("target") then return nil end
    return C_NamePlate.GetNamePlateForUnit("target")
end

local function DestroyInstance(id)
    local e = live[id]
    if not e then return end
    e.stack:Destroy()
    live[id] = nil
end

-- CAST-filter stacks track spell casts rather than aura presence -- see the
-- matching note in StackManager.lua: there is no per-unit cast event filter
-- like RegisterUnitEvent gives UNIT_AURA, so this registers the global event
-- and filters by unit token in Lua.
local function CreateInstance(id, sdb, plate)
    local stack = ID.Stack.New(sdb, plate)
    stack.unitToken = "target"
    stack.anchor:ClearAllPoints()
    stack.anchor:SetPoint(sdb.anchor.myPoint, plate, sdb.anchor.relPoint,
        sdb.anchor.x, sdb.anchor.y)

    local ev = CreateFrame("Frame")
    if sdb.filter == "CAST" then
        ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        ev:SetScript("OnEvent", function(_, _, unit, _, spellID)
            if unit == "target" then stack:OnCast(spellID) end
        end)
    else
        ev:RegisterUnitEvent("UNIT_AURA", "target")
        ev:SetScript("OnEvent", function() stack:Scan() end)
    end
    stack.eventFrame = ev

    live[id] = { stack = stack, plate = plate, filter = sdb.filter }
    if sdb.filter ~= "CAST" then
        stack:Scan()
    end
end

local function EachNameplateStack(fn)
    for id, sdb in pairs(ID.db.profile.stacks) do
        if sdb.kind == "nameplate" and sdb.enabled then
            fn(id, sdb)
        end
    end
end

-- Re-resolve every live nameplate stack against the current target's plate.
-- Called on target changes and on any nameplate add/remove (the target's own
-- plate can appear/disappear independently of PLAYER_TARGET_CHANGED, e.g.
-- out-of-range at the moment of targeting, then walking into view).
local function RepositionAll()
    local plate = ResolveTargetPlate()
    EachNameplateStack(function(id, sdb)
        local e = live[id]
        if not plate then
            if e then DestroyInstance(id) end
        elseif not e or e.plate ~= plate or e.filter ~= sdb.filter then
            if e then DestroyInstance(id) end
            CreateInstance(id, sdb, plate)
        end
    end)
end

local function EnsureWatching()
    if watchFrame then return end
    watchFrame = CreateFrame("Frame")
    watchFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    watchFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    watchFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    watchFrame:SetScript("OnEvent", RepositionAll)
end

-- Create/destroy instances to match current config. Call after any change to
-- profile.stacks (add/remove/enable/disable/kind change/filter change).
function NameplateStackManager.Rebuild()
    local stacks = ID.db.profile.stacks
    local any = false
    for _, sdb in pairs(stacks) do
        if sdb.kind == "nameplate" and sdb.enabled then any = true; break end
    end
    if any then EnsureWatching() end

    for id, e in pairs(live) do
        local sdb = stacks[id]
        if not sdb or sdb.kind ~= "nameplate" or not sdb.enabled then
            DestroyInstance(id)
        end
    end
    RepositionAll()
end

function NameplateStackManager.ForEach(fn)
    for _, e in pairs(live) do fn(e.stack) end
end

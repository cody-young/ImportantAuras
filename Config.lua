local addonName, ID = ...

-- =========================================================================
-- AceDB-backed saved variables: profile.stacks[stackID] = { ... }
--
-- stack (kind == "unit"):
--   name, kind="unit", enabled, unit ("player"|"target"|...|"arena5"|...),
--   filter ("HARMFUL"|"HELPFUL"|"CAST"), targets = {[spellID]=true},
--   order = {spellID,...}, layout ("stack"|"row"), iconSize, spacing, bg,
--   panel, panelPad, locked, castDuration (seconds a CAST match flashes for;
--   unused for HARMFUL/HELPFUL), showCooldown (masked cooldown swipe on
--   matched icons; unused for CAST -- no duration data in that path),
--   anchor = { useFrame, myPoint, relPoint, x, y, point (free-float fallback) }
--
-- stack (kind == "nameplate"):
--   name, kind="nameplate", enabled -- always follows the player's CURRENT
--     TARGET's nameplate (resolved via C_NamePlate.GetNamePlateForUnit, see
--     NameplateStackManager); no scope/name-matching options,
--   filter, targets, order, layout, iconSize, spacing, castDuration,
--   anchor = { myPoint, relPoint, x, y }  -- no free-float, no lock
--
-- filter == "CAST": instead of scanning ongoing auras, the stack listens for
-- UNIT_SPELLCAST_SUCCEEDED on its unit and flashes the matching tracked
-- spell's icon in slot 1 for `castDuration` seconds (see Stack:OnCast). A
-- cast is a momentary event with no "end" to scan back down from, unlike an
-- aura's presence/absence, hence the timer instead of a continuous scan.
-- =========================================================================

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepcopy(v) end
    return c
end

-- NOTE: deliberately NOT put under AceDB's `defaults` table. AceDB re-applies
-- any defaults key still missing from a profile on EVERY login (that's how
-- `copyDefaults` works), so a starter stack living there would silently
-- resurrect itself after being deleted. Instead this is seeded once, below,
-- only if the profile has no stacks at all yet (fresh install).
local function NewDefaultStack()
    return {
        name     = "Player",
        kind     = "unit",
        enabled  = true,
        unit     = "player",
        filter   = "HARMFUL",
        -- A couple of well-known IDs so a fresh install shows *something*.
        targets  = { [589] = true, [980] = true },
        order    = { 589, 980 },
        layout   = "stack",
        iconSize = 36,
        spacing  = 4,
        bg       = { 0.05, 0.05, 0.05, 0.85 },
        panel    = true,
        panelPad = 3,
        locked   = false,
        castDuration = 2,
        showCooldown = true,
        anchor   = {
            useFrame  = false,
            myPoint   = "BOTTOMLEFT",
            relPoint  = "TOPRIGHT",
            x = 0, y = 0,
            point = { "CENTER", "UIParent", "CENTER", 0, 0 },
        },
    }
end

local DEFAULTS = {
    profile = {
        nextStackID = 1,
        stacks = {},
    },
}

-- Reconcile a single stack's priority order against its target set (targets
-- is the source of membership truth; order only ranks it). Drop stale/dup
-- entries, append newly tracked IDs at the bottom (least important).
function ID.ReconcileOrder(stack)
    local seen, i = {}, 1
    while i <= #stack.order do
        local id = stack.order[i]
        if stack.targets[id] and not seen[id] then
            seen[id] = true
            i = i + 1
        else
            table.remove(stack.order, i)
        end
    end
    local missing = {}
    for id in pairs(stack.targets) do
        if not seen[id] then missing[#missing + 1] = id end
    end
    table.sort(missing)
    for _, id in ipairs(missing) do stack.order[#stack.order + 1] = id end
end

-- Pre-AceDB-init migration: the old flat schema had `.targets`/`.order`/etc
-- directly on the SavedVariables root, with no `.profiles`. Detect it, stash
-- it, wipe the root, then (after AceDB seeds its own structure) fold it in
-- as a single stack so upgrading users keep their tracked IDs and position.
local function ExtractLegacyStack(old)
    return {
        name     = "Player",
        kind     = "unit",
        enabled  = true,
        unit     = old.unit or "player",
        filter   = old.filter or "HARMFUL",
        targets  = deepcopy(old.targets) or {},
        order    = deepcopy(old.order) or {},
        layout   = old.layout or "stack",
        iconSize = old.iconSize or 36,
        spacing  = old.spacing or 4,
        bg       = deepcopy(old.bg) or { 0.05, 0.05, 0.05, 0.85 },
        panel    = old.panel ~= false,
        panelPad = old.panelPad or 3,
        locked   = old.locked or false,
        castDuration = old.castDuration or 2,
        showCooldown = old.showCooldown ~= false,
        anchor   = {
            useFrame  = false,
            myPoint   = "BOTTOMLEFT",
            relPoint  = "TOPRIGHT",
            x = 0, y = 0,
            point = deepcopy(old.point) or { "CENTER", "UIParent", "CENTER", 0, 0 },
        },
    }
end

function ID.InitDB()
    if ID.db then return ID.db end -- ADDON_LOADED + PLAYER_LOGIN both call this

    local raw = _G["ImportantAurasDB"]
    local legacyStack
    if type(raw) == "table" and type(raw.targets) == "table" and raw.profiles == nil then
        legacyStack = ExtractLegacyStack(raw)
        for k in pairs(raw) do raw[k] = nil end
    end

    ID.db = LibStub("AceDB-3.0"):New("ImportantAurasDB", DEFAULTS, true)

    if legacyStack then
        local id = tostring(ID.db.profile.nextStackID)
        ID.db.profile.nextStackID = ID.db.profile.nextStackID + 1
        ID.db.profile.stacks[id] = legacyStack
    elseif not next(ID.db.profile.stacks) then
        -- brand new install, nothing to migrate: seed one example stack
        local id = tostring(ID.db.profile.nextStackID)
        ID.db.profile.nextStackID = ID.db.profile.nextStackID + 1
        ID.db.profile.stacks[id] = NewDefaultStack()
    end

    for _, stack in pairs(ID.db.profile.stacks) do
        ID.ReconcileOrder(stack)
        if stack.showCooldown == nil then stack.showCooldown = true end
    end

    return ID.db
end

-- =========================================================================
-- Slash command: bare `/ia` opens the options GUI. Per-stack editing lives
-- in the GUI; `reset` wipes the saved profile back to a fresh install.
-- =========================================================================
local function pr(msg)
    print("|cff66ccffImportantAuras|r: " .. tostring(msg))
end

SLASH_IMPORTANTAURAS1 = "/ia"
SLASH_IMPORTANTAURAS2 = "/importantauras"
SlashCmdList["IMPORTANTAURAS"] = function(msg)
    local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        if ID.Options and ID.Options.Open then
            ID.Options.Open()
        else
            pr("options UI not ready yet")
        end

    elseif cmd == "reset" then
        ID.db:ResetProfile()
        local id = tostring(ID.db.profile.nextStackID)
        ID.db.profile.nextStackID = ID.db.profile.nextStackID + 1
        ID.db.profile.stacks[id] = NewDefaultStack()
        ID.ReconcileOrder(ID.db.profile.stacks[id])
        ID.RefreshAll()
        if ID.Options and ID.Options.Rebuild then ID.Options.Rebuild() end
        pr("reset to defaults")

    else
        pr("commands:")
        print("  /ia          - open the options window")
        print("  /ia reset    - reset all stacks back to defaults")
    end
end

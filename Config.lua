local addonName, ID = ...

-- =========================================================================
-- AceDB-backed saved variables: profile.stacks[stackID] = { ... }
--
-- stack (kind == "unit"):
--   name, kind="unit", enabled, group (free-text label; stacks sharing one
--   are shown together in the options tree and export/import as a set),
--   units = {"player","party1",...} (ORDERED list -- the stack fans out to
--   one display instance per token, Next Features #12; replaces the old
--   single `unit` field, migrated in InitDB),
--   filter ("HARMFUL"|"HELPFUL"|"CAST"), targets = {[spellID]=true},
--   order = {spellID,...}, layout ("stack"|"row"), iconSize, spacing, bg,
--   panel, panelPad, locked, castDuration (seconds a CAST match flashes for
--   when the cast spell has NO cooldown -- fallback only since Next Features
--   #14; unused for HARMFUL/HELPFUL), showCooldown (masked cooldown drain on
--   matched icons: aura remaining duration, or the cast spell's cooldown),
--   anchor = { useFrame, myPoint, relPoint, x, y, point (free-float fallback) }
--
-- stack (kind == "nameplate"):
--   name, kind="nameplate", enabled, group -- always follows the player's CURRENT
--     TARGET's nameplate (resolved via C_NamePlate.GetNamePlateForUnit, see
--     NameplateStackManager); no scope/name-matching options,
--   filter, targets, order, layout, iconSize, spacing, castDuration,
--   anchor = { myPoint, relPoint, x, y }  -- no free-float, no lock
--
-- filter == "CAST": instead of scanning ongoing auras, the stack listens for
-- UNIT_SPELLCAST_SUCCEEDED on its unit and shows the matching tracked
-- spell's icon in slot 1 for that spell's COOLDOWN with a cooldown swipe
-- (Next Features #14; `castDuration` seconds when the spell has no cooldown
-- -- see Stack:OnCast/ResolveCastCooldown). A cast is a momentary event with
-- no "end" to scan back down from, unlike an aura's presence/absence, hence
-- timers instead of a continuous scan.
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
-- Exposed on ID so Options.lua's "Add stack", Presets.lua, and Transfer.lua's
-- import sanitizer all build from the same canonical shape.
function ID.NewDefaultStack()
    return {
        name     = "Player",
        kind     = "unit",
        enabled  = true,
        group    = "",
        units    = { "player" },
        filter   = "HARMFUL",
        -- A couple of well-known IDs so a fresh install shows *something*.
        targets  = { [589] = true, [980] = true },
        order    = { 589, 980 },
        layout   = "stack",
        iconSize = 36,
        spacing  = 4,
        growth   = "VERTICAL", -- CAST fan-out axis (see FrameAnchor)
        align    = "LEFT",     -- CAST fan-out justification
        bg       = { 0.05, 0.05, 0.05, 0.85 },
        panel    = false,
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

-- Ordered list of unit tokens a unit-kind stack may fan out to (Next
-- Features #12). Order drives the options GUI's toggle layout, the saved
-- `units` array, and the on-screen free-float column order. NOTE: WoW has no
-- "party5" token -- a 5-player group is player + party1..party4 -- and
-- current arenas cap at 3 enemies (arena1..arena3 + their pets).
ID.UNIT_TOKEN_ORDER = {
    "player", "target", "focus", "pet",
    "party1", "party2", "party3", "party4",
    "arena1", "arena2", "arena3",
    "arenapet1", "arenapet2", "arenapet3",
    "boss1", "boss2", "boss3", "boss4", "boss5",
}

function ID.NewStackID()
    local db = ID.db.profile
    local id = tostring(db.nextStackID)
    db.nextStackID = db.nextStackID + 1
    return id
end

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
        group    = "",
        units    = { old.unit or "player" },
        filter   = old.filter or "HARMFUL",
        targets  = deepcopy(old.targets) or {},
        order    = deepcopy(old.order) or {},
        layout   = old.layout or "stack",
        iconSize = old.iconSize or 36,
        spacing  = old.spacing or 4,
        growth   = old.growth or "VERTICAL",
        align    = old.align or "LEFT",
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
        ID.db.profile.stacks[id] = ID.NewDefaultStack()
    end

    for _, stack in pairs(ID.db.profile.stacks) do
        ID.ReconcileOrder(stack)
        if stack.showCooldown == nil then stack.showCooldown = true end
        if stack.growth == nil then stack.growth = "VERTICAL" end
        if stack.align == nil then stack.align = "LEFT" end
        -- single `unit` -> ordered `units` list (Next Features #12)
        if stack.units == nil then
            stack.units = { stack.unit or "player" }
        end
        stack.unit = nil
        if stack.group == nil then stack.group = "" end
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

-- Debug output, toggled with `/ia debug`. Off by default; nothing prints
-- unless the user turns it on for a diagnostic session.
--
-- `print`/`string.format("%d", secret)` are valid secret sinks (even in
-- combat); only `secret .. x` and arithmetic error. So a secret spellID is safe
-- as a `...` arg. Whole format+print is pcall'd as a backstop.
ID.debug = false
function ID.dprintf(fmt, ...)
    if ID.debug then
        local args, n = { ... }, select("#", ...)
        pcall(function()
            print(string.format("|cffffcc00IA-dbg|r: " .. fmt, unpack(args, 1, n)))
        end)
    end
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
        ID.db.profile.stacks[id] = ID.NewDefaultStack()
        ID.ReconcileOrder(ID.db.profile.stacks[id])
        ID.RefreshAll()
        if ID.Options and ID.Options.Rebuild then ID.Options.Rebuild() end
        pr("reset to defaults")

    elseif cmd == "debug" then
        ID.debug = not ID.debug
        pr("debug " .. (ID.debug and "ON" or "off"))

    else
        pr("commands:")
        print("  /ia          - open the options window")
        print("  /ia reset    - reset all stacks back to defaults")
        print("  /ia debug    - toggle debug logging")
    end
end

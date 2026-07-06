local addonName, ID = ...

-- =========================================================================
-- FrameAnchor: positions a unit-kind Stack's anchor frame, either attached to
-- a LibGetFrame-resolved unit frame (`db.anchor.useFrame = true`) or free-
-- floating at a saved absolute point (today's original drag-anywhere
-- behavior, used as the fallback when useFrame is off or resolution fails --
-- e.g. an empty party/arena slot).
--
-- When frame-attached, the offset (`myPoint`/`relPoint`/`x`/`y`) is set only
-- through the options GUI, not by dragging -- the target frame can move or
-- not exist yet, so "drag to the right spot" doesn't have a stable meaning
-- the way it does for a free-floating anchor. Dragging is disabled while
-- attached; the moveHint highlight is repurposed to mean "unlocked and
-- draggable" only in the free-float fallback.
-- =========================================================================

local FrameAnchor = {}
ID.FrameAnchor = FrameAnchor

local LGF = LibStub("LibGetFrame-1.0")

-- Every live unit-kind Stack currently being kept positioned.
local watchers = {}

-- ---- Ellesmere UI compat (LibGetFrame-1.0 MINOR 74 doesn't know it) -----
-- EllesmereUIUnitFrames spawns its own oUF frames under fixed, addon-
-- prefixed global names (e.g. "EllesmereUIUnitFrames_Player") instead of the
-- "oUF_<suffix><Unit>"-style names LibGetFrame's generic-oUF patterns
-- pattern-match, so LibGetFrame can never resolve them -- not a version
-- issue, just a naming mismatch. Rather than patch the vendored library
-- (refreshed from upstream, not meant to carry local edits -- see CLAUDE.md),
-- this is a small addon-specific lookup checked first, gated on the addon
-- actually being loaded so it can't misfire under any other UI.
local ELLESMERE_LOADED = C_AddOns and C_AddOns.IsAddOnLoaded("EllesmereUIUnitFrames")
-- Note: "player" is deliberately NOT here. The player's icons always go on the
-- EUI party frame (or nothing) -- never the standalone player unit frame -- so
-- "player" skips this table and routes straight to GetEllesmerePartyFrame.
local ELLESMERE_FIXED_NAMES = {
    target = "EllesmereUIUnitFrames_Target",
    focus = "EllesmereUIUnitFrames_Focus",
    pet = "EllesmereUIUnitFrames_Pet",
    targettarget = "EllesmereUIUnitFrames_TargetTarget",
    focustarget = "EllesmereUIUnitFrames_FocusTarget",
}

-- Party frames come from a SEPARATE addon, EllesmereUIRaidFrames, and -- CONTRARY
-- to an earlier assumption in CLAUDE.md -- it does NOT skin Blizzard's
-- Compact*Frame. It SUPPRESSES the Blizzard party/raid frames (parks them
-- hidden, off in a corner) and builds its OWN party frames: a
-- SecureGroupHeaderTemplate named "ERFPartyHeader" whose child buttons carry
-- the unit token on the secure "unit" attribute (no per-unit global name), plus
-- a static "ERFPartySelfButton" (unit="player") used when "show self first" is
-- on. So LibGetFrame's "^CompactParty" pattern matches the HIDDEN Blizzard
-- frame in the corner (the reported bug: party preview anchored bottom-right
-- while the real frames sit mid-left). Resolve the real EUI party button by
-- walking the header's children and matching GetAttribute("unit").
local ELLESMERE_RF_LOADED = C_AddOns and C_AddOns.IsAddOnLoaded("EllesmereUIRaidFrames")

local function GetEllesmerePartyFrame(unit)
    if not ELLESMERE_RF_LOADED then return nil end
    -- Only friendly party members live on the EUI party header; enemy arena
    -- units, boss, etc. do not.
    if unit ~= "player" and not unit:match("^party%d$") then return nil end
    -- Self button owns the player slot when "show self first" is on in a group;
    -- when it's the player's own button in the header instead, the loop below
    -- catches it.
    local selfBtn = _G["ERFPartySelfButton"]
    if selfBtn and selfBtn:IsVisible() and selfBtn:GetAttribute("unit") == unit then
        return selfBtn
    end
    -- The header's child buttons are real global frames named
    -- "ERFPartyHeaderUnitButton<n>" (the SecureGroupHeaderTemplate
    -- "$parentUnitButton<n>" convention -- confirmed via /framestack). Each
    -- carries its unit token on the secure "unit" attribute, which EUI's own
    -- _RebuildPartyUnitMap reads the same way. Order isn't fixed (the header
    -- sorts), so match by attribute rather than by index.
    for i = 1, 5 do
        local btn = _G["ERFPartyHeaderUnitButton" .. i]
        if btn and btn:IsVisible() and btn:GetAttribute("unit") == unit then
            return btn
        end
    end
    return nil
end

local function GetEllesmereFrame(unit)
    if ELLESMERE_LOADED then
        local name = ELLESMERE_FIXED_NAMES[unit]
        if not name then
            local n = unit:match("^boss(%d)$")
            if n then name = "EllesmereUIUnitFrames_Boss" .. n end
        end
        if name and _G[name] then return _G[name] end
    end
    return GetEllesmerePartyFrame(unit)
end

-- Per-instance offset from the stack's shared saved point. Instances of a
-- multi-unit stack fan out along the growth axis by instance index so they
-- form a row/column instead of a pile. growth/align (CAST stacks; default
-- VERTICAL/LEFT = the original downward column) decide axis and direction:
--   HORIZONTAL: Left grows right, Right grows left, Center is centered.
--   VERTICAL:   Left grows down,  Right grows up,   Center is centered.
-- Exposed so the drag handler can subtract instance 1's offset before saving
-- the base point (else CENTER/RIGHT align would drift it on each drag).
function FrameAnchor.FreeFloatOffset(db, idx, count)
    local step = db.iconSize + 8
    local align = db.align or "LEFT"
    local posn
    if align == "CENTER" then
        posn = (idx - (count - 1) / 2) * step
    elseif align == "RIGHT" then
        posn = -idx * step
    else -- LEFT / start
        posn = idx * step
    end
    if (db.growth or "VERTICAL") == "HORIZONTAL" then
        return posn, 0
    end
    return 0, -posn
end

local function ApplyFreeFloat(stack)
    local db = stack.db
    local p = db.anchor.point
    local idx = (stack.freeIndex or 1) - 1
    local dx, dy = FrameAnchor.FreeFloatOffset(db, idx, stack.freeCount or 1)
    stack.anchor:ClearAllPoints()
    stack.anchor:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4] + dx, p[5] + dy)
    -- Only instance 1 drags (it owns the saved point), and never while the
    -- stack is configured as frame-attached: if LibGetFrame hasn't resolved
    -- the unit frame yet (its cache fills asynchronously after login), this
    -- fallback positions the icons but must NOT present as draggable --
    -- that's the stray blue drag-hint square of Bug #3.
    local draggable = not stack.db.locked
        and not stack.db.anchor.useFrame
        and idx == 0
    stack.anchor:EnableMouse(draggable)
    if stack.anchor.moveHint then
        stack.anchor.moveHint:SetShown(draggable)
    end
end

local function ApplyFrameAttach(stack, frame)
    local a = stack.db.anchor
    stack.anchor:ClearAllPoints()
    stack.anchor:SetPoint(a.myPoint, frame, a.relPoint, a.x, a.y)
    stack.anchor:EnableMouse(false)
    if stack.anchor.moveHint then
        stack.anchor.moveHint:Hide()
    end
end

function FrameAnchor.Reposition(stack)
    local a = stack.db.anchor
    local unit = stack.unitToken or (stack.db.units and stack.db.units[1])
    local frame = a.useFrame and unit and (GetEllesmereFrame(unit) or LGF.GetUnitFrame(unit))
    if frame then
        ApplyFrameAttach(stack, frame)
    else
        ApplyFreeFloat(stack)
    end
end

function FrameAnchor.Watch(stack)
    watchers[stack] = true
    FrameAnchor.Reposition(stack)
end

function FrameAnchor.Unwatch(stack)
    watchers[stack] = nil
end

local function RepositionAll()
    for stack in pairs(watchers) do
        FrameAnchor.Reposition(stack)
    end
end
FrameAnchor.RepositionAll = RepositionAll

-- LibGetFrame re-scans on its own triggers (roster changes, regen state,
-- etc.) and fires these when a resolved frame appears/changes/disappears.
LGF.RegisterCallback(FrameAnchor, "FRAME_UNIT_ADDED", RepositionAll)
LGF.RegisterCallback(FrameAnchor, "FRAME_UNIT_UPDATE", RepositionAll)
LGF.RegisterCallback(FrameAnchor, "FRAME_UNIT_REMOVED", RepositionAll)
LGF.RegisterCallback(FrameAnchor, "GETFRAME_REFRESH", RepositionAll)

-- Belt-and-suspenders: arena/party composition and zoning can change which
-- frame exists for a given unit token outside of LibGetFrame's own triggers.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:SetScript("OnEvent", RepositionAll)

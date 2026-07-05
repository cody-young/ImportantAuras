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

local function ApplyFreeFloat(stack)
    local p = stack.db.anchor.point
    stack.anchor:ClearAllPoints()
    stack.anchor:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
    stack.anchor:EnableMouse(not stack.db.locked)
    if stack.anchor.moveHint then
        stack.anchor.moveHint:SetShown(not stack.db.locked)
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
    local frame = a.useFrame and LGF.GetUnitFrame(stack.db.unit)
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

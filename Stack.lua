local addonName, ID = ...

-- =========================================================================
-- Stack: one instance of the production dual-punch matcher machinery (see
-- CLAUDE.md for the full derivation), lifted out of the original single-
-- instance Core.lua so multiple stacks can run concurrently. Everything here
-- is unchanged from the original mask mechanics -- only what OWNS `anchor`/
-- `slots` changed, from module-level locals to a `self` instance.
--
-- The matcher pool is shared/global across every Stack instance: matchers
-- are generic reusable frames keyed only by icon+geometry, not by unit, so
-- sharing avoids frame churn as stacks are added/removed/rebuilt. Slots stay
-- per-instance (an aura index is only meaningful within one unit's scan).
-- =========================================================================

local MAX_AURAS = 40
local PUNCH_MARGIN = 4 -- keeps parked punch edges off the icon (filter bleed)
local TEX_TRANS = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Trans8x8.tga"

-- 12.0 secret-safe cooldown plumbing (see the cdBar block in AcquireMatcher):
-- DurationObjects carry (possibly secret) timings from C to C without Lua
-- ever reading them. Enum fallbacks per warcraft.wiki: Immediate = 0,
-- RemainingTime = 1.
local CreateDurationObject = C_DurationUtil and C_DurationUtil.CreateDuration
local CD_INTERP = (Enum and Enum.StatusBarInterpolation
    and Enum.StatusBarInterpolation.Immediate) or 0
local CD_DIR = (Enum and Enum.StatusBarTimerDirection
    and Enum.StatusBarTimerDirection.RemainingTime) or 1

local function GetIcon(spellID)
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    return tex or 134400 -- red question mark
end
ID.GetIcon = GetIcon

-- ---- shared matcher pool ------------------------------------------------
local pool = {}

local function RefreshPunchLoAnchors(m, iconSize)
    local fill = m.blo:GetStatusBarTexture()
    m.pLo:ClearAllPoints()
    m.pLo:SetPoint("TOPLEFT", fill, "TOPRIGHT")
    m.pLo:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT",
        iconSize + 2 * PUNCH_MARGIN, 0)
    if m.cdLo then -- the cooldown drain's own punchLo clone tracks the same fill
        m.cdLo:ClearAllPoints()
        m.cdLo:SetPoint("TOPLEFT", fill, "TOPRIGHT")
        m.cdLo:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT",
            iconSize + 2 * PUNCH_MARGIN, 0)
    end
end

local function AcquireMatcher(parent, iconSize)
    local m = table.remove(pool)
    if not m then
        m = CreateFrame("Frame", nil, parent)
        m.icon = m:CreateTexture(nil, "ARTWORK")
        m.icon:SetAllPoints(m)

        -- BLo drives punchLo: icon rect inflated by the margin on ALL FOUR
        -- sides (a punch edge flush with the icon edge leaks a sliver).
        m.blo = CreateFrame("StatusBar", nil, m)
        m.blo:SetPoint("TOPLEFT", m, "TOPLEFT", -PUNCH_MARGIN, PUNCH_MARGIN)
        m.blo:SetPoint("BOTTOMRIGHT", m, "BOTTOMRIGHT", PUNCH_MARGIN, -PUNCH_MARGIN)
        m.blo:SetOrientation("HORIZONTAL")
        m.blo.tex = m.blo:CreateTexture(nil, "ARTWORK")
        m.blo:SetStatusBarTexture(m.blo.tex); m.blo:SetStatusBarColor(1, 1, 1, 0)

        -- BHi drives punchHi: wide bar, 0%/50%/100% fills (anchored below,
        -- width depends on iconSize).
        m.bhi = CreateFrame("StatusBar", nil, m)
        m.bhi:SetOrientation("HORIZONTAL")
        m.bhi.tex = m.bhi:CreateTexture(nil, "ARTWORK")
        m.bhi:SetStatusBarTexture(m.bhi.tex); m.bhi:SetStatusBarColor(1, 1, 1, 0)

        -- NEAREST filtering is load-bearing: LINEAR blends the edge texel
        -- with the clamp border over half a texel EACH SIDE of the rect
        -- edge, leaking faint icon edge lines past the margin.
        m.pLo = m:CreateMaskTexture()
        m.pLo:SetTexture(TEX_TRANS, "CLAMPTOWHITE", "CLAMPTOWHITE", "NEAREST")
        m.icon:AddMaskTexture(m.pLo)

        m.pHi = m:CreateMaskTexture()
        m.pHi:SetTexture(TEX_TRANS, "CLAMPTOWHITE", "CLAMPTOWHITE", "NEAREST")
        m.pHi:SetAllPoints(m.bhi:GetStatusBarTexture())
        m.icon:AddMaskTexture(m.pHi)

        -- Cooldown display (reworked 2026-07-06, Bug #6 follow-up). The
        -- radial Cooldown widget is unusable: its swipe is NOT a retrievable
        -- Texture (Cooldown:GetSwipeTexture doesn't exist -- that's what the
        -- old "couldn't mask the swipe texture" diagnostic was tripping on),
        -- so the dual-punch masks can never apply to it, and an unmasked
        -- swipe would render for every MISS matcher. Instead: a vertical
        -- StatusBar "drain" whose fill texture is OURS and carries clones of
        -- both punch masks, animated entirely in C from a DurationObject
        -- (StatusBar:SetTimerDuration, 12.0.0) so secret aura timings never
        -- touch Lua. Dark translucent fill height = remaining time. Masks
        -- can't be shared with the icon's pair here without assuming
        -- cross-frame AddMaskTexture works, so the bar gets its own copies
        -- anchored to the same punch geometry (cdLo tracks blo's fill via
        -- RefreshPunchLoAnchors; cdHi rides bhi's fill like pHi does).
        if CreateDurationObject then
            m.cdBar = CreateFrame("StatusBar", nil, m)
            m.cdBar:SetAllPoints(m)
            m.cdBar:SetOrientation("VERTICAL")
            m.cdBar:SetMinMaxValues(0, 1)
            m.cdBar.tex = m.cdBar:CreateTexture(nil, "ARTWORK")
            -- The fill needs real texture CONTENT to render: SetStatusBarColor
            -- is only a vertex color multiplied over the texels, and a
            -- file-less texture has none -- the drain was invisible until this
            -- was set (Bug #7 follow-up). blo/bhi skip this on purpose (their
            -- fills are meant to be invisible; only the fill RECT matters).
            m.cdBar.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            m.cdBar:SetStatusBarTexture(m.cdBar.tex)
            m.cdBar:SetStatusBarColor(0, 0, 0, 0.6)
            m.cdBar:Hide()
            if m.cdBar.SetTimerDuration then
                m.cdLo = m.cdBar:CreateMaskTexture()
                m.cdLo:SetTexture(TEX_TRANS, "CLAMPTOWHITE", "CLAMPTOWHITE", "NEAREST")
                m.cdBar.tex:AddMaskTexture(m.cdLo)
                m.cdHi = m.cdBar:CreateMaskTexture()
                m.cdHi:SetTexture(TEX_TRANS, "CLAMPTOWHITE", "CLAMPTOWHITE", "NEAREST")
                m.cdHi:SetAllPoints(m.bhi:GetStatusBarTexture())
                m.cdBar.tex:AddMaskTexture(m.cdHi)
                m.durObj = CreateDurationObject()
                m.cdOK = true
            end
        end
        if not m.cdOK and not ID.cdWarned then
            ID.cdWarned = true
            print("|cffff4444ImportantAuras|r: cooldown display unavailable on this client build (no DurationObject / StatusBar:SetTimerDuration API) -- icons will show without a cooldown drain.")
        end
    end
    m:SetParent(parent)
    m:ClearAllPoints()
    m:SetAllPoints(parent)
    -- size-dependent geometry (re-applied on reuse so icon-size changes work).
    -- BHi spans [iconLeft-(size+3m) .. iconRight+m], inflated m vertically:
    -- 100% covers the icon with m margin on all sides; 50% parks the punch
    -- with its right edge at iconLeft-m, a full m off-icon.
    m.bhi:ClearAllPoints()
    m.bhi:SetPoint("TOPLEFT", m, "TOPLEFT", -(iconSize + 3 * PUNCH_MARGIN), PUNCH_MARGIN)
    m.bhi:SetPoint("BOTTOMRIGHT", m, "BOTTOMRIGHT", PUNCH_MARGIN, -PUNCH_MARGIN)
    RefreshPunchLoAnchors(m, iconSize)
    m:Show()
    return m
end

local function ReleaseMatcher(m)
    m.castHideToken = (m.castHideToken or 0) + 1 -- orphan pending cast-expiry hides
    m:Hide()
    if m.cdOK then m.cdBar:Hide() end
    m:SetParent(UIParent)
    m:ClearAllPoints()
    pool[#pool + 1] = m
end

-- Point a matcher at target X (plain, known). Bars start at X-1 so punchLo
-- covers the icon (hidden) until a real value is fed.
local function SetMatcherTarget(m, X, iconSize)
    m.targetID = X -- plain tracked id (kept for per-matcher cast cooldowns)
    m.icon:SetTexture(GetIcon(X))
    m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the default icon border
    m.blo:SetMinMaxValues(X - 1, X); m.blo:SetValue(X - 1)
    m.bhi:SetMinMaxValues(X - 1, X + 1); m.bhi:SetValue(X - 1)
    RefreshPunchLoAnchors(m, iconSize)
end

-- ---- Stack instance ------------------------------------------------------
local Stack = {}
Stack.__index = Stack
ID.Stack = Stack

-- db: the saved stack table (profile.stacks[id]).
-- parent: frame to parent the anchor to (UIParent for unit-kind stacks;
--   the resolved nameplate frame for nameplate-kind stacks).
function Stack.New(db, parent)
    local self = setmetatable({}, Stack)
    self.db = db
    self.slots = {}

    local anchor = CreateFrame("Frame", nil, parent or UIParent)
    self.anchor = anchor

    -- Backing panel: drawn behind the slot frames (sublayer -1). Cosmetic
    -- only now that misses are transparent -- see CLAUDE.md.
    local panel = anchor:CreateTexture(nil, "BACKGROUND", nil, -1)
    anchor.panel = panel

    return self
end

-- Wires drag-to-move (only meaningful for free-floating unit-kind stacks;
-- nameplate stacks never call this). FrameAnchor.lua owns EnableMouse/
-- moveHint visibility based on lock state and frame-attach status.
function Stack:EnableDragging()
    local anchor = self.anchor
    anchor:SetMovable(true)
    anchor:RegisterForDrag("LeftButton")

    local hint = anchor:CreateTexture(nil, "BACKGROUND")
    hint:SetAllPoints(anchor)
    hint:SetColorTexture(0.2, 0.6, 1, 0.25)
    anchor.moveHint = hint

    anchor:SetScript("OnDragStart", function(f) f:StartMoving() end)
    anchor:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local p1, _, p3, x, y = f:GetPoint()
        -- The dragged frame is instance 1 (freeIndex 1, idx 0), which may sit
        -- offset from the shared base point (CENTER/RIGHT align). Subtract that
        -- offset so the saved base point stays put across drags.
        if ID.FrameAnchor and ID.FrameAnchor.FreeFloatOffset then
            local dx, dy = ID.FrameAnchor.FreeFloatOffset(self.db, 0, self.freeCount or 1)
            x, y = x - dx, y - dy
        end
        self.db.anchor.point = { p1, "UIParent", p3, x, y }
        -- A multi-unit stack shares one saved point across its instances
        -- (each offset by its index); only instance 1 is draggable, so
        -- resettle the siblings under the new point immediately.
        if ID.FrameAnchor then ID.FrameAnchor.RepositionAll() end
    end)
end

function Stack:Destroy()
    self.destroyed = true
    if self.eventFrame then
        self.eventFrame:UnregisterAllEvents()
        self.eventFrame:SetScript("OnEvent", nil)
    end
    for _, slot in pairs(self.slots) do
        for _, m in ipairs(slot.matchers) do ReleaseMatcher(m) end
        slot.frame:Hide()
        slot.frame:SetParent(nil)
    end
    wipe(self.slots)
    self.anchor:Hide()
    self.anchor:ClearAllPoints()
    self.anchor:SetParent(nil)
end

-- Build one matcher per tracked target for a slot. Misses are transparent
-- and never clobber, so all target icons overlap and at most one per slot is
-- ever visible. Frame levels follow priority rank -- rank 1 draws on top.
function Stack:BuildSlotBars(slot)
    for _, m in ipairs(slot.matchers) do ReleaseMatcher(m) end
    wipe(slot.matchers)
    local order = self.db.order
    local base = slot.frame:GetFrameLevel() + 1
    for rank, X in ipairs(order) do
        local m = AcquireMatcher(slot.frame, self.db.iconSize)
        SetMatcherTarget(m, X, self.db.iconSize)
        m:SetFrameLevel(base + (#order - rank))
        slot.matchers[#slot.matchers + 1] = m
    end
end

function Stack:AcquireSlot(i)
    local slot = self.slots[i]
    if not slot then
        local f = CreateFrame("Frame", nil, self.anchor)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints(f)
        slot = { frame = f, matchers = {} }
        self.slots[i] = slot
        self:BuildSlotBars(slot)
    end
    return slot
end

-- Feed one aura's (possibly secret) spellId into both bars of every matcher,
-- plus (optionally) a DurationObject into the matcher's masked cooldown
-- drain. The old path computed `expirationTime - duration` here -- that's
-- arithmetic on secrets, which always errored in combat and tripped the
-- cdBroken latch, so the drain could never render. A DurationObject moves
-- that subtraction into C: we never read it, just hand it to the bar's
-- timer. durObj may be nil (no duration API, permanent aura, Preview) --
-- the drain simply hides.
function Stack:FeedSlot(slot, secretSpellId, durObj)
    local showCD = self.db.showCooldown
    for _, m in ipairs(slot.matchers) do
        m.castHideToken = (m.castHideToken or 0) + 1 -- a fresh feed supersedes any pending cast-expiry hide
        m:Show() -- may have been hidden by a cast-expiry timer (CAST-stack Preview)
        m.blo:SetValue(secretSpellId) -- secret goes to C; never read here
        m.bhi:SetValue(secretSpellId)
        RefreshPunchLoAnchors(m, self.db.iconSize)
        if m.cdOK then
            if durObj and showCD and not self.cdBroken then
                local ok = pcall(m.cdBar.SetTimerDuration, m.cdBar, durObj,
                    CD_INTERP, CD_DIR)
                if ok then
                    m.cdBar:Show()
                else
                    self.cdBroken = true
                    m.cdBar:Hide()
                    print("|cffff4444ImportantAuras|r: cooldown drain disabled for '"
                        .. (self.db.name or "?") .. "' (SetTimerDuration rejected the aura duration)")
                end
            else
                m.cdBar:Hide()
            end
        end
    end
    slot.frame:Show()
end

function Stack:Layout(activeCount)
    local db = self.db
    local size, gap = db.iconSize, db.spacing
    local stacked = db.layout ~= "row"
    for i = 1, MAX_AURAS do
        local slot = self.slots[i]
        if slot then
            if i <= activeCount then
                slot.frame:SetSize(size, size)
                slot.frame:ClearAllPoints()
                if stacked then
                    slot.frame:SetPoint("LEFT", self.anchor, "LEFT", 0, 0)
                else
                    slot.frame:SetPoint("LEFT", self.anchor, "LEFT", (i - 1) * (size + gap), 0)
                end
                slot.frame.bg:SetColorTexture(db.bg[1], db.bg[2], db.bg[3], 0)
                slot.frame:Show()
            else
                slot.frame:Hide()
            end
        end
    end
    if stacked then
        self.anchor:SetSize(size, size)
    else
        self.anchor:SetSize(math.max(activeCount, 1) * (size + gap), size)
    end

    -- Backing panel removed from the UI; keep the texture hidden.
    if self.anchor.panel then self.anchor.panel:Hide() end
end

-- unitToken is set by whichever manager created the instance: one of
-- db.units for unit-kind stacks (one instance per token), "target" for
-- nameplate stacks.
function Stack:Scan()
    if self.previewing then return end -- don't stomp an active preview
    local unit = self.unitToken
    if not unit or not UnitExists(unit) then
        self:Layout(0)
        return
    end
    local filter = self.db.filter
    local count = 0
    for i = 1, MAX_AURAS do
        local data = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
        if not data then break end
        count = i
        local slot = self:AcquireSlot(i)
        -- data.spellId may be secret; that's fine, it goes straight to C.
        -- The remaining duration reaches the drain bar as a DurationObject
        -- built by C_UnitAuras.GetAuraDuration from PLAIN args (unit token +
        -- auraInstanceID) -- the sanctioned 12.0 path; its innards may be
        -- secret but Lua never reads them.
        local durObj
        if C_UnitAuras.GetAuraDuration then
            -- Skip permanent auras (no expiration): a never-ending timer
            -- would park a full dark drain over the icon forever. The bool
            -- is expected plain metadata; if it comes back secret we can't
            -- branch on it (issecretvalue is the one safe test), so fail
            -- open and let C render whatever it computes.
            local wantCD = true
            if C_UnitAuras.DoesAuraHaveExpirationTime then
                local okE, hasExp = pcall(C_UnitAuras.DoesAuraHaveExpirationTime,
                    unit, data.auraInstanceID)
                if okE and (not issecretvalue or not issecretvalue(hasExp))
                    and hasExp == false then
                    wantCD = false
                end
            end
            if wantCD then
                local okD, d = pcall(C_UnitAuras.GetAuraDuration, unit, data.auraInstanceID)
                if okD then durObj = d end
            end
        end
        self:FeedSlot(slot, data.spellId, durObj)
    end
    self:Layout(count)
end

-- Cooldown lookup for a TRACKED id -- always m.targetID, a PLAIN int the user
-- typed, never the cast payload (which may be secret), so everything here is
-- plain data and plain decisions. Returns startTime, duration (seconds), both
-- always from the spell's static base cooldown via GetSpellBaseCooldown
-- (resolves any spell id, learned or not; talent CDR invisible to us for
-- EVERY unit including the player -- see below). A spell with no cooldown at
-- all falls back to db.castDuration (the old fixed flash).
--
-- C_Spell.GetSpellCooldown was tried first (as requested) for the player's
-- own cast, on the theory that it reflects the player's live cooldown state
-- including talent CDR -- REVERTED (2026-07-06) after an in-game error:
-- `cd.duration > 0` errored "a secret number value, while execution tainted
-- by 'ImportantAuras'". So the LIVE cooldown fields are secret -- same
-- restriction class as aura spellIds/nameplate names -- while the STATIC
-- base cooldown stays plain in the cases tested so far. There is no known
-- way to read "is this spell live-cooling-down and for how long" without
-- branching on a secret, so this addon can't do better than the static
-- value for anyone, player included.
--
-- Per CLAUDE.md's general principle (any API call is guilty of returning a
-- secret until proven otherwise, even with a plain argument), the arithmetic
-- AND the validity check on GetSpellBaseCooldown's result both happen INSIDE
-- the pcall -- a first pass left `ms / 1000` and the `<= 0` check outside it,
-- which is exactly the naked-arithmetic-on-a-maybe-secret bug this file
-- keeps having to fix. If the division/comparison errors (ms turns out
-- secret), the pcall catches it and `base` just stays 0 -> falls back to
-- castDuration, same as "no base cooldown found".
function Stack:ResolveCastCooldown(spellID)
    local now = GetTime()
    local base = 0
    if GetSpellBaseCooldown then
        local ok, result = pcall(function()
            local ms = GetSpellBaseCooldown(spellID)
            if type(ms) ~= "number" or ms <= 0 then return 0 end
            return ms / 1000
        end)
        if ok and type(result) == "number" then base = result end
    end
    if base <= 0 then
        return now, self.db.castDuration or 2
    end
    return now, base
end

-- Cast-mode entry point (db.filter == "CAST"): show the matching tracked
-- icon for that spell's COOLDOWN, with a cooldown swipe (Next Features #14).
-- A cast is a momentary event with no "ends" event to scan back down from,
-- so timers hide it instead. The trick that keeps this secret-safe: we never
-- learn WHICH tracked spell matched (that's decided in C by the dual punch),
-- but every matcher owns one plain tracked id, so each matcher gets ITS OWN
-- spell's cooldown swipe and its own plain hide timer -- for the one visible
-- (matched) matcher those are exactly right, and for the transparent misses
-- they're invisible no-ops. Slot 1 is reused for every cast.
function Stack:OnCast(spellID)
    -- EVERY successful cast on this unit lands here -- hidden proc/internal
    -- spells included, plus whatever the player presses on the next GCD.
    -- Feeding an untracked id would overwrite a live match's bar values and
    -- the dual punch (correctly) blanks the icon on the mismatch -- so a
    -- tracked cast's cooldown display only survived until the unit's NEXT
    -- cast event (Bug #7's split-second flash). When the payload is PLAIN
    -- (own casts verified plain in-game: Core.lua compares this same payload
    -- against the round-start marker id without erroring), drop untracked
    -- ids in Lua before they reach the bars. A secret payload can't be
    -- compared, so it falls through and feeds C as before -- a secret miss
    -- still blanks (bars have no latch; no known fix).
    if not issecretvalue or not issecretvalue(spellID) then
        local tracked = false
        for _, X in ipairs(self.db.order) do
            if X == spellID then tracked = true; break end
        end
        if not tracked then return end
    end
    local slot = self:AcquireSlot(1)
    local showCD = self.db.showCooldown
    local now = GetTime()
    local maxRemaining = 0
    for _, m in ipairs(slot.matchers) do
        m.blo:SetValue(spellID) -- possibly secret; goes straight to C
        m.bhi:SetValue(spellID)
        RefreshPunchLoAnchors(m, self.db.iconSize)
        m:Show() -- may still be hidden from a previous cast's expiry

        -- start/duration are PLAIN numbers (m.targetID is the user-typed
        -- tracked id; GetSpellBaseCooldown's result is verified plain), so
        -- the hide-timer arithmetic below is safe. The drain still goes
        -- through the matcher's own DurationObject so CAST and aura modes
        -- share one display path.
        local start, duration = self:ResolveCastCooldown(m.targetID)
        if m.cdOK then
            if showCD and not self.cdBroken then
                local ok = pcall(function()
                    m.durObj:SetTimeFromStart(start, duration)
                    m.cdBar:SetTimerDuration(m.durObj, CD_INTERP, CD_DIR)
                end)
                if ok then
                    m.cdBar:Show()
                else
                    self.cdBroken = true
                    m.cdBar:Hide()
                    print("|cffff4444ImportantAuras|r: cooldown drain disabled for '"
                        .. (self.db.name or "?") .. "' (SetTimeFromStart/SetTimerDuration rejected the cooldown values)")
                end
            else
                m.cdBar:Hide()
            end
        end

        local remaining = start + duration - now
        if remaining < 0.1 then remaining = 0.1 end
        if remaining > maxRemaining then maxRemaining = remaining end
        m.castHideToken = (m.castHideToken or 0) + 1
        local tok = m.castHideToken
        C_Timer.After(remaining, function()
            if m.castHideToken == tok then m:Hide() end
        end)
    end
    slot.frame:Show()
    self:Layout(1)

    -- Backstop: once every matcher's timer has run, collapse the slot too.
    local token = (self.castToken or 0) + 1
    self.castToken = token
    C_Timer.After(maxRemaining + 0.1, function()
        if not self.destroyed and self.castToken == token then
            self:Layout(0)
        end
    end)
end

-- Options-GUI "Preview" (Next Features #9): light up the highest-priority
-- tracked icon for a few seconds so the user can see/position the stack
-- without needing the real aura up. The fed value is the tracked ID itself --
-- a PLAIN integer the user typed, so this never touches a secret; the dual
-- punch just sees value == X and shows the icon. `previewing` keeps a
-- concurrent UNIT_AURA-driven Scan from immediately clearing it.
local PREVIEW_SECONDS = 3
function Stack:Preview()
    -- For a FRAME-ATTACHED stack, only flash where the unit actually exists --
    -- otherwise there's no unit frame to anchor to and the fallback would show
    -- a phantom (e.g. party3 while solo). A FREE-FLOATING stack positions at
    -- its saved UIParent point regardless of whether the unit is present, so it
    -- must still preview -- this is exactly the arena-kicks case (preview
    -- arena1-3 while not in an arena, to position the column).
    if self.unitToken and self.db.anchor.useFrame
        and not UnitExists(self.unitToken) then
        return
    end
    local top = self.db.order[1]
    if not top then return end
    local slot = self:AcquireSlot(1)
    self:FeedSlot(slot, top, nil) -- no duration -> no drain during preview
    self:Layout(1)

    local token = (self.previewToken or 0) + 1
    self.previewToken = token
    self.previewing = true
    C_Timer.After(PREVIEW_SECONDS, function()
        if not self.destroyed and self.previewToken == token then
            self.previewing = false
            self:Rebuild()
        end
    end)
end

-- Rebuild everything when the tracked-target set or sizing changes.
function Stack:Rebuild()
    for _, slot in pairs(self.slots) do
        self:BuildSlotBars(slot)
    end
    if self.db.filter == "CAST" then
        self:Layout(0) -- no persistent state to rescan; next cast repopulates
    else
        self:Scan()
    end
end

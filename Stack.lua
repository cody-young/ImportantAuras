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

local function GetIcon(spellID)
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    return tex or 134400 -- red question mark
end
ID.GetIcon = GetIcon

-- ---- shared matcher pool ------------------------------------------------
local pool = {}

local function RefreshPunchLoAnchors(m, iconSize)
    m.pLo:ClearAllPoints()
    m.pLo:SetPoint("TOPLEFT", m.blo:GetStatusBarTexture(), "TOPRIGHT")
    m.pLo:SetPoint("BOTTOMRIGHT", m.blo:GetStatusBarTexture(), "BOTTOMRIGHT",
        iconSize + 2 * PUNCH_MARGIN, 0)
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

        -- Cooldown swipe: a Texture, so it can reuse the same dual-punch masks
        -- as the icon. Countdown NUMBERS are a FontString and can't be masked
        -- (same wall as spell-name text -- see CLAUDE.md), so they stay off;
        -- swipe-only.
        m.cd = CreateFrame("Cooldown", nil, m, "CooldownFrameTemplate")
        m.cd:SetAllPoints(m)
        m.cd:SetDrawEdge(false)
        m.cd:SetDrawBling(false)
        m.cd:SetHideCountdownNumbers(true)
        local okTex, swipeTex = pcall(m.cd.GetSwipeTexture, m.cd)
        if okTex and swipeTex then
            swipeTex:AddMaskTexture(m.pLo)
            swipeTex:AddMaskTexture(m.pHi)
            m.cdMaskable = true
        else
            m.cd:Hide() -- can't safely mask -> never show it (fail closed)
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
    m:Hide()
    if m.cdMaskable then m.cd:Hide() end
    m:SetParent(UIParent)
    m:ClearAllPoints()
    pool[#pool + 1] = m
end

-- Point a matcher at target X (plain, known). Bars start at X-1 so punchLo
-- covers the icon (hidden) until a real value is fed.
local function SetMatcherTarget(m, X, iconSize)
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
        self.db.anchor.point = { p1, "UIParent", p3, x, y }
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
-- plus its (possibly secret) duration/expirationTime into the matcher's
-- masked cooldown swipe. duration/expirationTime must always be concrete
-- plain numbers at the call site (never nil) -- an `or` fallback here would
-- be a truthiness check on a value that might be secret, which errors the
-- same way `if value >= max` does (see CLAUDE.md).
function Stack:FeedSlot(slot, secretSpellId, duration, expirationTime)
    local showCD = self.db.showCooldown
    for _, m in ipairs(slot.matchers) do
        m.blo:SetValue(secretSpellId) -- secret goes to C; never read here
        m.bhi:SetValue(secretSpellId)
        RefreshPunchLoAnchors(m, self.db.iconSize)
        if m.cdMaskable then
            m.cd:SetShown(showCD)
            if showCD and not self.cdBroken then
                local ok = pcall(m.cd.SetCooldown, m.cd, expirationTime - duration, duration)
                if not ok then
                    self.cdBroken = true
                    print("|cffff4444ImportantAuras|r: cooldown swipe disabled for '"
                        .. (self.db.name or "?") .. "' (rejected -- run /ia probe)")
                end
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

    local panel = self.anchor.panel
    if panel then
        if db.panel and activeCount > 0 then
            local pad = db.panelPad or 0
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", self.anchor, "TOPLEFT", -pad, pad)
            panel:SetPoint("BOTTOMRIGHT", self.anchor, "BOTTOMRIGHT",
                pad - (stacked and 0 or gap), -pad)
            panel:SetColorTexture(db.bg[1], db.bg[2], db.bg[3], 1)
            panel:Show()
        else
            panel:Hide()
        end
    end
end

-- unitToken overrides db.unit for nameplate stacks (which have no db.unit).
function Stack:Scan()
    local unit = self.unitToken or self.db.unit
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
        -- data.spellId/duration/expirationTime may be secret; that's fine
        self:FeedSlot(slot, data.spellId, data.duration, data.expirationTime)
    end
    self:Layout(count)
end

-- Cast-mode entry point (db.filter == "CAST"): flash the tracked-target
-- matcher for a fixed duration, since a cast is a momentary event rather than
-- an ongoing aura -- there's no "cast ends" event to scan back down from, so
-- a timer hides it instead. Slot 1 is reused for every cast; misses are
-- transparent (dual punch), so an untracked spellID just shows nothing and
-- the duration timer harmlessly hides an already-empty slot.
function Stack:OnCast(spellID)
    local slot = self:AcquireSlot(1)
    self:FeedSlot(slot, spellID, 0, 0) -- no duration data for a momentary cast
    self:Layout(1)

    local token = (self.castToken or 0) + 1
    self.castToken = token
    C_Timer.After(self.db.castDuration or 2, function()
        if not self.destroyed and self.castToken == token then
            self:Layout(0)
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

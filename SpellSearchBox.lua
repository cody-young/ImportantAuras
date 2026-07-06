local addonName, ID = ...

-- =========================================================================
-- Custom AceGUI widget ("IA-SpellSearchBox") for the "Add spell" box
-- (Next Features #8.1 addendum). Modeled on TellMeWhen's Suggester: a plain
-- EditBox with a floating results dropdown that updates live as you type,
-- instead of AceConfigDialog's stock EditBox, which only calls option.set
-- (and therefore only re-renders results) on Enter/tab-out -- confirmed by
-- reading AceConfigDialog-3.0.lua's FeedOptions: for type="input" it wires
-- ONLY "OnEnterPressed" to ActivateControl, never "OnTextChanged". Building
-- a real per-keystroke experience needs a widget that does its own thing on
-- OnTextChanged rather than going through option.get/set at all.
--
-- Rather than intercepting AceGUI's "OnTextChanged"/"OnEnterPressed" events
-- (AceConfigDialog claims "OnEnterPressed" for its own no-op ActivateControl
-- call, and a second control:SetCallback for the same event would just
-- replace it), this hooks the raw Blizzard EditBox scripts directly via
-- HookScript, which layers on top of AceGUI's own script without conflict.
--
-- Search results are rendered into a small popout frame parented straight to
-- UIParent (matching AceGUI's own Dropdown-Pullout widget), anchored to
-- (not parented under) the editbox -- so it draws above the Blizzard options
-- panel and is never clipped by the options tree's scrollframe.
-- =========================================================================

local Type, Version = "IA-SpellSearchBox", 1
local AceGUI = LibStub("AceGUI-3.0")

local ROW_HEIGHT = 20
local MAX_RESULTS = 8
local DEBOUNCE = 0.15

-- ---------------------------------------------------------------- dropdown

local function HideDropdown(self)
    self.dropdown:Hide()
end

local function GetRow(self, i)
    local row = self.rows[i]
    if row then return row end

    row = CreateFrame("Button", nil, self.dropdown)
    row:SetHeight(ROW_HEIGHT)
    if i == 1 then
        row:SetPoint("TOPLEFT", self.dropdown, "TOPLEFT", 2, -2)
        row:SetPoint("TOPRIGHT", self.dropdown, "TOPRIGHT", -2, -2)
    else
        row:SetPoint("TOPLEFT", self.rows[i - 1], "BOTTOMLEFT")
        row:SetPoint("TOPRIGHT", self.rows[i - 1], "BOTTOMRIGHT")
    end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.text:SetPoint("RIGHT", -2, 0)
    row.text:SetJustifyH("LEFT")

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row:SetScript("OnClick", function(rowSelf)
        local spellID = rowSelf.spellID
        if spellID and self.onAdd then
            self.onAdd(spellID)
            if self.onCommit then self.onCommit() end
        end
        self.editbox:SetText("")
        HideDropdown(self)
        self.editbox:ClearFocus()
    end)

    self.rows[i] = row
    return row
end

local function ShowResults(self, results)
    if #results == 0 then
        HideDropdown(self)
        return
    end

    for i, res in ipairs(results) do
        local row = GetRow(self, i)
        row.icon:SetTexture(res.icon or 134400) -- INV_Misc_QuestionMark fallback
        row.text:SetText(("%d  -  %s"):format(res.id, res.name or "Unknown spell"))
        row.spellID = res.id
        row:Show()
    end
    for i = #results + 1, #self.rows do
        self.rows[i]:Hide()
    end

    self.dropdown:SetHeight(#results * ROW_HEIGHT + 4)
    self.dropdown:Show()
end

-- ------------------------------------------------------------- edit box

local function OnQueryChanged(self)
    if self.debounceTimer then
        self.debounceTimer:Cancel()
        self.debounceTimer = nil
    end

    local text = self.editbox:GetText()
    local trimmed = text:match("^%s*(.-)%s*$")

    if trimmed == "" then
        HideDropdown(self)
        return
    end

    if trimmed:match("^%d+$") then
        -- Single spell id: preview its name/icon immediately, no debounce needed.
        local spellID = tonumber(trimmed)
        local name, icon = ID.SpellSearch.GetDisplay(spellID)
        ShowResults(self, { { id = spellID, name = name, icon = icon } })
        return
    elseif trimmed:match("^[%d%s,]+$") then
        -- Multiple ids being pasted/typed -- committed in bulk on Enter, no preview.
        HideDropdown(self)
        return
    end

    self.debounceTimer = C_Timer.NewTimer(DEBOUNCE, function()
        self.debounceTimer = nil
        if not self.editbox:IsShown() then return end
        local filterType = self.getFilter and self.getFilter()
        ShowResults(self, ID.SpellSearch.Search(self.editbox:GetText(), MAX_RESULTS, filterType))
    end)
end

local function OnEnterPressed(editbox)
    local self = editbox.obj
    local text = editbox:GetText():match("^%s*(.-)%s*$")
    if text ~= "" and text:match("^[%d%s,]+$") then
        for numStr in text:gmatch("%d+") do
            if self.onAdd then self.onAdd(tonumber(numStr)) end
        end
        if self.onCommit then self.onCommit() end
        editbox:SetText("")
        HideDropdown(self)
    end
end

-- ---------------------------------------------------------------- methods

local methods = {
    ["OnAcquire"] = function(self)
        self:SetWidth(200)
        self:SetDisabled(false)
        self:SetLabel()
        self:SetText()
        self.onAdd, self.onCommit, self.getFilter = nil, nil, nil
        HideDropdown(self)
    end,

    ["OnRelease"] = function(self)
        if self.debounceTimer then
            self.debounceTimer:Cancel()
            self.debounceTimer = nil
        end
        self.editbox:ClearFocus()
        HideDropdown(self)
    end,

    ["SetCustomData"] = function(self, arg)
        arg = arg or {}
        self.onAdd = arg.onAdd
        self.onCommit = arg.onCommit
        self.getFilter = arg.getFilter
    end,

    ["SetDisabled"] = function(self, disabled)
        self.disabled = disabled
        if disabled then
            self.editbox:EnableMouse(false)
            self.editbox:ClearFocus()
            self.editbox:SetTextColor(0.5, 0.5, 0.5)
            self.label:SetTextColor(0.5, 0.5, 0.5)
        else
            self.editbox:EnableMouse(true)
            self.editbox:SetTextColor(1, 1, 1)
            self.label:SetTextColor(1, .82, 0)
        end
    end,

    ["SetText"] = function(self, text)
        self.editbox:SetText(text or "")
        self.editbox:SetCursorPosition(0)
    end,

    ["GetText"] = function(self)
        return self.editbox:GetText()
    end,

    ["SetLabel"] = function(self, text)
        if text and text ~= "" then
            self.label:SetText(text)
            self.label:Show()
            self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, -18)
            self:SetHeight(44)
        else
            self.label:SetText("")
            self.label:Hide()
            self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, 0)
            self:SetHeight(26)
        end
    end,
}

-- -------------------------------------------------------------- constructor

local function Constructor()
    local num = AceGUI:GetNextWidgetNum(Type)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local editbox = CreateFrame("EditBox", "IASpellSearchBox" .. num, frame, "InputBoxTemplate")
    editbox:SetAutoFocus(false)
    editbox:SetFontObject(ChatFontNormal)
    editbox:SetTextInsets(0, 0, 3, 3)
    editbox:SetMaxLetters(256)
    editbox:SetPoint("BOTTOMLEFT", 6, 0)
    editbox:SetPoint("BOTTOMRIGHT")
    editbox:SetHeight(19)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, -2)
    label:SetPoint("TOPRIGHT", 0, -2)
    label:SetJustifyH("LEFT")
    label:SetHeight(18)

    local dropdown = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    -- TOOLTIP, not FULLSCREEN_DIALOG: the Settings panel itself sits at
    -- FULLSCREEN_DIALOG with a much higher internal frame level, so a tied
    -- strata left the dropdown (parented straight to UIParent, default
    -- level) drawing underneath it. TOOLTIP is the highest normal strata,
    -- so this wins unconditionally regardless of frame-level ties.
    dropdown:SetFrameStrata("TOOLTIP")
    dropdown:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
    dropdown:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -2)
    dropdown:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    dropdown:SetBackdropColor(0, 0, 0, 0.95)
    dropdown:Hide()

    local widget = {
        editbox  = editbox,
        label    = label,
        dropdown = dropdown,
        rows     = {},
        frame    = frame,
        type     = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end
    editbox.obj = widget

    -- Blizzard's EditBox checks this before clearing focus on mouse-down
    -- elsewhere -- without it, clicking a result row defocuses (and hides)
    -- the dropdown before the row's OnClick ever runs.
    function editbox:HasStickyFocus()
        return widget.dropdown:IsShown() and IsMouseButtonDown("LeftButton")
    end

    editbox:HookScript("OnTextChanged", function() OnQueryChanged(widget) end)
    editbox:HookScript("OnEnterPressed", OnEnterPressed)
    editbox:HookScript("OnEscapePressed", function() HideDropdown(widget) end)
    editbox:HookScript("OnEditFocusLost", function() HideDropdown(widget) end)

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)

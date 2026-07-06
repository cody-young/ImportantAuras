local addonName, ID = ...

-- =========================================================================
-- Import/export of stacks and stack groups (Next Features #4/#5) as plain
-- text strings the user can paste to other people/characters.
--
-- Format: "IA1:" followed by a Lua-table-literal-subset serialization of
-- { type = "stack", stack = {...} } or
-- { type = "group", group = "name", stacks = { {...}, ... } }.
--
-- The string is NEVER loadstring'd on import -- it's untrusted input, so a
-- small recursive-descent parser below handles exactly the grammar the
-- serializer emits (numbers, %q strings, booleans, nested tables), and every
-- imported stack is then rebuilt field-by-field onto ID.NewDefaultStack()
-- via SanitizeStack, which whitelists keys, type-checks and clamps values,
-- restricts unit tokens/points to known sets, and forces free-float anchors
-- to be relative to UIParent. Unknown/malformed fields silently fall back to
-- defaults rather than failing the whole import.
-- =========================================================================

ID.Transfer = {}
local Transfer = ID.Transfer

local PREFIX = "IA1:"
local MAX_IMPORT_LEN = 200000
local MAX_DEPTH = 12

-- ------------------------------------------------------------- serializer

local function SerializeInto(v, out)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = string.format("%.14g", v)
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            SerializeInto(v[i], out)
            out[#out + 1] = ","
        end
        for k, val in pairs(v) do
            local isArrayIndex = type(k) == "number" and k >= 1 and k <= n and k % 1 == 0
            if not isArrayIndex then
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    out[#out + 1] = k .. "="
                elseif type(k) == "number" then
                    out[#out + 1] = "[" .. string.format("%.14g", k) .. "]="
                else
                    error("unsupported table key type: " .. type(k))
                end
                SerializeInto(val, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    else
        error("unsupported value type: " .. t)
    end
end

local function Serialize(v)
    local out = {}
    SerializeInto(v, out)
    return table.concat(out)
end

-- ----------------------------------------------------------------- parser

local Parser = {}
Parser.__index = Parser

function Parser:ws()
    local _, e = self.s:find("^%s*", self.pos)
    self.pos = e + 1
end

function Parser:peek()
    return self.s:sub(self.pos, self.pos)
end

function Parser:expect(c)
    if self:peek() ~= c then
        error(("expected '%s' at position %d"):format(c, self.pos))
    end
    self.pos = self.pos + 1
end

-- Handles the escapes Lua 5.1's %q emits: \" \\ , \n for embedded newlines
-- (%q emits backslash + literal newline), and \ddd decimal escapes; a few
-- common single-char escapes are accepted too for robustness.
function Parser:parseString()
    self:expect('"')
    local out = {}
    while true do
        local c = self.s:sub(self.pos, self.pos)
        if c == "" then error("unterminated string") end
        self.pos = self.pos + 1
        if c == '"' then break end
        if c == "\\" then
            local e = self.s:sub(self.pos, self.pos)
            self.pos = self.pos + 1
            if e == "n" or e == "\n" or e == "\r" then
                out[#out + 1] = "\n"
            elseif e == "r" then
                out[#out + 1] = "\r"
            elseif e == "t" then
                out[#out + 1] = "\t"
            elseif e:match("%d") then
                local digits = e
                for _ = 1, 2 do
                    local d = self.s:sub(self.pos, self.pos)
                    if d:match("%d") then
                        digits = digits .. d
                        self.pos = self.pos + 1
                    else
                        break
                    end
                end
                out[#out + 1] = string.char(tonumber(digits) % 256)
            else
                out[#out + 1] = e -- covers \\ \" \' verbatim
            end
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

function Parser:parseValue(depth)
    if depth > MAX_DEPTH then error("nesting too deep") end
    self:ws()
    local c = self:peek()
    if c == '"' then
        return self:parseString()
    elseif c == "{" then
        return self:parseTable(depth)
    elseif c:match("[%d%-%+%.]") then
        -- grab the maximal number-ish run; tonumber validates it. None of
        -- these characters can start the NEXT token (',' '}' ']' etc), so
        -- this can't over-consume within the grammar.
        local m = self.s:match("^[%-%+%.%deExX]+", self.pos)
        local n = m and tonumber(m)
        if not n then error("malformed number at position " .. self.pos) end
        self.pos = self.pos + #m
        return n
    else
        local word = self.s:match("^[%a_][%w_]*", self.pos)
        if word == "true" then
            self.pos = self.pos + 4
            return true
        elseif word == "false" then
            self.pos = self.pos + 5
            return false
        end
        error("unexpected token at position " .. self.pos)
    end
end

function Parser:parseTable(depth)
    self:expect("{")
    local t = {}
    local nextIndex = 1
    while true do
        self:ws()
        if self:peek() == "}" then
            self.pos = self.pos + 1
            break
        end
        local key
        if self:peek() == "[" then
            self.pos = self.pos + 1
            key = self:parseValue(depth + 1)
            self:ws()
            self:expect("]")
            self:ws()
            self:expect("=")
        else
            -- bare identifier followed by '=' is a key; 'true'/'false' are
            -- always values (the serializer never emits them as bare keys)
            local ws_, we = self.s:find("^[%a_][%w_]*", self.pos)
            if ws_ then
                local word = self.s:sub(ws_, we)
                if word ~= "true" and word ~= "false" and self.s:match("^%s*=", we + 1) then
                    self.pos = we + 1
                    self:ws()
                    self:expect("=")
                    key = word
                end
            end
        end
        local v = self:parseValue(depth + 1)
        if key ~= nil then
            t[key] = v
        else
            t[nextIndex] = v
            nextIndex = nextIndex + 1
        end
        self:ws()
        if self:peek() == "," then
            self.pos = self.pos + 1
        end
    end
    return t
end

local function Deserialize(s)
    local p = setmetatable({ s = s, pos = 1 }, Parser)
    local ok, result = pcall(function()
        local v = p:parseValue(1)
        p:ws()
        if p.pos <= #p.s then error("trailing garbage") end
        return v
    end)
    if ok then return result end
    return nil, result
end

-- -------------------------------------------------------------- sanitizer

local POINT_SET = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Rebuild an untrusted (imported) stack table onto the canonical default
-- shape. Also used on EXPORT to strip a live saved table down to exactly the
-- known schema before serializing.
local function SanitizeStack(raw)
    if type(raw) ~= "table" then return nil end
    local s = ID.NewDefaultStack()

    local function str(k)
        if type(raw[k]) == "string" then s[k] = raw[k]:sub(1, 100) end
    end
    local function boolean(k)
        if type(raw[k]) == "boolean" then s[k] = raw[k] end
    end
    local function num(k, lo, hi)
        local v = raw[k]
        if type(v) == "number" then
            if v < lo then v = lo elseif v > hi then v = hi end
            s[k] = v
        end
    end

    str("name"); str("group")
    boolean("enabled"); boolean("panel"); boolean("locked"); boolean("showCooldown")
    num("iconSize", 8, 128)
    num("spacing", 0, 32)
    num("panelPad", 0, 32)
    num("castDuration", 0.1, 30)

    if raw.kind == "nameplate" then s.kind = "nameplate" end
    if raw.filter == "HELPFUL" or raw.filter == "CAST" then s.filter = raw.filter end
    if raw.layout == "row" then s.layout = "row" end
    if raw.growth == "HORIZONTAL" then s.growth = "HORIZONTAL" end
    if raw.align == "CENTER" or raw.align == "RIGHT" then s.align = raw.align end

    if type(raw.units) == "table" then
        local wanted = {}
        for _, u in ipairs(raw.units) do
            if type(u) == "string" then wanted[u] = true end
        end
        local units = {}
        for _, tok in ipairs(ID.UNIT_TOKEN_ORDER) do
            if wanted[tok] then units[#units + 1] = tok end
        end
        if #units > 0 then s.units = units end
    end

    s.targets, s.order = {}, {}
    if type(raw.order) == "table" then
        for _, spellID in ipairs(raw.order) do
            if type(spellID) == "number" and spellID > 0 and spellID % 1 == 0
                    and not s.targets[spellID] then
                s.targets[spellID] = true
                s.order[#s.order + 1] = spellID
            end
        end
    end
    if type(raw.targets) == "table" then
        for spellID, v in pairs(raw.targets) do
            if type(spellID) == "number" and spellID > 0 and spellID % 1 == 0 and v then
                s.targets[spellID] = true
            end
        end
    end
    ID.ReconcileOrder(s)

    if type(raw.bg) == "table" then
        for i = 1, 4 do
            local v = raw.bg[i]
            if type(v) == "number" then
                s.bg[i] = math.max(0, math.min(1, v))
            end
        end
    end

    if type(raw.anchor) == "table" then
        local a = raw.anchor
        if type(a.useFrame) == "boolean" then s.anchor.useFrame = a.useFrame end
        if POINT_SET[a.myPoint] then s.anchor.myPoint = a.myPoint end
        if POINT_SET[a.relPoint] then s.anchor.relPoint = a.relPoint end
        if type(a.x) == "number" then s.anchor.x = math.max(-500, math.min(500, a.x)) end
        if type(a.y) == "number" then s.anchor.y = math.max(-500, math.min(500, a.y)) end
        if type(a.point) == "table" and POINT_SET[a.point[1]] and POINT_SET[a.point[3]]
                and type(a.point[4]) == "number" and type(a.point[5]) == "number" then
            -- free-float is always relative to UIParent on import -- never
            -- trust an arbitrary frame name out of a pasted string
            s.anchor.point = { a.point[1], "UIParent", a.point[3], a.point[4], a.point[5] }
        end
    end

    return s
end
Transfer.SanitizeStack = SanitizeStack

-- ----------------------------------------------------------------- dialog

local dialog
local function GetDialog()
    if dialog then return dialog end

    local f = CreateFrame("Frame", "ImportantAurasTransferDialog", UIParent, "BackdropTemplate")
    f:SetSize(480, 280)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frame) frame:StartMoving() end)
    f:SetScript("OnMouseUp", function(frame) frame:StopMovingOrSizing() end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -16)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -38)
    scroll:SetPoint("BOTTOMRIGHT", -38, 50)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(410)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    f.edit = edit

    f.accept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.accept:SetSize(110, 22)
    f.accept:SetPoint("BOTTOMRIGHT", -18, 16)

    f.closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.closeBtn:SetSize(110, 22)
    f.closeBtn:SetPoint("BOTTOMLEFT", 18, 16)
    f.closeBtn:SetText(CLOSE or "Close")
    f.closeBtn:SetScript("OnClick", function() f:Hide() end)

    dialog = f
    return f
end

function Transfer.ShowExport(text)
    local f = GetDialog()
    f.title:SetText("Export string -- Ctrl+C to copy")
    f.accept:Hide()
    f.edit:SetText(text)
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

function Transfer.ShowImport()
    local f = GetDialog()
    f.title:SetText("Paste an ImportantAuras export string")
    f.edit:SetText("")
    f.accept:SetText("Import")
    f.accept:SetScript("OnClick", function()
        local ok, msg = Transfer.Import(f.edit:GetText())
        print("|cff66ccffImportantAuras|r: " .. msg)
        if ok then f:Hide() end
    end)
    f.accept:Show()
    f:Show()
    f.edit:SetFocus()
end

-- ------------------------------------------------------------ entry points

function Transfer.ExportStack(sdb)
    local clean = SanitizeStack(sdb) -- canonical copy: schema fields only
    Transfer.ShowExport(PREFIX .. Serialize({ type = "stack", stack = clean }))
end

function Transfer.ExportGroup(groupName)
    local ids = {}
    for id, sdb in pairs(ID.db.profile.stacks) do
        if (sdb.group or "") == groupName then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

    local stacks = {}
    for _, id in ipairs(ids) do
        stacks[#stacks + 1] = SanitizeStack(ID.db.profile.stacks[id])
    end
    Transfer.ShowExport(PREFIX .. Serialize({
        type = "group", group = groupName, stacks = stacks,
    }))
end

-- Returns ok, humanReadableMessage.
function Transfer.Import(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if #text > MAX_IMPORT_LEN then
        return false, "import failed: string too long"
    end
    if text:sub(1, #PREFIX) ~= PREFIX then
        return false, "import failed: not an ImportantAuras export string (missing " .. PREFIX .. " prefix)"
    end

    local payload = Deserialize(text:sub(#PREFIX + 1))
    if type(payload) ~= "table" then
        return false, "import failed: corrupt export string"
    end

    local toAdd = {}
    if payload.type == "stack" then
        toAdd[1] = SanitizeStack(payload.stack)
    elseif payload.type == "group" then
        local gname = type(payload.group) == "string" and payload.group ~= ""
            and payload.group or "Imported"
        if type(payload.stacks) == "table" then
            for _, raw in ipairs(payload.stacks) do
                local s = SanitizeStack(raw)
                if s then
                    s.group = gname
                    toAdd[#toAdd + 1] = s
                end
            end
        end
    end

    if #toAdd == 0 or toAdd[1] == nil then
        return false, "import failed: no valid stacks in string"
    end

    for _, s in ipairs(toAdd) do
        ID.db.profile.stacks[ID.NewStackID()] = s
    end
    ID.RefreshAll()
    if ID.Options and ID.Options.Rebuild then ID.Options.Rebuild() end
    return true, ("imported %d stack(s)"):format(#toAdd)
end

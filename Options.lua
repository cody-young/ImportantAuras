local addonName, ID = ...

-- =========================================================================
-- AceConfig/AceGUI options for the multi-stack system. `/ia` (no args,
-- see Config.lua) opens this. Editing any field calls ID.RefreshAll(), which
-- re-syncs both managers against the current saved config and re-scans/
-- repositions every live stack -- simple and correct at the scale this addon
-- runs at (a handful of stacks), even if not the most surgical update path.
-- =========================================================================

local APP_NAME = "ImportantAuras"

local UNIT_TOKENS = {
    player = "Player", target = "Target", focus = "Focus", pet = "Pet",
    party1 = "Party 1", party2 = "Party 2", party3 = "Party 3", party4 = "Party 4",
    arena1 = "Arena 1", arena2 = "Arena 2", arena3 = "Arena 3", arena4 = "Arena 4", arena5 = "Arena 5",
    boss1 = "Boss 1", boss2 = "Boss 2", boss3 = "Boss 3", boss4 = "Boss 4", boss5 = "Boss 5",
}

local POINTS = {
    TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
    LEFT = "Left", CENTER = "Center", RIGHT = "Right",
    BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}

-- Re-sync both managers against current config, then rescan/reposition every
-- live stack so edits take effect immediately.
function ID.RefreshAll()
    ID.StackManager.Rebuild()
    ID.NameplateStackManager.Rebuild()
    ID.StackManager.ForEach(function(stack)
        stack:Rebuild()
        ID.FrameAnchor.Reposition(stack)
    end)
    ID.NameplateStackManager.ForEach(function(stack) stack:Rebuild() end)
end

local function NotifyOptionsChanged()
    LibStub("AceConfigRegistry-3.0"):NotifyChange(APP_NAME)
end

local function NewStackID()
    local db = ID.db.profile
    local id = tostring(db.nextStackID)
    db.nextStackID = db.nextStackID + 1
    return id
end

-- Adds/removes a spell id from a stack's priority list, reused by both the
-- numeric-paste and the search-result-click paths below.
local function AddTrackedSpell(sdb, spellID)
    if spellID and spellID > 0 and not sdb.targets[spellID] then
        sdb.targets[spellID] = true
        sdb.order[#sdb.order + 1] = spellID
    end
end

-- Builds the "Tracked spells" table (Next Features #8.1: spellID + name +
-- up/down/remove per row, replacing the old comma-separated text box) plus
-- the "Add spell" box (#8, #8.1 addendum: a custom AceGUI widget --
-- SpellSearchBox.lua's "IA-SpellSearchBox" -- styled after TellMeWhen's
-- Suggester, showing live-as-you-type results in a floating dropdown rather
-- than AceConfigDialog's stock EditBox, which only re-renders on Enter).
-- Rows are one `inline` group each so they each land on their own line
-- regardless of the options pane's width.
local function BuildSpellListArgs(id, sdb)
    local args = {}
    local order = 6

    for i, spellID in ipairs(sdb.order) do
        order = order + 0.001
        local name, icon = ID.SpellSearch.GetDisplay(spellID)
        local iconStr = icon and ("|T%d:16:16:0:0|t "):format(icon) or ""
        local label = ("%s%d  -  %s"):format(iconStr, spellID, name or "Unknown spell")

        args["spellRow" .. i] = {
            type = "group", inline = true, name = "", order = order,
            args = {
                label = {
                    type = "description", name = label, order = 1, width = 1.6,
                },
                up = {
                    type = "execute", name = "Up", order = 2, width = 0.4,
                    disabled = (i == 1),
                    func = function()
                        sdb.order[i], sdb.order[i - 1] = sdb.order[i - 1], sdb.order[i]
                        ID.RefreshAll()
                        ID.Options.Rebuild()
                    end,
                },
                down = {
                    type = "execute", name = "Down", order = 3, width = 0.4,
                    disabled = (i == #sdb.order),
                    func = function()
                        sdb.order[i], sdb.order[i + 1] = sdb.order[i + 1], sdb.order[i]
                        ID.RefreshAll()
                        ID.Options.Rebuild()
                    end,
                },
                remove = {
                    type = "execute", name = "Remove", order = 4, width = 0.4,
                    func = function()
                        sdb.targets[spellID] = nil
                        table.remove(sdb.order, i)
                        ID.RefreshAll()
                        ID.Options.Rebuild()
                    end,
                },
            },
        }
    end

    order = order + 0.001
    args.addSpell = {
        type = "input", dialogControl = "IA-SpellSearchBox",
        name = "Add spell (ID, or name to search your spellbook)",
        order = order, width = "full",
        get = function() return "" end,
        set = function() end, -- widget handles adds itself via arg.onAdd/onCommit
        arg = {
            onAdd = function(spellID) AddTrackedSpell(sdb, spellID) end,
            onCommit = function()
                ID.RefreshAll()
                ID.Options.Rebuild()
            end,
            getFilter = function() return sdb.filter end,
        },
    }

    return args
end

local function BuildStackArgs(id, sdb, order)
    local args = {
            name = {
                type = "input", name = "Name", order = 1,
                get = function() return sdb.name end,
                set = function(_, v) sdb.name = v; ID.Options.Rebuild() end,
            },
            enabled = {
                type = "toggle", name = "Enabled", order = 2,
                get = function() return sdb.enabled end,
                set = function(_, v) sdb.enabled = v; ID.RefreshAll() end,
            },
            filter = {
                type = "select", name = "Aura type", order = 5,
                values = { HARMFUL = "Debuffs", HELPFUL = "Buffs", CAST = "Spell Cast" },
                get = function() return sdb.filter end,
                set = function(_, v) sdb.filter = v; ID.RefreshAll() end,
            },
            castDuration = {
                type = "range", name = "Flash duration (seconds)", order = 5.1,
                min = 0.1, max = 10, step = 0.1,
                hidden = function() return sdb.filter ~= "CAST" end,
                get = function() return sdb.castDuration end,
                set = function(_, v) sdb.castDuration = v; ID.RefreshAll() end,
            },

            spellsHeader = { type = "header", name = "Tracked spells (priority order)", order = 6 },

            layout = {
                type = "select", name = "Layout", order = 7,
                hidden = function() return sdb.filter == "CAST" end,
                values = { stack = "Stacked (priority)", row = "Row (aura mirror)" },
                get = function() return sdb.layout end,
                set = function(_, v) sdb.layout = v; ID.RefreshAll() end,
            },
            iconSize = {
                type = "range", name = "Icon size", order = 8, min = 8, max = 128, step = 1,
                get = function() return sdb.iconSize end,
                set = function(_, v) sdb.iconSize = v; ID.RefreshAll() end,
            },
            spacing = {
                type = "range", name = "Spacing", order = 9, min = 0, max = 32, step = 1,
                hidden = function() return sdb.filter == "CAST" or sdb.layout ~= "row" end,
                get = function() return sdb.spacing end,
                set = function(_, v) sdb.spacing = v; ID.RefreshAll() end,
            },

            anchorHeader = { type = "header", name = "Anchor", order = 10 },

            kind = {
                type = "select", name = "Anchor kind", order = 10.1,
                values = { unit = "Unit Frame", nameplate = "Nameplate" },
                get = function() return sdb.kind end,
                set = function(_, v)
                    sdb.kind = v
                    if v == "unit" then
                        sdb.unit = sdb.unit or "player"
                        sdb.anchor.point = sdb.anchor.point or { "CENTER", "UIParent", "CENTER", 0, 0 }
                    end
                    ID.RefreshAll()
                    NotifyOptionsChanged()
                end,
            },
            unit = {
                type = "select", name = "Unit", order = 10.2,
                hidden = function() return sdb.kind ~= "unit" end,
                values = UNIT_TOKENS,
                get = function() return sdb.unit end,
                set = function(_, v) sdb.unit = v; ID.RefreshAll() end,
            },
            nameplateNote = {
                type = "description", order = 10.2,
                name = "Nameplate stacks always follow your current target.",
                hidden = function() return sdb.kind ~= "nameplate" end,
            },

            useFrame = {
                type = "toggle", name = "Attach to unit frame", order = 11,
                hidden = function() return sdb.kind ~= "unit" end,
                get = function() return sdb.anchor.useFrame end,
                set = function(_, v) sdb.anchor.useFrame = v; ID.RefreshAll() end,
            },
            myPoint = {
                type = "select", name = "My point", order = 12,
                hidden = function() return sdb.kind == "unit" and not sdb.anchor.useFrame end,
                values = POINTS,
                get = function() return sdb.anchor.myPoint end,
                set = function(_, v) sdb.anchor.myPoint = v; ID.RefreshAll() end,
            },
            relPoint = {
                type = "select", name = "Frame's point", order = 13,
                hidden = function() return sdb.kind == "unit" and not sdb.anchor.useFrame end,
                values = POINTS,
                get = function() return sdb.anchor.relPoint end,
                set = function(_, v) sdb.anchor.relPoint = v; ID.RefreshAll() end,
            },
            x = {
                type = "range", name = "X offset", order = 14, min = -200, max = 200, step = 1,
                hidden = function() return sdb.kind == "unit" and not sdb.anchor.useFrame end,
                get = function() return sdb.anchor.x end,
                set = function(_, v) sdb.anchor.x = v; ID.RefreshAll() end,
            },
            y = {
                type = "range", name = "Y offset", order = 15, min = -200, max = 200, step = 1,
                hidden = function() return sdb.kind == "unit" and not sdb.anchor.useFrame end,
                get = function() return sdb.anchor.y end,
                set = function(_, v) sdb.anchor.y = v; ID.RefreshAll() end,
            },
            locked = {
                type = "toggle", name = "Locked", order = 16,
                hidden = function()
                    return sdb.kind == "nameplate" or (sdb.kind == "unit" and sdb.anchor.useFrame)
                end,
                get = function() return sdb.locked end,
                set = function(_, v) sdb.locked = v; ID.RefreshAll() end,
            },

            displayHeader = { type = "header", name = "Display", order = 20 },
            panel = {
                type = "toggle", name = "Backing panel", order = 21,
                hidden = function() return sdb.kind ~= "unit" end,
                get = function() return sdb.panel end,
                set = function(_, v) sdb.panel = v; ID.RefreshAll() end,
            },
            showCooldown = {
                type = "toggle", name = "Cooldown swipe", order = 22,
                hidden = function() return sdb.filter == "CAST" end,
                get = function() return sdb.showCooldown end,
                set = function(_, v) sdb.showCooldown = v; ID.RefreshAll() end,
            },

            deleteHeader = { type = "header", name = " ", order = 90 },
            delete = {
                type = "execute", name = "Delete stack", order = 91, confirm = true,
                confirmText = "Delete this stack?",
                func = function()
                    ID.db.profile.stacks[id] = nil
                    ID.RefreshAll()
                    ID.Options.Rebuild()
                end,
            },
    }

    for k, v in pairs(BuildSpellListArgs(id, sdb)) do
        args[k] = v
    end

    return {
        type = "group",
        name = sdb.name ~= "" and sdb.name or ("Stack " .. id),
        order = order,
        args = args,
    }
end

local function BuildOptions()
    local options = {
        type = "group",
        name = "Important Auras",
        childGroups = "tree",
        args = {
            addstack = {
                type = "execute", name = "Add stack", order = 1,
                func = function()
                    local id = NewStackID()
                    ID.db.profile.stacks[id] = {
                        name = "New Stack", kind = "unit", enabled = true,
                        unit = "target", filter = "HARMFUL",
                        targets = {}, order = {},
                        layout = "stack", iconSize = 36, spacing = 4,
                        bg = { 0.05, 0.05, 0.05, 0.85 }, panel = true, panelPad = 3,
                        locked = false, castDuration = 2, showCooldown = true,
                        anchor = {
                            useFrame = false, myPoint = "BOTTOMLEFT", relPoint = "TOPRIGHT",
                            x = 0, y = 0, point = { "CENTER", "UIParent", "CENTER", 0, 0 },
                        },
                    }
                    ID.RefreshAll()
                    ID.Options.Rebuild()
                end,
            },
        },
    }

    local order = 10
    for id, sdb in pairs(ID.db.profile.stacks) do
        options.args["stack" .. id] = BuildStackArgs(id, sdb, order)
        order = order + 1
    end

    return options
end

ID.Options = {}

function ID.Options.Rebuild()
    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
    LibStub("AceConfig-3.0"):RegisterOptionsTable(APP_NAME, BuildOptions())
    AceConfigRegistry:NotifyChange(APP_NAME)
end

function ID.Options.Open()
    if not ID.Options._initialized then
        ID.Options.Init()
    end
    LibStub("AceConfigDialog-3.0"):Open(APP_NAME)
end

function ID.Options.Init()
    if ID.Options._initialized then return end
    LibStub("AceConfig-3.0"):RegisterOptionsTable(APP_NAME, BuildOptions())
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(APP_NAME, "Important Auras")
    ID.Options._initialized = true
end

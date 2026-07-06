local addonName, ID = ...

-- =========================================================================
-- AceConfig/AceGUI options for the multi-stack system. `/ia` (no args,
-- see Config.lua) opens this. Editing any field calls ID.RefreshAll(), which
-- re-syncs both managers against the current saved config and re-scans/
-- repositions every live stack -- simple and correct at the scale this addon
-- runs at (a handful of stacks), even if not the most surgical update path.
-- =========================================================================

local APP_NAME = "ImportantAuras"

-- Labels for ID.UNIT_TOKEN_ORDER (Config.lua owns the canonical ordered
-- list); rendered as one toggle per token so a stack can fan out to several
-- units at once (Next Features #12).
local UNIT_LABELS = {
    player = "Player", target = "Target", focus = "Focus", pet = "Pet",
    party1 = "Party 1", party2 = "Party 2", party3 = "Party 3", party4 = "Party 4", party5 = "Party 5",
    arena1 = "Arena 1", arena2 = "Arena 2", arena3 = "Arena 3",
    arenapet1 = "Arena Pet 1", arenapet2 = "Arena Pet 2", arenapet3 = "Arena Pet 3",
    boss1 = "Boss 1", boss2 = "Boss 2", boss3 = "Boss 3", boss4 = "Boss 4", boss5 = "Boss 5",
}

local function StackHasUnit(sdb, token)
    for _, u in ipairs(sdb.units) do
        if u == token then return true end
    end
    return false
end

-- Rebuilds sdb.units from scratch in canonical token order, so the saved
-- list (and therefore instance/event creation and the free-float column)
-- never depends on the order boxes were clicked in.
local function StackSetUnit(sdb, token, on)
    local wanted = {}
    for _, u in ipairs(sdb.units) do wanted[u] = true end
    wanted[token] = on or nil
    local units = {}
    for _, tok in ipairs(ID.UNIT_TOKEN_ORDER) do
        if wanted[tok] then units[#units + 1] = tok end
    end
    sdb.units = units
end

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

-- Preview (Next Features #9): flash every live instance of one stack id.
function ID.PreviewStack(id)
    ID.StackManager.ForStack(id, function(stack) stack:Preview() end)
    ID.NameplateStackManager.ForStack(id, function(stack) stack:Preview() end)
end

local function NotifyOptionsChanged()
    LibStub("AceConfigRegistry-3.0"):NotifyChange(APP_NAME)
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
        name = "Add spell (ID, or name to search)",
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

    -- Most casts apply their aura under the SAME id (verified against simc's
    -- client-data dumps -- including Kingsbane 385627, previously suspected
    -- of using a different debuff id), and where the aura is a separate
    -- spell it's usually in the search corpus under the same name. Only
    -- server-side script-applied auras are unmappable from any data source,
    -- and since aura spellIds are secret in-game, the only way to
    -- distinguish candidate ids is to try them.
    order = order + 0.001
    args.spellIdNote = {
        type = "description", order = order, fontSize = "small",
        hidden = function() return sdb.filter == "CAST" end,
        name = "|cff999999A rare few auras are applied under a different id than the cast "
            .. "that triggers them. If a tracked icon never lights up, search the name "
            .. "again and add every id listed for it (or look the aura id up on Wowhead "
            .. "and type it), get the aura applied once, and remove the ones that stay dark.|r",
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
            group = {
                type = "input", name = "Group", order = 3,
                desc = "Stacks sharing a group name are shown together in the list "
                    .. "and can be exported/imported as a set. Leave empty for none.",
                get = function() return sdb.group or "" end,
                set = function(_, v)
                    sdb.group = v:match("^%s*(.-)%s*$")
                    ID.Options.Rebuild()
                end,
            },
            preview = {
                type = "execute", name = "Preview", order = 4, width = 0.7,
                desc = "Flash the highest-priority tracked icon on every live "
                    .. "instance of this stack for a few seconds.",
                func = function() ID.PreviewStack(id) end,
            },
            filter = {
                type = "select", name = "Aura type", order = 5,
                values = { HARMFUL = "Debuffs", HELPFUL = "Buffs", CAST = "Spell Cast" },
                get = function() return sdb.filter end,
                set = function(_, v) sdb.filter = v; ID.RefreshAll() end,
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
            -- Growth/align arrange a CAST stack's per-unit icons (one per
            -- checked unit) when they free-float; ignored per-instance when
            -- frame-attached (each icon follows its own unit's frame).
            growth = {
                type = "select", name = "Growth", order = 9.1,
                hidden = function() return sdb.filter ~= "CAST" end,
                values = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" },
                get = function() return sdb.growth or "VERTICAL" end,
                set = function(_, v) sdb.growth = v; ID.RefreshAll() end,
            },
            align = {
                type = "select", name = "Align", order = 9.2,
                hidden = function() return sdb.filter ~= "CAST" end,
                desc = "Horizontal: Left grows right, Right grows left, Center is "
                    .. "centered. Vertical: Left grows down, Right grows up, Center "
                    .. "is centered.",
                values = { LEFT = "Left / Top", CENTER = "Center", RIGHT = "Right / Bottom" },
                get = function() return sdb.align or "LEFT" end,
                set = function(_, v) sdb.align = v; ID.RefreshAll() end,
            },

            anchorHeader = { type = "header", name = "Anchor", order = 10 },

            -- One dropdown covers both the old `kind` (unit vs nameplate) and
            -- the old "Attach to unit frame" toggle: UIParent = free-floating
            -- unit stack (useFrame=false), Unit Frame = attached (useFrame=true),
            -- Nameplate = follows the current target's plate.
            anchorKind = {
                type = "select", name = "Anchor kind", order = 10.1,
                values = { uiparent = "UIParent (free)", unit = "Unit Frame", nameplate = "Nameplate" },
                sorting = { "uiparent", "unit", "nameplate" },
                get = function()
                    if sdb.kind == "nameplate" then return "nameplate" end
                    return sdb.anchor.useFrame and "unit" or "uiparent"
                end,
                set = function(_, v)
                    if v == "nameplate" then
                        sdb.kind = "nameplate"
                    else
                        sdb.kind = "unit"
                        sdb.anchor.useFrame = (v == "unit")
                        if not sdb.units or #sdb.units == 0 then sdb.units = { "player" } end
                        sdb.anchor.point = sdb.anchor.point or { "CENTER", "UIParent", "CENTER", 0, 0 }
                    end
                    ID.RefreshAll()
                    NotifyOptionsChanged()
                end,
            },
            unitsNote = {
                type = "description", order = 10.15, fontSize = "medium",
                name = "Units -- the stack shows once per checked unit "
                    .. "(e.g. Player + Party 1 + Party 2 to see who has a tracked buff):",
                hidden = function() return sdb.kind ~= "unit" end,
            },
            nameplateNote = {
                type = "description", order = 10.2,
                name = "Nameplate stacks always follow your current target.",
                hidden = function() return sdb.kind ~= "nameplate" end,
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
            showCooldown = {
                type = "toggle", name = "Cooldown drain", order = 22,
                desc = "Animate a dark vertical drain over matched icons: the "
                    .. "aura's remaining duration, or for Spell Cast stacks the "
                    .. "cast spell's cooldown.",
                get = function() return sdb.showCooldown end,
                set = function(_, v) sdb.showCooldown = v; ID.RefreshAll() end,
            },

            deleteHeader = { type = "header", name = " ", order = 90 },
            export = {
                type = "execute", name = "Export stack", order = 91,
                desc = "Show a text string you can paste to share this stack.",
                func = function() ID.Transfer.ExportStack(sdb) end,
            },
            delete = {
                type = "execute", name = "Delete stack", order = 92, confirm = true,
                confirmText = "Delete this stack?",
                func = function()
                    ID.db.profile.stacks[id] = nil
                    ID.RefreshAll()
                    ID.Options.Rebuild()
                end,
            },
    }

    -- One toggle per unit token, in canonical order (a multiselect widget
    -- renders its values in pairs() order, i.e. randomly -- individual
    -- toggles with explicit `order` keep Player..party..arena..boss stable).
    for i, tok in ipairs(ID.UNIT_TOKEN_ORDER) do
        args["unit_" .. tok] = {
            type = "toggle", name = UNIT_LABELS[tok] or tok,
            order = 10.2 + i * 0.001, width = 0.65,
            hidden = function() return sdb.kind ~= "unit" end,
            get = function() return StackHasUnit(sdb, tok) end,
            set = function(_, v)
                StackSetUnit(sdb, tok, v)
                ID.RefreshAll()
            end,
        }
    end

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

-- Presets page (Next Features #6): a description + Create button per entry
-- in ID.Presets (Presets.lua).
local function BuildPresetArgs()
    local args = {
        intro = {
            type = "description", order = 1, fontSize = "medium",
            name = "One-click starter setups. Each button creates new stack(s) in "
                .. "their own group -- tweak or delete them like any other stack.\n",
        },
    }
    for i, preset in ipairs(ID.Presets or {}) do
        args["preset" .. i .. "desc"] = {
            type = "description", order = i * 10,
            name = "\n|cffffd100" .. preset.name .. "|r\n" .. preset.desc,
        }
        args["preset" .. i .. "btn"] = {
            type = "execute", name = "Create", order = i * 10 + 1, width = 0.7,
            func = function() ID.ApplyPreset(preset) end,
        }
    end
    return args
end

-- Pick a group name not already in use, so "Create group" always makes a new
-- tree node rather than dropping a stack into an existing group.
local function UniqueGroupName()
    local used = {}
    for _, sdb in pairs(ID.db.profile.stacks) do
        if sdb.group and sdb.group ~= "" then used[sdb.group] = true end
    end
    if not used["New Group"] then return "New Group" end
    local i = 2
    while used["New Group " .. i] do i = i + 1 end
    return "New Group " .. i
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
                    local s = ID.NewDefaultStack()
                    s.name = "New Stack"
                    s.units = { "target" }
                    ID.db.profile.stacks[ID.NewStackID()] = s
                    ID.RefreshAll()
                    ID.Options.Rebuild()
                end,
            },
            addgroup = {
                type = "execute", name = "Create group", order = 1.5,
                desc = "Create a new group (with one stack in it). Stacks sharing a "
                    .. "group name nest together and export/import as a set.",
                func = function()
                    local s = ID.NewDefaultStack()
                    s.name = "New Stack"
                    s.units = { "target" }
                    s.group = UniqueGroupName()
                    ID.db.profile.stacks[ID.NewStackID()] = s
                    ID.RefreshAll()
                    ID.Options.Rebuild()
                end,
            },
            import = {
                type = "execute", name = "Import", order = 2,
                desc = "Paste a stack or group export string.",
                func = function() ID.Transfer.ShowImport() end,
            },
            presets = {
                type = "group", name = "Presets", order = 5,
                args = BuildPresetArgs(),
            },
        },
    }

    -- Sort ids so the tree order is stable across rebuilds (pairs() order is
    -- not), then hang each stack either at the root or under its group's
    -- tree node (Next Features #5).
    local ids = {}
    for id in pairs(ID.db.profile.stacks) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        return (tonumber(a) or math.huge) < (tonumber(b) or math.huge)
    end)

    local order = 10
    local groupNodes = {}
    for _, id in ipairs(ids) do
        local sdb = ID.db.profile.stacks[id]
        local node = BuildStackArgs(id, sdb, order)
        local g = sdb.group or ""
        if g ~= "" then
            local gnode = groupNodes[g]
            if not gnode then
                gnode = {
                    type = "group", name = g, order = order, childGroups = "tree",
                    args = {
                        exportGroup = {
                            type = "execute", name = "Export group", order = 1,
                            desc = "Show a text string containing every stack in this group.",
                            func = function() ID.Transfer.ExportGroup(g) end,
                        },
                    },
                }
                options.args["group_" .. g] = gnode
                groupNodes[g] = gnode
            end
            gnode.args["stack" .. id] = node
        else
            options.args["stack" .. id] = node
        end
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

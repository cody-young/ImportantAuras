local addonName, ID = ...

-- =========================================================================
-- One-click presets (Next Features #6): each entry creates ready-made
-- stack(s) under a named group. Built on the multi-unit fan-out (#12) --
-- e.g. one CAST stack with units={"arena1","arena2","arena3",...} recreates
-- an OmniBar-style kick tracker, flashing the kick's icon on the caster's
-- frame when UNIT_SPELLCAST_SUCCEEDED fires for a tracked interrupt.
--
-- Spell IDs are the well-known *cast* IDs, which is exactly right for CAST
-- stacks (the event payload carries the cast's ID, not any aura's).
-- =========================================================================

-- Every class's interrupt kit (cast spell IDs).
local INTERRUPT_IDS = {
    6552,   -- Pummel (Warrior)
    96231,  -- Rebuke (Paladin)
    147362, -- Counter Shot (Hunter)
    187707, -- Muzzle (Survival Hunter)
    1766,   -- Kick (Rogue)
    15487,  -- Silence (Priest)
    47528,  -- Mind Freeze (Death Knight)
    57994,  -- Wind Shear (Shaman)
    2139,   -- Counterspell (Mage)
    19647,  -- Spell Lock (Warlock felhunter)
    89766,  -- Axe Toss (Warlock felguard)
    132409, -- Spell Lock (Warlock, Grimoire of Sacrifice)
    116705, -- Spear Hand Strike (Monk)
    106839, -- Skull Bash (Druid)
    78675,  -- Solar Beam (Balance Druid)
    183752, -- Disrupt (Demon Hunter)
    351338, -- Quell (Evoker)
}

-- This is for debuffs applied to an enemy that represent a "go". For example, kingsbane, deathmark, Ray of frost
-- Dispellable CC will be in a separate list
local OFFENSIVE_DEBUFFS = {
    205021, -- Ray of Frost (Mage)
    343527, -- Execution Sentence (Paladin)
    354124, -- Hemotoxin (Rogue)
    360194, -- Deathmark (Rogue)
    385627, -- Kingsbane (Rogue)
    198817, -- Sharpen Blade (Warrior)
}

-- Non-magical but potentially dispellable CC. For example, Chimeral sting is a poison. We will ignore stuns, which are technically dispellable by paladins, but would already display on the UI.
local NON_MAGIC_DISPELLABLE_CC = {
    356719, -- Chimeral Sting (Hunter)
    1330,  -- Garrote (Rogue)
}

-- This will track big offensive abilities. These would be typically refered to as "goes" For example, Mage Combustion, Hunter True shot
local BIG_OFFENSIVE = {
    51271, -- Pillar of Frost (Death Knight)
    275699, -- Apocalypse (Death Knight)
    42650, -- Army of the Dead (Death Knight)
    1233448, -- Dark Transformation (Death Knight)
    191427, -- Metamorphosis (Demon Hunter)
    323764, -- Convoke the Spirits (Druid)
    102560, -- Incarnation: Chosen of Elune (Druid)
    102543, -- Incarnation: Avatar of Ashamane (Druid)
    357210, -- Deep Breath (Evoker)
    375087, -- Dragonrage (Evoker)
    19574, -- Bestial Wrath (Hunter)
    288613, -- Trueshot (Hunter)
    1250646, -- Takedown (Hunter)
    190319, -- Combustion (Mage)
    205021, -- Ray of Frost (Mage)
    365350, -- Arcane Surge (Mage)
    123904, -- Invoke Xuen, the White Tiger (Monk)
    1249625, -- Windwalker's Zenith (Monk)
    31884, -- Avenging Wrath (Paladin)
    228260, -- Voidform (Priest)
    211522, -- Psyfiend (Priest)
    10060, -- Power Infusion (Priest)
    354124, -- Hemotoxin (Rogue)
    360194, -- Deathmark (Rogue)
    385627, -- Kingsbane (Rogue)
    13750, -- Adrenaline Rush (Rogue)
    121471, -- Shadow Blades (Rogue)
    280719, -- Secret Technique (Rogue)
    76577, -- Smoke Bomb (Rogue)
    204330, -- Totem of Wrath (Shaman)
    114049, -- Ascendance (Shaman)
    114051, -- Ascendance (Shaman)
    384352, -- Doom Winds (Shaman)
    204361, -- Bloodlust pvp talent
    204362, -- Heroism pvp talent
    205180, -- Summon Darkglare (Warlock)
    1122, -- Summon Infernal (Warlock)
    265187, -- Summon Demonic Tyrant (Warlock)
    107574, -- Avatar (Warrior)
    198817, -- Sharpen Blade (Warrior)
    1719, -- Recklessness (Warrior)
}

local PVP_TRINKETS = {
    42292, -- PvP Trinket
    7744,   -- Will of the Forsaken
    59752, -- Will to Survive (Human racial)
}

-- Mage ice block, aspect of the turtle, Shaman astral shift and burrow, etc
local BIG_DEFENSIVES = {
    48707, -- Anti-Magic Shell (Death Knight)
    48792, -- Icebound Fortitude (Death Knight)
    55233, -- Vampiric Blood (Death Knight)
    198589, -- Blur (Demon Hunter)
    22812, -- Barkskin (Druid)
    363916, -- Obsidian Scales (Evoker)
    5384, -- Feign Death (Hunter) (Need to test if works)
    186265, -- Aspect of the Turtle (Hunter)
    264735, -- Survival of the Fittest (Hunter)
    272682, -- Master's Call (Hunter)
    45438, -- Ice Block (Mage)
    342246, -- Alter Time (Mage)
    115203, -- Fortifying Brew (Monk)
    125174, -- Touch of Karma (Monk)
    642, -- Divine Shield (Paladin)
    31850, -- Ardent Defender (Paladin)
    19236, -- Desperate Prayer (Priest)
    47585, -- Dispersion (Priest)
    5277, -- Evasion (Rogue)
    31224, -- Cloak of Shadows (Rogue)
    108271, -- Astral Shift (Shaman)
    409293, -- Burrow (Shaman)
    104773, -- Unending Resolve (Warlock)
    108416, -- Dark Pact (Warlock)
    212295, -- Nether Ward (Warlock)
    871, -- Shield Wall (Warrior)
    118038, -- Die by the Sword (Warrior)
    184364, -- Enraged Regeneration (Warrior)
    23920, -- Spell Reflection (Warrior)
}

local EXTERNALS = {
    48707, -- Anti-Magic Shell (Death Knight) (Useable on others with Spellwarden pvp talent)
    164065, -- Anti-Magic Zone (Death Knight)
    196718, -- Darkness (Demon Hunter)
    102342, -- Ironbark (Druid)
    357170, -- Time Dilation (Evoker)
    378441, -- Time Stop (Evoker)
    53480, -- Roar of Sacrifice (Paladin)
    115310, -- Life Cocoon (Monk)
    1022, -- Blessing of Protection (Paladin)
    6940, -- Blessing of Sacrifice (Paladin)
    633, -- Lay on Hands (Paladin)
    204018, -- Blessing of Spellwarding (Paladin)
    47788, -- Guardian Spirit (Priest)
    33206, -- Pain Suppression (Priest)
    62618, -- Power Word: Barrier (Priest)
    98008, -- Spirit Link Totem (Shaman)
    97462, -- Rallying Cry (Warrior)
}

-- Generic frame-attached tracker builder. `opts` overrides defaults:
--   filter ("CAST"/"HARMFUL"/"HELPFUL"), iconSize, castDuration, and the four
--   anchor fields (myPoint/relPoint/x/y) so several presets can sit on
--   different edges of the same unit frame instead of stacking on top of each
--   other. All presets attach to the resolved unit frame (useFrame = true).
local function NewTrackerStack(name, group, units, ids, opts)
    opts = opts or {}
    local s = ID.NewDefaultStack()
    s.name = name
    s.group = group
    s.units = units
    s.filter = opts.filter or "CAST"
    -- For CAST stacks the icon shows for the spell's actual cooldown (with a
    -- drain) since Next Features #14/#16; castDuration is only the fallback
    -- when a tracked id has no cooldown.
    s.castDuration = opts.castDuration or 4
    s.iconSize = opts.iconSize or 28
    s.panel = false
    s.targets, s.order = {}, {}
    for _, spellID in ipairs(ids) do
        s.targets[spellID] = true
        s.order[#s.order + 1] = spellID
    end
    s.anchor.useFrame = true
    s.anchor.myPoint = opts.myPoint or "RIGHT"
    s.anchor.relPoint = opts.relPoint or "LEFT"
    s.anchor.x = opts.x or -6
    s.anchor.y = opts.y or 0
    return s
end

local ARENA_UNITS = { "arena1", "arena2", "arena3" }
local ARENA_UNITS_PETS = {
    "arena1", "arena2", "arena3", "arenapet1", "arenapet2", "arenapet3",
}
local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

local function NewKickStack(name, group, units)
    return NewTrackerStack(name, group, units, INTERRUPT_IDS, {
        filter = "CAST",
        iconSize = 28,
        -- Kicks park to the LEFT of the frame.
        myPoint = "RIGHT", relPoint = "LEFT", x = -6, y = 0,
    })
end

-- Ordered list consumed by Options.lua's Presets page.
ID.Presets = {
    {
        name = "Arena Kick Tracker Cooldowns",
        desc = "Shows enemy's interrupt on their arena frame when they use it "
            .. "(arena1-3 plus their pets, for Spell Lock/Axe Toss). "
            .. "Creates one CAST stack in group 'Arena Kicks', attached to the arena unit frames.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewKickStack(
                "Arena1 Kicks", "Arena Kicks",
                { "arena1", "arenapet1"})
            ID.db.profile.stacks[ID.NewStackID()] = NewKickStack(
                "Arena2 Kicks", "Arena Kicks",
                { "arena2", "arenapet2"})
            ID.db.profile.stacks[ID.NewStackID()] = NewKickStack(
                "Arena3 Kicks", "Arena Kicks",
                { "arena3", "arenapet3"})
        end,
    },
    {
        name = "Party Kick Tracker (M+) Cooldowns",
        desc = "Shows each ally's interrupt on their party frame when they use it "
            .. "(you + party1-4). Creates one CAST stack in group 'Party Kicks', "
            .. "attached to the party unit frames.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewKickStack(
                "Party Kicks", "Party Kicks",
                PARTY_UNITS)
        end,
    },
    {
        name = "Enemy Offensive Debuffs Duration",
        desc = "Shows enemy team's kill-window debuffs (Kingsbane, Deathmark, "
            .. "Execution Sentence, ...) on your frames while they're up. "
            .. "Creates one HARMFUL stack in group 'Arena Offense', on player,party1-3, "
            .. "parked to the RIGHT of each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Offensive Debuffs", "Arena Offense",
                PARTY_UNITS, OFFENSIVE_DEBUFFS, {
                    filter = "HARMFUL",
                    myPoint = "LEFT", relPoint = "RIGHT", x = 6, y = 0,
                })
        end,
    },
    {
        name = "Enemy \"Goes\" (Big Offensive CDs) Cooldowns",
        desc = "Shows an enemy's major offensive cooldown (Combustion, Trueshot, "
            .. "Metamorphosis, ...) on their arena frame the moment they press it. "
            .. "Uses CAST so it works for both self-buffs and debuff-based cooldowns. "
            .. "Creates one CAST stack in group 'Arena Offense', on arena1-3 + pets, "
            .. "parked ABOVE each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Enemy Goes", "Arena Offense",
                ARENA_UNITS_PETS, BIG_OFFENSIVE, {
                    filter = "CAST", iconSize = 32,
                    myPoint = "BOTTOM", relPoint = "TOP", x = 0, y = 6,
                })
        end,
    },
    {
        name = "Enemy Defensives Durations",
        desc = "Shows an enemy's active defensive (Ice Block, Divine Shield, "
            .. "Aspect of the Turtle, ...) on their arena frame so you don't waste a go "
            .. "into it. Creates one HELPFUL stack in group 'Arena Defense', on "
            .. "arena1-3, parked BELOW each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Enemy Defensives", "Arena Defense",
                ARENA_UNITS, BIG_DEFENSIVES, {
                    filter = "HELPFUL",
                    myPoint = "TOP", relPoint = "BOTTOM", x = 0, y = -6,
                })
        end,
    },
    {
        name = "Enemy Defensive Cooldowns",
        desc = "Shows an enemy's major defensive cooldown (Ice Block, Divine Shield, "
            .. "Aspect of the Turtle, ...) on their arena frame the moment they press it. "
            .. "Uses CAST so it works for both self-buffs and debuff-based cooldowns. "
            .. "Creates one CAST stack in group 'Arena Defense', on arena1-3 + pets, "
            .. "parked BELOW each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Enemy Defensives (CAST)", "Arena Defense",
                ARENA_UNITS_PETS, BIG_DEFENSIVES, {
                    filter = "CAST", iconSize = 32,
                    myPoint = "TOP", relPoint = "BOTTOM", x = 0, y = -6,
                })
        end,
    },
    {
        name = "Enemy Externals Duration",
        desc = "Shows external protection (Pain Suppression, Ironbark, "
            .. "Blessing of Protection, ...) landed on an enemy arena frame. "
            .. "Creates one HELPFUL stack in group 'Arena Defense', on arena1-3, "
            .. "parked to the RIGHT of each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Enemy Externals", "Arena Defense",
                ARENA_UNITS, EXTERNALS, {
                    filter = "HELPFUL",
                    myPoint = "LEFT", relPoint = "RIGHT", x = 6, y = 0,
                })
        end,
    },
    {
        name = "Enemy Externals Cooldowns",
        desc = "Shows external protection (Pain Suppression, Ironbark, "
            .. "Blessing of Protection, ...) on an enemy arena frame the moment they press it. "
            .. "Uses CAST so it works for both self-buffs and debuff-based cooldowns. "
            .. "Creates one CAST stack in group 'Arena Defense', on arena1-3 + pets, "
            .. "parked to the RIGHT of each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Enemy Externals (CAST)", "Arena Defense",
                ARENA_UNITS_PETS, EXTERNALS, {
                    filter = "CAST", iconSize = 32,
                    myPoint = "LEFT", relPoint = "RIGHT", x = 6, y = 0,
                })
        end,
    },
    {
        name = "Enemy PvP Trinkets Cooldowns",
        desc = "Shows when an enemy uses their PvP trinket (or racial equivalent) "
            .. "on their arena frame, so you know their trinket is down. "
            .. "Creates one CAST stack in group 'Arena Defense', on arena1-3, "
            .. "parked to the LEFT of each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "PvP Trinkets", "Arena Defense",
                ARENA_UNITS, PVP_TRINKETS, {
                    filter = "CAST",
                    myPoint = "RIGHT", relPoint = "LEFT", x = -6, y = 0,
                })
        end,
    },
    {
        name = "Party Dispellable CC Duration",
        desc = "Shows non-magic but dispellable CC (poisons, bleeds like Garrote / "
            .. "Chimeral Sting) on you and your party so you can cleanse it. "
            .. "Creates one HARMFUL stack in group 'Party Defense', on you + party1-4, "
            .. "parked ABOVE each frame.",
        create = function()
            ID.db.profile.stacks[ID.NewStackID()] = NewTrackerStack(
                "Dispellable CC", "Party Defense",
                PARTY_UNITS, NON_MAGIC_DISPELLABLE_CC, {
                    filter = "HARMFUL",
                    myPoint = "BOTTOM", relPoint = "TOP", x = 0, y = 6,
                })
        end,
    },
}

function ID.ApplyPreset(preset)
    preset.create()
    ID.RefreshAll()
    if ID.Options and ID.Options.Rebuild then ID.Options.Rebuild() end
    print("|cff66ccffImportantAuras|r: created preset '" .. preset.name .. "'")
end

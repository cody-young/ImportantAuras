local addonName, ID = ...

-- =========================================================================
-- Spell name -> id/icon lookup used by Options.lua's "Add spell" box
-- (Next Features #8/#8.1). Two independent jobs:
--   * GetDisplay(id): name+icon for a spellID the user already typed in --
--     works for ANY spell in the game via C_Spell.GetSpellInfo, not just
--     known ones (that call is a plain by-id lookup, unrelated to the
--     secret-aura-value problem the rest of the addon works around -- the
--     id here is a plain int the user typed, never read off an aura).
--   * Search(query): name -> id, which WoW has no general API for. Two
--     sources are merged: the player's own spellbook (+ pet), and the static
--     ID.SpellDB table (Data/SpellDB.lua, offline-generated via
--     Tools/generate_spelldb.js from Blizzard's Game Data API -- covers every
--     class/spec/hero-talent/pvp-talent spell, not just ones the player has
--     learned). SpellDB entries carry no icon (never stored, so it can't go
--     stale across content patches) -- icons are always resolved live.
-- =========================================================================

ID.SpellSearch = {}

local cache = nil -- built lazily; array of { id=, name=, icon= }, rebuilt on demand

local function AddEntry(list, seen, id, name, icon)
    if id and name and name ~= "" and not seen[id] then
        seen[id] = true
        list[#list + 1] = { id = id, name = name, icon = icon }
    end
end

local function BuildCache()
    local list, seen = {}, {}

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo
            and C_SpellBook.GetSpellBookItemInfo and Enum.SpellBookItemType then
        -- Player bank: skill lines carry the index ranges.
        local ok, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        if ok and numLines then
            for i = 1, numLines do
                local okLine, lineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, i)
                if okLine and lineInfo then
                    local offset = lineInfo.itemIndexOffset or 0
                    local count = lineInfo.numSpellBookItems or 0
                    for j = offset + 1, offset + count do
                        local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, j,
                            Enum.SpellBookSpellBank.Player)
                        if okItem and item and item.itemType == Enum.SpellBookItemType.Spell then
                            AddEntry(list, seen, item.spellID or item.actionID, item.name, item.iconID)
                        end
                    end
                end
            end
        end

        -- Pet bank: NOT organized into skill lines -- HasPetSpells() returns
        -- the pet spell count and items are indexed 1..count directly.
        -- (Iterating the player skill-line offsets against the pet bank, as
        -- an earlier version did, reads mostly out-of-range indices.)
        if C_SpellBook.HasPetSpells then
            local okPet, numPet = pcall(C_SpellBook.HasPetSpells)
            if okPet and numPet then
                for j = 1, numPet do
                    local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, j,
                        Enum.SpellBookSpellBank.Pet)
                    if okItem and item and item.itemType == Enum.SpellBookItemType.Spell then
                        AddEntry(list, seen, item.spellID or item.actionID, item.name, item.iconID)
                    end
                end
            end
        end
    end

    -- Fills in every class/spec/hero-talent/pvp-talent spell not already
    -- covered by the player's own spellbook above (see the file header).
    if ID.SpellDB then
        for _, entry in ipairs(ID.SpellDB) do
            AddEntry(list, seen, entry.id, entry.name, nil)
        end
    end

    return list
end

-- Invalidate on anything that could add/remove/change known spells; rebuilt
-- lazily the next time Search() is called rather than on every event.
-- pcall-wrapped: an unrecognized event name here would otherwise throw at
-- file-load time (outside any function) and abort the rest of this file,
-- silently leaving ID.SpellSearch.GetDisplay/Search undefined for every
-- caller (that's what actually happened with LEARNED_SPELL_IN_TAB, which
-- this client rejects as unknown).
local watcher = CreateFrame("Frame")
for _, event in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_TALENT_UPDATE", "PLAYER_ENTERING_WORLD" }) do
    pcall(watcher.RegisterEvent, watcher, event)
end
watcher:SetScript("OnEvent", function() cache = nil end)

-- name+icon for a spellID the user has already tracked/typed in; works for any
-- spell in the game, not just known ones.
function ID.SpellSearch.GetDisplay(id)
    if not id or not (C_Spell and C_Spell.GetSpellInfo) then return nil, nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and info and info.name then
        return info.name, info.iconID
    end
    return nil, nil
end

-- filterType is one of "HARMFUL"/"HELPFUL" (a stack's Aura Type) or
-- nil/"CAST" (no aura polarity to filter by). Checked live via
-- C_Spell.IsSpellHarmful/IsSpellHelpful, which work for ANY spell id, not
-- just known ones. Fails open (keeps the entry) if the check errors -- this
-- is a search UI, not a security boundary, so a spurious API hiccup
-- shouldn't hide a result the user is looking for.
local function MatchesFilter(id, filterType)
    if filterType ~= "HARMFUL" and filterType ~= "HELPFUL" then return true end
    if not C_Spell then return true end
    local checker = filterType == "HARMFUL" and C_Spell.IsSpellHarmful or C_Spell.IsSpellHelpful
    if not checker then return true end
    local ok, matches = pcall(checker, id)
    if not ok then return true end
    return matches
end

-- Search the merged spellbook + SpellDB corpus by substring, prefix matches
-- first, optionally restricted to harmful/helpful spells (see MatchesFilter).
-- Returns an array of { id, name, icon }, capped at `limit` (default 15).
function ID.SpellSearch.Search(query, limit, filterType)
    if not cache then cache = BuildCache() end
    limit = limit or 15
    query = query:lower():match("^%s*(.-)%s*$")
    if query == "" then return {} end

    local starts, contains = {}, {}
    for _, entry in ipairs(cache) do
        local lname = entry.name:lower()
        local s = lname:find(query, 1, true)
        if s and MatchesFilter(entry.id, filterType) then
            if s == 1 then
                starts[#starts + 1] = entry
            else
                contains[#contains + 1] = entry
            end
        end
    end
    table.sort(starts, function(a, b) return a.name < b.name end)
    table.sort(contains, function(a, b) return a.name < b.name end)

    local results = {}
    for _, e in ipairs(starts) do
        results[#results + 1] = { id = e.id, name = e.name, icon = e.icon or select(2, ID.SpellSearch.GetDisplay(e.id)) }
        if #results >= limit then return results end
    end
    for _, e in ipairs(contains) do
        results[#results + 1] = { id = e.id, name = e.name, icon = e.icon or select(2, ID.SpellSearch.GetDisplay(e.id)) }
        if #results >= limit then return results end
    end
    return results
end

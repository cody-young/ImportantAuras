local addonName, ID = ...

-- =========================================================================
-- Important Auras -- bootstrap.
--
-- The dual-punch matcher design (icon visible iff a secret spellId == a
-- tracked target, computed entirely in C via StatusBar fill + MaskTexture,
-- never branching on the secret in Lua) lives in Stack.lua. See CLAUDE.md's
-- "Core idea" and "Multi-stack architecture" sections for the full writeup;
-- the research-era diagnostic demos (demo/demomask/demomask2/demomask3/sweep/
-- probe) that proved it out have been removed now that the design is
-- production-verified.
-- =========================================================================
-- Auto-cast by the player at the start of every arena round (including each
-- Solo Shuffle round) -- ported from ArenaTalentReminder (sibling addon,
-- same author), which uses this exact spellID/event to detect round
-- restarts; it's a spell CAST, not a buff.
local ROUND_START_SPELL = 228212 -- Arena Starting Area Marker

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(self, event, a1, a2, a3)
    if event == "ADDON_LOADED" and a1 == addonName then
        ID.InitDB()
    elseif event == "PLAYER_LOGIN" then
        ID.InitDB()
        ID.Options.Init()
        ID.RefreshAll()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Zone change: rebuild to drop stale CAST-mode timers.
        if ID.db then ID.RefreshAll() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- One global stream of every cast on every unit. In combat an enemy
        -- player's spellID (a3) is secret via EVERY token (nameplate included),
        -- and the castGUID (a2) is secret too -- so even though the GUID string
        -- embeds the spellID, it can't be recovered in Lua (string.match/find/
        -- tonumber all reject secrets). No Lua path to a plain cast spellID.
        ID.dprintf("cast u=%s spell=%d secret=%s", tostring(a1), a3,
            tostring(issecretvalue and issecretvalue(a3)))
        -- a1=="player" short-circuits before the a3 equality, so a secret enemy
        -- payload never reaches (and errors on) the ROUND_START_SPELL compare.
        if a1 == "player" and a3 == ROUND_START_SPELL then
            if ID.db then ID.RefreshAll() end
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- Fires on the VICTIM (unit whose cast was kicked); payload (unit,
        -- castGUID, spellID) with spellID = the INTERRUPTED spell, NOT the kick.
        -- Diagnostic only -- watching whether/how this fires in arena to judge
        -- if it's viable for kick tracking.
        ID.dprintf("INTERRUPTED u=%s spell=%d secret=%s guid=%s", tostring(a1), a3,
            tostring(issecretvalue and issecretvalue(a3)), a2)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat. If spellIDs go secret only after this line, the
        -- secret regime is combat-gated (as expected) -- a plain reading
        -- before combat can't be relied on mid-fight.
        ID.dprintf("|cffff4040>>> ENTER COMBAT|r")
    elseif event == "PLAYER_REGEN_ENABLED" then
        ID.dprintf("|cff40ff40<<< LEAVE COMBAT|r")
    end
end)

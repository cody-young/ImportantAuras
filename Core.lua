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
ev:SetScript("OnEvent", function(self, event, a1, a2, a3)
    if event == "ADDON_LOADED" and a1 == addonName then
        ID.InitDB()
    elseif event == "PLAYER_LOGIN" then
        ID.InitDB()
        ID.Options.Init()
        ID.RefreshAll()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Zone change: stale CAST-mode timers (cooldown swipes/hide timers
        -- sized for the previous zone's casts) get torn down and rebuilt
        -- clean via RefreshAll's Rebuild pass.
        if ID.db then ID.RefreshAll() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and a1 == "player" and a3 == ROUND_START_SPELL then
        -- New arena round: the previous round's cast/cooldown state no
        -- longer applies, so clean up the same way.
        if ID.db then ID.RefreshAll() end
    end
end)

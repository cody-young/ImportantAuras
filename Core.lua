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
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        ID.InitDB()
    elseif event == "PLAYER_LOGIN" then
        ID.InitDB()
        ID.Options.Init()
        ID.RefreshAll()
    end
end)

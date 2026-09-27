-- Assault phase detection for the reactive glow. Loaded with lib/managers/hudmanagerpd2.
--
-- HUDManager:sync_start_assault / sync_end_assault are what the game itself calls on every client
-- when an assault begins and ends (VanillaHUD Plus and Extra Heist Info wrap the same pair);
-- sync_start_anticipation_music marks the build-up. Each is checked before hooking, because
-- Hooks:PostHook on a missing method is an error in a hook file.

dofile(ModPath .. "lua/core.lua")
dofile(ModPath .. "lua/reactive.lua")
local T = _G.AnimSkinsTuner

if T._reactive_hud_hooked then return end
T._reactive_hud_hooked = true

local hooked = {}
local function hook(name, fn)
	if type(HUDManager) == "table" and type(HUDManager[name]) == "function" then
		Hooks:PostHook(HUDManager, name, "AnimSkinsTuner_Reactive_" .. name, function(...)
			pcall(fn, ...)
		end)
		table.insert(hooked, name)
	end
end

hook("sync_start_assault", function() T:on_assault(true) end)
hook("sync_end_assault", function() T:on_assault(false) end)
hook("sync_start_anticipation_music", function() T:on_anticipation() end)

log("[AnimSkins Tuner] reactive: HUD hooks " .. (#hooked > 0 and table.concat(hooked, ", ") or "NONE found on HUDManager"))

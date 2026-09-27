-- Heat for the reactive glow: every shot actually fired feeds T:on_shot.
--
-- Wrapped the way BeardLib wraps the same method for its sound fix -- call the original, act on a
-- truthy result -- rather than PostHook, which never sees the return value. RaycastWeaponBase is
-- the parent class and is loaded by the time this file (newraycastweaponbase) runs.
--
-- Settings are pushed onto a weapon by the AnimSkinsSwapped listener in core.lua, straight after
-- AnimSkins swaps its configs; nothing here needs to hook weapon assembly.

dofile(ModPath .. "lua/core.lua")
dofile(ModPath .. "lua/reactive.lua")
local T = _G.AnimSkinsTuner

if not T._fire_wrapped and type(RaycastWeaponBase) == "table" and type(RaycastWeaponBase.fire) == "function" then
	T._fire_wrapped = true
	local fire = RaycastWeaponBase.fire
	function RaycastWeaponBase:fire(...)
		local result = fire(self, ...)
		if result then
			pcall(T.on_shot, T, self)
		end
		return result
	end
	log("[AnimSkins Tuner] reactive: fire wrapped for heat")
end

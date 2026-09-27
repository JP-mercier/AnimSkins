-- AnimSkins
--
-- Puts the animated material configs on the local player's own first-person weapon parts, the
-- same way Inversion Universal does: no base game file is overridden, so teammates, bots,
-- enemies and lobby characters keep their vanilla materials.
--
-- It also keeps a record of exactly which units it swapped and to which config, and announces
-- each swap with Hooks:Call("AnimSkinsSwapped", weapon, swapped). The tuner works from that
-- record only, so it never writes to a material this file did not put there.

_G.AnimSkins = _G.AnimSkins or {}
local AS = _G.AnimSkins

AS.path = ModPath
AS.MATERIALS_DIR = "units/mods/animskins3/materials/"

-- Set to false by the tuner's "Show in menus" option: the inventory and customise previews then
-- keep vanilla materials and only the weapon in your hands in a heist is swapped.
if AS.menus == nil then
	AS.menus = true
end

-- weapon base -> { { unit = part unit, config = config name, ids = config Idstring }, ... }
AS.swapped = AS.swapped or setmetatable({}, { __mode = "k" })

local IDS_MATERIAL_CONFIG = Idstring("material_config")

-- Each line of material_configs.txt is "<vanilla path> <config name>". Parts whose configs are
-- identical share one file, so several vanilla paths can name the same config.
local replacements = {}
local count = 0

for line in io.lines(ModPath .. "material_configs.txt") do
	local vanilla, name = line:match("^%s*(%S+)%s+(%S+)%s*$")

	if vanilla then
		replacements[Idstring(vanilla):key()] = { name = name, ids = Idstring(AS.MATERIALS_DIR .. name) }
		count = count + 1
	end
end

log("[AnimSkins] " .. count .. " weapon parts mapped")

local function replacement_for(part_data)
	-- Same default the vanilla code falls back to when it restores a part's material config.
	local vanilla = part_data.material_config or part_data.unit

	if type(vanilla) == "string" then
		vanilla = Idstring(vanilla)
	end

	return replacements[vanilla:key()]
end

-- main.xml loads every config into the dynamic resource package at startup. That load is
-- asynchronous, so a weapon built in the first moments of the main menu can arrive before it is
-- done. A config is only handed to set_material_config once the engine reports it loaded, the
-- same check vanilla makes before it swaps in a _cc or _thq config. A part skipped here is
-- picked up the next time the weapon updates its materials.
local function is_loaded(ids)
	return managers.dyn_resource:is_resource_ready(IDS_MATERIAL_CONFIG, ids, DynamicResourceManager.DYN_RESOURCES_PACKAGE)
end

local function in_game()
	return Global.level_data and Global.level_data.level_id ~= nil
end

local function wanted(self)
	-- NPC weapons are every third-person weapon (teammates, bots, lobby characters).
	-- VR renders the local weapon with third-person materials, and depth scaling would break it.
	return not self:is_npc() and not _G.IS_VR and managers.dyn_resource and (AS.menus or in_game())
end

-- A weapon wearing a game weapon skin gets our configs through the skin system itself.
--
-- For a skinned weapon, vanilla _update_materials asks _material_config_name which config each
-- part should wear, puts that config on, and collects the materials it will paint the skin onto
-- (those with a wear_tear_value variable), then loads the skin's textures in the background and
-- binds them when they arrive. Answering that question with our config means the part is given
-- our config once, by the skin system, in its own order: it finds nothing to paint on (the
-- animated materials have no skin layers), requests no textures, and is done.
--
-- The old way let vanilla put the _cc config on first and swapped it out afterwards, destroying
-- materials the skin system had just made and was still loading textures for. That crashed the
-- renderer a few seconds after a skinned akimbo STRYK was drawn.
--
-- Third person (dropped magazines pass force_third_person) and NPC weapons keep vanilla's answer.
local material_config_name = NewRaycastWeaponBase._material_config_name

if material_config_name and not AS._name_wrapped then
	AS._name_wrapped = true

	function NewRaycastWeaponBase:_material_config_name(part_id, part_data, use_cc_material_config, force_third_person, ...)
		if use_cc_material_config and not force_third_person and part_data and wanted(self) then
			local replacement = replacement_for(part_data)

			if replacement and is_loaded(replacement.ids) then
				return replacement.ids
			end
		end

		return material_config_name(self, part_id, part_data, use_cc_material_config, force_third_person, ...)
	end
end

local logged = 0

Hooks:PostHook(NewRaycastWeaponBase, "_update_materials", "AnimSkins_update_materials", function(self)
	if not self._parts or not wanted(self) then
		return
	end

	-- A skinned weapon's configs are the skin system's business (see _material_config_name above):
	-- a part that did not get ours from it keeps what it has. Only unskinned weapons are swapped here.
	local skinned = self._cosmetics_data and true or false
	local swapped, total, waiting = {}, 0, 0

	for part_id, part in pairs(self._parts) do
		local part_data = managers.weapon_factory:get_part_data_by_part_id_from_weapon(part_id, self._factory_id, self._blueprint)
		local replacement = part_data and replacement_for(part_data)

		if replacement and alive(part.unit) then
			total = total + 1

			if part.unit:material_config() ~= replacement.ids and not skinned then
				if is_loaded(replacement.ids) then
					part.unit:set_material_config(replacement.ids, true)
				else
					waiting = waiting + 1
				end
			end

			if part.unit:material_config() == replacement.ids then
				table.insert(swapped, { unit = part.unit, config = replacement.name, ids = replacement.ids })
			end
		end
	end

	AS.swapped[self] = swapped

	if logged < 20 then
		logged = logged + 1
		log(("[AnimSkins] swap #%d: %d of %d parts, %d waiting for their config to load, factory=%s%s%s")
			:format(logged, #swapped, total, waiting, tostring(self._factory_id),
				skinned and (" (weapon skin " .. tostring(self._cosmetics_id) .. ")") or "",
				self._second_gun and " (akimbo)" or ""))
	end

	-- The tuner re-applies its settings here. set_material_config rebuilds a unit's materials, so
	-- anything written to the old ones is gone and has to be written again.
	-- A fault in a listener must never take the swap down with it.
	if #swapped > 0 then
		local ok, err = pcall(Hooks.Call, Hooks, "AnimSkinsSwapped", self, swapped)

		if not ok then
			log("[AnimSkins] a listener failed: " .. tostring(err))
		end
	end
end)

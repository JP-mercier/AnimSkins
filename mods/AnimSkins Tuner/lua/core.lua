-- AnimSkins Tuner -- shared state, and the only code that writes to a material.
--
-- WHAT IT TOUCHES
--
-- AnimSkins records every part it swaps: the unit, and the config it put on it. This file writes
-- to materials of those units only, and only while the unit is still wearing that config. Within
-- one, skin_materials.txt (written by AnimSkins' build) says which materials are animated and
-- which static ones show the skin's base. Everything else -- scope glass, reticles, lasers, and
-- every material on any weapon AnimSkins did not swap -- is never touched.
--
-- That matters because of how a skin is switched. set_variable on a material whose shader lacks
-- the variable is a harmless no-op, but Application:set_material_texture writes into a named
-- texture slot, and pushing a glow texture into a material that has no glow slot is a fault in
-- the render thread that no pcall can catch. The old tuner walked every material it could reach,
-- menu scene included; this one only writes where the config it built says the slot exists.
--
-- WHAT CAN AND CANNOT BE CHANGED AT RUNTIME
--
--   il_multiplier   glow brightness (0 turns the animation off; there is no true alpha)
--   il_bloom        how far the glow bleeds
--   uv_speed        scroll speed and direction
--   the two texture slots -> which skin is showing (every skin is loaded at startup)
--
-- A new skin still needs AnimSkins' tools/build.py and a restart.

_G.AnimSkinsTuner = _G.AnimSkinsTuner or {}
local T = _G.AnimSkinsTuner

if T._core_loaded then
	return
end
T._core_loaded = true

T._path = ModPath
T._save = SavePath .. "animskins_tuner.json"
-- Read when the file above does not exist yet: the name settings were saved under up to 2.0.
T._legacy_save = SavePath .. "glitchwave_tuner.json"

T.defaults = {
	enabled = true,
	glow = 5,          -- il_multiplier. The skins are built for 5.
	bloom = 1.0,       -- il_bloom. Vanilla's own animated materials run 1 to 10.
	speed = 0.1,       -- uv_speed magnitude, UV units per second
	direction = 6,     -- index into T.DIRECTIONS; 6 = each part's own built-in direction
	menus = true,      -- show the skin on inventory and customise previews

	-- Skin per slot, as an index into T.skins.
	primary_skin = 1,
	secondary_skin = 1,

	-- Reactive glow (lua/reactive.lua). All factors multiply the Glow slider.
	reactive = true,
	react_stealth = 0.35,   -- factor while in whisper mode: an ember
	react_assault = 1.6,    -- factor during an assault
	react_smooth = 4.0,     -- how fast the glow chases its target (per second)
	react_heat_gain = 0.06, -- heat added per shot (1.0 is fully hot: ~17 shots)
	react_heat_cool = 0.35, -- heat lost per second while not firing (~3 s to cool)
	react_heat_glow = 1.5,  -- extra glow factor at full heat (x2.5 total)
	react_heat_speed = 3.0, -- scroll speed multiplier at full heat
	react_heat_fx = 2,      -- index into T.HEAT_FX (1 = off)
	react_heat_at = 0.5,    -- heat level where the muzzle effect starts
	react_heat_fx_period = 1.0, -- seconds between replays of the (finite) heat effect while hot
	react_flash_fx = 2,     -- index into T.FLASH_FX (1 = off): star flash on every shot
	react_flash_life = 0.6, -- seconds each star flash lives before it is killed
}

T.settings = {}
for k, v in pairs(T.defaults) do
	T.settings[k] = v
end

-- Right, left, down, up, diagonal, and nil for "each part's own direction", which comes from
-- skin_materials.txt. UV islands are rotated and mirrored per part, so no single direction reads
-- the same way over a whole weapon; the built-in directions were picked per material for that.
T.DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.707, 0.707 }, false }

--------------------------------------------------------------------- AnimSkins' data
-- Found through BLT rather than a fixed folder name, so the mod folder can be called anything.
local function animskins_path()
	local mod = BLT and BLT.Mods and BLT.Mods:GetModByName("AnimSkins")
	if mod and mod:WasEnabledAtStart() then
		return mod:GetPath()
	end
	return _G.AnimSkins and _G.AnimSkins.path
end

T.skins = { { id = "default", name = "Default" } }
T.baked = { glow = 5, bloom = 1.0, speed = 0.1 }

function T:load_manifest()
	local path = animskins_path()
	if not path then
		log("[AnimSkins Tuner] AnimSkins is not installed or not enabled -- nothing to tune")
		return
	end
	self._animskins = path

	local f = io.open(path .. "variants.json", "r")
	if f then
		local ok, data = pcall(function() return json.decode(f:read("*all")) end)
		f:close()
		if ok and type(data) == "table" and type(data.skins) == "table" and #data.skins > 0 then
			self.skins = data.skins
			if type(data.baked) == "table" then
				self.baked = data.baked
			end
		end
	end

	-- config name -> { anim = { [material name key] = { u, v } }, base = { [material name key] = true } }
	self.configs = {}
	local n = 0
	for line in io.lines(path .. "skin_materials.txt") do
		local config, rest = line:match("^(%S+)%s*(.*)$")
		if config then
			local anim_part, base_part = rest:match("^(.-)|(.*)$")
			local entry = { anim = {}, base = {} }
			for name, u, v in (anim_part or rest):gmatch("(%S+):(%S+),(%S+)") do
				entry.anim[Idstring(name):key()] = { tonumber(u) or 0, tonumber(v) or 0 }
			end
			for name in (base_part or ""):gmatch("%S+") do
				entry.base[Idstring(name):key()] = true
			end
			self.configs[config] = entry
			n = n + 1
		end
	end

	-- Resolved once: the Idstring of each skin's two textures.
	for _, skin in ipairs(self.skins) do
		skin.ids_base = skin.base and Idstring(skin.base)
		skin.ids_glow = skin.glow and Idstring(skin.glow)
	end

	log(("[AnimSkins Tuner] %d skins, %d configs from %s"):format(#self.skins, n, path))
end

function T:load()
	local f = io.open(self._save, "r") or io.open(self._legacy_save, "r")
	if f then
		local ok, data = pcall(function() return json.decode(f:read("*all")) end)
		f:close()
		if ok and type(data) == "table" then
			for k, v in pairs(data) do
				if self.defaults[k] ~= nil and type(v) == type(self.defaults[k]) then
					self.settings[k] = v
				end
			end
			-- Older saves had a main skin plus per-slot pickers where 1 meant "use the main skin"
			-- and n meant skin n - 1. Carry those picks over the first time.
			local function old_slot(value)
				if type(value) == "number" and value > 1 then return value - 1 end
				return type(data.skin) == "number" and data.skin or nil
			end
			if data.primary_skin == nil and old_slot(data.skin_primary) then
				self.settings.primary_skin = old_slot(data.skin_primary)
			end
			if data.secondary_skin == nil and old_slot(data.skin_secondary) then
				self.settings.secondary_skin = old_slot(data.skin_secondary)
			end
		end
	end
	-- A saved index can outlive what it pointed at.
	local s = self.settings
	if not self.skins[s.primary_skin] then s.primary_skin = 1 end
	if not self.skins[s.secondary_skin] then s.secondary_skin = 1 end
	if self.DIRECTIONS[s.direction] == nil then s.direction = self.defaults.direction end
	self:sync_animskins()
end

function T:save()
	local f = io.open(self._save, "w+")
	if f then
		f:write(json.encode(self.settings))
		f:close()
	end
end

-- The one setting AnimSkins itself reads. The table is created here if AnimSkins has not loaded
-- yet; it keeps a value it finds rather than resetting it.
function T:sync_animskins()
	_G.AnimSkins = _G.AnimSkins or {}
	_G.AnimSkins.menus = self.settings.menus
end

--------------------------------------------------------------------- menu lists
function T:skin_names()
	local out = {}
	for _, s in ipairs(self.skins) do table.insert(out, s.name or s.id) end
	return out
end

-- Which skin a weapon wears. selection_index() is 2 for the primary and 1 for the secondary (BLT's
-- Utils:IsCurrentWeaponPrimary tests == 2). It comes from the weapon's tweak data, so menu previews
-- know their slot too; a weapon that somehow reports neither gets the primary skin.
function T:skin_for(weapon)
	local s = self.settings
	local idx
	if weapon and type(weapon.selection_index) == "function" then
		local ok, sel = pcall(weapon.selection_index, weapon)
		if ok then idx = sel end
	end
	local choice = idx == 1 and s.secondary_skin or s.primary_skin
	return self.skins[choice] or self.skins[1]
end

--------------------------------------------------------------------- engine writes
local IDS_MATERIAL = Idstring("material")
local IDS_TEXTURE = Idstring("texture")
local IDS_NORMAL = Idstring("normal")
local IL_MULT = Idstring("il_multiplier")
local IL_BLOOM = Idstring("il_bloom")
local UV_SPEED = Idstring("uv_speed")
local SLOT_DIFFUSE = Idstring("diffuse_texture")
local SLOT_GLOW = Idstring("self_illumination_texture")

-- AnimSkins' main.xml loads every skin at startup. A texture is bound only once the engine
-- reports it loaded; one that is not is skipped and logged, never bound half-loaded. Binding keeps
-- the texture alive: vanilla binds skin textures the same way and then releases its own reference.
local ready = {}
local function texture_ready(ids)
	if not ids then return false end
	local key = ids:key()
	if not ready[key] then
		local ok, is = pcall(function()
			return managers.dyn_resource:is_resource_ready(IDS_TEXTURE, ids, DynamicResourceManager.DYN_RESOURCES_PACKAGE)
		end)
		ready[key] = ok and is or nil
	end
	return ready[key] and true or false
end

--- The materials of one swapped weapon the tuner may write to:
--- { { unit = u, anim = { { m, u, v }, ... }, base = { m, ... } }, ... }
--- A unit that has died or been given another config since the swap is left out.
function T:collect(weapon)
	local groups = {}
	local swapped = _G.AnimSkins and _G.AnimSkins.swapped and _G.AnimSkins.swapped[weapon]
	if not swapped or not self.configs then
		return groups
	end
	for _, part in ipairs(swapped) do
		local unit = part.unit
		local info = self.configs[part.config]
		if info and alive(unit) and unit:material_config() == part.ids then
			local group = { unit = unit, ids = part.ids, anim = {}, base = {} }
			for _, m in ipairs(unit:get_objects_by_type(IDS_MATERIAL)) do
				local key = m:name():key()
				local dir = info.anim[key]
				if dir then
					table.insert(group.anim, { m, dir[1], dir[2] })
				elseif info.base[key] then
					table.insert(group.base, m)
				end
			end
			table.insert(groups, group)
		end
	end
	return groups
end

-- Still the unit AnimSkins swapped, still wearing the config it was given.
function T.group_live(group)
	return alive(group.unit) and group.unit:material_config() == group.ids
end

--- uv_speed for one material: the chosen direction, or the material's own.
function T:speed_for(u, v, scale)
	local s = self.settings
	local d = self.DIRECTIONS[s.direction]
	local speed = s.enabled and s.speed * (scale or 1) or 0
	if d then
		return Vector3(d[1] * speed, d[2] * speed, 0)
	end
	return Vector3(u * speed, v * speed, 0)
end

--- Write glow and scroll to every animated material in the groups. Used by apply and, every
--- tick, by the reactive glow. Returns the number of materials written.
function T:write_vars(groups, mult, speed_scale, bloom)
	local n = 0
	for _, group in ipairs(groups) do
		if T.group_live(group) then
			for _, entry in ipairs(group.anim) do
				local m = entry[1]
				m:set_variable(IL_MULT, mult)
				m:set_variable(UV_SPEED, self:speed_for(entry[2], entry[3], speed_scale))
				if bloom then
					m:set_variable(IL_BLOOM, bloom)
				end
				n = n + 1
			end
		end
	end
	return n
end

T._logcount = 0

--- Push the current settings onto one swapped weapon.
function T:apply(weapon)
	local s = self.settings
	local groups = self:collect(weapon)
	if #groups == 0 then
		return
	end

	-- Every skin sets both textures explicitly, the default included: once a texture has been
	-- pushed onto a material the only way back is to push another one.
	local skin = self:skin_for(weapon)
	local base = skin and texture_ready(skin.ids_base) and skin.ids_base
	local glow = skin and texture_ready(skin.ids_glow) and skin.ids_glow

	local n = self:write_vars(groups, s.enabled and s.glow or 0, 1, s.bloom)
	for _, group in ipairs(groups) do
		if T.group_live(group) then
			for _, entry in ipairs(group.anim) do
				if base then Application:set_material_texture(entry[1], SLOT_DIFFUSE, base, IDS_NORMAL) end
				if glow then Application:set_material_texture(entry[1], SLOT_GLOW, glow, IDS_NORMAL) end
			end
			if base then
				for _, m in ipairs(group.base) do
					Application:set_material_texture(m, SLOT_DIFFUSE, base, IDS_NORMAL)
				end
			end
		end
	end

	-- The reactive loop compares against its last write; this one was not its own.
	if self.react then
		self.react.applied = nil
		self.react.groups = nil
	end

	if self._logcount < 5 then
		self._logcount = self._logcount + 1
		log(("[AnimSkins Tuner] apply #%d: %d parts, %d animated materials, skin=%s%s")
			:format(self._logcount, #groups, n, tostring(skin and skin.id),
				(skin and not (base and glow)) and " (skin textures not loaded yet, kept the current ones)" or ""))
	end
end

--- Re-apply to every swapped weapon still alive: the one in your hands and the menu preview.
function T:apply_all()
	local swapped = _G.AnimSkins and _G.AnimSkins.swapped
	if not swapped then
		return
	end
	for weapon in pairs(swapped) do
		if weapon._unit and alive(weapon._unit) then
			local ok, err = pcall(self.apply, self, weapon)
			if not ok then
				log("[AnimSkins Tuner] apply failed: " .. tostring(err))
			end
		end
	end
end

-- AnimSkins announces every swap. set_material_config rebuilt the unit's materials, so the
-- settings are written again, after it and not merely somewhere during assembly.
Hooks:Add("AnimSkinsSwapped", "AnimSkinsTuner_apply", function(weapon)
	local ok, err = pcall(T.apply, T, weapon)
	if not ok then
		log("[AnimSkins Tuner] apply failed: " .. tostring(err))
	end
end)

-- AnimSkins' files are another mod's. If one is missing or malformed the tuner does nothing,
-- rather than raising an error inside a hook file, which BLT turns into a crash.
local ok, err = pcall(T.load_manifest, T)
if not ok then
	T.configs = nil
	log("[AnimSkins Tuner] could not read AnimSkins' data, tuner inactive: " .. tostring(err))
end
T:load()

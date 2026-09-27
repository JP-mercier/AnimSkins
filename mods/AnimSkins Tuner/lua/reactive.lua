-- Reactive glow: the skin's brightness follows what is happening in the heist.
--
--   stealth (whisper mode)   glow dims to an ember             react_stealth  x Glow
--   loud, between assaults   base glow                         1.0            x Glow
--   assault in progress      glow ramps up                     react_assault  x Glow
--   sustained fire           the gun HEATS: glow climbs, the pattern scrolls faster, and a
--                            heat effect burns at the muzzle until it cools back down
--   every shot               a star-sparkle muzzle flash, from the game's own particles
--
-- Everything is a multiplier on the Glow slider, so reactive off returns exactly to it. Only
-- il_multiplier and uv_speed are written, and only to the animated materials T:collect returns
-- for the weapon in your hands -- the same set T:apply writes to.
--
-- Event sources (each verified against installed mods):
--   RaycastWeaponBase:fire            wrapped in weapon.lua; a truthy return is a shot fired
--   HUDManager:sync_start_assault / sync_end_assault / sync_start_anticipation_music
--   managers.groupai:state():whisper_mode()   polled each tick
--   unit:get_object(Idstring("fire"))         the muzzle object
--   World:effect_manager():spawn({effect = Idstring(path), parent = obj})
--
-- Nothing engine-side is held across frames without its owner being rechecked: the material
-- groups carry their unit and are re-verified on every write, and every muzzle effect records
-- the unit it is parented to and is killed when that unit dies. An akimbo weapon destroys and
-- respawns its second gun on its own schedule, which is where holding on without rechecking
-- used to crash.

dofile(ModPath .. "lua/core.lua")
local T = _G.AnimSkinsTuner

if T._reactive_loaded then
	return
end
T._reactive_loaded = true

T.react = {
	assault = false,      -- set by the HUD sync hooks
	anticipation = false, -- the build-up before an assault
	heat = 0,             -- 0 cold .. 1 fully heated
	current = 1.0,        -- smoothed stealth/assault factor actually on the weapon
	applied = nil,        -- last il_multiplier written, to skip redundant writes
	weapon = nil,         -- weapon base the material groups belong to
	groups = nil,         -- T:collect(weapon)
	groups_age = 0,
	fx_id = nil,          -- id of the muzzle heat effect while it is alive
	fx_kind = nil,        -- which effect that id is, so a menu change swaps it
	fx_unit = nil,        -- unit the effect is parented to
	fx_at = 0,            -- when it was spawned, so a finite effect is replayed while hot
	flash_at = 0,         -- time of the last star flash
	flashes = {},         -- live star flashes: { id = .., dies = time, unit = parent unit }
	time = 0,
}

local OBJ_FIRE = Idstring("fire")
local IDS_EFFECT = Idstring("effect")

-- Muzzle effects the game itself ships. Index 1 is "off".
T.HEAT_FX = {
	{ name = "Off" },
	{ name = "Overheat",        path = "effects/payday2/particles/weapons/heat/overheat" },
	{ name = "Hailstorm heat",  path = "effects/payday2/particles/weapons/heat/hailstorm_heat" },
	{ name = "Sparks",          path = "effects/payday2/particles/explosions/sparks/sparks_loop" },
	{ name = "Electric sparks", path = "effects/payday2/particles/electric/electric_sparks_cable" },
	{ name = "Drill sparks",    path = "effects/payday2/environment/parts/drill_sparks_particles" },
}

-- Per-shot star flash. The "FPS" entries are the game's own first-person muzzle flashes and are
-- always loaded; the sparkles live in DLC packages, loaded on first use.
T.FLASH_FX = {
	{ name = "Off" },
	{ name = "Kawaii sparkles", path = "effects/payday2/particles/character/overkillpack/mega_kawaii_sparkles",
	  package = "packages/dlcs/dlc_pack_overkill/game_base" },
	{ name = "Sparkle burst",   path = "effects/payday2/particles/explosions/sparkle_enemies",
	  package = "packages/dlcs/sparkle/game_base" },
	{ name = "Small sparkles",  path = "effects/particles/fire/small_sparkles" },
	{ name = "Sniper glint",    path = "effects/particles/weapons/sniper_glint_marshal" },
	{ name = "Spark flash (FPS)",   path = "effects/payday2/particles/weapons/fps_parts/fps_spark_flash" },
	{ name = "Sparse flash (FPS)",  path = "effects/payday2/particles/weapons/fps_parts/fps_sparse_flash" },
	{ name = "Ball flash (FPS)",    path = "effects/payday2/particles/weapons/fps_parts/fps_ball_flash" },
	{ name = "Fireball (FPS)",      path = "effects/payday2/particles/weapons/fps_parts/fps_fireball" },
	{ name = "Blue flash (FPS)",    path = "effects/payday2/particles/weapons/fps_parts/fps_small_silence_blue_flash" },
}

local function names_of(list)
	local out = {}
	for _, fx in ipairs(list) do table.insert(out, fx.name) end
	return out
end
function T:heat_fx_names() return names_of(self.HEAT_FX) end
function T:flash_fx_names() return names_of(self.FLASH_FX) end

local ids_cache = {}
local function ids(path)
	if not ids_cache[path] then ids_cache[path] = Idstring(path) end
	return ids_cache[path]
end

-- Is the effect resident? Checked once per path; a DLC effect's package is loaded on first use.
local reported = {}
local function effect_ready(fx)
	local path = fx.path
	if reported[path] ~= nil then return reported[path] end
	local function resident()
		local ok, has = pcall(PackageManager.has, PackageManager, IDS_EFFECT, ids(path))
		return ok and has and true or false
	end
	local has = resident()
	if not has and fx.package then
		pcall(function()
			if PackageManager:package_exists(fx.package) and not PackageManager:loaded(fx.package) then
				PackageManager:load(fx.package)
				log("[AnimSkins Tuner] reactive: loaded package " .. fx.package)
			end
		end)
		has = resident()
	end
	reported[path] = has
	log(("[AnimSkins Tuner] reactive: effect %s: %s"):format(has and "loaded" or "NOT LOADED (pick another)", path))
	return has
end

--------------------------------------------------------------------- events
function T:on_assault(active)
	self.react.assault = active and true or false
	if active then self.react.anticipation = false end
end

function T:on_anticipation()
	self.react.anticipation = true
end

--------------------------------------------------------------------- weapon
local function equipped_base()
	local p = managers.player and managers.player:player_unit()
	if not alive(p) then return nil end
	local inventory = p:inventory()
	local unit = inventory and inventory:equipped_unit()
	local base = alive(unit) and unit:base()
	if base and base._unit and alive(base._unit) then return base end
	return nil
end

-- The muzzle object AND the unit that owns it. A suppressor or barrel extension moves the real
-- muzzle forward and carries its own "fire" object; the game resolves that to weapon._obj_fire
-- after assembly, so that is trusted first, then barrel_ext > barrel > slide, then the root.
local MUZZLE_TYPES = { "barrel_ext", "barrel", "slide" }

local function muzzle_object(weapon)
	if type(weapon._obj_fire) == "userdata" then return weapon._obj_fire, weapon._unit end
	local fparts = tweak_data.weapon.factory.parts
	for _, want in ipairs(MUZZLE_TYPES) do
		for part_id, part in pairs(weapon._parts or {}) do
			if fparts[part_id] and fparts[part_id].type == want and alive(part.unit) then
				local fire = part.unit:get_object(OBJ_FIRE)
				if fire then return fire, part.unit end
			end
		end
	end
	return weapon._unit:get_object(OBJ_FIRE), weapon._unit
end

-- Effects are PARENTED to the muzzle, never placed at its world position: the first-person gun
-- is drawn in its own depth-scaled space, and an effect dropped at the muzzle's world position
-- lands behind it, invisible, and stays in the world.
local function spawn_at_muzzle(weapon, fx)
	local obj, owner = muzzle_object(weapon)
	if not obj or not alive(owner) or not effect_ready(fx) then return nil end
	local id = World:effect_manager():spawn({ effect = ids(fx.path), parent = obj })
	return id, owner
end

local function effect_kill(id)
	local em = World:effect_manager()
	if type(em.fade_kill) == "function" then em:fade_kill(id) else em:kill(id) end
end

-- Called from the fire wrapper in weapon.lua for every shot actually fired.
function T:on_shot(weapon)
	local s = self.settings
	local r = self.react
	if not s.reactive or not s.enabled or weapon ~= r.weapon then return end
	r.heat = math.min(1, r.heat + s.react_heat_gain)

	-- Star flash, rate-limited so automatics do not spawn sixty a second.
	local fx = self.FLASH_FX[s.react_flash_fx]
	if fx and fx.path and r.time - r.flash_at > 0.06 then
		r.flash_at = r.time
		local id, owner = spawn_at_muzzle(weapon, fx)
		if id and id ~= -1 then
			table.insert(r.flashes, { id = id, dies = r.time + s.react_flash_life, unit = owner })
		end
	end
end

--------------------------------------------------------------------- effects housekeeping
local MAX_FLASHES = 8

-- Kill every star flash past its lifetime, whose parent unit has gone, or all of them.
local function flashes_update(all)
	local r = T.react
	local kept = {}
	for _, f in ipairs(r.flashes) do
		if all or r.time >= f.dies or not alive(f.unit) then
			pcall(effect_kill, f.id)
		else
			table.insert(kept, f)
		end
	end
	while #kept > MAX_FLASHES do
		pcall(effect_kill, table.remove(kept, 1).id)
	end
	r.flashes = kept
end

local function fx_kill()
	local r = T.react
	if r.fx_id then
		pcall(effect_kill, r.fx_id)
	end
	r.fx_id, r.fx_kind, r.fx_unit = nil, nil, nil
end

-- Keep the muzzle heat effect in step with the heat: alive above the threshold, gone a little
-- below it (so it does not flicker at the edge), swapped if the menu choice changed. The game's
-- heat effects play once and stop, so while the gun stays hot it is replayed every period.
local function fx_update(weapon)
	local s = T.settings
	local r = T.react
	if r.fx_id and not alive(r.fx_unit) then fx_kill() end
	local want = s.react_heat_fx > 1 and r.heat >= s.react_heat_at
	local keep = r.fx_id and r.heat >= s.react_heat_at * 0.6
	if r.fx_id and (not (want or keep) or r.fx_kind ~= s.react_heat_fx) then fx_kill() end
	if want and r.fx_id and r.time - r.fx_at >= s.react_heat_fx_period then fx_kill() end
	if want and not r.fx_id then
		local fx = T.HEAT_FX[s.react_heat_fx]
		if fx and fx.path then
			local id, owner = spawn_at_muzzle(weapon, fx)
			if id and id ~= -1 then
				r.fx_id, r.fx_kind, r.fx_unit, r.fx_at = id, s.react_heat_fx, owner, r.time
			end
		end
	end
end

--------------------------------------------------------------------- tick
function T:react_target()
	local s = self.settings
	local whisper = managers.groupai and managers.groupai:state() and managers.groupai:state():whisper_mode()
	if whisper then return s.react_stealth end
	if self.react.assault then return s.react_assault end
	if self.react.anticipation then return 1.0 + (s.react_assault - 1.0) * 0.4 end
	return 1.0
end

local function update(dt)
	local s = T.settings
	local r = T.react
	r.time = r.time + dt

	if not s.reactive or not s.enabled then
		-- Reactive off: drop the effects, put back the plain values once, then write nothing.
		if r.fx_id or #r.flashes > 0 then
			fx_kill()
			flashes_update(true)
		end
		if r.applied ~= nil and r.groups then
			T:write_vars(r.groups, s.enabled and s.glow or 0, 1)
		end
		r.applied, r.current, r.heat = nil, 1.0, 0
		return
	end

	local weapon = equipped_base()
	if weapon ~= r.weapon then
		-- Swapped, holstered or dead: the old gun's effects must not outlive it.
		fx_kill()
		flashes_update(true)
		r.weapon, r.groups, r.applied, r.heat = weapon, nil, nil, 0
	end
	if not weapon then return end

	-- Rebuilt every two seconds, and at once after any apply (which clears it): parts can finish
	-- assembling late, and an akimbo weapon replaces its second gun.
	r.groups_age = r.groups_age + dt
	if not r.groups or r.groups_age > 2.0 then
		r.groups = T:collect(weapon)
		r.groups_age = 0
		r.applied = nil
	end

	r.heat = math.max(0, r.heat - dt * s.react_heat_cool)

	local k = 1 - math.exp(-dt * math.max(s.react_smooth, 0.1))
	r.current = r.current + (T:react_target() - r.current) * k

	local mult = s.glow * r.current * (1 + r.heat * s.react_heat_glow)
	if r.applied == nil or math.abs(mult - r.applied) > 0.02 then
		T:write_vars(r.groups, mult, 1 + r.heat * (s.react_heat_speed - 1))
		r.applied = mult
	end

	fx_update(weapon)
	flashes_update(false)
end

local failed = false
Hooks:Add("GameSetupUpdate", "AnimSkinsTuner_Reactive", function(t, dt)
	if failed then return end
	local ok, err = pcall(update, dt or 0.016)
	if not ok then
		-- Stop rather than fail sixty times a second. Your weapon keeps its last values.
		failed = true
		log("[AnimSkins Tuner] reactive glow stopped after an error: " .. tostring(err))
	end
end)

log("[AnimSkins Tuner] reactive glow loaded")

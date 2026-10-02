-- Options > Mod Options > AnimSkins Tuner

dofile(ModPath .. "lua/core.lua")
dofile(ModPath .. "lua/reactive.lua")
local T = _G.AnimSkinsTuner

local MENU = "animskins_tuner"

Hooks:Add("LocalizationManagerPostInit", "AnimSkinsTuner_loc", function(loc)
	loc:load_localization_file(T._path .. "loc/english.txt")
end)

Hooks:Add("MenuManagerInitialize", "AnimSkinsTuner_callbacks", function(menu_manager)
	local function set(key, value, repaint)
		T.settings[key] = value
		if repaint then
			T:apply_all()
		end
	end

	-- A slider hands back a number, a toggle "on"/"off", a multiple choice its index.
	local function slider(key, repaint)
		return function(self, item) set(key, tonumber(item:value()) or T.defaults[key], repaint) end
	end
	local function toggle(key, repaint)
		return function(self, item) set(key, item:value() == "on", repaint) end
	end
	local function choice(key, repaint)
		return function(self, item) set(key, item:value(), repaint) end
	end

	MenuCallbackHandler.ast_set_primary_skin = choice("primary_skin", true)
	MenuCallbackHandler.ast_set_secondary_skin = choice("secondary_skin", true)
	MenuCallbackHandler.ast_set_enabled = toggle("enabled", true)
	MenuCallbackHandler.ast_set_glow = slider("glow", true)
	MenuCallbackHandler.ast_set_bloom = slider("bloom", true)
	MenuCallbackHandler.ast_set_speed = slider("speed", true)
	MenuCallbackHandler.ast_set_direction = choice("direction", true)
	MenuCallbackHandler.ast_set_menus = function(self, item)
		set("menus", item:value() == "on")
		T:sync_animskins()
	end
	MenuCallbackHandler.ast_set_attachments = function(self, item)
		set("attachments", item:value() == "on")
		T:sync_animskins()
	end
	MenuCallbackHandler.ast_set_sights = function(self, item)
		set("sights", item:value() == "on")
		T:sync_animskins()
	end

	MenuCallbackHandler.ast_set_reactive = toggle("reactive", true)
	MenuCallbackHandler.ast_set_react_stealth = slider("react_stealth")
	MenuCallbackHandler.ast_set_react_assault = slider("react_assault")
	MenuCallbackHandler.ast_set_react_heat_gain = slider("react_heat_gain")
	MenuCallbackHandler.ast_set_react_heat_cool = slider("react_heat_cool")
	MenuCallbackHandler.ast_set_react_heat_glow = slider("react_heat_glow")
	MenuCallbackHandler.ast_set_react_heat_speed = slider("react_heat_speed")
	MenuCallbackHandler.ast_set_react_heat_fx = choice("react_heat_fx")
	MenuCallbackHandler.ast_set_react_heat_fx_period = slider("react_heat_fx_period")
	MenuCallbackHandler.ast_set_react_heat_at = slider("react_heat_at")
	MenuCallbackHandler.ast_set_react_flash_fx = choice("react_flash_fx")
	MenuCallbackHandler.ast_set_react_flash_life = slider("react_flash_life")
	MenuCallbackHandler.ast_set_react_smooth = slider("react_smooth")

	MenuCallbackHandler.ast_reset = function()
		for k, v in pairs(T.defaults) do
			T.settings[k] = v
		end
		T:sync_animskins()
		T:save()
		T:apply_all()
		-- The menu items still show the old values until it is reopened; say so.
		QuickMenu:new(managers.localization:text("ast_reset_title"), managers.localization:text("ast_reset_done"), {}, true)
	end

	MenuCallbackHandler.ast_save = function()
		T:save()
	end
end)

-- The skin is picked in Mod Options, where no weapon is on screen, so the change has to show when
-- you come back to a menu that has one. The menu scene caches its preview weapon rather than
-- rebuilding it, so a swap will not happen again; re-apply to what AnimSkins already swapped.
for _, name in ipairs({ "open_node", "back", "close_menu" }) do
	if type(MenuManager[name]) == "function" then
		Hooks:PostHook(MenuManager, name, "AnimSkinsTuner_repaint_" .. name, function()
			T:apply_all()
		end)
	end
end

Hooks:Add("MenuManagerSetupCustomMenus", "AnimSkinsTuner_setup", function()
	MenuHelper:NewMenu(MENU)
end)

Hooks:Add("MenuManagerPopulateCustomMenus", "AnimSkinsTuner_populate", function()
	local s = T.settings
	local priority = 100

	local function add(kind, id, data)
		priority = priority - 1
		data.id = "ast_" .. id
		data.title = "ast_" .. id .. "_title"
		data.desc = "ast_" .. id .. "_desc"
		data.callback = "ast_set_" .. id
		data.menu_id = MENU
		data.priority = priority
		if kind == "slider" then
			data.show_value = true
			MenuHelper:AddSlider(data)
		elseif kind == "toggle" then
			MenuHelper:AddToggle(data)
		else
			MenuHelper:AddMultipleChoice(data)
		end
	end
	local function divider(id)
		priority = priority - 1
		MenuHelper:AddDivider({ id = "ast_div_" .. id, size = 12, menu_id = MENU, priority = priority })
	end

	add("choice", "primary_skin", { value = s.primary_skin, items = T:skin_names(), localized_items = false })
	add("choice", "secondary_skin", { value = s.secondary_skin, items = T:skin_names(), localized_items = false })
	add("toggle", "enabled", { value = s.enabled })
	add("slider", "glow", { value = s.glow, min = 0, max = 20, step = 0.5 })
	add("slider", "bloom", { value = s.bloom, min = 0, max = 10, step = 0.25 })
	add("slider", "speed", { value = s.speed, min = 0, max = 0.5, step = 0.01 })
	add("choice", "direction", { value = s.direction,
		items = { "ast_dir_right", "ast_dir_left", "ast_dir_down", "ast_dir_up", "ast_dir_diag", "ast_dir_part" } })
	add("toggle", "menus", { value = s.menus })
	add("toggle", "attachments", { value = s.attachments })
	add("toggle", "sights", { value = s.sights })

	divider("reactive")
	add("toggle", "reactive", { value = s.reactive })
	add("slider", "react_stealth", { value = s.react_stealth, min = 0, max = 1, step = 0.05 })
	add("slider", "react_assault", { value = s.react_assault, min = 1, max = 4, step = 0.1 })
	add("slider", "react_heat_gain", { value = s.react_heat_gain, min = 0.01, max = 0.5, step = 0.01 })
	add("slider", "react_heat_cool", { value = s.react_heat_cool, min = 0.05, max = 2, step = 0.05 })
	add("slider", "react_heat_glow", { value = s.react_heat_glow, min = 0, max = 5, step = 0.1 })
	add("slider", "react_heat_speed", { value = s.react_heat_speed, min = 1, max = 10, step = 0.5 })
	add("slider", "react_heat_at", { value = s.react_heat_at, min = 0.05, max = 1, step = 0.05 })
	add("choice", "react_heat_fx", { value = s.react_heat_fx, items = T:heat_fx_names(), localized_items = false })
	add("slider", "react_heat_fx_period", { value = s.react_heat_fx_period, min = 0.2, max = 5, step = 0.1 })
	add("choice", "react_flash_fx", { value = s.react_flash_fx, items = T:flash_fx_names(), localized_items = false })
	add("slider", "react_flash_life", { value = s.react_flash_life, min = 0.05, max = 2, step = 0.05 })
	add("slider", "react_smooth", { value = s.react_smooth, min = 0.5, max = 20, step = 0.5 })

	divider("reset")
	priority = priority - 1
	MenuHelper:AddButton({ id = "ast_reset", title = "ast_reset_title", desc = "ast_reset_desc",
		callback = "ast_reset", menu_id = MENU, priority = priority })
end)

Hooks:Add("MenuManagerBuildCustomMenus", "AnimSkinsTuner_build", function(menu_manager, nodes)
	nodes[MENU] = MenuHelper:BuildMenu(MENU, { back_callback = "ast_save" })
	MenuHelper:AddMenuItem(nodes.blt_options, MENU, "ast_menu_title", "ast_menu_desc")
end)

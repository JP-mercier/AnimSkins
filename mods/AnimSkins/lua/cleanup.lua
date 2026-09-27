-- AnimSkins: old version cleanup
--
-- Earlier versions shipped as mod_overrides packs (the 1.x skins, and the gloves up to 3.0). Those
-- override game files for every player and fight with this mod. When one is found, the main menu
-- offers to move it to "<PAYDAY 2>/AnimSkins old versions/", out of the game's reach. Nothing is
-- deleted, so the move can be undone by moving the folder back. tools/build.py --install does the
-- same outside the game.

local OVERRIDES = "assets/mod_overrides/"
local BACKUP = "AnimSkins old versions/"
local OLD_PACKS = { "AnimSkins", "AnimSkinsGloves" }

local function read(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local text = f:read("*all") or ""
	f:close()
	return text
end

-- Same markers as tools/build.py: a folder that merely has one of these names is left alone.
local function is_old_pack(folder)
	local main = read(folder .. "main.xml")
	return main:find('name="AnimSkinsGloves"', 1, true) ~= nil
		or main:find("units/mods/animskins/", 1, true) ~= nil
		or file.DirectoryExists(folder .. "assets/units/mods/animskins")
end

local function find_old_packs()
	local found = {}
	for _, name in ipairs(OLD_PACKS) do
		local folder = OVERRIDES .. name .. "/"
		if file.DirectoryExists(folder) and is_old_pack(folder) then
			table.insert(found, name)
		end
	end
	return found
end

local function free_target(name)
	local target, n = BACKUP .. name, 2
	while file.DirectoryExists(target) do
		target = ("%s%s (%d)"):format(BACKUP, name, n)
		n = n + 1
	end
	return target
end

local function move_old_packs(names)
	if not file.DirectoryExists(BACKUP) then
		file.CreateDirectory(BACKUP)
	end

	local moved, failed = {}, {}
	for _, name in ipairs(names) do
		local target = free_target(name)
		if file.MoveDirectory(OVERRIDES .. name, target) then
			log("[AnimSkins] moved " .. OVERRIDES .. name .. " to " .. target)
			table.insert(moved, name)
		else
			log("[AnimSkins] could not move " .. OVERRIDES .. name)
			table.insert(failed, name)
		end
	end

	if #failed == 0 then
		QuickMenu:new("AnimSkins",
			"Moved to \"" .. BACKUP .. "\" in your PAYDAY 2 folder:\n\n" .. table.concat(moved, "\n")
			.. "\n\nRestart the game to finish. Delete that folder once everything looks right.",
			{}, true)
	else
		QuickMenu:new("AnimSkins",
			"Could not move:\n\n" .. table.concat(failed, "\n")
			.. "\n\nThe game may be using their files. Close PAYDAY 2 and delete these folders from "
			.. OVERRIDES .. " by hand.",
			{}, true)
	end
end

local asked = false

Hooks:Add("MenuManagerOnOpenMenu", "AnimSkins_cleanup", function(menu_manager, menu_name)
	if asked or menu_name ~= "menu_main" then
		return
	end
	asked = true

	local found = find_old_packs()
	if #found == 0 then
		return
	end
	log("[AnimSkins] old packs installed: " .. table.concat(found, ", "))

	local lines = {}
	for _, name in ipairs(found) do
		table.insert(lines, OVERRIDES .. name)
	end

	local several = #found > 1
	QuickMenu:new("AnimSkins",
		(several and "Older AnimSkins packs are still installed:" or "An older AnimSkins pack is still installed:")
		.. "\n\n" .. table.concat(lines, "\n") .. "\n\n"
		.. (several and "They change game files for every player and conflict" or "It changes game files for every player and conflicts")
		.. " with this version. Move " .. (several and "them" or "it") .. " to \"" .. BACKUP .. "\" in your PAYDAY 2 folder?",
		{
			{ text = several and "Move them" or "Move it", callback = function() move_old_packs(found) end },
			{ text = "Not now", is_cancel_button = true },
		},
		true)
end)

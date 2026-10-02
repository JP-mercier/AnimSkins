-- AnimSkins PartDumper
--
-- Writes the material config of every weapon part in tweak_data.weapon.factory.parts, and of every
-- unit a part or weapon override puts in a part's place, to
-- <SavePath>/animskins_part_dump.txt, for tools/build.py --import-dump. A part's config is the one
-- its .object file names (diesel.materials), unless the factory data overrides it
-- (part_data.material_config). This is the same chain the engine follows: .unit -> .object ->
-- .material_config.
--
-- Output, one block per distinct config and one line per part:
--     config <path>
--     <material config XML>
--     end
--     part <part id> <type> <unit path> <config path, or ? when the factory data names it by Idstring only>
--
-- Reads game files only, once, at the main menu. Remove the mod afterwards.

local OUT = SavePath .. "animskins_part_dump.txt"

local function read(ext, name)
	local ids = type(name) == "string" and name:id() or name
	if not DB:has(ext, ids) then
		return nil
	end
	local file = DB:open(ext, ids)
	return file and file:read()
end

local function parse(data)
	if not data then
		return nil
	end
	if data:match("^%s*<") then
		return ScriptSerializer:from_custom_xml(data)
	end
	return ScriptSerializer:from_binary(data)
end

-- A parsed node back to XML, for configs stored in binary. Vectors are written the way material
-- configs spell them ("x y z").
local function attribute(value)
	if type(value) == "userdata" and value.x and value.y and value.z then
		return ("%g %g %g"):format(value.x, value.y, value.z)
	end
	return tostring(value)
end

local function to_xml(node, indent, out)
	local attrs = {}
	for k, v in pairs(node) do
		if type(k) == "string" and k ~= "_meta" and type(v) ~= "table" then
			table.insert(attrs, ('%s="%s"'):format(k, attribute(v)))
		end
	end
	table.sort(attrs)
	local open = indent .. "<" .. tostring(node._meta) .. (#attrs > 0 and (" " .. table.concat(attrs, " ")) or "")
	if #node == 0 then
		table.insert(out, open .. "/>")
		return
	end
	table.insert(out, open .. ">")
	for _, child in ipairs(node) do
		if type(child) == "table" then
			to_xml(child, indent .. "\t", out)
		end
	end
	table.insert(out, indent .. "</" .. tostring(node._meta) .. ">")
end

local function config_xml(name)
	local data = read("material_config", name)
	if not data then
		return nil
	end
	if data:match("^%s*<") then
		return (data:gsub("\r", ""))
	end
	local out = {}
	to_xml(ScriptSerializer:from_binary(data), "", out)
	return table.concat(out, "\n")
end

local function default_config(unit)
	local unit_data = parse(read("unit", unit))
	local object = unit_data and unit_data.object and unit_data.object.file
	local object_data = object and parse(read("object", object))
	return object_data and object_data.diesel and object_data.diesel.materials
end

local function dump()
	local f = io.open(OUT, "w")
	if not f then
		log("[PartDumper] cannot write " .. OUT)
		return
	end

	local written, parts, failed = {}, 0, 0
	local factory = tweak_data.weapon.factory

	-- Every part, then every unit an override puts in a part's place: a part fitted next to another
	-- (the Judge's modern frame swaps in its own grip) or a weapon (conversion kits, akimbo variants)
	-- can replace a part's unit, and that unit is listed nowhere else. Override entries are named
	-- "<owner>><part id>" and dumped once per unit.
	local entries, seen_units = {}, {}
	local function add(id, part, once)
		if type(part) == "table" and type(part.unit) == "string" and not (once and seen_units[part.unit]) then
			seen_units[part.unit] = true
			table.insert(entries, { id = id, part = part })
		end
	end
	local function sorted_keys(t)
		local keys = {}
		for k in pairs(t) do
			if type(k) == "string" then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		return keys
	end
	local function add_overrides(owner, override)
		if type(override) ~= "table" then
			return
		end
		for _, target in ipairs(sorted_keys(override)) do
			local replacement = override[target]
			if type(replacement) == "table" and type(replacement.unit) == "string" then
				local base = factory.parts[target]
				add(owner .. ">" .. target, {
					unit = replacement.unit,
					type = replacement.type or (type(base) == "table" and base.type) or nil,
					material_config = replacement.material_config,
				}, true)
			end
		end
	end
	for _, part_id in ipairs(sorted_keys(factory.parts)) do
		add(part_id, factory.parts[part_id])
	end
	for _, part_id in ipairs(sorted_keys(factory.parts)) do
		local part = factory.parts[part_id]
		add_overrides(part_id, type(part) == "table" and part.override)
	end
	for _, factory_id in ipairs(sorted_keys(factory)) do
		local weapon = factory[factory_id]
		if factory_id ~= "parts" and type(weapon) == "table" then
			add_overrides(factory_id, weapon.override)
		end
	end

	for _, entry in ipairs(entries) do
		local part_id, part = entry.id, entry.part
		do
			local ok, err = pcall(function()
				local config, xml
				if part.material_config then
					config = "?"
					xml = config_xml(part.material_config)
				else
					config = default_config(part.unit)
					xml = config and config_xml(config)
				end
				if config and xml then
					local key = config == "?" and ("?" .. part_id) or config
					if not written[key] then
						written[key] = true
						f:write("config ", config == "?" and ("?" .. part_id) or config, "\n", xml, "\nend\n")
					end
					f:write("part ", part_id, " ", tostring(part.type or "-"), " ", part.unit, " ", config == "?" and ("?" .. part_id) or config, "\n")
					parts = parts + 1
				else
					f:write("missing ", part_id, " ", part.unit, "\n")
					failed = failed + 1
				end
			end)
			if not ok then
				f:write("error ", part_id, " ", (tostring(err):gsub("\n", " ")), "\n")
				failed = failed + 1
			end
		end
	end

	f:close()
	local message = ("%d parts written, %d without a readable config, to %s"):format(parts, failed, OUT)
	log("[PartDumper] " .. message)
	QuickMenu:new("AnimSkins PartDumper", message .. "\n\nYou can remove the PartDumper mod now.", {}, true)
end

local done = false

Hooks:Add("MenuManagerOnOpenMenu", "AnimSkinsPartDumper", function(_, menu_name)
	if done or menu_name ~= "menu_main" then
		return
	end
	done = true
	local ok, err = pcall(dump)
	if not ok then
		log("[PartDumper] failed: " .. tostring(err))
	end
end)

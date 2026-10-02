"""Rebuild src/parts.txt, src/animated.txt and src/static.xml from an in-game part dump.

tools/PartDumper writes the real material config of every weapon part. Each part's material list is
rebuilt from it, so it names exactly the materials its mesh has, and each material is classed by
its shader:

    generic, not skinned          animated; keeps its scroll direction from src/animated.txt, and a
                                  name not seen before gets one derived from its name
    effect, opacity, decal        static, the vanilla definition: reticles, scope glass, transparent
                                  windows and fake shadows keep working
    generic with SKINNED_*        static, the vanilla definition: meshes bent by bones (bow and
                                  crossbow strings) need the skinned shader

Entries the dump does not cover are kept unchanged, so a dump can add and correct but never remove.
Parts whose config the factory data names by Idstring only are dumped as "?<part id>";
src/explicit_configs.txt gives their paths. New magazine parts are appended to src/black_parts.txt.

    python tools/build.py --import-dump <PAYDAY 2>/mods/saves/animskins_part_dump.txt
"""
from pathlib import Path
import re
import zlib
import xml.etree.ElementTree as ET

SRC = Path(__file__).resolve().parent.parent / "src"
DIRECTION_NAMES = ["e", "w", "n", "s", "ne", "nw", "se", "sw"]
EFFECT_SHADERS = ("effect", "opacity", "decal")
MAGAZINE_TYPES = {"magazine", "magazine_1", "magazine_extra"}


def dedupe_attributes(xml):
    """The engine keeps the first of repeated attributes; ElementTree refuses the file instead."""
    def fix(m):
        seen, kept = set(), []
        for a in re.finditer(r"""([\w:]+)\s*=\s*("[^"]*"|'[^']*')""", m.group(2)):
            if a.group(1) not in seen:
                seen.add(a.group(1))
                kept.append(a.group(0))
        return "<" + m.group(1) + (" " + " ".join(kept) if kept else "") + m.group(3) + ">"
    return re.sub(r"""<([\w:]+)((?:\s+[\w:]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(/?)>""", fix, xml)


def read_dump(path):
    configs, parts = {}, []
    lines = Path(path).read_text(encoding="utf-8", errors="replace").split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("config "):
            end = lines.index("end", i + 1)
            configs[line[7:].strip()] = ET.fromstring(dedupe_attributes("\n".join(lines[i + 1:end])))
            i = end
        elif line.startswith("part "):
            _, part_id, part_type, unit, config = line.split(" ", 4)
            parts.append((part_id, part_type, unit, config.strip()))
        i += 1
    return configs, parts


def canon(el):
    return (el.tag, tuple(sorted((k, v) for k, v in el.attrib.items() if k not in ("id", "unique"))),
            tuple(canon(c) for c in el))


def static_definition(material, static_id):
    """A vanilla material as a static.xml entry: attributes and flat children, no text."""
    el = ET.Element("material", {"id": static_id, **{k: v for k, v in sorted(material.attrib.items()) if k != "unique"}})
    for child in material:
        el.append(ET.Element(child.tag, dict(sorted(child.attrib.items()))))
    return el


def direction_for(name):
    return DIRECTION_NAMES[zlib.crc32(name.encode()) % len(DIRECTION_NAMES)]


def read_table(path):
    return [line.split() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]


def classify(material):
    template = material.get("render_template", "")
    if template.split(":")[0] in EFFECT_SHADERS or "SKINNED" in template:
        return "static"
    return "animated"


def import_dump(dump_path):
    configs, dumped = read_dump(dump_path)
    explicit = dict(read_table(SRC / "explicit_configs.txt"))
    old_directions = dict(read_table(SRC / "animated.txt"))
    old_parts = {fields[0]: fields for fields in read_table(SRC / "parts.txt")}

    # "?<part id>" -> path; parts without one in explicit_configs.txt cannot be keyed and are reported.
    resolved, unresolved = {}, []
    for part_id, _, _, config in dumped:
        if config.startswith("?"):
            if part_id in explicit:
                resolved[config] = explicit[part_id]
            else:
                unresolved.append(part_id)
    by_path = {}
    for config, root in configs.items():
        by_path.setdefault(resolved.get(config, config), root)

    animated, static, static_by_canon, parts = {}, {}, {}, {}
    new_names = 0

    def static_ref(material):
        el = static_definition(material, "")
        key = canon(el)
        if key not in static_by_canon:
            sid, n = material.get("name"), 1
            while sid in static:
                n += 1
                sid = f"{material.get('name')}/{n}"
            el.set("id", sid)
            static[sid] = el
            static_by_canon[key] = sid
        return ("s", static_by_canon[key])

    used = {resolved.get(c, c) for _, _, _, c in dumped if not c.startswith("?") or c in resolved}
    for path in sorted(used):
        materials = [m for m in by_path[path] if m.tag == "material"]
        if not materials:
            continue  # an empty config: dummy parts with nothing to draw
        refs = []
        for material in materials:
            name = material.get("name")
            if classify(material) == "static":
                refs.append(static_ref(material))
            else:
                if name not in animated:
                    if name in old_directions:
                        animated[name] = old_directions[name]
                    else:
                        animated[name] = direction_for(name)
                        new_names += 1
                refs.append(("a", name))
        parts[path] = [path, by_path[path].get("group", "-"), *refs]

    # Entries the dump does not cover are kept as they are, so a dump that misses some units can
    # never take coverage away. Their static definitions come over from the old static.xml.
    old_static = {el.get("id"): el for el in ET.parse(SRC / "static.xml").getroot()}
    kept = sorted(old_parts.keys() - parts.keys())
    for path in kept:
        refs = []
        for ref in old_parts[path][2:]:
            if ref in old_static:
                el = old_static[ref]
                key = canon(el)
                if key not in static_by_canon:
                    sid, n = el.get("name"), 1
                    while sid in static:
                        n += 1
                        sid = f"{el.get('name')}/{n}"
                    copy = ET.Element("material", {"id": sid, **{k: v for k, v in el.attrib.items() if k != "id"}})
                    copy.extend(ET.Element(c.tag, dict(c.attrib)) for c in el)
                    static[sid] = copy
                    static_by_canon[key] = sid
                refs.append(("s", static_by_canon[key]))
            else:
                animated.setdefault(ref, old_directions.get(ref) or direction_for(ref))
                refs.append(("a", ref))
        parts[path] = [path, old_parts[path][1], *refs]

    # Every ref must be unambiguous: a static id that is also an animated name gets a suffix.
    renames = {}
    for sid in sorted(static):
        if sid in animated:
            name, n = static[sid].get("name"), 2
            while f"{name}/{n}" in static or f"{name}/{n}" in renames.values():
                n += 1
            renames[sid] = f"{name}/{n}"
    for old_id, new_id in renames.items():
        static[new_id] = static.pop(old_id)
        static[new_id].set("id", new_id)

    def text(ref):
        return renames.get(ref[1], ref[1]) if ref[0] == "s" else ref[1]

    lines = {path: [f[0], f[1], *map(text, f[2:])] for path, f in parts.items()}
    (SRC / "parts.txt").write_text("".join(" ".join(lines[k]) + "\n" for k in sorted(lines)), newline="\n")
    (SRC / "animated.txt").write_text("".join(f"{name} {animated[name]}\n" for name in sorted(animated)), newline="\n")
    root = ET.Element("materials")
    for sid in sorted(static):
        root.append(static[sid])
    ET.indent(root, "\t")
    (SRC / "static.xml").write_text(ET.tostring(root, encoding="unicode") + "\n", newline="\n")

    black_file = SRC / "black_parts.txt"
    black_lines = black_file.read_text().splitlines()
    black = {line.strip() for line in black_lines if line.strip() and not line.startswith("#")}
    added_black = sorted({resolved.get(c, c) for _, part_type, _, c in dumped
                          if part_type in MAGAZINE_TYPES and resolved.get(c, c) in lines and resolved.get(c, c) not in black})
    if added_black:
        black_file.write_text("\n".join(black_lines + added_black) + "\n", newline="\n")

    added = sorted(lines.keys() - old_parts.keys())
    changed = sum(1 for k in lines.keys() & old_parts.keys() if lines[k] != old_parts[k])
    print(f"import: {len(lines)} configs ({len(added)} new, {changed} changed, {len(kept)} not in the dump, kept as they were); "
          f"{len(animated)} animated names ({new_names} new), {len(static)} static materials; "
          f"{len(added_black)} magazines added to black_parts.txt")
    if unresolved:
        print("WARNING: no path in explicit_configs.txt for: " + ", ".join(sorted(unresolved)))

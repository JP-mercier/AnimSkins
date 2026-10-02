"""Build AnimSkins from src/.

Inputs:
    src/parts.txt, src/animated.txt, src/static.xml
                            weapon part data from Inversion Universal: per part, the vanilla material
                            config it replaces and the exact materials its mesh uses
    src/black_parts.txt     parts drawn solid black instead of animated (BLACK_PARTS)
    src/skins.json          the skins, in dropdown order
    mods/AnimSkins/assets/units/mods/animskins3/<id>_df.texture, <id>_il.texture
                            each skin's base and glow texture (DDS, DXT1 or DXT5, no mipmaps)

Outputs (don't edit them by hand):
    mods/AnimSkins/assets/units/mods/animskins3/black.texture
    mods/AnimSkins/assets/units/mods/animskins3/materials/*.material_config
    mods/AnimSkins/material_configs.txt   <vanilla path> <config name>, read by lua/animskins.lua
    mods/AnimSkins/skin_materials.txt     per config, the materials a skin switch may retexture (tuner)
    mods/AnimSkins/variants.json          the skins and their texture paths (tuner)
    mods/AnimSkins/main.xml               BeardLib file registration

A skin texture saved as DXT5 whose alpha is fully opaque is rewritten in place as DXT1: the alpha
half of each block carries nothing, and the colour half is kept bit for bit. With Pillow installed
the build decodes both versions and refuses to keep one that differs by a single pixel.

Usage (Python 3.10+, standard library only; Pillow optional, for the texture check):
    python tools/build.py                   build in place
    python tools/build.py --install [PD2]   build, then copy both mods into <PD2>/mods
    python tools/build.py --pack            build, then write dist/AnimSkins-<version>.zip
    python tools/build.py --import-dump D   merge a tools/PartDumper dump into src/, then build
"""
from pathlib import Path
import argparse
import json
import re
import shutil
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

# ---- Look baked into the configs. The tuner changes all of these live; Reset returns here. ----
DEFAULT_SKIN = "default"     # id from src/skins.json
SCROLL_SPEED = 0.1           # UV units per second
GLOW_MULTIPLIER = 5          # il_multiplier
GLOW_BLOOM = 1.0             # il_bloom
BLACK_PARTS = True           # draw the parts in src/black_parts.txt (the magazines) solid black

# Scroll direction in UV space (u, v), scaled by SCROLL_SPEED. Same names as Inversion Universal.
DIRECTIONS = {
    "e": (1, 0), "w": (-1, 0), "n": (0, 1), "s": (0, -1),
    "ne": (0.7, 0.7), "nw": (-0.7, 0.7), "se": (0.7, -0.7), "sw": (-0.7, -0.7),
}
# -----------------------------------------------------------------------------------------------

NAMESPACE = "units/mods/animskins3"
BLACK = f"{NAMESPACE}/black"
RENDER_TEMPLATE = "generic:DEPTH_SCALING:DIFFUSE_TEXTURE:DIFFUSE_UVANIM:SELF_ILLUMINATION:SELF_ILLUMINATION_BLOOM:SELF_ILLUMINATION_UVANIM"

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
MODS = ROOT / "mods"
MOD = MODS / "AnimSkins"
TEXTURES = MOD / "assets" / NAMESPACE
MATERIALS = TEXTURES / "materials"
DIST = ROOT / "dist"


# ---- Textures ---------------------------------------------------------------------------------
DDS_HEADER = 128


def read_dds(path):
    data = path.read_bytes()
    if data[:4] != b"DDS ":
        raise ValueError(f"{path.name}: not a DDS file")
    height, width, _, _, mips = struct.unpack_from("<5I", data, 12)
    fourcc = data[84:88]
    if fourcc not in (b"DXT1", b"DXT5") or mips > 1:
        raise ValueError(f"{path.name}: expected DXT1/DXT5 without mipmaps, got {fourcc} with {mips} mipmaps")
    block = 8 if fourcc == b"DXT1" else 16
    size = max(1, (width + 3) // 4) * max(1, (height + 3) // 4) * block
    if len(data) < DDS_HEADER + size:
        raise ValueError(f"{path.name}: {len(data) - DDS_HEADER} bytes of pixels, {width}x{height} {fourcc.decode()} needs {size}")
    return data, width, height, fourcc, size


def fully_opaque_dxt5(body):
    # A DXT5 alpha block whose two endpoints are both 255 decodes to 255 whatever its indices are.
    return all(body[i] == 255 and body[i + 1] == 255 for i in range(0, len(body), 16))


def dxt5_to_dxt1(body):
    """Drop the alpha half of every block, keeping the colour half bit for bit.

    A DXT5 colour block is always read in four-colour mode. DXT1 reads it in four-colour mode only
    when color0 > color1, so blocks the other way round are rewritten into the equivalent form: swap
    the endpoints and flip each 2-bit index (0<->1, 2<->3), which names the same four colours. When
    the endpoints are equal all four colours are the same, so every index can point at color0.
    """
    out = bytearray(len(body) // 2)
    for src in range(0, len(body), 16):
        c0, c1, indices = struct.unpack_from("<HHI", body, src + 8)
        if c0 < c1:
            c0, c1, indices = c1, c0, indices ^ 0x55555555
        elif c0 == c1:
            indices = 0
        struct.pack_into("<HHI", out, src // 2, c0, c1, indices)
    return bytes(out)


def dds_header(width, height, fourcc, size):
    # The same header the game's own textures carry: caps, height, width, pixel format, linear size.
    header = bytearray(DDS_HEADER)
    header[0:4] = b"DDS "
    struct.pack_into("<7I", header, 4, 124, 0x81007, height, width, size, 0, 0)
    struct.pack_into("<2I4s", header, 76, 32, 0x4, fourcc)
    struct.pack_into("<I", header, 108, 0x1000)
    return bytes(header)


def decodes_identically(a, b):
    """Decode both DDS files and compare every pixel. None when Pillow is not installed."""
    try:
        from io import BytesIO
        from PIL import Image
    except ImportError:
        return None
    first, second = (Image.open(BytesIO(data)).convert("RGBA") for data in (a, b))
    return first.size == second.size and first.tobytes() == second.tobytes()


def compact_texture(path):
    """Rewrite an opaque DXT5 texture as DXT1 in place. Returns the format the file ends up in."""
    data, width, height, fourcc, size = read_dds(path)
    body = data[DDS_HEADER:DDS_HEADER + size]
    if fourcc != b"DXT5" or not fully_opaque_dxt5(body):
        return fourcc.decode()
    converted = dds_header(width, height, b"DXT1", size // 2) + dxt5_to_dxt1(body)
    if decodes_identically(data, converted) is False:
        sys.exit(f"{path.name}: DXT1 version decodes differently; leaving it as DXT5 is not supported")
    path.write_bytes(converted)
    print(f"{path.name}: DXT5 -> DXT1 ({len(data)} -> {len(converted)} bytes)")
    return "DXT1"


# ---- Materials --------------------------------------------------------------------------------
def number(value):
    return f"{round(value, 6):g}"


def animated_material(name, direction, skin):
    u, v = DIRECTIONS[direction]
    material = ET.Element("material", name=name, render_template=RENDER_TEMPLATE, version="2")
    ET.SubElement(material, "diffuse_texture", file=skin["df"])
    ET.SubElement(material, "self_illumination_texture", file=skin["il"])
    ET.SubElement(material, "variable", name="uv_speed", value=f"{number(u * SCROLL_SPEED)} {number(v * SCROLL_SPEED)} 0", type="vector3")
    ET.SubElement(material, "variable", name="il_bloom", value=str(GLOW_BLOOM), type="float")
    ET.SubElement(material, "variable", name="il_multiplier", value=str(GLOW_MULTIPLIER), type="scalar")
    return material


# static.xml names the skin's textures as $diffuse, and in a few places by Inversion Universal's own
# texture paths. Those paths are not registered here, so they are pointed at the skin's textures too.
UNIVERSAL_TEXTURES = {
    "$diffuse": "df",
    "units/mods/inversion_universal/inversion_df": "df",
    "units/mods/inversion_universal/inversion_il": "il",
}


def black_material(name):
    # The animated shader, so no render template is used that the other materials do not already
    # use, with both textures black and no glow. The tuner never lists these, so it leaves them be.
    material = ET.Element("material", name=name, render_template=RENDER_TEMPLATE, version="2")
    ET.SubElement(material, "diffuse_texture", file=BLACK)
    ET.SubElement(material, "self_illumination_texture", file=BLACK)
    ET.SubElement(material, "variable", name="uv_speed", value="0 0 0", type="vector3")
    ET.SubElement(material, "variable", name="il_bloom", value="0", type="float")
    ET.SubElement(material, "variable", name="il_multiplier", value="0", type="scalar")
    return material


def static_material(source, skin):
    material = ET.Element("material", {k: v for k, v in source.attrib.items() if k != "id"})
    for child in source:
        material.append(ET.Element(child.tag, {k: skin[UNIVERSAL_TEXTURES[v]] if v in UNIVERSAL_TEXTURES else v for k, v in child.attrib.items()}))
    return material


def retexturable(source):
    # A static material the tuner may point at another skin's base: a generic shader whose diffuse
    # slot is the skin's. Effect and opacity shaders (reticles, scope glass) are never touched.
    return source.get("render_template", "").startswith("generic:") and any(
        child.tag == "diffuse_texture" and child.get("file") == "$diffuse" for child in source)


def read_lines(path):
    return [line.split() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]


# ---- Install and pack -------------------------------------------------------------------------
def find_pd2():
    """PAYDAY 2's folder from Steam's library list, or None."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
    except (ImportError, OSError):
        return None
    libraries = [steam]
    vdf = steam / "steamapps" / "libraryfolders.vdf"
    if vdf.is_file():
        libraries += [Path(p.replace("\\\\", "\\")) for p in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(errors="replace"))]
    for library in libraries:
        pd2 = library / "steamapps" / "common" / "PAYDAY 2"
        if (pd2 / "mods").is_dir():
            return pd2
    return None


def mod_folders():
    return [folder for folder in sorted(MODS.iterdir()) if (folder / "mod.txt").is_file()]


def is_old_animskins(folder):
    """True for the mod_overrides packs earlier versions shipped: the 1.x skins and the gloves."""
    main = folder / "main.xml"
    text = main.read_text(errors="replace") if main.is_file() else ""
    return ('name="AnimSkinsGloves"' in text
            or "units/mods/animskins/" in text
            or (folder / "assets" / "units" / "mods" / "animskins").is_dir())


def retire_old_versions(pd2):
    """Move earlier versions' mod_overrides packs out of the game's reach, into <PD2>/AnimSkins old versions."""
    backup = pd2 / "AnimSkins old versions"
    for name in ("AnimSkins", "AnimSkinsGloves"):
        folder = pd2 / "assets" / "mod_overrides" / name
        if not folder.is_dir():
            continue
        if not is_old_animskins(folder):
            print(f"WARNING: {folder} does not look like an AnimSkins pack; left in place")
            continue
        target = backup / name
        n = 2
        while target.exists():
            target = backup / f"{name} ({n})"
            n += 1
        backup.mkdir(exist_ok=True)
        shutil.move(str(folder), str(target))
        print(f"moved old version {folder} -> {target} (delete it once you're happy)")


def mod_name(folder):
    return json.loads((folder / "mod.txt").read_text(encoding="utf-8"))["name"]


def install(pd2):
    if pd2 is None:
        pd2 = find_pd2()
        if pd2 is None:
            sys.exit("--install: PAYDAY 2 not found through Steam; pass its folder: --install <PD2>")
    mods = pd2 / "mods"
    if not mods.is_dir():
        sys.exit(f"--install: {mods} does not exist (is SuperBLT installed?)")

    for folder in mod_folders():
        target = mods / folder.name
        if target.exists():
            if not (target / "mod.txt").is_file() or mod_name(target) != mod_name(folder):
                sys.exit(f"--install: {target} exists and is not {mod_name(folder)}; not touching it")
            shutil.rmtree(target)
        shutil.copytree(folder, target)
        print(f"installed {target}")

    retire_old_versions(pd2)

    # A separate mod, so it is reported rather than moved.
    if (mods / "Inversion Universal").exists():
        print(f"WARNING: {mods / 'Inversion Universal'} is installed -- it swaps the same parts; whichever hook runs last wins")
    print("Restart the game: material configs and textures are only registered at startup.")


def pack():
    version = json.loads((MOD / "mod.txt").read_text(encoding="utf-8"))["version"]
    archive = DIST / f"AnimSkins-{version}.zip"
    DIST.mkdir(exist_ok=True)
    files = [ROOT / "README.md"] + sorted(p for folder in mod_folders() for p in folder.rglob("*") if p.is_file())
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            z.write(path, path.relative_to(ROOT))
    print(f"{len(files)} files -> {archive.relative_to(ROOT)} ({archive.stat().st_size / 1e6:.1f} MB)")


# ---- Build ------------------------------------------------------------------------------------
AUTO = object()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--install", nargs="?", const=AUTO, type=Path, metavar="PD2",
                        help="copy both mods into <PD2>/mods (PAYDAY 2 is found through Steam if omitted)")
    parser.add_argument("--pack", action="store_true", help="write dist/AnimSkins-<version>.zip")
    parser.add_argument("--import-dump", type=Path, metavar="DUMP",
                        help="merge a tools/PartDumper dump into src/ before building (see tools/import_dump.py)")
    args = parser.parse_args()

    if args.import_dump:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from import_dump import import_dump
        import_dump(args.import_dump)

    errors = []

    skins = json.loads((SRC / "skins.json").read_text())["skins"]
    ids = [skin["id"] for skin in skins]
    for duplicate in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append(f"skins.json: duplicate id {duplicate!r}")
    if DEFAULT_SKIN not in ids:
        errors.append(f"DEFAULT_SKIN {DEFAULT_SKIN!r} is not in skins.json")
    for skin in skins:
        skin["df"] = f"{NAMESPACE}/{skin['id']}_df"
        skin["il"] = f"{NAMESPACE}/{skin['id']}_il"
        for slot in ("df", "il"):
            try:
                read_dds(MOD / "assets" / f"{skin[slot]}.texture")
            except (OSError, ValueError) as e:
                errors.append(f"skins.json: {skin['id']}: {e}")
    expected = {f"{skin[slot].rsplit('/', 1)[1]}.texture" for skin in skins for slot in ("df", "il")} | {"black.texture"}
    for unused in sorted({p.name for p in TEXTURES.glob("*.texture")} - expected):
        errors.append(f"{unused}: not used by any skin in skins.json")

    animated = {}
    for name, direction in read_lines(SRC / "animated.txt"):
        if direction not in DIRECTIONS:
            errors.append(f"animated.txt: {name}: unknown direction {direction!r}")
        animated[name] = direction

    static = {el.get("id"): el for el in ET.parse(SRC / "static.xml").getroot()}
    for ambiguous in sorted(static.keys() & animated.keys()):
        errors.append(f"{ambiguous!r} is both an animated name and a static id")

    parts = read_lines(SRC / "parts.txt")
    names = [fields[0].rsplit("/", 1)[1] for fields in parts]
    for duplicate in sorted({n for n in names if names.count(n) > 1}):
        errors.append(f"parts.txt: two parts would both be named {duplicate}")
    for vanilla, _, *materials in parts:
        if not materials:
            errors.append(f"parts.txt: {vanilla}: no materials")
        for ref in materials:
            if ref not in animated and ref not in static:
                errors.append(f"parts.txt: {vanilla}: unknown material {ref!r}")

    if errors:
        sys.exit("\n".join(errors))

    default = skins[ids.index(DEFAULT_SKIN)]
    black_parts = {fields[0] for fields in read_lines(SRC / "black_parts.txt")} if BLACK_PARTS else set()

    # Textures
    formats = {}
    for skin in skins:
        for slot in ("df", "il"):
            written = compact_texture(MOD / "assets" / f"{skin[slot]}.texture")
            formats[written] = formats.get(written, 0) + 1
    # One 4x4 DXT1 block: both endpoints black, every index on color0.
    (MOD / "assets" / f"{BLACK}.texture").write_bytes(dds_header(4, 4, b"DXT1", 8) + bytes(8))

    # Material configs. Parts whose configs come out byte-identical share one file.
    MATERIALS.mkdir(parents=True, exist_ok=True)
    for old in MATERIALS.glob("*.material_config"):
        old.unlink()
    files = {}          # content -> config name
    retexture = {}      # config name -> (animated names, static names using the skin's base)
    mapping = []
    registered = {skin[slot] for skin in skins for slot in ("df", "il")} | {BLACK}
    for name, (vanilla, group, *materials) in sorted(zip(names, parts)):
        root = ET.Element("materials", version="3")
        if group != "-":
            root.set("group", group)
        black = vanilla in black_parts
        for ref in materials:
            if ref in animated:
                root.append(black_material(ref) if black else animated_material(ref, animated[ref], default))
            else:
                root.append(static_material(static[ref], default))
        # The engine shares one material instance between every unit wearing the same config, so
        # without this a part fitted to both weapons (a suppressor, a sight) would show whichever
        # skin the tuner wrote last on both. Vanilla's _cc configs mark their materials unique for
        # the same reason: weapon skins are painted per weapon.
        for material in root:
            material.set("unique", "true")
        ET.indent(root, "\t")
        # A config naming a mod texture that main.xml does not register would point the renderer at
        # a texture that is not there.
        for element in root.iter():
            texture = element.get("file", "")
            if texture.startswith("units/mods/") and texture not in registered:
                sys.exit(f"{vanilla}: references unregistered texture {texture}")
        content = ET.tostring(root, encoding="unicode") + "\n"
        config = files.setdefault(content, name)
        mapping.append((vanilla, config))
        retexture[config] = (
            sorted({ref for ref in materials if ref in animated and not black}),
            sorted({static[ref].get("name") for ref in materials if ref in static and retexturable(static[ref])}),
        )
    for content, name in files.items():
        (MATERIALS / f"{name}.material_config").write_text(content, newline="\n")

    (MOD / "material_configs.txt").write_text("".join(f"{vanilla} {config}\n" for vanilla, config in mapping), newline="\n")

    # skin_materials.txt: "<config> <animated name>:<u>,<v> ... | <static name> ...", one line per config.
    # The tuner only retextures the materials listed for the config a unit is wearing, so a name that
    # is animated in one part and an effect shader in another can never be mixed up.
    lines = []
    for config in sorted(retexture):
        anim, base_only = retexture[config]
        dirs = [f"{ref}:{number(DIRECTIONS[animated[ref]][0])},{number(DIRECTIONS[animated[ref]][1])}" for ref in anim]
        lines.append(" ".join([config, *dirs, "|", *base_only]))
    (MOD / "skin_materials.txt").write_text("\n".join(lines) + "\n", newline="\n")

    (MOD / "variants.json").write_text(json.dumps({
        "mod": "AnimSkins",
        "default": DEFAULT_SKIN,
        "baked": {"glow": GLOW_MULTIPLIER, "bloom": GLOW_BLOOM, "speed": SCROLL_SPEED},
        "skins": [{"id": s["id"], "name": s["name"], "base": s["df"], "glow": s["il"]} for s in skins],
    }, indent=2) + "\n", newline="\n")

    # load="true": BeardLib loads every file into the dynamic resource package at startup, so the
    # configs are resident before a weapon is swapped and every skin is resident before the tuner
    # switches to it. Without it the files would only be added to the database.
    xml = ['<table name="AnimSkins">', '\t<AddFiles directory="assets" load="true">']
    xml += [f'\t\t<texture path="{skin[slot]}" force="true"/>' for skin in skins for slot in ("df", "il")]
    xml += [f'\t\t<texture path="{BLACK}" force="true"/>']
    xml += [f'\t\t<material_config path="{NAMESPACE}/materials/{name}"/>' for name in sorted(files.values())]
    xml += ["\t</AddFiles>", "</table>", ""]
    (MOD / "main.xml").write_text("\n".join(xml), newline="\n")

    print(f"{len(skins)} skins ({', '.join(f'{n} {f}' for f, n in sorted(formats.items()))} textures), default {DEFAULT_SKIN}")
    print(f"{len(black_parts & {fields[0] for fields in parts})} parts black")
    print(f"{len(parts)} parts in {len(files)} material configs, {len(animated)} animated materials, {len(static)} static materials")

    if args.install:
        install(None if args.install is AUTO else args.install)
    if args.pack:
        pack()


if __name__ == "__main__":
    main()

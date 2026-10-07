"""Material shaders for the HD Ground mod: the game's terrain shaders, ported
from your shader dump and given the texture pack's normal, height and ORM maps.

The terrain shaders draw the ground in layers (frost, mud, snow...), one pass
per layer, each with the layer's texture in fetch constant 0. For each one
found in the dump this:

1. ports it with tools/xenos_to_hlsl.py - a faithful HLSL copy, so everything
   the maps don't touch renders exactly as before;
2. splices in calls to hd_ground/hd_ground_terrain.hlsli: the maps' frame and
   parallax at the start, the layer's coordinates moved by parallax, the
   game's normal map texel replaced by the pack's normal (along the game's own
   tangent vectors, traced through the microcode - see normal_frame), the sun
   shadow kept for the highlights, and at the end the highlights from each of
   the shader's lights and the layer's height for blending the layers by
   height (the SDK's layer blending - XeLayerBlend in xenos_d3d12.hlsli);
3. builds it (FXC, via tools/build_material_shaders.py) into the mod.

The output is derived from the game's shaders, like the textures are from its
textures: it's written into the mod on your machine only.

Making a shader dump: run the game once with --dump_shaders=shader_dump and
walk the snowy streets; the dump lands next to the executable.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
import xenos_to_hlsl  # noqa: E402

TERRAIN_INCLUDE = Path(__file__).with_name("hd_ground") / "hd_ground_terrain.hlsli"

# The terrain shaders that draw the ground layers - from the game's log with
# the pack installed ("Texture ... (with maps) is drawn by pixel shader ...").
# By feature: the sun only, or up to four nearby lights with a local shadow
# map; and with or without the far-away blend into a large-scale texture.
TERRAIN_SHADERS = (
    "4755A2E4A05BA678",  # sun
    "AF1E16EE57E4BB06",  # two lights
    "578342593A37DD35",  # four lights
    "9C2144E42E95A76F",  # sun, far blend
    "45243B758F9272AB",  # lights, far blend
    "04F23292B2F44077",  # lights, far blend
)

# The shader options the mod declares (options.toml), read by
# hd_ground_terrain.hlsli at these slots.
OPTIONS = (
    dict(id="hd_ground_enabled", slot=23, default=1.0, type="checkbox", label="Use the maps",
         description="Normal, height and ORM maps on the HD ground"),
    dict(id="hd_ground_normal", slot=16, default=1.0, min=0.0, max=3.0, label="Normal strength",
         description="How strongly the normal map shapes the lighting"),
    dict(id="hd_ground_parallax", slot=17, default=0.006, min=0.0, max=0.03,
         label="Parallax depth",
         description="How far the stones stand out (in texture repeats, 0 = off)"),
    dict(id="hd_ground_specular", slot=18, default=1.0, min=0.0, max=4.0, label="Highlights",
         description="Highlights from the sun and fires"),
    dict(id="hd_ground_roughness", slot=19, default=1.0, min=0.3, max=2.0, label="Roughness",
         description="Scales the roughness map (lower = shinier)"),
    dict(id="hd_ground_height_blend", slot=20, default=6.0, min=0.0, max=16.0,
         label="Height blending",
         description="Where layers meet, the higher one shows: snow fills the joints, the "
                     "stones poke through (0 = the game's blending)"),
)

FETCH = re.compile(r"^(?P<indent>\s*)xe_f = XeTextureFetch2D\((?P<fetch>\d+)u, (?P<sampler>\d+)u, "
                   r"\d+u, \d+u, 0x[0-9A-Fa-f]+u, (?P<coords>[^,]+), ")
DEFINE = re.compile(r"^#define c(\d+) ", re.MULTILINE)


class TerrainError(Exception):
    pass


# The microcode the port lists in its comments: "// 12: mad r9.xy__, r9.yxxx, ...".
INSTRUCTION = re.compile(r"^\s*// \d+: (?P<op>\w+) (?P<operands>.*)$")
OPERAND = re.compile(r"^-?(?:r_abs\[(?P<abs>\d+)\]|r(?P<reg>\d+))\.(?P<swizzle>[xyzw_01]+)$")


def normal_frame(hlsl):
    """The interpolators the game turns its normal map texel into a normal
    with: (the one texel x is along, the one texel y is along).

    The terrain shaders decode the texel (* 2 - 1, in whichever register
    components) and add each component times a tangent vector from the vertex
    shader - which vectors, and which way they point relative to the texture,
    varies by shader. This follows the texel through the microcode to the
    vectors it multiplies; they must still be untouched interpolators."""
    texel = {}     # (register, component) -> "x" / "y": the texel's raw components
    decoded = {}   # (register, component) -> "x" / "y": decoded, ready to multiply
    written = set()
    frame = {}
    for line in hlsl.split("\n"):
        match = INSTRUCTION.match(line)
        if not match:
            continue
        op = match["op"]
        operands = [operand.strip() for operand in match["operands"].split(",")]
        destination = OPERAND.match(operands[0])
        sources = [OPERAND.match(operand) for operand in operands[1:]]
        if op == "tfetch2D" and operands[2] == "tf2" and destination:
            register = int(destination["reg"])
            for component, letter in zip("xyzw", destination["swizzle"]):
                if letter in "xy":
                    texel[(register, component)] = letter
            written.add(register)
            continue
        # Reads, before this instruction's write.
        if op in ("mul", "mad") and len(sources) >= 2 and all(sources[:2]):
            for this, other in ((sources[0], sources[1]), (sources[1], sources[0])):
                swizzle = this["swizzle"]
                if not this["reg"] or len(set(swizzle)) != 1:
                    continue
                letter = decoded.get((int(this["reg"]), swizzle[0]))
                if letter and other["reg"] and letter not in frame:
                    vector = int(other["reg"])
                    if vector in written:
                        raise TerrainError(f"the normal map's tangent r{vector} isn't an "
                                           "interpolator")
                    frame[letter] = vector
        new_decoded = {}
        # A scalar times the decoded components (blending them with another
        # normal - the far-away blend): still the same components.
        if (op in ("mul", "mad") and destination and destination["reg"] and
                len(sources) >= 2 and all(sources[:2])):
            for scale, value in ((sources[0], sources[1]), (sources[1], sources[0])):
                if not value["reg"] or len(set(scale["swizzle"])) != 1:
                    continue
                if scale["reg"] and (int(scale["reg"]), scale["swizzle"][0]) in decoded:
                    continue
                for component, mask, letter in zip("xyzw", destination["swizzle"],
                                                   value["swizzle"]):
                    symbol = decoded.get((int(value["reg"]), letter))
                    if mask != "_" and symbol:
                        new_decoded[(int(destination["reg"]), component)] = symbol
        if (op == "mad" and destination and destination["reg"] and sources[0] and
                sources[0]["reg"] and len(operands) == 4 and
                all(operand.lstrip("-").startswith("c") for operand in operands[2:])):
            source = int(sources[0]["reg"])
            for component, mask, letter in zip("xyzw", destination["swizzle"],
                                               sources[0]["swizzle"]):
                if mask != "_" and (source, letter) in texel:
                    new_decoded[(int(destination["reg"]), component)] = texel[(source, letter)]
        if destination and destination["reg"]:
            register = int(destination["reg"])
            for component, mask in zip("xyzw", destination["swizzle"]):
                if mask != "_" and len(destination["swizzle"]) == 4:
                    texel.pop((register, component), None)
                    decoded.pop((register, component), None)
                    written.add(register)
        decoded.update(new_decoded)
        if len(frame) == 2:
            return frame["x"], frame["y"]
    raise TerrainError("can't follow the normal map texel to its tangent vectors")


def find_dump(folders, shader_hash):
    """The dump folder holding a shader: its microcode and the bindings of its
    Direct3D 12 translations."""
    for folder in map(Path, folders):
        if ((folder / f"shader_{shader_hash}.ucode.frag").is_file() and
                any(folder.glob(f"shader_{shader_hash}_*.d3d12_rtv.bindings.txt"))):
            return folder
    return None


def transform(hlsl):
    """Splices the HD Ground calls into a port of a terrain shader."""
    lines = hlsl.split("\n")
    fetches = {}
    for index, line in enumerate(lines):
        match = FETCH.match(line)
        if match:
            fetches.setdefault(int(match["fetch"]), []).append((index, match))
    if 0 not in fetches or 2 not in fetches:
        raise TerrainError("no layer texture (tf0) and normal map (tf2) fetches")
    layer = fetches[0][0][1]
    coords = layer["coords"]
    uv = re.fullmatch(r"r(\d+)\.([xyzw]{2})", coords)
    position = re.search(r"-r(\d+)\.[xyzw]+ \+ c19\.[xyzw]+", hlsl)
    if not uv or not position:
        raise TerrainError("can't find the layer's coordinates or the world position")
    defined = {int(number) for number in DEFINE.findall(hlsl)}
    if 20 not in defined:
        raise TerrainError("no output scale (c20)")

    insert_after = {}   # line index -> lines
    insert_before = {}
    for fetch in (0, 2):
        for index, match in fetches[fetch]:
            if match["coords"] != coords:
                raise TerrainError(f"tf{fetch} isn't sampled at the layer's coordinates")
            lines[index] = lines[index].replace(f", {coords}, ", ", hd.uv, ", 1)
    for index, match in fetches[2]:
        insert_after[index] = [f"{match['indent']}xe_f = HdNormalTexel(xe_f, hd);"]
    for index, match in fetches.get(8, []):
        insert_after[index] = [f"{match['indent']}hd.sun_shadow = xe_f.x;"]

    frame_x, frame_y = normal_frame(hlsl)
    setup = [
        "",
        "  // HD Ground: the layer texture's maps (fetch constant 0).",
        f"  HdGround hd = HdGroundSetup(xe_input.interpolator{uv[1]}.{uv[2]}, "
        f"xe_input.interpolator{position[1]}.xyz, c19.xyz, {layer['sampler']}u, "
        f"xe_input.interpolator{frame_x}.xyz, xe_input.interpolator{frame_y}.xyz);",
    ]
    declarations = next((i for i, line in enumerate(lines) if line.strip() == "int xe_a0 = 0;"),
                        None)
    if declarations is None:
        raise TerrainError("unexpected port layout (no register declarations)")
    insert_after[declarations] = setup

    # Highlights from each light the shader takes, faded like the game fades
    # it. Light i: position or direction in c80 + i, color in c87 + i, and
    # component i of: whether it falls off (c94), 1 / radius (c96), spot cosine
    # (c105) and scale (c107), sun shadow strength (c112); spot direction in
    # c98 + i. Shaders without those take the light as is (the sun).
    highlights = []
    for light in range(4):
        if 80 + light not in defined or 87 + light not in defined:
            continue
        component = "xyzw"[light]
        position = f"c{80 + light}"
        falloff = f"c94.{component}" if 94 in defined else f"{position}.w"
        radius = f"c96.{component}" if 96 in defined else "0.0"
        if {98 + light, 105, 107} <= defined:
            spot = f"c{98 + light}.xyz, c105.{component}, c107.{component}"
        else:
            spot = "0.0.xxx, 0.0, 0.0"
        shadowing = (f"c112.{component}" if 112 in defined
                     else f"({position}.w < 0.5 ? 1.0 : 0.0)")
        highlights.append(f"    hd_specular += HdLightSpecular(hd, {position}, c{87 + light}.rgb, "
                          f"{falloff}, {radius}, {spot}, {shadowing});")
    epilogue = next((i for i, line in enumerate(lines) if line.strip() == "// Epilogue."), None)
    if epilogue is None:
        raise TerrainError("unexpected port layout (no epilogue)")
    insert_before[epilogue] = [
        "  // HD Ground: highlights from the shader's lights.",
        "  {",
        "    float3 hd_specular = 0.0;",
        *highlights,
        "    xe_color0.rgb += hd_specular * HdSpecularScale(hd) * c20.w;",
        "  }",
        "",
    ]

    # Height blending: the layer's share by its height, normalized with the
    # other layers' by the SDK - after the color output, with a second output.
    output = next((i for i, line in enumerate(lines)
                   if line.strip() == "xe_out_color0 = XeColorOutput(xe_color0, 0u);"), None)
    if output is None:
        raise TerrainError("unexpected port layout (no color output)")
    insert_after[output] = [
        "  XeLayerBlend(xe_out_color0, xe_out_color1, HdLayerFactor(hd), xe_input.position.xy);"]

    out = []
    for index, line in enumerate(lines):
        out.extend(insert_before.get(index, []))
        out.append(line)
        out.extend(insert_after.get(index, []))
    text = "\n".join(out)
    target = "out float4 xe_out_color0 : SV_Target0"
    if text.count(target) != 2:
        raise TerrainError("unexpected port layout (no color output declarations)")
    text = text.replace(target, target + ",\n          out float4 xe_out_color1 : SV_Target1")
    include = '#include "../include/xenos_d3d12.hlsli"'
    if include not in text:
        raise TerrainError("unexpected port layout (no xenos_d3d12.hlsli include)")
    return text.replace(include, "#define XE_LAYER_BLENDING 1\n" + include +
                        '\n#include "../include/hd_ground_terrain.hlsli"', 1)


def options_toml():
    lines = ["# HD Ground's shader options (F6 > Shader Options).", ""]
    for option in OPTIONS:
        lines.append("[[option]]")
        for key in ("id", "slot", "default", "label", "group", "type", "min", "max",
                     "description"):
            value = "HD Ground" if key == "group" else option.get(key)
            if value is None:
                continue
            lines.append(f'{key} = "{value}"' if isinstance(value, str) else f"{key} = {value}")
        lines.append("")
    return "\n".join(lines)


def build(dump_folders, materials, fxc="fxc"):
    """Ports, transforms and builds the terrain shaders found in the dumps into
    <mod>/materials/d3d12, and writes the options. Returns the shaders built."""
    built = []
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        (work / "include").mkdir()
        for include in (ROOT / "materials" / "include").glob("*.hlsli"):
            shutil.copy(include, work / "include")
        shutil.copy(TERRAIN_INCLUDE, work / "include")
        (work / "src").mkdir()
        for shader_hash in TERRAIN_SHADERS:
            folder = find_dump(dump_folders, shader_hash)
            if not folder:
                print(f"  {shader_hash}: not in the shader dump, skipped")
                continue
            try:
                port = xenos_to_hlsl.generate(folder, shader_hash)
                with open(work / "src" / f"{shader_hash}.hlsl", "w", newline="\n") as file:
                    file.write(transform(port))
                built.append(shader_hash)
            except (xenos_to_hlsl.ConvertError, TerrainError) as error:
                print(f"  {shader_hash}: {error}, skipped")
        if not built:
            return built
        output = Path(materials) / "d3d12"
        result = subprocess.run([sys.executable, str(TOOLS / "build_material_shaders.py"),
                                 "--fxc", fxc, "--sources", str(work / "src"),
                                 "--output", str(output)], capture_output=True, text=True)
        if result.returncode:
            print(result.stdout + result.stderr, file=sys.stderr)
            raise TerrainError("building the terrain shaders failed")
    (Path(materials) / "options.toml").write_text(options_toml(), encoding="utf-8")
    return built

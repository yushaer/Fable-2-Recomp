# Mods and texture packs

Mods change the game without touching its files: replacement textures (and the
maps material shaders use with them), material shaders, lights, and
replacement game files. A mod is a folder in `mods/` next to `fable_2.exe`.

- [A mod](#a-mod)
- [Texture packs](#texture-packs)
- [Material shaders, options and textures](#material-shaders-options-and-textures)
- [Reloading while the game runs](#reloading-while-the-game-runs)

## A mod

```
mods/
  My Mod/
    mod.toml      optional: name, author, version, description, priority
    files/        game files, laid over the game's own (same paths as in data/)
    textures/     replacement textures and their maps
    materials/    material shaders (d3d12/), lights.toml, options.toml, textures.toml
```

A folder with any of `files/`, `textures/` or `materials/` is a mod even
without a `mod.toml`. The manifest gives it a name and a priority:

```toml
[mod]
name = "HD Ground"
author = "You"
version = "1.0"
description = "The snowy streets' cobblestones at 4K"
priority = 10      # higher wins when two mods replace the same thing
```

**F6 → Mods** lists the mods, turns them on and off (saved in `mods_disabled`)
and reloads them. The cvars: `mods` (load mods at all), `mods_path` (default
`mods`), `mods_disabled` (folder names, comma-separated), and the command
`mods_reload`.

## Texture packs

### Finding a texture

**F6 → Mods → Dump textures for modding** writes every texture the game uses
from then on to `texture_dump/<HASH>.png` next to the executable - walk around
where the textures you want to replace are, then turn it off again. The name is
a hash of the texture's contents: the same in every run and on every machine,
so a pack works for everyone. (The cvar is `dump_textures`.)

### Replacing it

Put an image named after the hash in a mod's `textures/` folder: `<HASH>.png`,
or with notes after the hash, like `3D775A3269360513_cobblestones.png`.

- **Formats:** PNG, JPG, TGA and BMP (mipmaps are generated); DDS in BC1-BC5,
  BC7 or RGBA8/BGRA8 (its own mipmaps are used, so it loads faster and takes
  less video memory - BC7 is a quarter of RGBA8).
- **Size:** any - a 512×512 original can become 4096×4096. Keep the aspect
  ratio; the game samples it with the same coordinates, filtering and channels
  as the original, so draw it the way the dump looks.
- `textures/` next to the executable works too, without a mod.

`texture_replacement` turns replacement off; replacing the textures of a
running game takes `mods_reload`.

### Maps for material shaders

Next to a texture, maps with the same name plus a suffix:

| Suffix | Contents |
|---|---|
| `_normal` | Tangent-space normal map, DirectX convention (green points down the image) |
| `_orm` | R occlusion, G roughness, B metalness |
| `_height` | Height, 0 (low) to 1 (high), for parallax |
| `_emissive` | Light the surface gives off (RGB) |

e.g. `3D775A3269360513_cobblestones_normal.png`. The game loads them with the
texture and hands them to material shaders, which sample them with
`XeSampleCompanion` (`materials/include/xenos_d3d12.hlsli`) - shaders opt in;
the built-in ones don't use them yet.

### Example: HD Ground

```
python tools/textures/make_hd_ground.py
```

makes `mods/HD Ground`: the snowy streets' cobblestones and snow at 4096×4096,
with normal, height and ORM maps. It needs numpy, opencv-python and pillow
(scipy makes it faster), and the three textures in `texture_dump/` (dump them
in the opening's streets first). The stones are drawn procedurally on the
original's fan layout and scale, with its colors - the header explains why
upscaling doesn't work for a texture like this. Its output derives from the
game's textures, so keep it on your machine.

## Material shaders, options and textures

A mod's `materials/d3d12/<HASH>_<MODIFICATION>.dxbc` replaces that shader
translation like the built-in ones do (see [materials/README.md](../materials/README.md)
for writing one); the highest-priority mod wins, then the built-in shaders.

### options.toml - settings in the menu

```toml
[[option]]
id = "grass_sheen"      # unique name
slot = 3                # 0-31: the shader reads XeMaterialOption(3)
default = 1.0
label = "Grass sheen"   # shown in F6 -> Shader Options
group = "Grass"
type = "slider"         # or "checkbox" (0 or 1)
min = 0.0
max = 2.0
description = "How much the grass catches the light"
```

Values changed in the menu are kept in the `material_options` cvar.

### textures.toml - extra textures for shaders

```toml
[[texture]]
slot = 0                       # 0-7: XeSampleCustomTexture(0, uv, mip) in the shader
file = "noise/blue_noise.png"  # relative to this materials folder
```

For noise, ramps, lookup tables - anything a shader needs that the game
doesn't have.

### lights.toml - lights for the dynamic lighting

Says where a lit shader keeps its light constants, so the dynamic lights
(`scene_fx_dynamic_lights`) and fire effects can pick its lights up. See
[materials/lights.toml](../materials/lights.toml) for the format.

## Reloading while the game runs

| What | How |
|---|---|
| Textures and their maps | F6 → Mods → Reload mods (`mods_reload`) |
| Material shaders, options, custom textures, lights | F6 → Materials → Reload from disk (`material_shaders_reload`) |
| Game files (`files/`) | Restart the game |

"""Example texture pack: the snowy streets' cobblestones and snow, remade at 4K.

    python tools/textures/make_hd_ground.py [--size 4096] [--exe <exe folder>]
                                            [--preview preview.png]

Reads three ground textures from the game's texture dump (F6 > Mods > "Dump
textures for modding", then walk the snowy streets of the opening), and writes
the mod "<exe>/mods/HD Ground": for each texture an albedo and its normal, height
and ORM (occlusion, roughness, metalness) maps.

A 512x512 cobblestone texture holds about 20 texels per stone, too little for an
upscaler (AI or not) to recover - so the stones are re-drawn instead: a tileable
fan ("Segmentbogen") pattern at the original's scale, every stone with its own
shape, chips, bevel, tilt and granite grain, and frost or mud settling in the
joints. The original texture provides the colors and where the frost and mud
patches lie. The two cobblestone layers share one stone layout, so where the game
blends them the street just turns muddy.

The output derives from the game's textures: keep it on your machine - never
commit or share it.
"""
import argparse
import math
import time
from pathlib import Path

import numpy as np

import texkit as tk

FROSTY = "3D775A3269360513"
MUDDY = "FFAF7B1A7F0F20B7"
SNOW = "91197293A4B801C9"

# The originals' scale: about 22 stones across (their spectra, and side by side in
# game), 2 fans across.
STONES_ACROSS = 22
FANS_ACROSS = 2
LAYOUT_SEED = 7
# How much of the ambient occlusion to bake into the albedo (0..1).
BAKED_OCCLUSION = 0.6

# Stone colors (with how common each is), joint color and what covers the street.
RECIPES = {
    FROSTY: dict(
        name="hd_frosty_cobbles",
        stones=[((0.40, 0.35, 0.29), 0.42), ((0.33, 0.28, 0.22), 0.24),
                ((0.46, 0.34, 0.27), 0.12), ((0.43, 0.42, 0.40), 0.22)],
        joint=(0.66, 0.66, 0.65),
        cover="frost",
        cover_color=(0.86, 0.88, 0.91),
    ),
    MUDDY: dict(
        name="hd_muddy_cobbles",
        stones=[((0.40, 0.40, 0.38), 0.42), ((0.30, 0.30, 0.29), 0.24),
                ((0.48, 0.35, 0.27), 0.14), ((0.42, 0.36, 0.28), 0.20)],
        joint=(0.31, 0.24, 0.14),
        cover="mud",
        cover_color=(0.30, 0.23, 0.13),
    ),
}


class FanLayout:
    """Cobblestones laid in fans: fish scales (circles touching in their row, the
    rows half a circle apart and staggered), each a set of arcs around its center;
    lower rows overlap the ones above. Tiles with the texture."""

    def __init__(self, size, fans_across, stones_across, seed):
        self.size = size
        self.width = size / fans_across
        self.row_height = self.width / 2
        self.rows = int(round(size / self.row_height))
        self.radius = self.width / 2
        self.pitch = size / stones_across
        self.fans_across = fans_across
        self.seed = seed

    def _row_center(self, row, x):
        offset = np.mod(row, 2) * (self.width / 2)
        column = np.round((x - offset) / self.width)
        return column, column * self.width + offset, row * self.row_height

    def evaluate(self, x, y, gap):
        """Per texel: signed distance to the nearest stone's edge (texels, negative
        inside), the stone's id hash and the texel's position on the stone (in
        pitches, across and along the arc)."""
        w, r_fan = self.width, self.radius
        base_row = np.floor(y / self.row_height)
        fan_col = np.zeros_like(x)
        fan_row = np.zeros_like(x)
        cx = np.zeros_like(x)
        cy = np.zeros_like(x)
        dist = np.full_like(x, np.inf)
        found = np.zeros(x.shape, bool)
        # The front-most (lowest) fan containing the texel.
        for dr in (-1, 0, 1, 2):
            row = base_row + dr
            column, ccx, ccy = self._row_center(row, x)
            d = np.hypot(x - ccx, y - ccy)
            inside = d < r_fan
            fan_col = np.where(inside, column, fan_col)
            fan_row = np.where(inside, row, fan_row)
            cx = np.where(inside, ccx, cx)
            cy = np.where(inside, ccy, cy)
            dist = np.where(inside, d, dist)
            found |= inside
        # Distance to the fan's visible edge: its own rim, or a front fan's rim.
        edge = r_fan - dist
        for fx, fy in ((-w / 2, self.row_height), (w / 2, self.row_height), (0.0, 2 * self.row_height)):
            edge = np.minimum(edge, np.hypot(x - (cx + fx), y - (cy + fy)) - r_fan)

        # The arcs bow around a point low in the fan, hidden by the fans in front
        # (round its own center they'd close into rings).
        pitch = self.pitch
        ay = cy + 0.85 * r_fan
        arc = np.hypot(x - cx, y - ay)
        ring = np.floor(arc / pitch)
        ring_mid = (ring + 0.5) * pitch
        count = np.maximum(1.0, np.round(2 * math.pi * ring_mid / pitch))
        fan_id = (np.mod(fan_col, self.fans_across).astype(np.int64),
                  np.mod(fan_row, self.rows).astype(np.int64))
        ring_hash = tk.hash_ints(self.seed, *fan_id, ring.astype(np.int64))
        phase = tk.hash_random(ring_hash, 0)
        angle = np.mod(np.arctan2(ay - y, x - cx), 2 * math.pi)
        t = angle / (2 * math.pi) * count + phase
        index = np.floor(t)
        stone = tk.hash_ints(ring_hash, np.mod(index, count).astype(np.int64))
        u = (t - index - 0.5) * (2 * math.pi * arc / count)
        v = arc - ring_mid

        # Each stone a little off-center, turned and smaller.
        ou = (tk.hash_random(stone, 10) - 0.5) * 0.08 * pitch
        ov = (tk.hash_random(stone, 11) - 0.5) * 0.08 * pitch
        turn = (tk.hash_random(stone, 12) - 0.5) * 0.18
        shrink = tk.hash_random(stone, 13) * 0.06 * pitch
        c, s = np.cos(turn), np.sin(turn)
        su = (u - ou) * c + (v - ov) * s
        sv = -(u - ou) * s + (v - ov) * c
        half_u = math.pi * ring_mid / count - gap / 2 - shrink
        half_v = pitch / 2 - gap / 2 - shrink
        corner = np.maximum(0.28 * np.minimum(half_u, half_v), 1.0)
        qu = np.abs(su) - half_u + corner
        qv = np.abs(sv) - half_v + corner
        sdf = (np.hypot(np.maximum(qu, 0), np.maximum(qv, 0)) +
               np.minimum(np.maximum(qu, qv), 0) - corner)
        sdf = np.maximum(sdf, gap / 2 - edge)
        sdf = np.where(found, sdf, gap)
        return sdf, stone, su / pitch, sv / pitch


class Noises:
    """The tileable noise fields the materials are made of, scaled to the stones."""

    def __init__(self, size, pitch, seed):
        p = pitch
        bands = dict(
            edge=(p / 4, p), edge_fine=(p / 16, p / 6), fine=(1.5, 6), mid=(6, p / 4),
            grit=(1.2, 4), large=(p * 0.8, p * 4), chip=(p / 8, p / 3), speck_dark=(1.5, 3.5),
            speck_light=(1.5, 3.5), mid2=(8, p / 3), patch=(p * 0.5, p * 2))
        self.fields = {}
        for i, (name, (lo, hi)) in enumerate(bands.items()):
            self.fields[name] = tk.band_noise(size, max(lo, 1.2), max(hi, lo * 1.5), seed * 100 + i)

    def rows(self, y0, y1):
        return {name: field[y0:y1] for name, field in self.fields.items()}


def regional_fields(original, size, pitch_src):
    """From the original texture: its broad color, and its brightness and detail
    (as z-scores), enlarged to the output size."""
    clean = tk.wrap_denoise(original).astype(np.float32) / 255.0
    regional = tk.wrap_blur(clean, 0.6 * pitch_src)
    lum = tk.luminance(regional)
    brightness = (lum - lum.mean()) / max(float(lum.std()), 1e-6)
    detail_lum = tk.luminance(clean)
    high = detail_lum - tk.wrap_blur(detail_lum, 1.2)
    energy = np.log(tk.wrap_blur(high * high, 0.8 * pitch_src) + 1e-6)
    detail = (energy - energy.mean()) / max(float(energy.std()), 1e-6)
    return (tk.wrap_resize(regional, size), tk.wrap_resize(brightness.astype(np.float32), size),
            tk.wrap_resize(detail.astype(np.float32), size), clean)


CHUNK = 256  # rows at a time


def match_colors(albedo, original):
    """Gives the albedo the original's color and contrast: per channel, its mean
    and its spread at the original's resolution (the finer detail comes along at
    the same scale)."""
    import cv2
    target = original.astype(np.float32) / 255.0
    target_mean = target.reshape(-1, 3).mean(0)
    target_std = target.reshape(-1, 3).std(0)
    for _ in range(2):  # again after clipping
        small = cv2.resize(albedo, original.shape[1::-1], interpolation=cv2.INTER_AREA)
        mean = albedo.reshape(-1, 3).mean(0)
        scale = np.clip(target_std / np.maximum(small.reshape(-1, 3).std(0), 1e-4), 0.4, 1.5)
        albedo = np.clip((albedo - mean) * scale + target_mean, 0.0, 1.0)
    return albedo


def lay_stones(layout, noises, size):
    """The stones of the whole texture: each texel's signed distance to its stone's
    edge, the stone's id and the texel's place on it."""
    pitch = layout.pitch
    gap = 0.15 * pitch
    sdf = np.empty((size, size), np.float32)
    ids = np.empty((size, size), np.uint32)
    u = np.empty((size, size), np.float32)
    v = np.empty((size, size), np.float32)
    xs = np.arange(size, dtype=np.float32) + 0.5
    for y0 in range(0, size, CHUNK):
        y1 = min(size, y0 + CHUNK)
        y, x = np.meshgrid(np.arange(y0, y1, dtype=np.float32) + 0.5, xs, indexing="ij")
        n = noises.rows(y0, y1)
        d, ids[y0:y1], u[y0:y1], v[y0:y1] = layout.evaluate(x, y, gap)
        sdf[y0:y1] = d + n["edge"] * 0.03 * pitch + n["edge_fine"] * 0.008 * pitch
    # Drop the slivers where fans meet (anything thinner than 2 rho): an opening,
    # the distance to the stones' cores less rho.
    rho = 0.1 * pitch
    sdf = np.maximum(sdf, tk.wrap_distance(sdf < -rho, 3 * rho) - rho)
    return dict(sdf=sdf, id=ids, u=u, v=v)


def make_cobbles(original, recipe, size, layout, noises, stones):
    pitch = layout.pitch
    regional, brightness, detail, clean = regional_fields(original, size,
                                                          original.shape[0] / STONES_ACROSS)
    if recipe["cover"] == "frost":
        cover_amount = tk.smoothstep(-0.4, 1.6, brightness)
    else:
        cover_amount = tk.smoothstep(0.2, -1.6, detail)
    colors = np.array([c for c, _ in recipe["stones"]], np.float32)
    weights = np.array([w for _, w in recipe["stones"]], np.float32)
    cumulative = np.cumsum(weights / weights.sum())
    joint = np.array(recipe["joint"], np.float32)
    cover_color = np.array(recipe["cover_color"], np.float32)
    regional_tint = regional / regional.reshape(-1, 3).mean(0)

    albedo = np.empty((size, size, 3), np.float32)
    height = np.empty((size, size), np.float32)
    rough = np.empty((size, size), np.float32)
    for y0 in range(0, size, CHUNK):
        y1 = min(size, y0 + CHUNK)
        n = noises.rows(y0, y1)
        sdf = stones["sdf"][y0:y1]
        stone = stones["id"][y0:y1]
        su = stones["u"][y0:y1]
        sv = stones["v"][y0:y1]
        coverage = np.clip(0.5 - sdf, 0.0, 1.0)
        depth = np.maximum(-sdf, 0.0)
        b = np.clip(depth / (0.2 * pitch), 0.0, 1.0)
        bevel = 1.0 - (1.0 - b) ** 2
        crown = np.clip(depth / (0.5 * pitch), 0.0, 1.0)
        tilt = ((tk.hash_random(stone, 2) - 0.5) * su + (tk.hash_random(stone, 3) - 0.5) * sv) * 0.35
        chip = tk.smoothstep(1.0, 1.8, n["chip"]) * (1.0 - tk.smoothstep(0.0, 0.3 * pitch, depth))
        # The stones' shape, then their surface on top.
        shape = (0.15 + bevel * (0.55 + 0.25 * tk.hash_random(stone, 1)) + 0.12 * crown +
                 tilt * bevel)
        stone_height = shape + 0.035 * n["mid"] * bevel + 0.02 * n["fine"] - 0.3 * chip
        joint_height = 0.08 + 0.035 * n["grit"] + 0.03 * n["mid2"]
        h = joint_height + coverage * np.maximum(stone_height - joint_height, 0.0)
        smooth_h = 0.08 + coverage * np.maximum(shape - 0.08, 0.0)

        # Stones: a color each, granite grain and specks, dirt along the edges.
        pick = np.searchsorted(cumulative, tk.hash_random(stone, 4))
        stone_rgb = colors[np.minimum(pick, len(colors) - 1)]
        stone_rgb = stone_rgb * (1.0 + 0.24 * (tk.hash_random(stone, 5) - 0.5))[..., None]
        warm = (tk.hash_random(stone, 6) - 0.5) * 0.08
        stone_rgb = stone_rgb * np.stack([1 + warm, np.ones_like(warm), 1 - warm], -1)
        grain = (1.0 + 0.10 * n["fine"] + 0.06 * n["mid"] -
                 0.35 * tk.smoothstep(1.7, 2.3, n["speck_dark"]) +
                 0.30 * tk.smoothstep(1.9, 2.5, n["speck_light"]))
        stone_rgb = stone_rgb * (grain * (0.80 + 0.20 * bevel))[..., None]
        stone_rgb = stone_rgb + (stone_rgb * 0.25 + 0.03) * chip[..., None]
        joint_rgb = joint * (1.0 + 0.14 * n["grit"] + 0.08 * n["mid2"])[..., None]
        rgb = joint_rgb + (stone_rgb - joint_rgb) * coverage[..., None]
        r = 0.9 + (0.70 + 0.05 * n["mid"] - 0.14 * crown - 0.9) * coverage

        amount = cover_amount[y0:y1]
        if recipe["cover"] == "frost":
            # Frost fills the joints, and dusts the stones - more on their edges and
            # where the street is frostier - in crystals, never hiding them.
            joint_frost = np.clip(0.1 + 0.6 * amount + 0.2 * n["patch"], 0.0, 0.9)
            dust = (np.clip(amount * (0.45 + 0.2 * n["patch"]) + 0.2 * (1.0 - bevel), 0.0, 0.65) *
                    tk.smoothstep(-0.6, 1.2, n["fine"] + 0.6 * n["grit"]))
            mask = joint_frost + (dust - joint_frost) * coverage
            frost = cover_color * (1.0 + 0.05 * n["grit"])[..., None]
            rgb = rgb + (frost - rgb) * mask[..., None]
            h = h + 0.02 * mask * n["grit"]
            r = r + (0.45 - r) * mask
        else:
            # Mud fills the street up to a level; stones stand out of it, stained.
            # Its edge follows the stones' shape, not their grain.
            level = 0.10 + 0.5 * amount + 0.06 * n["patch"]
            mask = tk.smoothstep(-0.03, 0.03, level - smooth_h + 0.012 * n["mid2"])
            mud = cover_color * (1.0 + 0.12 * n["grit"] + 0.08 * n["mid2"])[..., None]
            stain = (0.25 * amount)[..., None]
            rgb = rgb + (cover_color - rgb) * stain * coverage[..., None]
            rgb = rgb + (mud - rgb) * mask[..., None]
            h = h + (level + 0.01 * n["grit"] - h) * mask
            r = r + (0.55 - 0.15 * tk.smoothstep(0.3, 0.8, amount) - r) * mask
        rgb = rgb * (1.0 + (regional_tint[y0:y1] - 1.0) * 0.3)
        albedo[y0:y1] = rgb
        height[y0:y1] = h
        rough[y0:y1] = r

    occlusion = (tk.cavity_occlusion(height, 0.08 * pitch, 3.0) *
                 tk.cavity_occlusion(height, 0.3 * pitch, 1.2))
    # Shading baked in like the original's, for shaders that don't use the maps.
    albedo *= (1.0 - BAKED_OCCLUSION + BAKED_OCCLUSION * occlusion)[..., None]
    albedo = match_colors(albedo, original)
    return dict(albedo=np.clip(albedo, 0, 1), height=np.clip(height, 0, 1),
                roughness=np.clip(rough, 0.05, 1), occlusion=occlusion,
                normal_strength=0.14 * pitch)


def make_snow(original, size, noises, pitch):
    clean = tk.wrap_denoise(original, 3).astype(np.float32) / 255.0
    base = tk.wrap_resize(tk.wrap_blur(clean, 0.7), size)
    f = noises.fields
    sparkle = tk.smoothstep(2.6, 3.2, f["speck_light"])
    grain = 1.0 + 0.02 * f["fine"] + 0.015 * f["grit"]
    albedo = base * grain[..., None] + 0.05 * sparkle[..., None]
    albedo = match_colors(albedo, original)
    lum = tk.luminance(base)
    height = (0.5 + 0.22 * f["large"] / 3 + 0.10 * f["mid"] / 3 + 0.04 * f["fine"] / 3 +
              1.5 * (lum - lum.mean()))
    occlusion = tk.cavity_occlusion(height, 0.1 * pitch, 2.0)
    roughness = 0.55 - 0.15 * sparkle + 0.05 * f["mid2"] / 3
    return dict(albedo=np.clip(albedo, 0, 1), height=np.clip(height, 0, 1),
                roughness=np.clip(roughness, 0.05, 1), occlusion=occlusion,
                normal_strength=0.05 * pitch)


def write_texture(folder, texture_hash, name, maps):
    base = Path(folder) / f"{texture_hash}_{name}"
    tk.save_png(f"{base}.png", maps["albedo"])
    tk.save_png(f"{base}_normal.png", tk.normal_map(maps["height"], maps["normal_strength"]))
    tk.save_png(f"{base}_height.png", maps["height"])
    tk.save_png(f"{base}_orm.png", tk.orm_map(maps["occlusion"], maps["roughness"]))


def preview(path, results, crop=1024):
    """Each texture: whole (scaled), a full-resolution corner, and that corner lit
    from the side by its normal map."""
    import cv2
    rows = []
    for maps in results:
        albedo = maps["albedo"]
        size = albedo.shape[0]
        c = min(crop, size)
        normal = tk.normal_map(maps["height"], maps["normal_strength"]).astype(np.float32) / 127.5 - 1
        light = np.array([-0.6, -0.5, 0.62], np.float32)
        light /= np.linalg.norm(light)
        lit = albedo * (0.25 + 0.75 * np.maximum((normal * light).sum(-1), 0) *
                        maps["occlusion"])[..., None]
        y0 = size // 3
        tiles = [cv2.resize(albedo, (c, c), interpolation=cv2.INTER_AREA),
                 albedo[y0:y0 + c, y0:y0 + c], lit[y0:y0 + c, y0:y0 + c]]
        rows.append(np.concatenate(tiles, 1))
    tk.save_png(path, np.concatenate(rows, 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--size", type=int, default=4096)
    parser.add_argument("--exe", type=Path, default=tk.default_exe_folder(),
                        help="the game's folder (with texture_dump/ and mods/)")
    parser.add_argument("--dump", type=Path, help="the texture dump (default <exe>/texture_dump)")
    parser.add_argument("--mod", type=Path, help='output mod (default <exe>/mods/HD Ground)')
    parser.add_argument("--preview", type=Path, help="also write a preview sheet here")
    args = parser.parse_args()
    dump = args.dump or args.exe / "texture_dump"
    mod = args.mod or args.exe / "mods" / "HD Ground"

    originals = {}
    for texture_hash in (FROSTY, MUDDY, SNOW):
        path = tk.find_dump(dump, texture_hash)
        if not path:
            raise SystemExit(f"{texture_hash} isn't in {dump} - dump the textures in the snowy "
                             "streets first (F6 > Mods > Dump textures for modding)")
        originals[texture_hash] = tk.load_rgb(path)

    start = time.time()
    layout = FanLayout(args.size, FANS_ACROSS, STONES_ACROSS, LAYOUT_SEED)
    noises = Noises(args.size, layout.pitch, LAYOUT_SEED)
    print(f"noise: {time.time() - start:.1f} s")
    textures = mod / "textures"
    stones = lay_stones(layout, noises, args.size)
    print(f"stones: {time.time() - start:.1f} s")
    results = []
    for texture_hash in (FROSTY, MUDDY):
        recipe = RECIPES[texture_hash]
        t = time.time()
        maps = make_cobbles(originals[texture_hash], recipe, args.size, layout, noises, stones)
        write_texture(textures, texture_hash, recipe["name"], maps)
        results.append(maps)
        print(f"{recipe['name']}: {time.time() - t:.1f} s")
    t = time.time()
    maps = make_snow(originals[SNOW], args.size, noises, layout.pitch)
    write_texture(textures, SNOW, "hd_snow", maps)
    results.append(maps)
    print(f"hd_snow: {time.time() - t:.1f} s")
    tk.write_mod_manifest(
        mod, "HD Ground", author="Fable 2 Recomp", version="1.0",
        description=f"The snowy streets' cobblestones and snow at {args.size}x{args.size}, "
                    "with normal, height and ORM maps",
        priority=10)
    if args.preview:
        preview(args.preview, results)
    print(f"wrote {mod}")


if __name__ == "__main__":
    main()

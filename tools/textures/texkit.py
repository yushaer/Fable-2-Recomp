"""Shared helpers for the texture tools: tileable noise and filters, material maps
(normal, height, ORM) and writing texture-pack mods.

Everything here works on tileable textures: blurs, resizes and gradients wrap
around the edges, so what they produce tiles too.

Needs numpy, opencv-python and pillow (scipy makes the noise faster).
"""
from pathlib import Path
import re

import cv2
import numpy as np
from PIL import Image

try:
    import scipy.fft as _fft

    def _rfft2(a):
        return _fft.rfft2(a, workers=-1)

    def _irfft2(a, shape):
        return _fft.irfft2(a, s=shape, workers=-1)
except ImportError:  # pragma: no cover - numpy fallback
    def _rfft2(a):
        return np.fft.rfft2(a)

    def _irfft2(a, shape):
        return np.fft.irfft2(a, s=shape).astype(np.float32)


HASH_NAME = re.compile(r"^([0-9A-Fa-f]{16})")


# --- Filters ----------------------------------------------------------------

def _wrap_pad(img, pad):
    return np.pad(img, ((pad, pad), (pad, pad)) + ((0, 0),) * (img.ndim - 2), mode="wrap")


def wrap_blur(img, sigma):
    """Gaussian blur that wraps around the edges."""
    if sigma <= 0:
        return img
    pad = min(int(sigma * 3.5) + 1, min(img.shape[:2]))
    out = cv2.GaussianBlur(_wrap_pad(img, pad), (0, 0), sigma)
    return out[pad:-pad, pad:-pad]


def wrap_resize(img, size, interpolation=cv2.INTER_CUBIC):
    """Resizes a tileable image to size x size, wrapping around the edges."""
    h, w = img.shape[:2]
    pad = 4
    scale_x, scale_y = size / w, size / h
    big = cv2.resize(_wrap_pad(img, pad), (int(round((w + 2 * pad) * scale_x)),
                                          int(round((h + 2 * pad) * scale_y))),
                     interpolation=interpolation)
    px, py = int(round(pad * scale_x)), int(round(pad * scale_y))
    return big[py:py + size, px:px + size]


def wrap_distance(mask, limit=None):
    """Each texel's distance to the nearest texel of the mask (0 on it), wrapping
    around the edges; limit = the farthest distance that needs to be right."""
    size = min(mask.shape[:2])
    pad = min(int(limit) + 2 if limit else size // 4, size)
    outside = np.ascontiguousarray(_wrap_pad((~mask).astype(np.uint8), pad))
    dist = cv2.distanceTransform(outside, cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    return dist[pad:-pad, pad:-pad]


def wrap_denoise(rgb8, strength=5):
    """Removes block compression noise (non-local means), wrapping around the edges."""
    pad = 24
    out = cv2.fastNlMeansDenoisingColored(_wrap_pad(rgb8, pad), None, strength, strength, 5, 15)
    return out[pad:-pad, pad:-pad]


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def luminance(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


# --- Noise ------------------------------------------------------------------

def band_noise(size, wavelength_min, wavelength_max, seed, slope=1.0):
    """Tileable noise of a size x size texture with features from wavelength_min to
    wavelength_max texels (a 1/f^slope spectrum in that band), mean 0, std 1."""
    rng = np.random.default_rng(seed)
    spectrum = _rfft2(rng.standard_normal((size, size), dtype=np.float32))
    fy = np.fft.fftfreq(size).astype(np.float32)[:, None]
    fx = np.fft.rfftfreq(size).astype(np.float32)[None, :]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    log_f = np.log(f)
    soft = 0.2
    weight = (np.power(f, -slope) /
              (1.0 + np.exp(-(log_f - np.log(1.0 / wavelength_max)) / soft)) /
              (1.0 + np.exp((log_f - np.log(1.0 / wavelength_min)) / soft)))
    weight[0, 0] = 0.0
    noise = _irfft2(spectrum * weight.astype(np.float32), (size, size)).astype(np.float32)
    return noise / max(float(noise.std()), 1e-8)


# --- Integer hashing (per-cell random numbers) ------------------------------

def hash_ints(*values):
    """A well-mixed uint32 hash of integer arrays (broadcast together)."""
    h = np.uint32(0x811C9DC5)
    with np.errstate(over="ignore"):
        for v in values:
            h = (h ^ np.asarray(v).astype(np.uint32)) * np.uint32(0x01000193)
            h ^= h >> np.uint32(15)
        h ^= h >> np.uint32(16)
        h *= np.uint32(0x85EBCA6B)
        h ^= h >> np.uint32(13)
        h *= np.uint32(0xC2B2AE35)
        h ^= h >> np.uint32(16)
    return h


def hash_random(h, channel):
    """A uniform [0, 1) number per hash, a different one for each channel."""
    return hash_ints(h, channel).astype(np.float64).astype(np.float32) / np.float32(4294967296.0)


# --- Material maps ----------------------------------------------------------

def normal_map(height, strength):
    """Tangent-space normal map (DirectX convention: green = +V, down the image)
    from a height field in [0, 1]; strength = the height range in texels."""
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * (0.5 * strength)
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * (0.5 * strength)
    n = np.stack([-dx, -dy, np.ones_like(height)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return to_u8(n * 0.5 + 0.5)


def cavity_occlusion(height, radius, strength):
    """Ambient occlusion from how far below its surroundings each texel is."""
    surroundings = wrap_blur(height, radius)
    return np.clip(1.0 - np.maximum(surroundings - height, 0.0) * strength, 0.0, 1.0)


def orm_map(occlusion, roughness, metalness=None):
    """Occlusion, roughness, metalness in R, G, B."""
    if metalness is None:
        metalness = np.zeros_like(occlusion)
    return to_u8(np.stack([occlusion, roughness, metalness], axis=-1))


# --- Files ------------------------------------------------------------------

def to_u8(img):
    return np.clip(img * 255.0 + 0.5, 0, 255).astype(np.uint8)


def load_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"))


def save_png(path, img):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if img.dtype != np.uint8:
        img = to_u8(img)
    Image.fromarray(img).save(path, compress_level=3)
    return path


def find_dump(dump_folder, texture_hash):
    """The dumped image of a texture (texture_dump/<HASH>[...].png)."""
    texture_hash = texture_hash.upper()
    for path in Path(dump_folder).glob(f"{texture_hash}*"):
        if path.suffix.lower() in (".png", ".dds", ".tga", ".jpg", ".bmp"):
            return path
    return None


def write_mod_manifest(folder, name, author="", version="1.0", description="", priority=0):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)

    def quote(text):
        return '"' + str(text).replace("\\", "\\\\").replace('"', '\\"') + '"'

    (folder / "mod.toml").write_text(
        "[mod]\n"
        f"name = {quote(name)}\n"
        f"author = {quote(author)}\n"
        f"version = {quote(version)}\n"
        f"description = {quote(description)}\n"
        f"priority = {int(priority)}\n", encoding="utf-8")


def default_exe_folder():
    root = Path(__file__).resolve().parents[2]
    for preset in ("win-amd64-release-profiling", "win-amd64-release", "win-amd64-relwithdebinfo",
                   "win-amd64-debug"):
        folder = root / "out" / "build" / preset
        if (folder / "texture_dump").is_dir() or (folder / "mods").is_dir():
            return folder
    return root / "out" / "build" / "win-amd64-release"

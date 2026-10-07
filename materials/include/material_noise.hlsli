// Procedural noise for the material shaders' animated effects.

#ifndef MATERIAL_NOISE_HLSLI_
#define MATERIAL_NOISE_HLSLI_

// A hash of a 2D point to [0, 1) (Dave Hoskins' hash without sine).
float NoiseHash12(float2 p) {
  float3 p3 = frac(p.xyx * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return frac((p3.x + p3.y) * p3.z);
}

// Smoothly interpolated value noise, [0, 1).
float ValueNoise(float2 p) {
  float2 cell = floor(p);
  float2 f = p - cell;
  float2 u = f * f * (3.0 - 2.0 * f);
  return lerp(lerp(NoiseHash12(cell), NoiseHash12(cell + float2(1.0, 0.0)), u.x),
              lerp(NoiseHash12(cell + float2(0.0, 1.0)), NoiseHash12(cell + float2(1.0, 1.0)), u.x),
              u.y);
}

// Two octaves of value noise, [0, 1).
float FractalNoise(float2 p) { return ValueNoise(p) * 0.65 + ValueNoise(p * 2.03 + 17.1) * 0.35; }

#endif  // MATERIAL_NOISE_HLSLI_

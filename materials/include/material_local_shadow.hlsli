// Shadow maps sampled by Fable II's lit materials themselves (rather than
// through the screen-space sun shadow mask): the nearby light's map (boolean
// constant 135), and in the forward-shadowed materials (for alpha-blended
// surfaces like hair) the sun's two cascades. Each is projected with four
// float constant rows - 0 and 1 the texture coordinates, 2 the depth, 3 w -
// and a point is lit if 1 - its depth isn't below what the map stores.
//
// The game filters 2x2 at point-sampled texels for the nearby light, and
// 5x5/2x2 for the cascades. The smooth filter here is a tent 3 or 5 texels
// wide - 4x4 or 6x6 texels from 4 or 9 gathers - with receiver plane depth
// bias, for soft edges without noise.

#ifndef MATERIAL_LOCAL_SHADOW_HLSLI_
#define MATERIAL_LOCAL_SHADOW_HLSLI_

struct LocalShadowMap {
  uint fetch;
  uint sampler_slot;
  uint srv_unsigned_slot;
  uint srv_signed_slot;
  // The texel size the game filters with (c48 for the nearby light's map).
  float2 texel_size;
};

LocalShadowMap MakeShadowMap(uint fetch, uint sampler_slot, uint srv_unsigned_slot,
                             uint srv_signed_slot, float2 texel_size) {
  LocalShadowMap map;
  map.fetch = fetch;
  map.sampler_slot = sampler_slot;
  map.srv_unsigned_slot = srv_unsigned_slot;
  map.srv_signed_slot = srv_signed_slot;
  map.texel_size = texel_size;
  return map;
}

// The point in the map: xy - texture coordinates, z - the reference (1 -
// depth).
float3 LocalShadowCoords(float4 rows[4], float3 world_position) {
  float4 position = float4(world_position, 1.0);
  float inverse_w = rcp(dot(rows[3], position));
  return float3(XeMul(dot(rows[0], position), inverse_w),
                XeMul(dot(rows[1], position), inverse_w),
                1.0 - XeMul(dot(rows[2], position), inverse_w));
}

float2 ShadowMapSize(LocalShadowMap map) {
  float2 size;
  float elements;
  xe_textures_2d[XeDescriptorIndex(map.srv_unsigned_slot)].GetDimensions(size.x, size.y, elements);
  return size;
}

// How the reference changes per texel of the map across the surface, from the
// screen-space derivatives of the coordinates (call in uniform control flow).
float2 LocalShadowReferenceGradient(LocalShadowMap map, float3 coords) {
  float2 size = ShadowMapSize(map);
  float3 dx = ddx(float3(coords.xy * size, coords.z));
  float3 dy = ddy(float3(coords.xy * size, coords.z));
  float determinant = dx.x * dy.y - dy.x * dx.y;
  if (abs(determinant) < 1.0e-8) {
    return 0.0;
  }
  float2 gradient = float2(dx.z * dy.y - dy.z * dx.y, dy.z * dx.x - dx.z * dy.x) / determinant;
  // Silhouettes and depth discontinuities give meaningless derivatives.
  return clamp(gradient, -0.01, 0.01);
}

// The game's filter for the nearby light: 2x2 point-sampled texels,
// bilinearly weighted.
float LocalShadowLitClassic(LocalShadowMap map, float3 coords) {
  float4 stored;
  [unroll] for (uint i = 0; i < 4; ++i) {
    float2 offset = float2(i >> 1, i & 1);
    stored[i] = XeTextureFetch2D(map.fetch, map.sampler_slot, map.srv_unsigned_slot,
                                 map.srv_signed_slot, 0x1u, coords.xy,
                                 kXeFetchRoundingOffset + offset, XE_FETCH_COMPUTED_LOD, 0.0,
                                 0.0)
                    .x;
  }
  // stored: (0, 0), (0, 1), (1, 0), (1, 1).
  float4 lit = XeSge(coords.z, stored);
  float2 weights =
      frac(XeMul(float4(coords.xy, 0.0, 0.0), float4(rcp(map.texel_size), 0.0, 0.0)).xy);
  return lerp(lerp(lit.x, lit.z, weights.x), lerp(lit.y, lit.w, weights.x), weights.y);
}

// The lit fraction over a tent filter of 2 * gathers_per_axis texels: radius
// 1.5 texels with 2 gathers per axis, 2.5 with 3.
float ShadowMapLitTent(LocalShadowMap map, float3 coords, float2 reference_gradient,
                       uint gathers_per_axis) {
  float2 size = ShadowMapSize(map);
  float exp_scale = XeFetchExpScale(map.fetch);
  float radius = float(gathers_per_axis) - 0.5;
  // Texel k's center is at k.
  float2 position = coords.xy * size - 0.5;
  float2 base = floor(position);
  float2 fraction = position - base;
  // The first texel, relative to base.
  float first = 1.0 - float(gathers_per_axis);
  // A small constant bias on top of the plane's.
  float reference = coords.z + 2.0e-5;
  float lit = 0.0, weight_sum = 0.0;
  [unroll] for (uint gather_y = 0; gather_y < 3; ++gather_y) {
    [unroll] for (uint gather_x = 0; gather_x < 3; ++gather_x) {
      if (gather_x < gathers_per_axis && gather_y < gathers_per_axis) {
        // The first of the 2x2 texels (k), relative to the point, and the
        // gather between it and k + 1 (at k + 1 in coordinates of texel
        // corners).
        float2 texel_k = first + float2(gather_x * 2, gather_y * 2);
        float2 texel = texel_k - fraction;
        float2 gather_uv = (base + texel_k + 1.0) / size;
        float4 stored = xe_textures_2d[XeDescriptorIndex(map.srv_unsigned_slot)].GatherRed(
                            xe_samplers[XeDescriptorIndex(map.sampler_slot)],
                            float3(gather_uv, 0.0)) *
                        exp_scale;
        // Gather order: (-, +), (+, +), (+, -), (-, -).
        float4 references =
            reference + float4(dot(reference_gradient, texel + float2(0.0, 1.0)),
                               dot(reference_gradient, texel + float2(1.0, 1.0)),
                               dot(reference_gradient, texel + float2(1.0, 0.0)),
                               dot(reference_gradient, texel));
        float4 distances_x = abs(float4(texel.x, texel.x + 1.0, texel.x + 1.0, texel.x));
        float4 distances_y = abs(float4(texel.y + 1.0, texel.y + 1.0, texel.y, texel.y));
        float4 weights = max(radius - distances_x, 0.0) * max(radius - distances_y, 0.0);
        lit += dot((references >= stored) ? 1.0 : 0.0, weights);
        weight_sum += dot(weights, 1.0);
      }
    }
  }
  return lit / max(weight_sum, 1.0e-6);
}

float LocalShadowLitSmooth(LocalShadowMap map, float3 coords, float2 reference_gradient) {
  return ShadowMapLitTent(map, coords, reference_gradient, 3u);
}

#endif  // MATERIAL_LOCAL_SHADOW_HLSLI_

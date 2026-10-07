// Fable II's grass material (guest pixel shader E99F4ACC7A3C78B4): tufts of
// alpha-tested blades and flowers, lit by the sun and up to two nearby lights,
// with their normals bent toward a per-vertex direction for soft, rounded
// shading, and a dithered fade with distance.
//
// Rewritten as foliage (material_foliage):
// - Smooth blade edges: instead of a hard alpha test, the blades cover the
//   pixel's antialiasing samples in proportion to how far their alpha is past
//   the threshold - antialiased edges instead of jagged, crawling ones.
// - Translucency: light from behind the blades shines through them, tinted by
//   their color - most toward the light, as forward scattering does - and the
//   sky's light comes through too.
// - A soft sheen on the blades from the sun and nearby lights.
// - Natural variation: tufts vary in brightness and hue across a patch, by
//   noise in world space.
// - Alpha kept with distance: mipmapping averages the blades' alpha with the
//   gaps between them, thinning them out far away - the alpha is scaled up by
//   the mip level to keep the tufts full.
// With material_foliage off, the game's grass.
//
// The rest takes the material's inputs as they are: the albedo, the screen-
// space sun shadow mask, the nearby light's shadow map (smoothed like the
// characters' with material_soft_shadows), vertex lighting, the distance fog
// ramps and the dithered fade.
//
// xe_modifications: 0000000B0010001F

// The translation's bindings (shader_E99F4ACC7A3C78B4_*.bindings.txt).
#define XE_FLOAT_CONSTANT_COUNT 28
#define XE_DESCRIPTOR_INDEX_VECTOR_COUNT 5
#include "../include/xenos_d3d12.hlsli"
#include "../include/material_lit_mesh.hlsli"
#include "../include/material_local_shadow.hlsli"

// Material constants (the guest float constants, packed in ascending order).
#define kShadowMaskTransform xe_float_constants[0]  // c0: xy offset, zw scale
#define kAlbedoUvTransform xe_float_constants[1]    // c8: xy scale, zw offset
#define kFade xe_float_constants[2]                 // c15: y 1 / length, z start
#define kCameraPosition xe_float_constants[3]       // c19
#define kExposure xe_float_constants[4]             // c20: a
#define kFogBlend xe_float_constants[5]             // c28: x amount, y color scale
#define kLocalShadowRow(i) xe_float_constants[6 + (i)]  // c32-c35
#define kLocalShadowTexelSize xe_float_constants[10]    // c48: xy
#define kDitherScale xe_float_constants[11]         // c50: xy
#define kFogSunDirection xe_float_constants[12]     // c66
#define kFog xe_float_constants[13]                 // c67: x start, z color, w density
#define kFogColor xe_float_constants[14]            // c68
// The two lights: xyz a position (w 1) or a direction toward the light (w 0).
#define kLight0 xe_float_constants[15]              // c80
#define kLight1 xe_float_constants[16]              // c81
#define kLight0Color xe_float_constants[17]         // c87
#define kLight1Color xe_float_constants[18]         // c88
#define kLightIsLocal xe_float_constants[19]        // c94: xy 1 if attenuated
#define kLightRange xe_float_constants[20]          // c96: xy 1 / radius
#define kSpot0Direction xe_float_constants[21]      // c98
#define kSpot1Direction xe_float_constants[22]      // c99
#define kSpotCosine xe_float_constants[23]          // c105: xy cone edge cosine
#define kSpotScale xe_float_constants[24]           // c107: xy 1 / falloff width
#define kSunShadowStrength xe_float_constants[25]   // c112: xy per light
#define kLocalShadowStrength xe_float_constants[26] // c114: xy per light

static const float2 kFetchOffset = kXeFetchRoundingOffset;
float FetchSunVisibility(float2 uv) {
  return XeTextureFetch2D(8u, 1u, 2u, 3u, 0x1u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).x;
}
float4 FetchAlbedo(float2 uv) {
  return XeTextureFetch2D(0u, 4u, 5u, 6u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0);
}
float FetchDither(float2 uv) {
  return XeTextureFetch2D(10u, 16u, 17u, 18u, 0x8u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).a;
}
float3 FetchFogColor(float coordinate) {
  return XeTextureFetch1D(4u, 10u, 11u, 12u, 0x7u, coordinate, kXeFetchRoundingOffset,
                          XE_FETCH_COMPUTED_LOD, 0.0, 0.0).rgb;
}
float3 FetchFogTransmittance(float coordinate) {
  return XeTextureFetch1D(5u, 13u, 14u, 15u, 0x7u, coordinate, kXeFetchRoundingOffset,
                          XE_FETCH_COMPUTED_LOD, 0.0, 0.0).rgb;
}

struct Input {
  float4 texcoord : TEXCOORD0;
  float4 vertex_normal : TEXCOORD1;
  float4 world_position : TEXCOORD2;
  // xyz - the direction the normal bends toward, w - how far.
  float4 bent_normal : TEXCOORD3;
  centroid float4 vertex_light : TEXCOORD4;
  float4 position : SV_Position;
  bool is_front_face : SV_IsFrontFace;
};

// The mip level the albedo is sampled from.
float AlbedoMipLevel(float2 uv) {
  float2 size = XeTextureSize2D(0u);
  float2 dx = ddx(uv * size), dy = ddy(uv * size);
  return 0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1.0e-8));
}

// Antialiased alpha testing: the samples covered in proportion to how far the
// alpha is past the threshold, over its change across the pixel. Only for the
// "greater" tests, with multisampling and no alpha to coverage of the game's
// own; otherwise the game's test. Discards the pixel if no sample is covered.
uint FoliageCoverage(float alpha, float alpha_width, float4 position) {
  uint function = (xe_flags >> XE_SYS_FLAG_ALPHA_PASS_IF_LESS_SHIFT) & 7u;
  if ((function != 4u && function != 6u) || xe_alpha_to_mask || !xe_sample_count_log2.y) {
    XeAlphaTest(alpha);
    return XeAlphaToCoverage(alpha, position);
  }
  float covered = saturate((alpha - xe_alpha_test_reference) / max(alpha_width, 1.0e-4) + 0.5);
  // Ordered dither between neighboring pixels.
  uint2 pixel = uint2(position.xy);
  float dither = ((pixel.x ^ pixel.y) & 1u) ? 0.25 : -0.25;
  uint coverage = 0u;
  if (xe_sample_count_log2.x) {
    // 4 samples.
    float samples = covered * 4.0 + dither;
    coverage = (samples > 0.5 ? 1u : 0u) | (samples > 1.5 ? 8u : 0u) | (samples > 2.5 ? 2u : 0u) |
               (samples > 3.5 ? 4u : 0u);
  } else {
    // 2 samples - native, or the top and bottom of 4.
    bool msaa_2x = (XeTranslationFlags() & XE_TRANSLATION_MSAA_2X_SUPPORTED) != 0;
    float samples = covered * 2.0 + dither;
    coverage = (samples > 0.5 ? (msaa_2x ? 2u : 1u) : 0u) | (samples > 1.5 ? (msaa_2x ? 1u : 8u) : 0u);
  }
  if (!coverage) {
    discard;
  }
  return coverage;
}

void main(Input input, out float4 color_out : SV_Target0, out uint coverage_out : SV_Coverage) {
  bool foliage = XeMaterialFeature(XE_MATERIAL_FEATURE_FOLIAGE);

  // Surface, stored premultiplied.
  float2 albedo_uv = input.texcoord.xy * kAlbedoUvTransform.xy + kAlbedoUvTransform.zw;
  float4 albedo_sample = FetchAlbedo(albedo_uv);
  float texture_alpha = albedo_sample.a;
  float3 albedo =
      XeMul((albedo_sample.rgb * albedo_sample.rgb).rgbr, rcp(texture_alpha * texture_alpha)).rgb;
  float3 world_position = input.world_position.xyz;
  if (foliage) {
    texture_alpha = saturate(texture_alpha * (1.0 + 0.25 * max(AlbedoMipLevel(albedo_uv), 0.0)));
    // Variation across the patch (world Z is up).
    float broad = FractalNoise(world_position.xy * 0.35);
    float fine = ValueNoise(world_position.xy * 1.9 + 5.3);
    albedo *= lerp(0.78, 1.18, broad) * lerp(float3(1.06, 1.0, 0.9), float3(0.94, 1.03, 1.06), fine);
  }
  float alpha_width = fwidth(texture_alpha);

  float3 vertex_normal = normalize(input.vertex_normal.xyz);
  float3 n = normalize(lerp(vertex_normal, input.bent_normal.xyz, saturate(input.bent_normal.w)));
  float3 to_camera = kCameraPosition.xyz - world_position;
  float camera_distance = length(to_camera);
  float3 v = to_camera / camera_distance;

  // Shadowed amounts for the two lights (x, y): the sun's screen-space mask,
  // and the nearby light's shadow map.
  float2 pixel = abs(XePsParamGen(input.position, input.is_front_face).xy);
  float2 screen_uv = pixel * kShadowMaskTransform.zw + kShadowMaskTransform.xy;
  float sun_visibility = FetchSunVisibility(screen_uv);
  float2 shadow = (1.0 - sun_visibility) * kSunShadowStrength.xy;
  if (XeBoolConstant(135u)) {
    LocalShadowMap map = MakeShadowMap(9u, 7u, 8u, 9u, kLocalShadowTexelSize.xy);
    float4 rows[4] = {kLocalShadowRow(0), kLocalShadowRow(1), kLocalShadowRow(2),
                      kLocalShadowRow(3)};
    float3 coords = LocalShadowCoords(rows, world_position);
    float2 gradient = LocalShadowReferenceGradient(map, coords);
    float lit = XeMaterialFeature(XE_MATERIAL_FEATURE_SOFT_SHADOWS)
                    ? LocalShadowLitSmooth(map, coords, gradient)
                    : LocalShadowLitClassic(map, coords);
    shadow = max(shadow, (1.0 - lit) * kLocalShadowStrength.xy);
  }

  Light lights[2] = {
      GetLight(kLight0, kLight0Color.rgb, world_position, kLightRange.x, kSpot0Direction.xyz,
               kSpotCosine.x, kSpotScale.x, kLightIsLocal.x, 1.0 - shadow.x),
      GetLight(kLight1, kLight1Color.rgb, world_position, kLightRange.y, kSpot1Direction.xyz,
               kSpotCosine.y, kSpotScale.y, kLightIsLocal.y, 1.0 - shadow.y),
  };

  float3 diffuse = 0.0, sheen = 0.0;
  float translucency = XeFoliageTranslucency();
  [unroll] for (uint light_index = 0; light_index < 2; ++light_index) {
    Light light = lights[light_index];
    float n_dot_l = dot(n, light.direction);
    if (foliage) {
      // Wrapped diffuse, and the light through the blade: scattered forward
      // toward the eye, and diffusely out of the side facing away.
      float forward = saturate(dot(-v, light.direction));
      float transmission = 0.9 * forward * forward * forward + 0.35 * saturate(-n_dot_l);
      diffuse += light.radiance *
                 (saturate((n_dot_l + 0.5) / 1.5) + transmission * translucency);
      sheen += SpecularGgx(n, v, light.direction, 0.04, 0.35) * light.radiance;
    } else {
      diffuse += light.radiance * saturate(n_dot_l);
    }
  }
  float3 ambient = input.vertex_light.rgb;
  if (foliage) {
    // The sky's light through the blades too.
    ambient *= 1.0 + 0.3 * translucency;
  }
  float3 color = albedo * (diffuse + ambient) + sheen * XeSpecularIntensity();

  color = LitMeshFog(color, camera_distance, kFog, kFogBlend, kFogColor.rgb,
                     FetchFogColor(saturate(dot(-v, kFogSunDirection.xyz))),
                     FetchFogTransmittance(XeMul(kFog.w, camera_distance - kFog.x)));

  // Faded out with distance by a dither pattern.
  float fade = saturate(1.0 - XeMul(camera_distance - kFade.z, kFade.y));
  float dither = FetchDither(screen_uv * kDitherScale.xy);
  float visible = (fade + dither >= 1.0) ? 1.0 : 0.0;

  float4 result = float4(kExposure.a * color, visible * texture_alpha);
  if (foliage) {
    coverage_out = FoliageCoverage(result.a, alpha_width * visible, input.position);
  } else {
    XeAlphaTest(result.a);
    coverage_out = XeAlphaToCoverage(result.a, input.position);
  }
  color_out = XeColorOutput(result, 0u);
}

// Fable II's forward-shadowed lit mesh material (guest pixel shader
// 44B567635EB10620): alpha-blended surfaces that can't use the screen-space
// sun shadow mask - characters' hair and the ragged edges of their clothes,
// and blended props - so it looks the sun's shadow cascades up itself. Lit
// like 648B965C200A5113 otherwise: the sun and up to two nearby lights, vertex
// lighting with sky occlusion, highlights, reflections and fog.
//
// Rewritten with the same modern lighting and character shader as
// 648B965C200A5113 (see material_lit_mesh.hlsli), and the cascades filtered
// with tents (5 texels wide for the near cascade, 3 for the far) with
// receiver plane depth bias, instead of the game's 5x5 and 2x2 filters.
//
// xe_modifications: 000000000040007F 000040000040007F

// The translation's bindings (shader_44B567635EB10620_*.bindings.txt).
#define XE_FLOAT_CONSTANT_COUNT 47
#define XE_DESCRIPTOR_INDEX_VECTOR_COUNT 8
#include "../include/xenos_d3d12.hlsli"
#include "../include/material_lit_mesh.hlsli"
#include "../include/material_local_shadow.hlsli"

// Material constants (the guest float constants, packed in ascending order).
#define kAlbedoUvTransform xe_float_constants[0]    // c8: xy scale, zw offset
#define kSpecularUvTransform xe_float_constants[1]  // c9
#define kNormalUvTransform xe_float_constants[2]    // c10
// c12: x near-to-far cascade blend start, y fade start (distances), z blend
// length, w the sun's visibility past the fade.
#define kCascadeRanges xe_float_constants[3]
#define kCascadeTexelSize xe_float_constants[4]     // c13: xy
#define kCameraPosition xe_float_constants[5]       // c19
#define kAmbient xe_float_constants[6]              // c20: rgb ambient, a exposure
#define kVertexLight xe_float_constants[7]          // c21: rgb scale, a power
#define kSkyOcclusion xe_float_constants[8]         // c22: rgb fully occluded
#define kSpecularControl xe_float_constants[9]      // c23: a N.L sharpness
#define kLightmap xe_float_constants[10]            // c24: z scale
#define kOutput xe_float_constants[11]              // c26: rgb color, a alpha
#define kDiffuse xe_float_constants[12]             // c27: a ambient diffuse scale
#define kFogBlend xe_float_constants[13]            // c28: x amount, y color scale
#define kLocalShadowRow(i) xe_float_constants[14 + (i)]  // c32-c35
#define kNearCascadeRow(i) xe_float_constants[18 + (i)]  // c36-c39
#define kFarCascadeRow(i) xe_float_constants[22 + (i)]   // c40-c43
#define kLocalShadowTexelSize xe_float_constants[26]     // c48: xy
#define kTint xe_float_constants[27]                // c49
#define kFogSunDirection xe_float_constants[28]     // c66
#define kFog xe_float_constants[29]                 // c67: x start, z color, w density
#define kFogColor xe_float_constants[30]            // c68
// The two lights: xyz a position (w 1) or a direction toward the light (w 0).
#define kLight0 xe_float_constants[31]              // c80
#define kLight1 xe_float_constants[32]              // c81
#define kLight0Color xe_float_constants[33]         // c87
#define kLight1Color xe_float_constants[34]         // c88
#define kLightIsLocal xe_float_constants[35]        // c94: xy 1 if attenuated
#define kLightRange xe_float_constants[36]          // c96: xy 1 / radius
#define kSpot0Direction xe_float_constants[37]      // c98
#define kSpot1Direction xe_float_constants[38]      // c99
#define kSpotCosine xe_float_constants[39]          // c105: xy cone edge cosine
#define kSpotScale xe_float_constants[40]           // c107: xy 1 / falloff width
#define kSunShadowStrength xe_float_constants[41]   // c112: xy per light
#define kLocalShadowStrength xe_float_constants[42] // c114: xy per light
// c253.w: 1 / the length of the cascades' fade.
#define kCascadeFadeScale xe_float_constants[44].w

static const float2 kFetchOffset = kXeFetchRoundingOffset;
float4 FetchAlbedo(float2 uv) {
  return XeTextureFetch2D(0u, 7u, 8u, 9u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0);
}
float3 FetchSpecular(float2 uv) {
  return XeTextureFetch2D(1u, 10u, 11u, 12u, 0x7u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).rgb;
}
float2 FetchNormal(float2 uv) {
  return XeTextureFetch2D(2u, 4u, 5u, 6u, 0x3u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).xy;
}
float3 FetchLightmap(float2 uv) {
  return XeTextureFetch2D(13u, 19u, 20u, 21u, 0x7u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).rgb;
}
float3 FetchEnvironment(float3 direction) {
  direction /= max(max(abs(direction.x), abs(direction.y)), abs(direction.z));
  float face_lod = XeFetchLod(14u, XE_FETCH_COMPUTED_LOD, 0.0, 0.0);
  float3 gradient_scale = exp2(face_lod);
  bool2 srvs = XeFetchSrvsNeeded(14u, 0x7u);
  float4 unsigned_value = 0.0, signed_value = 0.0;
  if (srvs.x) {
    unsigned_value = XeSampleCube(23u, 22u, direction, true, ddx_coarse(direction) * gradient_scale,
                                  ddy_coarse(direction) * gradient_scale, 0.0);
  }
  if (srvs.y) {
    signed_value = XeSampleCube(24u, 22u, direction, true, ddx_coarse(direction) * gradient_scale,
                                ddy_coarse(direction) * gradient_scale, 0.0);
  }
  return XeFetchFinish(14u, 0x7u, unsigned_value, signed_value).rgb;
}
float3 FetchFogColor(float coordinate) {
  return XeTextureFetch1D(4u, 28u, 29u, 30u, 0x7u, coordinate, kXeFetchRoundingOffset,
                          XE_FETCH_COMPUTED_LOD, 0.0, 0.0).rgb;
}
float3 FetchFogTransmittance(float coordinate) {
  return XeTextureFetch1D(5u, 25u, 26u, 27u, 0x7u, coordinate, kXeFetchRoundingOffset,
                          XE_FETCH_COMPUTED_LOD, 0.0, 0.0).rgb;
}

#if XE_MODIFICATION_INDEX == 0
#define XE_EARLY_DEPTH_STENCIL 0
#else
#define XE_EARLY_DEPTH_STENCIL 1
#endif

struct Input {
  float4 texcoord : TEXCOORD0;
  float4 vertex_normal : TEXCOORD1;
  float4 world_position : TEXCOORD2;
  float4 tangent : TEXCOORD3;
  float4 binormal : TEXCOORD4;
  float4 occlusion_direction : TEXCOORD5;
  centroid float4 vertex_color : TEXCOORD6;
  float4 position : SV_Position;
  bool is_front_face : SV_IsFrontFace;
};

#if XE_EARLY_DEPTH_STENCIL
[earlydepthstencil]
void main(Input input, out float4 color_out : SV_Target0) {
#else
void main(Input input, out float4 color_out : SV_Target0, out uint coverage_out : SV_Coverage) {
#endif
  bool modern = XeMaterialFeature(XE_MATERIAL_FEATURE_SPECULAR);
  float2 uv = input.texcoord.xy;

  // Surface. The albedo is premultiplied by its alpha (blended so).
  float4 albedo_sample = FetchAlbedo(uv * kAlbedoUvTransform.xy + kAlbedoUvTransform.zw);
  float alpha = albedo_sample.a;
  LitMeshSurface surface;
  surface.albedo = albedo_sample.rgb * albedo_sample.rgb;
  float3 specular_sample =
      FetchSpecular(uv * kSpecularUvTransform.xy + kSpecularUvTransform.zw);
  surface.specular_color = specular_sample * specular_sample;
  float2 normal_xy = FetchNormal(uv * kNormalUvTransform.xy + kNormalUvTransform.zw) * 2.0 - 1.0;
  float normal_z = sqrt(abs(1.0 - dot(normal_xy, normal_xy)));
  surface.n = normalize(normal_xy.x * input.tangent.xyz + normal_xy.y * input.binormal.xyz +
                        normal_z * normalize(input.vertex_normal.xyz));
  float3 world_position = input.world_position.xyz;
  float3 to_camera = kCameraPosition.xyz - world_position;
  float camera_distance = length(to_camera);
  surface.v = to_camera / camera_distance;
  surface.character =
      XeIsCharacter() && XeMaterialFeature(XE_MATERIAL_FEATURE_CHARACTER_LIGHTING);
  // Skin judged by the color without the alpha premultiplication.
  surface.skin = surface.character
                     ? SkinLikelihood(surface.albedo / max(alpha * alpha, 1.0e-3))
                     : 0.0;

  // The sun's cascades: the near one, blended into the far one with distance,
  // then faded to a constant visibility.
  float4 near_rows[4] = {kNearCascadeRow(0), kNearCascadeRow(1), kNearCascadeRow(2),
                         kNearCascadeRow(3)};
  float4 far_rows[4] = {kFarCascadeRow(0), kFarCascadeRow(1), kFarCascadeRow(2),
                        kFarCascadeRow(3)};
  LocalShadowMap near_map = MakeShadowMap(6u, 1u, 2u, 3u, kCascadeTexelSize.xy);
  LocalShadowMap far_map = MakeShadowMap(7u, 13u, 14u, 15u, kCascadeTexelSize.xy);
  float3 near_coords = LocalShadowCoords(near_rows, world_position);
  float3 far_coords = LocalShadowCoords(far_rows, world_position);
  float2 near_gradient = LocalShadowReferenceGradient(near_map, near_coords);
  float2 far_gradient = LocalShadowReferenceGradient(far_map, far_coords);
  float near_lit = ShadowMapLitTent(near_map, near_coords, near_gradient, 3u);
  float far_lit = ShadowMapLitTent(far_map, far_coords, far_gradient, 2u);
  float cascade_blend =
      saturate(XeMul(camera_distance - kCascadeRanges.x, rcp(kCascadeRanges.z)));
  float cascade_fade = saturate(XeMul(kCascadeFadeScale, camera_distance - kCascadeRanges.y));
  float sun_lit = lerp(lerp(near_lit, far_lit, cascade_blend), kCascadeRanges.w, cascade_fade);

  // Shadowed amounts for the two lights (x, y).
  float2 shadow = (1.0 - sun_lit) * kSunShadowStrength.xy;
  if (XeBoolConstant(135u)) {
    LocalShadowMap map = MakeShadowMap(9u, 16u, 17u, 18u, kLocalShadowTexelSize.xy);
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
  float3 ambient = LitMeshAmbient(input.vertex_color, kVertexLight, input.occlusion_direction.xyz,
                                  surface.n, kSkyOcclusion.rgb, kAmbient.rgb);
  float3 diffuse, specular;
  LitMeshDirect(surface, lights, kSpecularControl.a, diffuse, specular);
  float3 color = surface.albedo * (kDiffuse.a * ambient + diffuse) + specular;

  if (XeBoolConstant(133u)) {
    float3 lightmap = FetchLightmap(uv);
    color += lightmap * lightmap * kLightmap.z;
  }

  if (XeBoolConstant(134u)) {
    float3 reflected = reflect(-surface.v, surface.n);
    float3 frame = reflected.x * input.tangent.xyz + reflected.y * input.binormal.xyz +
                   reflected.z * input.vertex_normal.xyz;
    float3 environment = FetchEnvironment(float3(frame.x, frame.z, -frame.y));
    environment *= environment;
    float3 reflectance =
        modern ? FresnelSchlickRoughness(surface.specular_color,
                                         saturate(dot(surface.n, surface.v)), XeRoughness()) *
                     XeSpecularIntensity()
               : surface.specular_color;
    color += environment * reflectance;
  }
  if (surface.character) {
    // Premultiplied like the rest.
    color += CharacterRim(surface, lights, ambient) * alpha;
  }

  color *= kTint.rgb;
  // The fog's color is premultiplied by the alpha too.
  float4 fog_blend = float4(kFogBlend.x, XeMul(kFogBlend.y, alpha), kFogBlend.zw);
  color = LitMeshFog(color, camera_distance, kFog, fog_blend, kFogColor.rgb,
                     FetchFogColor(saturate(dot(-surface.v, kFogSunDirection.xyz))),
                     FetchFogTransmittance(XeMul(kFog.w, camera_distance - kFog.x)));

  float4 result = float4(kAmbient.a * kOutput.rgb * color, kOutput.a * alpha);
#if !XE_EARLY_DEPTH_STENCIL
  XeAlphaTest(result.a);
  coverage_out = XeAlphaToCoverage(result.a, input.position);
#endif
  color_out = XeColorOutput(result, 0u);
}

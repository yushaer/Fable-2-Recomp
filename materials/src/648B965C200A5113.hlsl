// Fable II's lit mesh material for characters and movable props (guest pixel
// shader 648B965C200A5113): the bodies, faces and clothes of people and
// creatures, and props like market stalls, carts, doors and lamp posts - lit
// by the sun and up to two nearby lights (point or spot, such as a brazier's
// fire), with a shadow map for the nearest one.
//
// Rewritten with modern lighting, from the material's inputs (see
// material_lit_mesh.hlsli):
// - Highlights from both lights (material_specular): GGX microfacet specular
//   with Schlick Fresnel from the specular map, as for the world material, and
//   environment reflections weighted by Fresnel.
// - A character shader (material_character_lighting) for skinned meshes only
//   - characters and creatures, not the props sharing the material: light
//   wrapped past the terminator for a soft falloff, reddened on skin as light
//   scattered under it comes back out; smoother highlights on skin than
//   cloth; and rim light - the sky's sheen at grazing angles and lights behind
//   a figure outlining it.
// - Firelight that flickers with its flames (material_fire).
// - The nearby light's shadow map smoothed with a 5 texel tent filter
//   (material_soft_shadows) instead of the game's 2x2 filter.
// With the features off, the classic lighting: Phong highlights with an
// exponent of 4, constant-weighted reflections and the 2x2 shadow filter.
//
// The rest takes the material's inputs as they are: the albedo, specular and
// normal maps, the screen-space sun shadow mask, vertex lighting with sky
// occlusion, the lightmap, and the distance fog ramps.
//
// xe_modifications: 0000000F0040007F 0000400F0040007F

// The translation's bindings (shader_648B965C200A5113_*.bindings.txt).
#define XE_FLOAT_CONSTANT_COUNT 36
#define XE_DESCRIPTOR_INDEX_VECTOR_COUNT 7
#include "../include/xenos_d3d12.hlsli"
#include "../include/material_lit_mesh.hlsli"
#include "../include/material_local_shadow.hlsli"

// Material constants (the guest float constants, packed in ascending order).
#define kShadowMaskTransform xe_float_constants[0]  // c0: xy offset, zw scale
#define kAlbedoUvTransform xe_float_constants[1]    // c8: xy scale, zw offset
#define kSpecularUvTransform xe_float_constants[2]  // c9
#define kNormalUvTransform xe_float_constants[3]    // c10
#define kCameraPosition xe_float_constants[4]       // c19
#define kAmbient xe_float_constants[5]              // c20: rgb ambient, a exposure
#define kVertexLight xe_float_constants[6]          // c21: rgb scale, a power
#define kSkyOcclusion xe_float_constants[7]         // c22: rgb fully occluded
#define kSpecularControl xe_float_constants[8]      // c23: a N.L sharpness
#define kLightmap xe_float_constants[9]             // c24: z scale
#define kOutput xe_float_constants[10]              // c26: rgb color, a alpha
#define kDiffuse xe_float_constants[11]             // c27: a ambient diffuse scale
#define kFogBlend xe_float_constants[12]            // c28: x amount, y color scale
#define kLocalShadowRow(i) xe_float_constants[13 + (i)]  // c32-c35
#define kLocalShadowTexelSize xe_float_constants[17]     // c48: xy
#define kTint xe_float_constants[18]                // c49
#define kFogSunDirection xe_float_constants[19]     // c66
#define kFog xe_float_constants[20]                 // c67: x start, z color, w density
#define kFogColor xe_float_constants[21]            // c68
// The two lights: xyz a position (w 1) or a direction toward the light (w 0).
#define kLight0 xe_float_constants[22]              // c80
#define kLight1 xe_float_constants[23]              // c81
#define kLight0Color xe_float_constants[24]         // c87
#define kLight1Color xe_float_constants[25]         // c88
#define kLightIsLocal xe_float_constants[26]        // c94: xy 1 if attenuated
#define kLightRange xe_float_constants[27]          // c96: xy 1 / radius
#define kSpot0Direction xe_float_constants[28]      // c98
#define kSpot1Direction xe_float_constants[29]      // c99
#define kSpotCosine xe_float_constants[30]          // c105: xy cone edge cosine
#define kSpotScale xe_float_constants[31]           // c107: xy 1 / falloff width
#define kSunShadowStrength xe_float_constants[32]   // c112: xy per light
#define kLocalShadowStrength xe_float_constants[33] // c114: xy per light

// Texture fetches: fetch constant, then the sampler and the unsigned and
// signed texture descriptor slots.
static const float2 kFetchOffset = kXeFetchRoundingOffset;
float4 FetchAlbedo(float2 uv) {
  return XeTextureFetch2D(0u, 4u, 5u, 6u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0);
}
float3 FetchSpecular(float2 uv) {
  return XeTextureFetch2D(1u, 7u, 8u, 9u, 0x7u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).rgb;
}
float2 FetchNormal(float2 uv) {
  return XeTextureFetch2D(2u, 1u, 2u, 3u, 0x3u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).xy;
}
float FetchSunVisibility(float2 uv) {
  return XeTextureFetch2D(8u, 10u, 11u, 12u, 0x1u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).x;
}
float3 FetchLightmap(float2 uv) {
  return XeTextureFetch2D(13u, 16u, 17u, 18u, 0x7u, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0,
                          0.0).rgb;
}
// The cube map from a direction (any length).
float3 FetchEnvironment(float3 direction) {
  // Projected onto the cube's faces, as the translation samples it.
  direction /= max(max(abs(direction.x), abs(direction.y)), abs(direction.z));
  float face_lod = XeFetchLod(14u, XE_FETCH_COMPUTED_LOD, 0.0, 0.0);
  float3 gradient_scale = exp2(face_lod);
  bool2 srvs = XeFetchSrvsNeeded(14u, 0x7u);
  float4 unsigned_value = 0.0, signed_value = 0.0;
  if (srvs.x) {
    unsigned_value = XeSampleCube(20u, 19u, direction, true, ddx_coarse(direction) * gradient_scale,
                                  ddy_coarse(direction) * gradient_scale, 0.0);
  }
  if (srvs.y) {
    signed_value = XeSampleCube(21u, 19u, direction, true, ddx_coarse(direction) * gradient_scale,
                                ddy_coarse(direction) * gradient_scale, 0.0);
  }
  return XeFetchFinish(14u, 0x7u, unsigned_value, signed_value).rgb;
}
float3 FetchFogColor(float coordinate) {
  return XeTextureFetch1D(4u, 22u, 23u, 24u, 0x7u, coordinate, kXeFetchRoundingOffset,
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

  // Surface.
  float4 albedo_sample = FetchAlbedo(uv * kAlbedoUvTransform.xy + kAlbedoUvTransform.zw);
  float alpha = albedo_sample.a;
  LitMeshSurface surface;
  surface.albedo = albedo_sample.rgb * albedo_sample.rgb;
  if (XeBoolConstant(128u)) {
    // Stored premultiplied.
    surface.albedo = XeMul(surface.albedo.rgbr, rcp(alpha * alpha)).rgb;
  }
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
  surface.skin = surface.character ? SkinLikelihood(surface.albedo) : 0.0;

  // Shadowed amounts for the two lights (x, y): the sun's screen-space mask,
  // and the nearby light's shadow map.
  float2 pixel = abs(XePsParamGen(input.position, input.is_front_face).xy);
  float sun_visibility =
      FetchSunVisibility(pixel * kShadowMaskTransform.zw + kShadowMaskTransform.xy);
  float2 shadow = (1.0 - sun_visibility) * kSunShadowStrength.xy;
  if (XeBoolConstant(135u)) {
    LocalShadowMap map = MakeShadowMap(9u, 13u, 14u, 15u, kLocalShadowTexelSize.xy);
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
    // The reflection, in the cube map's space: in the frame of the vertex's
    // tangent, binormal and normal, Y and Z swapped.
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
    color += CharacterRim(surface, lights, ambient);
  }

  color *= kTint.rgb;
  color = LitMeshFog(color, camera_distance, kFog, kFogBlend, kFogColor.rgb,
                     FetchFogColor(saturate(dot(-surface.v, kFogSunDirection.xyz))),
                     FetchFogTransmittance(XeMul(kFog.w, camera_distance - kFog.x)));

  float4 result = float4(kAmbient.a * kOutput.rgb * color, kOutput.a * alpha);
#if !XE_EARLY_DEPTH_STENCIL
  XeAlphaTest(result.a);
  coverage_out = XeAlphaToCoverage(result.a, input.position);
#endif
  color_out = XeColorOutput(result, 0u);
}

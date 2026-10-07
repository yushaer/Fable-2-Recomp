// The lighting model of Fable II's lit mesh materials (648B965C200A5113,
// 44B567635EB10620 and their kin): the sun and up to two nearby lights (point
// or spot, with distance and cone falloff), vertex lighting with sky occlusion,
// highlights from a specular map - and the modern versions of each.
//
// Includes material_lighting.hlsli and material_noise.hlsli.

#ifndef MATERIAL_LIT_MESH_HLSLI_
#define MATERIAL_LIT_MESH_HLSLI_

#include "material_lighting.hlsli"
#include "material_noise.hlsli"

struct Light {
  float3 direction;  // Toward the light.
  float3 radiance;   // Color times distance and cone falloff and visibility.
};

// The flicker of a fire's light (material_fire): nearby lights with a warm
// color - braziers, torches, hearths - waver like their flames, each at its
// own pace from its position.
float FireLightFlicker(float4 light, float3 color, float is_local) {
  if (!XeMaterialFeature(XE_MATERIAL_FEATURE_FIRE) || is_local < 0.5 || light.w < 0.5) {
    return 1.0;
  }
  float warmth = saturate((color.r - color.b) / max(color.r, 1.0e-4) * 1.5 - 0.5);
  if (warmth <= 0.0) {
    return 1.0;
  }
  float time = XeTime();
  float seed = dot(light.xyz, float3(0.37, 0.13, 0.71));
  float flicker = ValueNoise(float2(time * 7.3, seed)) * 0.6 +
                  ValueNoise(float2(time * 17.9, seed + 31.0)) * 0.4;
  return lerp(1.0, 0.72 + 0.56 * flicker, warmth);
}

// light: xyz a position (w 1) or a direction toward the light (w 0).
Light GetLight(float4 light, float3 color, float3 world_position, float range,
               float3 spot_direction, float spot_cosine, float spot_scale, float is_local,
               float visibility) {
  float3 to_light = light.xyz - world_position * light.w;
  float distance = length(to_light);
  Light result;
  result.direction = to_light / distance;
  float attenuation = saturate(1.0 - distance * range);
  float spot = saturate(XeMul(spot_scale, dot(result.direction, spot_direction) - spot_cosine));
  result.radiance = color * (lerp(1.0, spot * attenuation, is_local) * visibility *
                             FireLightFlicker(light, color, is_local));
  return result;
}

// Ambient: vertex lighting raised to a power, darkened facing away from the
// open sky, plus a constant.
float3 LitMeshAmbient(float4 vertex_color, float4 vertex_light, float3 occlusion_direction,
                      float3 n, float3 sky_occlusion_color, float3 ambient_color) {
  float sky = saturate(dot(normalize(occlusion_direction), n));
  float3 sky_occlusion = lerp(sky_occlusion_color, 1.0, sky * sky);
  float3 light;
  [unroll] for (uint i = 0; i < 3; ++i) {
    light[i] = exp2(XeMul(vertex_light.a, log2(abs(vertex_color[i]))));
  }
  return light * vertex_light.rgb * sky_occlusion + ambient_color;
}

// How much a linear albedo looks like skin, 0 to 1: warm, moderately saturated
// and not dark (cloth, leather and hair are mostly darker or off-hue).
float SkinLikelihood(float3 albedo) {
  float3 c = sqrt(saturate(albedo));
  if (!(c.r > c.g && c.g > c.b)) {
    return 0.0;
  }
  float saturation = (c.r - c.b) / max(c.r, 1.0e-3);
  float hue = (c.r - c.g) / max(c.r - c.b, 1.0e-3);
  return smoothstep(0.12, 0.25, saturation) * (1.0 - smoothstep(0.6, 0.8, saturation)) *
         smoothstep(0.3, 0.45, c.r) * (1.0 - smoothstep(0.75, 0.95, hue));
}

struct LitMeshSurface {
  float3 albedo;
  float3 specular_color;  // The specular map, linear.
  float3 n;
  float3 v;
  bool character;  // Skinned, with character lighting on.
  float skin;      // SkinLikelihood for characters.
};

// The lights' diffuse and specular, modern or classic.
void LitMeshDirect(LitMeshSurface surface, Light lights[2], float specular_control,
                   out float3 diffuse, out float3 specular) {
  bool modern = XeMaterialFeature(XE_MATERIAL_FEATURE_SPECULAR);
  float roughness = XeRoughness();
  if (surface.character) {
    // Skin is smoother (a soft sheen), cloth rougher.
    roughness = lerp(saturate(roughness + 0.15), 0.4, surface.skin);
  }
  // Characters: diffuse wrapped past the terminator - more for skin, where
  // the light scattered under the surface comes out reddened.
  float wrap = surface.character ? lerp(0.2, 0.5, surface.skin) : 0.0;
  float3 scatter_color = lerp(1.0, float3(1.0, 0.38, 0.22), surface.skin);
  diffuse = 0.0;
  specular = 0.0;
  [unroll] for (uint i = 0; i < 2; ++i) {
    float n_dot_l = dot(surface.n, lights[i].direction);
    float lit = saturate(n_dot_l);
    float wrapped = saturate((n_dot_l + wrap) / (1.0 + wrap));
    diffuse += lights[i].radiance * (lit + (wrapped - lit) * scatter_color);
    if (modern) {
      specular += SpecularGgx(surface.n, surface.v, lights[i].direction, surface.specular_color,
                              roughness) *
                  lights[i].radiance * XeSpecularIntensity();
    } else {
      float r_dot_v = saturate(dot(reflect(-lights[i].direction, surface.n), surface.v));
      float r_dot_v_2 = r_dot_v * r_dot_v;
      specular += surface.specular_color * lights[i].radiance * (r_dot_v_2 * r_dot_v_2) *
                  saturate(specular_control * lit);
    }
  }
}

// Characters without a cube map: the sky's sheen at grazing angles, and the
// rim the lights draw around a figure lit from behind.
float3 CharacterRim(LitMeshSurface surface, Light lights[2], float3 ambient) {
  float n_dot_v = saturate(dot(surface.n, surface.v));
  float grazing = MaterialPow5(1.0 - n_dot_v);
  float3 rim = ambient * (1.2 * grazing);
  [unroll] for (uint i = 0; i < 2; ++i) {
    float behind = saturate(dot(-surface.v, lights[i].direction));
    float facing = saturate(dot(surface.n, lights[i].direction) + 0.3);
    rim += lights[i].radiance * (behind * behind * facing * (1.0 - n_dot_v) * (1.0 - n_dot_v));
  }
  return rim * XeSheenIntensity();
}

// Distance fog: the color from a ramp by the angle to the sun, the
// transmittance from a ramp by the distance.
float3 LitMeshFog(float3 color, float camera_distance, float4 fog, float4 fog_blend,
                  float3 fog_color_constant, float3 fog_ramp_color, float3 fog_transmittance) {
  float fog_distance = camera_distance - fog.x;
  if (fog_distance > 0.0) {
    float3 fog_color =
        lerp(fog_color_constant, fog_ramp_color, saturate(XeMul(fog.z, fog_distance)));
    float3 fogged = color * fog_transmittance + (1.0 - fog_transmittance) * fog_blend.y * fog_color;
    color = lerp(color, fogged, fog_blend.x);
  }
  return color;
}

#endif  // MATERIAL_LIT_MESH_HLSLI_

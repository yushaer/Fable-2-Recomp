// HD Ground: what the texture pack's maps add to the game's terrain shaders.
//
// tools/textures/make_hd_ground.py ports the terrain shaders from your shader
// dump (tools/xenos_to_hlsl.py), splices in calls to these functions and
// builds them into the mod. The layer texture is fetch constant 0; when it has
// no maps (any other terrain in the game), every function leaves the shader
// exactly as it was.
//
// What the maps add:
// - Normal map: the game's terrain lighting uses it in place of the game's
//   own normal map (a fine detail map, not matching the new stones).
// - Height map: parallax occlusion - the stones stand out of the ground as the
//   camera moves - and blending the layers by height: where layers meet, the
//   higher one shows (snow fills the joints, the stones poke through). The
//   terrain adds its layers up in separate passes, so the SDK's layer
//   blending (XeLayerBlend) normalizes them together.
// - ORM map: highlights from the game's lights with the surface's roughness
//   (the game's terrain has none), dimmed by its occlusion.

#ifndef HD_GROUND_TERRAIN_HLSLI
#define HD_GROUND_TERRAIN_HLSLI

// Options (the mod's materials/options.toml).
#define HD_OPTION_NORMAL 16u        // normal map strength
#define HD_OPTION_PARALLAX 17u      // parallax depth, in texture repeats
#define HD_OPTION_SPECULAR 18u      // highlight strength
#define HD_OPTION_ROUGHNESS 19u     // roughness scale
#define HD_OPTION_HEIGHT_BLEND 20u  // height blending sharpness (0 = the game's blending)
#define HD_OPTION_ENABLED 23u       // all of it (0 also when options.toml is missing)

#define HD_PI 3.14159265

struct HdGround {
  bool active;            // the layer texture has maps
  uint sampler_slot;      // the layer texture's sampler
  float2 uv;              // the layer's texture coordinates, moved by parallax
  float2 uv_dx, uv_dy;    // the unmoved coordinates' screen gradients
  float3 position;        // world space
  float3 view;            // to the camera, normalized
  float3 tangent;         // world space, along +U, from the screen derivatives
  float3 bitangent;       // along +V
  float3 normal;          // the surface's (geometric) normal
  float3 frame_x;         // the game's tangent vectors for its normal map texel's
  float3 frame_y;         // x and y (any orientation), normalized
  float3 normal_ws;       // the normal map's normal, world space
  float height;           // 0 (joints) - 1 (stone tops); 0.5 without a height map
  float roughness;
  float occlusion;
  float sun_shadow;       // the game's sun shadow mask, if the shader has one
};

float HdOption(uint slot) { return XeMaterialOption(slot); }

float HdSampleHeight(HdGround hd, float2 uv) {
  return XeSampleCompanionGrad(0u, XE_COMPANION_HEIGHT, hd.sampler_slot, uv, hd.uv_dx, hd.uv_dy).r;
}

// Parallax occlusion: march the view ray down through the height field (1 at
// the top) and take the texture coordinates where it enters the surface.
float2 HdParallax(HdGround hd, float depth) {
  float3 view_ts = float3(dot(hd.view, hd.tangent), dot(hd.view, hd.bitangent),
                          dot(hd.view, hd.normal));
  // How far the coordinates move over the whole height range.
  float2 shift = view_ts.xy / max(view_ts.z, 0.2) * depth;
  // More steps at grazing angles, where the ray crosses more of the texture.
  int steps = int(lerp(24.0, 8.0, saturate(view_ts.z)));
  float layer_step = 1.0 / float(steps);
  float2 uv_step = shift * layer_step;
  float layer = 1.0;
  float2 uv = hd.uv;
  float height = HdSampleHeight(hd, uv);
  [loop] for (int i = 0; i < steps && height < layer; ++i) {
    layer -= layer_step;
    uv -= uv_step;
    height = HdSampleHeight(hd, uv);
  }
  // Between the last step above the surface and the first below it.
  float2 previous_uv = uv + uv_step;
  float above = HdSampleHeight(hd, previous_uv) - (layer + layer_step);
  float below = height - layer;
  float t = below / min(below - above, -1e-5);
  return lerp(uv, previous_uv, saturate(t));
}

// Call at the start of the shader: uv = the layer's texture coordinates,
// position = the world position interpolator, camera = its position (c19),
// sampler_slot = the layer texture's sampler, frame_x and frame_y = the
// interpolators the game multiplies its normal map texel's x and y by.
HdGround HdGroundSetup(float2 uv, float3 position, float3 camera, uint sampler_slot,
                       float3 frame_x, float3 frame_y) {
  HdGround hd = (HdGround)0;
  hd.sampler_slot = sampler_slot;
  hd.uv = uv;
  hd.height = 0.5;
  hd.roughness = 1.0;
  hd.occlusion = 1.0;
  hd.sun_shadow = 1.0;
  hd.active = XeMaterialOptionOn(HD_OPTION_ENABLED) &&
              (XeHasCompanion(0u, XE_COMPANION_NORMAL) || XeHasCompanion(0u, XE_COMPANION_HEIGHT) ||
               XeHasCompanion(0u, XE_COMPANION_ORM));
  // Derivatives before any branch (they need the whole pixel quad).
  hd.uv_dx = ddx(uv);
  hd.uv_dy = ddy(uv);
  float3 dp_dx = ddx(position);
  float3 dp_dy = ddy(position);
  if (!hd.active) {
    return hd;
  }
  hd.position = position;
  hd.view = normalize(camera - position);
  // The tangent frame from how position and coordinates change across the
  // screen ("normal mapping without precomputed tangents") - so the maps
  // follow the texture coordinates whichever way the game's tangents point.
  float3 normal = normalize(cross(dp_dx, dp_dy));
  normal = dot(normal, hd.view) < 0.0 ? -normal : normal;
  float3 dp_dy_perp = cross(dp_dy, normal);
  float3 dp_dx_perp = cross(normal, dp_dx);
  float3 tangent = dp_dy_perp * hd.uv_dx.x + dp_dx_perp * hd.uv_dy.x;
  float3 bitangent = dp_dy_perp * hd.uv_dx.y + dp_dx_perp * hd.uv_dy.y;
  float scale = rsqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 1e-30));
  hd.tangent = tangent * scale;
  hd.bitangent = bitangent * scale;
  hd.normal = normal;

  if (XeHasCompanion(0u, XE_COMPANION_HEIGHT)) {
    float depth = HdOption(HD_OPTION_PARALLAX);
    if (depth > 0.0) {
      hd.uv = HdParallax(hd, depth);
    }
    hd.height = HdSampleHeight(hd, hd.uv);
  }
  // The game's smooth normal (the geometric one is faceted), and the map's
  // directions along it.
  hd.frame_x = frame_x * rsqrt(max(dot(frame_x, frame_x), 1e-12));
  hd.frame_y = frame_y * rsqrt(max(dot(frame_y, frame_y), 1e-12));
  float3 smooth = cross(hd.frame_x, hd.frame_y);
  smooth = dot(smooth, smooth) > 1e-6 ? normalize(smooth) : normal;
  smooth = dot(smooth, normal) < 0.0 ? -smooth : smooth;
  hd.normal_ws = smooth;
  if (XeHasCompanion(0u, XE_COMPANION_NORMAL)) {
    // DirectX convention: green along +V.
    float3 n = XeSampleCompanionGrad(0u, XE_COMPANION_NORMAL, sampler_slot, hd.uv, hd.uv_dx,
                                     hd.uv_dy).xyz * 2.0 - 1.0;
    n.xy *= HdOption(HD_OPTION_NORMAL);
    n = normalize(float3(n.xy, max(n.z, 1e-3)));
    float3 u = normalize(hd.tangent - smooth * dot(hd.tangent, smooth));
    float3 v = normalize(hd.bitangent - smooth * dot(hd.bitangent, smooth));
    hd.normal_ws = normalize(u * n.x + v * n.y + smooth * n.z);
  }
  if (XeHasCompanion(0u, XE_COMPANION_ORM)) {
    float3 orm = XeSampleCompanionGrad(0u, XE_COMPANION_ORM, sampler_slot, hd.uv, hd.uv_dx,
                                       hd.uv_dy).rgb;
    hd.occlusion = orm.r;
    hd.roughness = saturate(orm.g * HdOption(HD_OPTION_ROUGHNESS));
  }
  return hd;
}

// The game's normal map texel (tf2), replaced by one carrying the normal map's
// normal: the game decodes x and y * 2 - 1, adds them times its tangent
// vectors (frame_x, frame_y) and rebuilds z along its normal - so x and y are
// the normal's components along those vectors.
float4 HdNormalTexel(float4 game_texel, HdGround hd) {
  if (!hd.active || !XeHasCompanion(0u, XE_COMPANION_NORMAL)) {
    return game_texel;
  }
  float2 n = float2(dot(hd.normal_ws, hd.frame_x), dot(hd.normal_ws, hd.frame_y));
  return float4(n * 0.5 + 0.5, game_texel.zw);
}

// Highlights from one of the game's lights, faded exactly as the game fades
// its light on the terrain (otherwise highlights show on patches the light
// doesn't reach, and flicker as the game hands lights to other patches):
// light = position (w = 1) or direction (w = 0); falloff = 1 if the light
// fades with distance and its spot cone, 0 if not; inverse_radius = 1 /
// radius; the spot cone's direction, cosine and scale (scale 0: no cone);
// sun_shadowing = how much the sun shadow mask dims the light (0-1).
float3 HdLightSpecular(HdGround hd, float4 light, float3 color, float falloff,
                       float inverse_radius, float3 spot_direction, float spot_cos,
                       float spot_scale, float sun_shadowing) {
  float3 to_light = light.xyz - hd.position * light.w;
  float distance = length(to_light);
  float3 l = to_light / max(distance, 1e-4);
  float fade = saturate(1.0 - distance * inverse_radius);
  float cone =
      spot_scale != 0.0 ? saturate((dot(l, spot_direction) - spot_cos) * spot_scale) : 1.0;
  float attenuation = 1.0 + falloff * (cone * fade - 1.0);
  attenuation *= 1.0 - (1.0 - hd.sun_shadow) * sun_shadowing;
  float3 n = hd.normal_ws;
  float3 h = normalize(l + hd.view);
  float n_dot_l = saturate(dot(n, l));
  float n_dot_v = saturate(dot(n, hd.view)) + 1e-4;
  float n_dot_h = saturate(dot(n, h));
  float v_dot_h = saturate(dot(hd.view, h));
  // GGX, Smith visibility, Schlick Fresnel for stone (F0 0.04).
  float alpha = max(hd.roughness * hd.roughness, 0.002);
  float alpha2 = alpha * alpha;
  float d = n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0;
  float distribution = alpha2 / (HD_PI * d * d);
  float k = alpha * 0.5;
  float visibility = 0.25 / ((n_dot_l * (1.0 - k) + k) * (n_dot_v * (1.0 - k) + k));
  float fresnel = 0.04 + 0.96 * pow(1.0 - v_dot_h, 5.0);
  return color * (distribution * visibility * fresnel * n_dot_l * attenuation);
}

// The highlights' scale (and nothing without maps).
float HdSpecularScale(HdGround hd) {
  if (!hd.active || !XeHasCompanion(0u, XE_COMPANION_ORM)) {
    return 0.0;
  }
  return HdOption(HD_OPTION_SPECULAR) * hd.occlusion;
}

// Height blending: how much more of this layer shows here than its weight
// says, for XeLayerBlend - more where it's higher. Layers without a height map
// (the game's own textures) count as halfway up.
float HdLayerFactor(HdGround hd) {
  float sharpness = HdOption(HD_OPTION_HEIGHT_BLEND);
  if (!hd.active || sharpness <= 0.0) {
    return 1.0;
  }
  return exp2(sharpness * (hd.height - 0.5));
}

#endif  // HD_GROUND_TERRAIN_HLSLI

// Fable II's flame particles (guest pixel shader A753A2072F78F00F): the fire of
// braziers, torches and hearths - three frames of flame cross-faded by the
// particle's age, tinted by the particle's color.
//
// Rewritten as living fire (material_fire):
// - Flame tongues: the frames are carved by animated noise rising up the
//   screen (whichever way the particle's texture faces), stretched upward like
//   real flames, and the frames are sampled through turbulence so the fire
//   licks and churns instead of just cross-fading.
// - Color by temperature: the flame's brightness picks a blackbody color - deep
//   red at the cool edges, through orange and yellow, to a near-white core -
//   blended with the frame's own color.
// - Glowing cores: the hottest parts are brightened beyond the frame's range
//   (material_fire_intensity) so the bloom picks them up as fire's glow, with a
//   flicker.
// With material_fire off, the game's flames.
//
// xe_modifications: 0000000000000003 0000000000020003

// The translation's bindings (shader_A753A2072F78F00F_*.bindings.txt).
#define XE_FLOAT_CONSTANT_COUNT 3
#define XE_DESCRIPTOR_INDEX_VECTOR_COUNT 3
#include "../include/xenos_d3d12.hlsli"
#include "../include/material_noise.hlsli"

#define kExposure xe_float_constants[0]    // c20: a
#define kFrameStart xe_float_constants[1]  // c31: x frame 1, y frame 2 - in age
#define kFrameRate xe_float_constants[2]   // c46: xy 1 / cross-fade length

static const float2 kFetchOffset = kXeFetchRoundingOffset;
float4 FetchFrame0(float2 uv) {
  return XeTextureFetch2D(0u, 7u, 8u, 9u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0, 0.0);
}
float4 FetchFrame1(float2 uv) {
  return XeTextureFetch2D(1u, 4u, 5u, 6u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0, 0.0);
}
float4 FetchFrame2(float2 uv) {
  return XeTextureFetch2D(2u, 1u, 2u, 3u, 0xFu, uv, kFetchOffset, XE_FETCH_COMPUTED_LOD, 0.0, 0.0);
}

#if XE_MODIFICATION_INDEX == 1
#define COLOR_INTERPOLATION centroid
#else
#define COLOR_INTERPOLATION
#endif

struct Input {
  // xy - texture coordinates, z - the particle's age.
  float4 texcoord : TEXCOORD0;
  // rgb - color, a - intensity.
  COLOR_INTERPOLATION float4 color : TEXCOORD1;
  float4 position : SV_Position;
  bool is_front_face : SV_IsFrontFace;
};

// The color of a black body glowing at a temperature from 0 (dull red) to 1
// (yellow-white), normalized to the brightest channel.
float3 BlackbodyColor(float temperature) {
  float t = saturate(temperature);
  return float3(1.0, saturate(t * 1.25 - 0.05), saturate(t * t * 1.4 - 0.35)) *
         lerp(0.55, 1.0, t);
}

float4 SampleFlame(float2 uv, float fade_1, float fade_2) {
  return lerp(lerp(FetchFrame0(uv), FetchFrame1(uv), fade_1), FetchFrame2(uv), fade_2);
}

void main(Input input, out float4 color_out : SV_Target0, out uint coverage_out : SV_Coverage) {
  bool fire = XeMaterialFeature(XE_MATERIAL_FEATURE_FIRE);
  float2 uv = input.texcoord.xy;
  float age = input.texcoord.z;
  float fade_1 = saturate(XeMul(kFrameRate.x, age - kFrameStart.x));
  float fade_2 = saturate(XeMul(kFrameRate.y, age - kFrameStart.y));

  // Screen up and right in the particle's texture coordinates, normalized to
  // the particle (the quad spans 1 in its coordinates).
  float2 uv_per_pixel_down = ddy(uv);
  float2 uv_per_pixel_right = ddx(uv);
  float2 up = -uv_per_pixel_down / max(length(uv_per_pixel_down), 1.0e-6);
  float2 right = uv_per_pixel_right / max(length(uv_per_pixel_right), 1.0e-6);

  float4 frame;
  float3 color;
  float alpha;
  if (fire) {
    float time = XeTime();
    // Each particle at its own phase.
    float phase = age * 2.3 + dot(input.color.rgb, 7.0);
    // The flame in rising coordinates: across, and up (scrolling down so the
    // noise rises).
    float2 flame = float2(dot(uv, right), dot(uv, up));
    float2 rising = float2(flame.x * 4.0 + phase, flame.y * 2.2 - time * 2.6 + phase * 1.7);
    float2 turbulence = float2(FractalNoise(rising), FractalNoise(rising + float2(23.1, 7.9))) -
                        0.5;
    // Less at the frame's borders, so they stay out of view.
    float2 edge = saturate(min(uv, 1.0 - uv) * 6.0);
    float2 warped_uv = uv + (turbulence.x * right + turbulence.y * up) * (0.09 * edge.x * edge.y);
    frame = SampleFlame(warped_uv, fade_1, fade_2);

    // Tongues: the flame carved by finer rising noise, so it flickers in
    // ragged licks - and a little denser than the frames.
    float tongues = FractalNoise(float2(flame.x * 7.0 - phase, flame.y * 3.5 - time * 4.1 + phase));
    float shape = saturate(frame.a * (0.7 + 0.9 * tongues));

    float3 flame_color = frame.rgb * frame.rgb;
    float heat = saturate(dot(flame_color, float3(0.2126, 0.7152, 0.0722)) * 2.0 * shape);
    float3 temperature_color =
        BlackbodyColor(heat) * max(max(flame_color.r, flame_color.g), flame_color.b);
    flame_color = lerp(flame_color, temperature_color, 0.6);
    float flicker = 0.8 + 0.4 * ValueNoise(float2(time * 8.0 + phase, phase * 3.1));
    // The cores glow far past the frame's range, for the bloom to spread.
    float glow = 1.0 + 4.0 * XeFireIntensity() * smoothstep(0.15, 0.8, heat);
    color = input.color.rgb * XeMul(input.color.a, kExposure.a) * flame_color * flicker * glow;
    alpha = XeMul(shape, input.color.a);

    // Embers: sparks rising out of the thinning parts of the flame.
    float2 spark_space = float2(flame.x * 9.0, flame.y * 5.0 - time * 3.2 + phase);
    float2 spark_cell = floor(spark_space);
    float spark_seed = NoiseHash12(spark_cell + floor(phase * 13.0));
    if (spark_seed > 0.9) {
      float2 spark_center =
          float2(NoiseHash12(spark_cell + 7.1), NoiseHash12(spark_cell + 3.3)) * 0.6 + 0.2;
      float spark = saturate(1.0 - length(spark_space - spark_cell - spark_center) * 7.0);
      spark *= smoothstep(0.02, 0.25, frame.a) * (1.0 - frame.a) *
               (0.5 + 0.5 * sin(time * 20.0 + spark_seed * 60.0));
      color += float3(1.0, 0.45, 0.12) * (6.0 * XeFireIntensity() * spark) *
               XeMul(input.color.a, kExposure.a);
      alpha = max(alpha, spark * input.color.a);
    }
  } else {
    frame = SampleFlame(uv, fade_1, fade_2);
    color = input.color.rgb * XeMul(input.color.a, kExposure.a) * frame.rgb * frame.rgb;
    alpha = XeMul(frame.a, input.color.a);
  }

  float4 result = float4(color, alpha);
  XeAlphaTest(result.a);
  coverage_out = XeAlphaToCoverage(result.a, input.position);
  color_out = XeColorOutput(result, 0u);
}

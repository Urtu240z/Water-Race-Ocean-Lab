#[compute]
#version 450

// Low-frequency FFT activity field for texture-driven shallow caustics.
// The artistic filament structure is sampled in ocean_surface.gdshader; this
// pass only reuses the four already-produced Ocean V3 normal maps to modulate
// it. No second spectrum, IFFT or CPU readback is introduced.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D normal_long_coastal;
layout(set = 0, binding = 1) uniform sampler2D normal_long_remainder;
layout(set = 0, binding = 2) uniform sampler2D normal_mid;
layout(set = 0, binding = 3) uniform sampler2D normal_short;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D caustics_field;

layout(push_constant, std430) uniform Params {
	vec4 field; // origin_x, origin_z, extent_m, projection_depth_m
	vec4 sun; // direction surface -> sun, focus clamp (legacy slot)
	vec4 focus; // gain, threshold, response power, debug mode (legacy slots)
	vec4 weights; // long coastal, long remainder, mid, short
	vec4 domains; // long coastal, long remainder, mid, short metres
} params;

vec2 spectrum_uv(vec2 world_xz, float domain_m) {
	return fract(world_xz / max(domain_m, 0.001) + 0.5);
}

vec2 slope_from_normal(vec3 normal) {
	return -normal.xz / max(abs(normal.y), 0.25);
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(caustics_field);
	if (any(greaterThanEqual(coord, size))) return;
	if (params.sun.y <= 0.001) {
		imageStore(caustics_field, coord, vec4(0.0));
		return;
	}
	float texel_m = params.field.z / float(size.x);
	vec2 world_xz = params.field.xy + (vec2(coord) + vec2(0.5)) * texel_m;
	vec2 long_coastal = slope_from_normal(textureLod(
		normal_long_coastal, spectrum_uv(world_xz, params.domains.x), 0.0).rgb);
	vec2 long_remainder = slope_from_normal(textureLod(
		normal_long_remainder, spectrum_uv(world_xz, params.domains.y), 0.0).rgb);
	vec2 mid = slope_from_normal(textureLod(
		normal_mid, spectrum_uv(world_xz, params.domains.z), 0.0).rgb);
	vec2 short_slope = slope_from_normal(textureLod(
		normal_short, spectrum_uv(world_xz, params.domains.w), 0.0).rgb);
	vec2 broad_slope = long_coastal * params.weights.x
		+ long_remainder * params.weights.y
		+ mid * params.weights.z
		+ short_slope * params.weights.w * 0.12;
	float activity = smoothstep(0.015, 0.32, length(broad_slope));
	// R is intentionally a bounded modulation, not a bright caustics image.
	// G/B retain a signed warp diagnostic for DEBUG_CAUSTICS_FFT_WARP.
	float modulation = clamp(activity, 0.0, 1.0);
	vec3 output_value = vec3(modulation, broad_slope * 0.5 + 0.5);
	imageStore(caustics_field, coord, vec4(output_value, 1.0));
}

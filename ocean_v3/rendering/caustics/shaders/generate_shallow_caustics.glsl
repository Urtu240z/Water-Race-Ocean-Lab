#[compute]
#version 450

// P0/P1 focusing approximation. Refract sunlight through the already
// assembled FFT normals, project each ray to a shallow receiver plane, then
// measure the local area change of that landing map. It is intentionally not
// photon mapping, but does model ray concentration rather than direction-only
// divergence.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D normal_long_coastal;
layout(set = 0, binding = 1) uniform sampler2D normal_long_remainder;
layout(set = 0, binding = 2) uniform sampler2D normal_mid;
layout(set = 0, binding = 3) uniform sampler2D normal_short;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D caustics_field;

layout(push_constant, std430) uniform Params {
	vec4 field; // origin_x, origin_z, extent_m, projection_depth_m
	vec4 sun; // direction surface -> sun, focus clamp
	vec4 focus; // gain, compression threshold, response power, debug mode
	vec4 weights; // long coastal, long remainder, mid, short
	vec4 domains; // long coastal, long remainder, mid, short metres
} params;

vec2 spectrum_uv(vec2 world_xz, float domain_m) {
	return fract(world_xz / max(domain_m, 0.001) + 0.5);
}

vec2 slope_from_normal(vec3 normal) {
	return -normal.xz / max(abs(normal.y), 0.25);
}

vec3 normal_at(vec2 world_xz) {
	vec3 long_coastal = textureLod(normal_long_coastal, spectrum_uv(world_xz, params.domains.x), 0.0).rgb;
	vec3 long_remainder = textureLod(normal_long_remainder, spectrum_uv(world_xz, params.domains.y), 0.0).rgb;
	vec3 mid = textureLod(normal_mid, spectrum_uv(world_xz, params.domains.z), 0.0).rgb;
	vec3 short = textureLod(normal_short, spectrum_uv(world_xz, params.domains.w), 0.0).rgb;
	// Combine recovered slopes, never independent art noise or a second wave set.
	vec2 slope = slope_from_normal(long_coastal) * params.weights.x
		+ slope_from_normal(long_remainder) * params.weights.y
		+ slope_from_normal(mid) * params.weights.z
		+ slope_from_normal(short) * params.weights.w;
	return normalize(vec3(-slope.x, 1.0, -slope.y));
}

vec3 refracted_ray(vec2 world_xz) {
	vec3 normal = normal_at(world_xz);
	vec3 incident = -normalize(params.sun.xyz);
	vec3 refracted = refract(incident, normal, 1.0 / 1.333);
	if (refracted.y >= -0.001 || any(isnan(refracted)) || any(isinf(refracted))) {
		return vec3(0.0, -1.0, 0.0);
	}
	return normalize(refracted);
}

vec2 landing_at(vec2 surface_xz, out vec3 ray) {
	ray = refracted_ray(surface_xz);
	return surface_xz + ray.xz * (params.field.w / max(-ray.y, 0.05));
}

vec3 landing_debug_color(vec2 landing_xz, float determinant) {
	// A 2 m periodic marker makes the projected landing map legible without a
	// readback. The blue channel preserves fold orientation.
	vec2 cell = fract(landing_xz * 0.5);
	return vec3(cell, determinant < 0.0 ? 1.0 : 0.0);
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
	vec3 ray;
	vec3 ray_x;
	vec3 ray_z;
	vec2 landing = landing_at(world_xz, ray);
	vec2 landing_x = landing_at(world_xz + vec2(texel_m, 0.0), ray_x);
	vec2 landing_z = landing_at(world_xz + vec2(0.0, texel_m), ray_z);
	vec2 jacobian_x = (landing_x - landing) / max(texel_m, 0.001);
	vec2 jacobian_z = (landing_z - landing) / max(texel_m, 0.001);
	float determinant = jacobian_x.x * jacobian_z.y - jacobian_x.y * jacobian_z.x;
	float compression = min(1.0 / max(abs(determinant), 0.0625), 16.0);
	float focused_excess = max(compression - (1.0 + params.focus.y), 0.0);
	float focus = clamp(focused_excess * params.focus.x, 0.0, params.sun.w);
	float final_caustic = pow(focus / max(params.sun.w, 0.001), params.focus.z);

	int debug_mode = int(round(params.focus.w));
	vec3 output_color = vec3(final_caustic);
	if (debug_mode == 3) {
		output_color = vec3(ray.x * 0.5 + 0.5, ray.z * 0.5 + 0.5, clamp(-ray.y, 0.0, 1.0));
	} else if (debug_mode == 4) {
		output_color = landing_debug_color(landing, determinant);
	} else if (debug_mode == 5) {
		output_color = vec3(focus / max(params.sun.w, 0.001));
	}
	imageStore(caustics_field, coord, vec4(output_color, clamp(compression / 16.0, 0.0, 1.0)));
}

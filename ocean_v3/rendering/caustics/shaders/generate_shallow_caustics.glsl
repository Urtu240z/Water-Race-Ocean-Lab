#[compute]
#version 450

// P0 approximation: refract the sun direction by the already assembled FFT
// normal. Local finite differences of the refracted horizontal ray estimate
// convergence. This is not a physically exact photon simulation.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D normal_long_coastal;
layout(set = 0, binding = 1) uniform sampler2D normal_long_remainder;
layout(set = 0, binding = 2) uniform sampler2D normal_mid;
layout(set = 0, binding = 3) uniform sampler2D normal_short;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D caustics_field;

layout(push_constant, std430) uniform Params {
	vec4 field; // origin_x, origin_z, extent_m, focus_gain
	vec4 sun; // direction surface -> sun, focus clamp
	vec4 weights; // long, mid, short, unused
	vec4 domains; // long coastal, long remainder, mid, short metres
} params;

vec2 spectrum_uv(vec2 world_xz, float domain_m) {
	return fract(world_xz / max(domain_m, 0.001) + 0.5);
}

vec3 normal_at(vec2 world_xz) {
	vec3 long_n = textureLod(normal_long_coastal, spectrum_uv(world_xz, params.domains.x), 0.0).rgb
		+ textureLod(normal_long_remainder, spectrum_uv(world_xz, params.domains.y), 0.0).rgb;
	vec3 mid_n = textureLod(normal_mid, spectrum_uv(world_xz, params.domains.z), 0.0).rgb;
	vec3 short_n = textureLod(normal_short, spectrum_uv(world_xz, params.domains.w), 0.0).rgb;
	// Individual normal maps are already unit vectors. Combining their slopes
	// preserves the FFT-driven movement without introducing a new wave source.
	vec2 slope = -(long_n.xz * params.weights.x + mid_n.xz * params.weights.y + short_n.xz * params.weights.z);
	return normalize(vec3(-slope.x, 1.0, -slope.y));
}

vec2 refracted_ray_xz(vec2 world_xz) {
	vec3 n = normal_at(world_xz);
	vec3 incident = -normalize(params.sun.xyz);
	vec3 refracted = refract(incident, n, 1.0 / 1.333);
	if (refracted.y >= -0.001 || any(isnan(refracted)) || any(isinf(refracted))) {
		return vec2(0.0);
	}
	return refracted.xz / max(-refracted.y, 0.05);
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
	vec2 ray = refracted_ray_xz(world_xz);
	vec2 ray_x = refracted_ray_xz(world_xz + vec2(texel_m, 0.0));
	vec2 ray_z = refracted_ray_xz(world_xz + vec2(0.0, texel_m));
	float divergence = ((ray_x.x - ray.x) + (ray_z.y - ray.y)) / max(texel_m, 0.001);
	float slope_energy = clamp(length(ray), 0.0, 2.0);
	float focus_raw = max(-divergence * params.field.w, 0.0);
	float focus = clamp(focus_raw, 0.0, params.sun.w);
	float final_caustic = focus / max(params.sun.w, 0.001);
	// R final, G FFT-driven source slope, B signed convergence visualization.
	imageStore(caustics_field, coord, vec4(final_caustic, slope_energy * 0.5, divergence * 0.25 + 0.5, 1.0));
}

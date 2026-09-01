#[compute]
#version 450

// One local render-space surface sample. It reuses the published FFT maps and
// stays entirely on the GPU; its output is consumed by underwater_medium.glsl.
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_long_coastal;
layout(set = 0, binding = 1) uniform sampler2D displacement_long_remainder;
layout(set = 0, binding = 2) uniform sampler2D displacement_mid;
layout(set = 0, binding = 3) uniform sampler2D normal_long_coastal;
layout(set = 0, binding = 4) uniform sampler2D normal_long_remainder;
layout(set = 0, binding = 5) uniform sampler2D normal_mid;
layout(rgba32f, set = 0, binding = 6) uniform image2D surface_probe;

layout(set = 0, binding = 7, std140) uniform ProbeParams {
	vec4 camera_sea; // camera xz, sea level, valid source flag
	vec4 domains; // long coastal, long remainder, mid, unused
} params;


vec2 spectrum_uv(vec2 world_xz, float domain_m) {
	return fract(world_xz / max(domain_m, 0.001));
}


vec2 slope_from_normal(vec3 normal_value) {
	vec3 n = normalize(normal_value);
	return -n.xz / max(n.y, 0.001);
}


void main() {
	vec2 world_xz = params.camera_sea.xy;
	vec3 coastal_displacement = textureLod(displacement_long_coastal,
		spectrum_uv(world_xz, params.domains.x), 0.0).rgb;
	vec3 remainder_displacement = textureLod(displacement_long_remainder,
		spectrum_uv(world_xz, params.domains.y), 0.0).rgb;
	vec3 mid_displacement = textureLod(displacement_mid,
		spectrum_uv(world_xz, params.domains.z), 0.0).rgb;
	vec2 slope = slope_from_normal(textureLod(normal_long_coastal,
		spectrum_uv(world_xz, params.domains.x), 0.0).rgb);
	slope += slope_from_normal(textureLod(normal_long_remainder,
		spectrum_uv(world_xz, params.domains.y), 0.0).rgb);
	slope += slope_from_normal(textureLod(normal_mid,
		spectrum_uv(world_xz, params.domains.z), 0.0).rgb);
	float height = params.camera_sea.z + coastal_displacement.y
		+ remainder_displacement.y + mid_displacement.y;
	bool valid = params.camera_sea.w > 0.5 && !isnan(height) && !isinf(height)
		&& !any(isnan(slope)) && !any(isinf(slope));
	imageStore(surface_probe, ivec2(0), valid
		? vec4(height, slope.x, slope.y, 1.0) : vec4(params.camera_sea.z, 0.0, 0.0, 0.0));
}

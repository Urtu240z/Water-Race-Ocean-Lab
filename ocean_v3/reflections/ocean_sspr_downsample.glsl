#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_mip;
layout(rgba16f, set = 0, binding = 1) uniform writeonly image2D destination_mip;

void main() {
	ivec2 destination_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 destination_size = imageSize(destination_mip);
	if (any(greaterThanEqual(destination_pixel, destination_size))) {
		return;
	}

	ivec2 source_size = textureSize(source_mip, 0);
	ivec2 source_base = destination_pixel * 2;
	ivec2 source_max = max(source_size - ivec2(1), ivec2(0));
	ivec2 c00 = min(source_base + ivec2(0, 0), source_max);
	ivec2 c10 = min(source_base + ivec2(1, 0), source_max);
	ivec2 c01 = min(source_base + ivec2(0, 1), source_max);
	ivec2 c11 = min(source_base + ivec2(1, 1), source_max);
	vec4 s00 = texelFetch(source_mip, c00, 0);
	vec4 s10 = texelFetch(source_mip, c10, 0);
	vec4 s01 = texelFetch(source_mip, c01, 0);
	vec4 s11 = texelFetch(source_mip, c11, 0);
	float coverage = clamp(s00.a, 0.0, 1.0) + clamp(s10.a, 0.0, 1.0)
		+ clamp(s01.a, 0.0, 1.0) + clamp(s11.a, 0.0, 1.0);
	vec3 weighted_color = s00.rgb * clamp(s00.a, 0.0, 1.0)
		+ s10.rgb * clamp(s10.a, 0.0, 1.0)
		+ s01.rgb * clamp(s01.a, 0.0, 1.0)
		+ s11.rgb * clamp(s11.a, 0.0, 1.0);
	vec3 result = coverage > 0.0001 ? weighted_color / coverage : vec3(0.0);
	imageStore(destination_mip, destination_pixel, vec4(result, coverage * 0.25));
}

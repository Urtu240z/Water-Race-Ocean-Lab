#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_mip;
layout(rgba16f, set = 0, binding = 1) uniform writeonly image2D destination_mip;

const ivec2 SAMPLE_OFFSETS[5] = ivec2[](
	ivec2(0, 0),
	ivec2(-1, -1),
	ivec2(1, -1),
	ivec2(-1, 1),
	ivec2(1, 1)
);

void main() {
	ivec2 destination_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 destination_size = imageSize(destination_mip);
	if (any(greaterThanEqual(destination_pixel, destination_size))) {
		return;
	}

	ivec2 source_size = textureSize(source_mip, 0);
	ivec2 source_center = destination_pixel * 2 + ivec2(1);
	vec3 weighted_color = vec3(0.0);
	float coverage = 0.0;
	for (int sample_index = 0; sample_index < 5; sample_index++) {
		ivec2 source_pixel = clamp(
			source_center + SAMPLE_OFFSETS[sample_index],
			ivec2(0), source_size - 1);
		vec4 sample_value = texelFetch(source_mip, source_pixel, 0);
		float sample_alpha = clamp(sample_value.a, 0.0, 1.0);
		weighted_color += sample_value.rgb * sample_alpha;
		coverage += sample_alpha;
	}
	coverage /= 5.0;
	vec3 result = coverage > 0.0001 ? weighted_color / max(coverage * 5.0, 0.0001) : vec3(0.0);
	imageStore(destination_mip, destination_pixel, vec4(result, coverage));
}

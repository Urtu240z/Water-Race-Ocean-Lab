#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(r32f, set = 0, binding = 1) uniform writeonly image2D destination_depth;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(destination_depth);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	imageStore(destination_depth, pixel, vec4(texelFetch(source_depth, pixel, 0).r));
}

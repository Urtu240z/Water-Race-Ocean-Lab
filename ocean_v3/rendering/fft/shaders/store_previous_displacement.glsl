#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D displacement_map;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image2D previous_displacement_map;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(previous_displacement_map);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}
	vec2 horizontal_displacement = imageLoad(displacement_map, coord).xz;
	imageStore(previous_displacement_map, coord, vec4(horizontal_displacement, 0.0, 1.0));
}

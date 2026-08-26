#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D source_mip;
layout(rg16f, set = 0, binding = 1) uniform writeonly image2D destination_mip;

void main() {
	ivec2 dst_coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 dst_size = imageSize(destination_mip);
	if (any(greaterThanEqual(dst_coord, dst_size))) return;
	ivec2 src_size = textureSize(source_mip, 0);
	ivec2 src_base = dst_coord * 2;
	ivec2 max_coord = max(src_size - ivec2(1), ivec2(0));
	ivec2 c00 = min(src_base + ivec2(0, 0), max_coord);
	ivec2 c10 = min(src_base + ivec2(1, 0), max_coord);
	ivec2 c01 = min(src_base + ivec2(0, 1), max_coord);
	ivec2 c11 = min(src_base + ivec2(1, 1), max_coord);
	vec2 average = (
		texelFetch(source_mip, c00, 0).rg +
		texelFetch(source_mip, c10, 0).rg +
		texelFetch(source_mip, c01, 0).rg +
		texelFetch(source_mip, c11, 0).rg
	) * 0.25;
	imageStore(destination_mip, dst_coord, vec4(average, 0.0, 1.0));
}

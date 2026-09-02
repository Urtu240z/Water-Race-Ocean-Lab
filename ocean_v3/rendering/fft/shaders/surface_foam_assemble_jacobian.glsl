#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D packed_payload;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D jacobian_map;
layout(set = 0, binding = 2, std140) uniform Params { vec4 values; } params; // normalization, unused

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(packed_payload);
	if (any(greaterThanEqual(coord, size))) return;
	float checkerboard = ((coord.x + coord.y) & 1) == 0 ? 1.0 : -1.0;
	float scale = checkerboard * params.values.x;
	vec4 packed = imageLoad(packed_payload, coord);
	float dhx_dx = packed.x * scale;
	float dhz_dz = packed.y * scale;
	float dhz_dx = packed.z * scale;
	float j = (1.0 + dhx_dx) * (1.0 + dhz_dz) - dhz_dx * dhz_dx;
	imageStore(jacobian_map, coord, vec4((isnan(j) || isinf(j)) ? 1.0 : j, 0.0, 0.0, 1.0));
}

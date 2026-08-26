#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D jacobian_map;
layout(rg16f, set = 0, binding = 1) uniform writeonly image2D topology_map;

layout(push_constant, std430) uniform Params {
	vec4 values; // surface whitecap, crest whitecap, source domain, topology resolution
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(topology_map);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 uv = (vec2(coord) + 0.5) / vec2(size);
	float j = textureLod(jacobian_map, uv, 0.0).r;
	if (isnan(j) || isinf(j)) j = 1.0;
	imageStore(topology_map, coord, vec4(max(0.0, params.values.x - j), max(0.0, params.values.y - j), 0.0, 1.0));
}

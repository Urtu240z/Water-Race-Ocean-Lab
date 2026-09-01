#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(r32f, set = 0, binding = 1) uniform image2D opaque_depth;
layout(set = 0, binding = 2, std140) uniform Params { vec4 viewport; } params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (p.x >= size.x || p.y >= size.y) return;
	imageStore(opaque_depth, p, vec4(texelFetch(source_depth, p, 0).r, 0.0, 0.0, 1.0));
}

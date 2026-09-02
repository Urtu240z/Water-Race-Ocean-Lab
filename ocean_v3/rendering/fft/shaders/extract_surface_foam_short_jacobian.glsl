#[compute]
#version 450

// Adapter used only by the Surface Foam MAIN_FFT_SHORT experiment.  The main
// FFT owns the RGBA displacement texture and keeps its exact spectral J in A;
// Surface Foam keeps its established R16 J input/output contract.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_short;
layout(r16f, set = 0, binding = 1) uniform writeonly image2D jacobian_map;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(jacobian_map);
	if (any(greaterThanEqual(coord, size))) return;
	float jacobian = texelFetch(displacement_short, coord, 0).a;
	if (isnan(jacobian) || isinf(jacobian)) jacobian = 1.0;
	imageStore(jacobian_map, coord, vec4(jacobian, 0.0, 0.0, 1.0));
}

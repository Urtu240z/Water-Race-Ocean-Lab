#[compute]
#version 450

// One invocation per quarter-resolution destination pixel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D scene_color;

layout(set = 0, binding = 1, std430) readonly buffer CandidateBuffer {
	uint candidates[];
};

layout(set = 0, binding = 2, rgba16f) uniform image2D reflection_output;

layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_projection;
	mat4 inverse_view;
	mat4 view_projection;
	vec4 source_size;
	vec4 destination_size;
	vec4 ocean_level;
} params;

const uint SOURCE_ID_MASK = (1u << 26u) - 1u;

void main() {
	ivec2 destination_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 destination_extent = ivec2(params.destination_size.xy);
	if (destination_pixel.x >= destination_extent.x || destination_pixel.y >= destination_extent.y) {
		return;
	}

	uint destination_id = uint(destination_pixel.y * destination_extent.x + destination_pixel.x);
	uint payload = candidates[destination_id];
	if (payload == 0xffffffffu) {
		imageStore(reflection_output, destination_pixel, vec4(0.0));
		return;
	}

	uint source_id = payload & SOURCE_ID_MASK;
	uint source_width = uint(params.source_size.x);
	uint source_height = uint(params.source_size.y);
	uint source_pixel_count = source_width * source_height;
	if (source_width == 0u || source_id >= source_pixel_count) {
		imageStore(reflection_output, destination_pixel, vec4(0.0));
		return;
	}

	uint source_x = source_id % source_width;
	uint source_y = source_id / source_width;
	vec2 source_uv = (vec2(source_x, source_y) + 0.5) / params.source_size.xy;
	vec3 reflected_scene = texture(scene_color, source_uv).rgb;
	if (any(isnan(reflected_scene)) || any(isinf(reflected_scene))) {
		imageStore(reflection_output, destination_pixel, vec4(0.0));
		return;
	}
	// Alpha is the validity contract consumed by the spatial shader. Output is
	// HDR/linear scene color; no tonemapping or exposure is applied here.
	imageStore(reflection_output, destination_pixel, vec4(reflected_scene, 1.0));
}

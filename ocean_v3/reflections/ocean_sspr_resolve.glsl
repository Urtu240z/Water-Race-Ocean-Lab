#[compute]
#version 450

// One invocation per quarter-resolution destination pixel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D scene_color;

layout(set = 0, binding = 1, std430) readonly buffer CandidateBuffer {
	uint candidates[];
};

layout(set = 0, binding = 2, rgba16f) uniform image2D reflection_output;
layout(set = 0, binding = 4, r16f) uniform image2D reflection_depth_output;

layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_projection;
	mat4 inverse_view;
	mat4 view_projection;
	vec4 source_size;
	vec4 destination_size;
	vec4 ocean_level;
} params;

const uint SOURCE_ID_MASK = (1u << 26u) - 1u;
const uint INVALID_PAYLOAD = 0xffffffffu;
const float HOLE_FILL_ALPHA = 0.35;

void main() {
	ivec2 destination_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 destination_extent = ivec2(params.destination_size.xy);
	if (destination_pixel.x >= destination_extent.x || destination_pixel.y >= destination_extent.y) {
		return;
	}

	uint destination_id = uint(destination_pixel.y * destination_extent.x + destination_pixel.x);
	uint payload = candidates[destination_id];
	float output_alpha = 1.0;
	if (payload == INVALID_PAYLOAD) {
		// Conservative 3x3 dilation: only an immediate valid candidate may fill
		// a hole. Prefer the closest destination, then the nearest projected
		// depth, then the packed payload for a deterministic tie-break. Large
		// holes remain invalid and therefore fall back to the environment.
		uint best_payload = INVALID_PAYLOAD;
		int best_distance = 99;
		uint best_metric = 63u;
		for (int offset_y = -1; offset_y <= 1; offset_y++) {
			for (int offset_x = -1; offset_x <= 1; offset_x++) {
				if (offset_x == 0 && offset_y == 0) {
					continue;
				}
				ivec2 neighbor = destination_pixel + ivec2(offset_x, offset_y);
				if (neighbor.x < 0 || neighbor.y < 0 ||
						neighbor.x >= destination_extent.x || neighbor.y >= destination_extent.y) {
					continue;
				}
				uint neighbor_payload = candidates[uint(neighbor.y * destination_extent.x + neighbor.x)];
				if (neighbor_payload == INVALID_PAYLOAD) {
					continue;
				}
				int neighbor_distance = abs(offset_x) + abs(offset_y);
				uint neighbor_metric = neighbor_payload >> 26u;
				if (neighbor_distance < best_distance ||
						(neighbor_distance == best_distance && neighbor_metric < best_metric) ||
						(neighbor_distance == best_distance && neighbor_metric == best_metric && neighbor_payload < best_payload)) {
					best_payload = neighbor_payload;
					best_distance = neighbor_distance;
					best_metric = neighbor_metric;
				}
			}
		}
		if (best_payload == INVALID_PAYLOAD) {
			imageStore(reflection_output, destination_pixel, vec4(0.0));
			imageStore(reflection_depth_output, destination_pixel, vec4(0.0));
			return;
		}
		payload = best_payload;
		output_alpha = HOLE_FILL_ALPHA;
	}

	uint source_id = payload & SOURCE_ID_MASK;
	uint source_width = uint(params.source_size.x);
	uint source_height = uint(params.source_size.y);
	uint source_pixel_count = source_width * source_height;
	if (source_width == 0u || source_height == 0u || source_id >= source_pixel_count) {
		imageStore(reflection_output, destination_pixel, vec4(0.0));
		imageStore(reflection_depth_output, destination_pixel, vec4(0.0));
		return;
	}

	uint source_x = source_id % source_width;
	uint source_y = source_id / source_width;
	vec2 source_uv = (vec2(source_x, source_y) + 0.5) / params.source_size.xy;
	vec3 reflected_scene = texture(scene_color, source_uv).rgb;
	if (any(isnan(reflected_scene)) || any(isinf(reflected_scene))) {
		imageStore(reflection_output, destination_pixel, vec4(0.0));
		imageStore(reflection_depth_output, destination_pixel, vec4(0.0));
		return;
	}
	// Alpha is the validity contract consumed by the spatial shader. Output is
	// HDR/linear scene color; no tonemapping or exposure is applied here.
	imageStore(reflection_output, destination_pixel, vec4(reflected_scene, output_alpha));
	imageStore(reflection_depth_output, destination_pixel,
		vec4(float(payload >> 26u) / 63.0, 0.0, 0.0, 0.0));
}

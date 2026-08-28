#[compute]
#version 450

// One invocation per source depth pixel. The source is the resolved opaque +
// sky buffer captured immediately before transparent rendering.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D scene_depth;

// Candidate payload is an exact source coordinate hash:
//   high 16 bits: source Y; low 16 bits: source X.
// The stored value is packed_coordinates + 1 so zero remains an unambiguous
// invalid sentinel for atomicMax. In Godot's upper-left screen coordinates Y
// grows downwards, so the largest source Y is the stable near-water candidate;
// X breaks ties deterministically. No depth quantization or writer race is used.
layout(set = 0, binding = 1, std430) buffer CandidateBuffer {
	uint candidates[];
};

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_projection;
	mat4 inverse_view;
	mat4 view_projection;
	vec4 source_size;
	vec4 destination_size;
	vec4 ocean_level;
} params;

const uint INVALID_PAYLOAD = 0u;

void main() {
	ivec2 source_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 source_extent = ivec2(params.source_size.xy);
	if (source_pixel.x >= source_extent.x || source_pixel.y >= source_extent.y) {
		return;
	}

	float raw_depth = texelFetch(scene_depth, source_pixel, 0).r;
	// Forward+ reversed-Z sky/background is zero. Treat invalid depth as a
	// rejected candidate, never as a fabricated reflected sky sample.
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001) {
		return;
	}

	vec2 source_uv = (vec2(source_pixel) + 0.5) / params.source_size.xy;
	vec2 source_ndc = source_uv * 2.0 - 1.0;
	vec4 view_position = params.inverse_projection * vec4(source_ndc, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.000001) {
		return;
	}
	view_position /= view_position.w;
	vec4 world_position = params.inverse_view * vec4(view_position.xyz, 1.0);
	if (abs(world_position.w) <= 0.000001) {
		return;
	}
	world_position /= world_position.w;
	if (any(isnan(world_position.xyz)) || any(isinf(world_position.xyz)) || world_position.y <= params.ocean_level.x) {
		return;
	}

	// Phase 2 reflects against the mean sea plane only. FFT instantaneous
	// displacement is intentionally not consulted here.
	world_position.y = 2.0 * params.ocean_level.x - world_position.y;
	vec4 destination_clip = params.view_projection * vec4(world_position.xyz, 1.0);
	if (!(destination_clip.w > 0.000001) || any(isnan(destination_clip)) || any(isinf(destination_clip))) {
		return;
	}
	vec3 destination_ndc = destination_clip.xyz / destination_clip.w;
	if (any(isnan(destination_ndc)) || any(isinf(destination_ndc)) || destination_ndc.x < -1.0 || destination_ndc.x > 1.0 ||
			destination_ndc.y < -1.0 || destination_ndc.y > 1.0 ||
		destination_ndc.z < 0.0 || destination_ndc.z > 1.0) {
		return;
	}

	vec2 destination_uv = destination_ndc.xy * 0.5 + 0.5;
	vec2 destination_pixel_f = destination_uv * params.destination_size.xy;
	ivec2 destination_extent = ivec2(params.destination_size.xy);
	if (source_pixel.x >= 65536 || source_pixel.y >= 65536) {
		return;
	}
	uint packed_coordinates = (uint(source_pixel.y) << 16u) | uint(source_pixel.x);
	uint payload = packed_coordinates + 1u;

	if (params.ocean_level.y <= 0.5) {
		// A/B baseline: one source pixel writes its single projected destination.
		ivec2 destination_pixel = ivec2(destination_pixel_f);
		if (destination_pixel.x < 0 || destination_pixel.y < 0 ||
			destination_pixel.x >= destination_extent.x || destination_pixel.y >= destination_extent.y) {
			return;
		}
		uint destination_id = uint(destination_pixel.y * destination_extent.x + destination_pixel.x);
		atomicMax(candidates[destination_id], payload);
		return;
	}

	// Conservative coverage: splat around the continuous projected position.
	// The -0.5 accounts for texel-center coordinates, so each source candidate
	// covers exactly the 2x2 destination footprint surrounding that position.
	ivec2 base_pixel = ivec2(floor(destination_pixel_f - vec2(0.5)));
	for (int offset_y = 0; offset_y < 2; offset_y++) {
		for (int offset_x = 0; offset_x < 2; offset_x++) {
			ivec2 destination_pixel = base_pixel + ivec2(offset_x, offset_y);
			if (destination_pixel.x < 0 || destination_pixel.y < 0 ||
				destination_pixel.x >= destination_extent.x || destination_pixel.y >= destination_extent.y) {
				continue;
			}
			uint destination_id = uint(destination_pixel.y * destination_extent.x + destination_pixel.x);
			atomicMax(candidates[destination_id], payload);
		}
	}
}

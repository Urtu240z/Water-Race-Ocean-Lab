#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current_color;
layout(set = 0, binding = 1) uniform sampler2D current_depth;
layout(set = 0, binding = 2) uniform sampler2D history_color;
layout(set = 0, binding = 3) uniform sampler2D history_depth;
layout(set = 0, binding = 4, rgba16f) uniform image2D reflection_output;
layout(set = 0, binding = 5, rgba16f) uniform image2D history_color_output;
layout(set = 0, binding = 6, r16f) uniform image2D history_depth_output;

layout(set = 0, binding = 7, std140) uniform TemporalParams {
	mat4 current_inverse_view_projection;
	mat4 previous_view_projection;
	vec4 destination_size;
	vec4 temporal_settings;
	vec4 ocean_level;
} params;

vec3 world_on_ocean_plane(vec2 uv, out bool valid) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 near_point = params.current_inverse_view_projection * vec4(ndc, 0.0, 1.0);
	vec4 far_point = params.current_inverse_view_projection * vec4(ndc, 1.0, 1.0);
	if (abs(near_point.w) <= 0.000001 || abs(far_point.w) <= 0.000001) {
		valid = false;
		return vec3(0.0);
	}
	near_point /= near_point.w;
	far_point /= far_point.w;
	float denominator = far_point.y - near_point.y;
	if (abs(denominator) <= 0.000001) {
		valid = false;
		return vec3(0.0);
	}
	float ray_t = (params.ocean_level.x - near_point.y) / denominator;
	if (ray_t < 0.0 || ray_t > 1.0) {
		valid = false;
		return vec3(0.0);
	}
	valid = true;
	return mix(near_point.xyz, far_point.xyz, ray_t);
}


vec2 previous_frame_uv(vec2 current_uv, out bool valid) {
	bool world_valid = false;
	vec3 world_position = world_on_ocean_plane(current_uv, world_valid);
	if (!world_valid) {
		valid = false;
		return vec2(0.0);
	}
	vec4 previous_clip = params.previous_view_projection * vec4(world_position, 1.0);
	if (previous_clip.w <= 0.000001 || any(isnan(previous_clip)) || any(isinf(previous_clip))) {
		valid = false;
		return vec2(0.0);
	}
	vec2 previous_uv = previous_clip.xy / previous_clip.w * 0.5 + 0.5;
	valid = previous_uv.x >= 0.0 && previous_uv.x <= 1.0
		&& previous_uv.y >= 0.0 && previous_uv.y <= 1.0;
	return previous_uv;
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = ivec2(params.destination_size.xy);
	if (pixel.x >= extent.x || pixel.y >= extent.y) {
		return;
	}

	vec4 current = texelFetch(current_color, pixel, 0);
	float current_depth_value = texelFetch(current_depth, pixel, 0).r;
	vec4 result = current;
	bool current_valid = current.a > 0.001 && current_depth_value > 0.000001;
	bool history_sample_valid = false;
	vec2 current_uv = (vec2(pixel) + 0.5) / params.destination_size.xy;
	vec2 previous_uv = previous_frame_uv(current_uv, history_sample_valid);
	float history_depth_value = 0.0;
	if (params.temporal_settings.x > 0.5 && params.temporal_settings.w > 0.5 && history_sample_valid) {
		vec4 history = texture(history_color, previous_uv);
		history_depth_value = texture(history_depth, previous_uv).r;
		if (current_valid) {
			float depth_threshold = max(params.temporal_settings.z, 0.0001);
			float depth_delta = abs(current_depth_value - history_depth_value);
			float depth_confidence = 1.0 - smoothstep(
				depth_threshold, depth_threshold * 2.0, depth_delta);
			if (history.a > 0.001 && history_depth_value > 0.000001 && depth_confidence > 0.0) {
				vec3 neighborhood_min = vec3(1e20);
				vec3 neighborhood_max = vec3(-1e20);
				for (int offset_y = -1; offset_y <= 1; offset_y++) {
					for (int offset_x = -1; offset_x <= 1; offset_x++) {
						ivec2 neighbor = clamp(pixel + ivec2(offset_x, offset_y), ivec2(0), extent - 1);
						vec4 neighbor_color = texelFetch(current_color, neighbor, 0);
						if (neighbor_color.a > 0.001) {
							neighborhood_min = min(neighborhood_min, neighbor_color.rgb);
							neighborhood_max = max(neighborhood_max, neighbor_color.rgb);
						}
					}
				}
				if (neighborhood_min.x < 1e19) {
					vec3 clamped_history = clamp(history.rgb, neighborhood_min, neighborhood_max);
					float blend_weight = clamp(params.temporal_settings.y * depth_confidence
						* min(current.a, history.a), 0.0, 1.0);
					result.rgb = mix(current.rgb, clamped_history, blend_weight);
				}
			}
		}
	}

	// Invalid current pixels remain invalid. History is only allowed to
	// stabilize an already valid current candidate.
	if (!current_valid) {
		result = vec4(0.0);
	}
	imageStore(reflection_output, pixel, result);
	imageStore(history_color_output, pixel, result);
	imageStore(history_depth_output, pixel,
		vec4(current_valid ? current_depth_value : 0.0, 0.0, 0.0, 0.0));
}

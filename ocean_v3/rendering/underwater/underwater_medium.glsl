#[compute]
#version 450

// Ocean V3 underwater medium. Sunrays V4 adds one light-entry sample to the
// existing medium; it does not alter the medium's scene-water path.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D sunrays_pattern_texture;
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // xy viewport size; zw retained for compatibility.
	vec4 camera; // xyz, binary underwater state
	vec4 medium; // sea level, transition width, max distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // underwater factor, debug mode, enabled, V4 pattern texture present
	vec4 light; // xyz light_into_water: physical photon travel sun -> water, w energy
	vec4 sun_color; // rgb, unused
	vec4 sunrays; // enabled, strength, anisotropy, density
	vec4 sunrays_pattern; // scale, contrast, animation speed, time
	vec4 sunrays_extra; // maximum distance, legacy, legacy, phase-debug constant
} params;

const float EPSILON = 0.00001;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	// Godot's projection already contains the backend Y convention. Do not flip it.
	vec4 world = params.inverse_view_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(world.w) <= EPSILON) return false;
	world_position = world.xyz / world.w;
	return finite_vec3(world_position);
}

float distance_to_plane(vec3 origin, vec3 direction, float plane_y, out bool hit) {
	hit = false;
	if (abs(direction.y) <= EPSILON) return 0.0;
	float distance_m = (plane_y - origin.y) / direction.y;
	if (distance_m > EPSILON && !isnan(distance_m) && !isinf(distance_m)) {
		hit = true;
		return distance_m;
	}
	return 0.0;
}

float water_path_for_scene(vec3 scene_world, bool scene_valid, vec2 uv) {
	vec3 camera_world = params.camera.xyz;
	float sea_level = params.medium.x;
	bool camera_below = params.camera.w > 0.5;
	if (!scene_valid) {
		if (!camera_below) return 0.0;
		vec3 sky_world;
		if (reconstruct_world(uv, 0.0, sky_world)) {
			vec3 sky_direction = normalize(sky_world - camera_world);
			bool surface_hit;
			float surface_distance = distance_to_plane(camera_world, sky_direction, sea_level, surface_hit);
			if (surface_hit) return surface_distance;
		}
		return params.medium.z;
	}
	vec3 ray = scene_world - camera_world;
	float ray_length = length(ray);
	if (ray_length <= EPSILON || isnan(ray_length) || isinf(ray_length)) return 0.0;
	vec3 ray_direction = ray / ray_length;
	bool scene_below = scene_world.y < sea_level;
	if (!camera_below && !scene_below) return 0.0;
	if (camera_below && scene_below) return ray_length;
	bool surface_hit;
	float surface_distance = distance_to_plane(camera_world, ray_direction, sea_level, surface_hit);
	if (!surface_hit || surface_distance > ray_length) return 0.0;
	return camera_below ? surface_distance : ray_length - surface_distance;
}

float sunrays_phase_response(vec3 view_to_camera_dir, vec3 light_into_water) {
	if (params.sunrays_extra.w > 0.5) return 1.0;
	// The scattering angle is incoming photon travel versus outgoing sample-to-camera.
	float cos_theta = clamp(dot(view_to_camera_dir, light_into_water), -1.0, 1.0);
	float g = clamp(params.sunrays.z, 0.0, 0.95);
	float denom = 1.0 + g * g - 2.0 * g * cos_theta;
	float phase = (1.0 - g * g) / max(pow(denom, 1.5), 0.001);
	float forward_denom = 1.0 + g * g - 2.0 * g;
	float forward_phase = (1.0 - g * g) / max(pow(forward_denom, 1.5), 0.001);
	float forward_gate = smoothstep(-0.15, 0.35, cos_theta);
	return clamp(phase / max(forward_phase, 0.001) * forward_gate, 0.0, 1.0);
}

float sunrays_pattern(vec3 light_entry) {
	// This is the organic two-scale field from the first sunrays implementation.
	if (params.state.w < 0.5 || params.sunrays_pattern.y <= EPSILON) return 0.5;
	float scale = max(params.sunrays_pattern.x, 0.01);
	float time = params.sunrays_pattern.w * params.sunrays_pattern.z;
	vec2 surface_xz = light_entry.xz;
	vec2 uv_a = surface_xz * (0.006 * scale) + vec2(time * 0.018, -time * 0.011);
	vec2 uv_b = surface_xz * (0.015 * scale) + vec2(-time * 0.012, time * 0.017);
	float p1 = texture(sunrays_pattern_texture, uv_a).r;
	float p2 = texture(sunrays_pattern_texture, uv_b).r;
	float pattern = mix(p1, p2, 0.35);
	float shaped = smoothstep(0.38, 0.76, pattern);
	float contrast = clamp(params.sunrays_pattern.y / 1.4, 0.0, 1.0);
	return mix(0.5, 0.35 + 0.65 * shaped, contrast);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.z < 0.5) return;
	int debug_mode = int(params.state.y + 0.5);
	bool transmittance_bypass = debug_mode == 45;
	vec4 color = imageLoad(color_image, pixel);
	if (debug_mode == 4) {
		color.rgb = vec3(params.camera.w, params.state.x, 0.0);
		imageStore(color_image, pixel, color);
		return;
	}
	if (params.camera.w < 0.5) return;

	vec3 light_into_water = params.light.xyz;
	float light_length = length(light_into_water);
	bool light_valid = finite_vec3(light_into_water) && light_length > EPSILON
		&& !isnan(light_length) && !isinf(light_length);
	if (light_valid) light_into_water /= light_length;
	if (debug_mode == 19) {
		vec3 toward_surface = -light_into_water;
		color.rgb = light_valid
			? vec3(0.5 + 0.5 * toward_surface.y, 0.5 + 0.5 * light_into_water.y, 1.0)
			: vec3(0.0);
		imageStore(color_image, pixel, color);
		return;
	}
	if (debug_mode == 30) {
		// SUNRAYS_LIGHT_TRAVEL_VECTOR: same sun -> water direction as the green guide.
		color.rgb = light_valid ? light_into_water * 0.5 + 0.5 : vec3(0.0);
		imageStore(color_image, pixel, color);
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001
		&& reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m)) water_path_m = 0.0;

	float phase_response = 0.0;
	float depth_response = 0.0;
	float pattern_debug = 0.0;
	float sunray_segment_debug_m = 0.0;
	float sunray_segment_source_debug = 0.0; // 1 analytic sea plane, 2 scene depth, 3 max distance
	vec3 sample_point_debug = vec3(0.0);
	vec3 light_entry_debug = vec3(0.0);
	vec3 sun_transmittance_debug = vec3(0.0);
	bool sample_point_valid = false;
	bool light_entry_valid = false;
	vec3 view_ray_debug = vec3(0.0);
	bool view_ray_valid = false;
	vec3 sunray_contribution = vec3(0.0);
	bool sunrays_debug = debug_mode >= 13 && debug_mode <= 46;

	if (params.sunrays.x > 0.5 || sunrays_debug) {
		vec3 ray_reference_world = vec3(0.0);
		bool ray_reference_valid = reconstruct_world(uv, 0.0, ray_reference_world);
		vec3 view_ray_world = ray_reference_world - params.camera.xyz;
		float view_ray_length = length(view_ray_world);
		bool view_valid = ray_reference_valid && finite_vec3(view_ray_world)
			&& view_ray_length > EPSILON && !isnan(view_ray_length) && !isinf(view_ray_length);
		if (view_valid) {
			view_ray_world /= view_ray_length;
			view_ray_debug = view_ray_world;
			view_ray_valid = true;

			// This authority is separate from water_path_m. An upward ray ends at the
			// analytic sea plane, so OceanClipmap topology cannot crop sunrays.
			bool analytic_surface_hit;
			float analytic_surface_distance_m = distance_to_plane(
				params.camera.xyz, view_ray_world, params.medium.x, analytic_surface_hit);
			float segment_base_m = analytic_surface_hit ? analytic_surface_distance_m : water_path_m;
			sunray_segment_source_debug = analytic_surface_hit ? 1.0 : (segment_base_m > EPSILON ? 2.0 : 0.0);
			float max_sunray_distance = max(params.sunrays_extra.x, EPSILON);
			if (max_sunray_distance <= segment_base_m + EPSILON) sunray_segment_source_debug = 3.0;
			float sunray_segment_m = min(segment_base_m, max_sunray_distance);
			sunray_segment_debug_m = sunray_segment_m;

			if (sunray_segment_m > EPSILON && light_valid) {
				// V4 uses one deterministic representative point: the segment midpoint.
				float sample_distance = sunray_segment_m * 0.5;
				vec3 sample_point = params.camera.xyz + view_ray_world * sample_distance;
				sample_point_valid = finite_vec3(sample_point)
					&& sample_point.y <= params.medium.x + EPSILON;
				sample_point_debug = sample_point;
				vec3 toward_surface = -light_into_water;
				float denom = toward_surface.y;
				if (sample_point_valid && abs(denom) > EPSILON) {
					float light_distance = (params.medium.x - sample_point.y) / denom;
					vec3 light_entry = sample_point + toward_surface * light_distance;
					light_entry_valid = light_distance >= 0.0 && !isnan(light_distance)
						&& !isinf(light_distance) && finite_vec3(light_entry)
						&& abs(light_entry.y - params.medium.x) <= 0.01;
					if (light_entry_valid) {
						light_entry_debug = light_entry;
						float sun_water_path = length(sample_point - light_entry);
						if (!isnan(sun_water_path) && !isinf(sun_water_path)) {
							sun_transmittance_debug = exp(-max(params.absorption.rgb, vec3(0.0))
								* max(params.medium.w, 0.0) * sun_water_path);
							if (!finite_vec3(sun_transmittance_debug)) sun_transmittance_debug = vec3(0.0);
							phase_response = sunrays_phase_response(
								normalize(params.camera.xyz - sample_point), light_into_water);
							float build_up = 1.0 - exp(-max(params.sunrays.w, 0.0) * sunray_segment_m);
							float far_fade = 1.0 - smoothstep(max_sunray_distance * 0.35,
								max_sunray_distance, sunray_segment_m);
							depth_response = clamp(build_up * far_fade, 0.0, 1.0);
							pattern_debug = sunrays_pattern(light_entry);
							vec3 sunray_color = params.sun_color.rgb * max(params.light.w, 0.0)
								* params.state.x * max(params.sunrays.y, 0.0) * phase_response
								* depth_response * pattern_debug * sun_transmittance_debug;
							float sunray_luma = dot(sunray_color, vec3(0.2126, 0.7152, 0.0722));
							if (sunray_luma > 0.75) sunray_color *= 0.75 / sunray_luma;
							sunray_contribution = max(sunray_color, vec3(0.0));
						}
					}
				}
			}
		}
	}

	if (debug_mode == 1) {
		color.rgb = vec3(water_path_m / max(params.medium.z, EPSILON));
	} else if (debug_mode == 2) {
		color.rgb = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m);
	} else if (debug_mode == 3) {
		float response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		color.rgb = max(params.scattering.rgb, vec3(0.0)) * response * max(params.absorption.w, 0.0);
	} else if (debug_mode == 13) {
		color.rgb = vec3(phase_response);
	} else if (debug_mode == 14 || debug_mode == 23) {
		color.rgb = vec3(pattern_debug);
	} else if (debug_mode == 15) {
		color.rgb = vec3(depth_response);
	} else if (debug_mode == 16 || debug_mode == 22 || debug_mode == 28 || debug_mode == 37 || debug_mode == 38) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 17) {
		color.rgb = sample_point_valid ? vec3(1.0,
			clamp(length(sample_point_debug - params.camera.xyz) / max(sunray_segment_debug_m, EPSILON), 0.0, 1.0), 0.0) : vec3(0.0);
	} else if (debug_mode == 18) {
		float entry_plane_error = abs(light_entry_debug.y - params.medium.x);
		color.rgb = light_entry_valid
			? vec3(pattern_debug, clamp(entry_plane_error * 100.0, 0.0, 1.0), 1.0 - pattern_debug)
			: vec3(0.0);
	} else if (debug_mode == 20) {
		color.rgb = light_entry_valid ? vec3(1.0) : vec3(0.0);
	} else if (debug_mode == 21) {
		color.rgb = sun_transmittance_debug;
	} else if (debug_mode == 31) {
		color.rgb = scene_valid ? 0.5 + 0.5 * sin(scene_world * vec3(0.071, 0.113, 0.097)) : vec3(0.0);
	} else if (debug_mode == 32) {
		color.rgb = view_ray_valid ? view_ray_debug * 0.5 + 0.5 : vec3(0.0);
	} else if (debug_mode == 42) {
		color.rgb = sunray_segment_source_debug == 1.0 ? vec3(0.0, 1.0, 0.0)
			: sunray_segment_source_debug == 2.0 ? vec3(1.0, 0.0, 0.0)
			: sunray_segment_source_debug == 3.0 ? vec3(0.0, 0.0, 1.0) : vec3(0.0);
	} else if (debug_mode == 46) {
		color.rgb = vec3(clamp(sunray_segment_debug_m / max(params.sunrays_extra.x, EPSILON), 0.0, 1.0));
	} else if (water_path_m > EPSILON) {
		vec3 transmittance = transmittance_bypass ? vec3(1.0)
			: exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m);
		float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		color.rgb = color.rgb * transmittance
			+ max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.absorption.w, 0.0)
			+ sunray_contribution;
	}
	imageStore(color_image, pixel, color);
}

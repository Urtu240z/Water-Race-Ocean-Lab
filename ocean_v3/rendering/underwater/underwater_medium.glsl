#[compute]
#version 450

// Simple binary medium: a flat sea-level interface and one POST_TRANSPARENT pass.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D sunrays_pattern_texture;

layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport;
	vec4 camera; // xyz, binary underwater state
	vec4 medium; // sea level, transition width, max distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // underwater factor, debug mode, enabled, unused
	vec4 sun; // direction from the water toward the sun, energy
	vec4 sun_color; // rgb
	vec4 sunrays; // enabled, strength, anisotropy, density
	vec4 sunrays_pattern; // scale, contrast, animation speed, time
	vec4 sunrays_extra; // maximum distance, benchmark tap count, unused
} params;

const float EPSILON = 0.00001;
const float TAP_0 = 0.125;
const float TAP_1 = 0.375;
const float TAP_2 = 0.625;
const float TAP_3 = 0.875;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
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

float sunrays_phase_response(vec3 view_dir_world, vec3 sun_direction_world) {
	// HG keeps the directional lobe cheap while the extra gate makes the back
	// side effectively dark enough for underwater gameplay.
	float cos_theta = clamp(dot(view_dir_world, -sun_direction_world), -1.0, 1.0);
	float g = clamp(params.sunrays.z, 0.0, 0.95);
	float denom = 1.0 + g * g - 2.0 * g * cos_theta;
	float phase = (1.0 - g * g) / max(pow(denom, 1.5), 0.001);
	float forward_denom = 1.0 + g * g - 2.0 * g;
	float forward_phase = (1.0 - g * g) / max(pow(forward_denom, 1.5), 0.001);
	float forward_gate = smoothstep(-0.15, 0.35, cos_theta);
	return clamp(phase / max(forward_phase, 0.001) * forward_gate, 0.0, 1.0);
}

float sunrays_pattern(vec3 surface_world, bool exaggerated) {
	if (params.state.w < 0.5 || (!exaggerated && params.sunrays_pattern.y <= EPSILON)) return 0.5;
	float scale = max(params.sunrays_pattern.x, 0.01);
	float time = params.sunrays_pattern.w * params.sunrays_pattern.z;
	vec2 surface_xz = surface_world.xz;
	// Both lobes use the existing caustics texture, but different world scales
	// and slow directions keep the breakup broad, soft, and non-grid-like.
	vec2 uv_a = surface_xz * (0.006 * scale) + vec2(time * 0.018, -time * 0.011);
	vec2 uv_b = surface_xz * (0.015 * scale) + vec2(-time * 0.012, time * 0.017);
	float p1 = texture(sunrays_pattern_texture, uv_a).r;
	float p2 = texture(sunrays_pattern_texture, uv_b).r;
	float pattern = mix(p1, p2, 0.35);
	float shaped = smoothstep(exaggerated ? 0.30 : 0.38, exaggerated ? 0.68 : 0.76, pattern);
	float contrast = exaggerated ? 1.0 : clamp(params.sunrays_pattern.y / 1.4, 0.0, 1.0);
	float low_value = exaggerated ? 0.12 : 0.35;
	return mix(0.5, low_value + (1.0 - low_value) * shaped, contrast);
}

bool evaluate_sunray_tap(vec3 camera_world, vec3 view_ray_world, float sunray_segment_m,
		float sea_level, vec3 toward_sun, vec3 absorption, float absorption_scale,
		float tap_fraction, bool exaggerated, out vec3 sample_point, out vec3 light_entry,
		out vec3 transmittance, out float pattern) {
	sample_point = camera_world + view_ray_world * (sunray_segment_m * tap_fraction);
	light_entry = vec3(0.0);
	transmittance = vec3(0.0);
	pattern = 0.0;
	if (sunray_segment_m <= EPSILON || !finite_vec3(sample_point)) return false;
	float denom = toward_sun.y;
	if (!finite_vec3(toward_sun) || abs(denom) <= EPSILON) return false;
	float light_distance = (sea_level - sample_point.y) / denom;
	if (light_distance < 0.0 || isnan(light_distance) || isinf(light_distance)) return false;
	light_entry = sample_point + toward_sun * light_distance;
	if (!finite_vec3(light_entry) || abs(light_entry.y - sea_level) > 0.01) return false;
	float sun_water_path = length(light_entry - sample_point);
	if (sun_water_path < 0.0 || isnan(sun_water_path) || isinf(sun_water_path)) return false;
	float effective_absorption_scale = max(absorption_scale, 0.0) * (exaggerated ? 0.20 : 1.0);
	transmittance = exp(-max(absorption, vec3(0.0)) * effective_absorption_scale * sun_water_path);
	if (!finite_vec3(transmittance)) return false;
	pattern = sunrays_pattern(light_entry, exaggerated);
	return !isnan(pattern) && !isinf(pattern);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.z < 0.5) return;
	int debug_mode = int(params.state.y + 0.5);
	vec4 color = imageLoad(color_image, pixel);
	// CAMERA_STATE is deliberately useful while the camera is above water. It
	// does not touch depth or reconstruct any path, so it remains a cheap
	// diagnostic even though normal AIR frames are gated off by the effect.
	if (debug_mode == 4) {
		color.rgb = vec3(params.camera.w, params.state.x, 0.0);
		imageStore(color_image, pixel, color);
		return;
	}
	if (params.camera.w < 0.5) return;
	if (debug_mode == 19) {
		vec3 toward_sun = params.sun.xyz;
		float sun_length = length(toward_sun);
		bool sun_valid = finite_vec3(toward_sun) && sun_length > EPSILON
			&& !isnan(sun_length) && !isinf(sun_length);
		if (sun_valid) toward_sun /= sun_length;
		vec3 light_into_water = -toward_sun;
		// Red encodes toward_sun.y and green encodes light_into_water.y;
		// 0.5 is zero, values above/below it are positive/negative.
		color.rgb = sun_valid
			? vec3(0.5 + 0.5 * toward_sun.y, 0.5 + 0.5 * light_into_water.y, 1.0)
			: vec3(0.0);
		imageStore(color_image, pixel, color);
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001 && reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m)) water_path_m = 0.0;
	float phase_response = 0.0;
	float depth_response = 0.0;
	float pattern_debug = 0.0;
	vec3 sample_point_debug = vec3(0.0);
	vec3 light_entry_debug = vec3(0.0);
	vec3 shaft_integral = vec3(0.0);
	int valid_tap_count = 0;
	vec3 sunray_contribution = vec3(0.0);
	bool sunrays_debug = debug_mode >= 13 && debug_mode <= 22;
	bool exaggerated = debug_mode == 22;
	bool force_pattern_debug = debug_mode == 14 || debug_mode == 18 || exaggerated;
	int tap_count = int(params.sunrays_extra.y + 0.5);
	// Only the benchmark may select the legacy midpoint. Production is always
	// four fixed taps; unknown values fail closed to the production path.
	bool one_tap_benchmark = tap_count == 1;
	if (params.sunrays.x > 0.5 || sunrays_debug) {
		vec3 sample_world = scene_world;
		if (!scene_valid) reconstruct_world(uv, 0.0, sample_world);
		vec3 view_ray_world = sample_world - params.camera.xyz;
		float view_ray_length = length(view_ray_world);
		bool view_valid = finite_vec3(sample_world) && view_ray_length > EPSILON
			&& !isnan(view_ray_length) && !isinf(view_ray_length);
		if (view_valid) {
			view_ray_world /= view_ray_length;
			vec3 toward_sun = params.sun.xyz;
			float sun_length = length(toward_sun);
			bool sun_direction_valid = finite_vec3(toward_sun) && sun_length > EPSILON
				&& !isnan(sun_length) && !isinf(sun_length);
			if (sun_direction_valid) toward_sun /= sun_length;
			// params.sun.xyz points from water toward the sun. Light physically
			// travels into the water along light_into_water = -toward_sun.
			vec3 view_dir_world = -view_ray_world;
		phase_response = sun_direction_valid
			? sunrays_phase_response(view_dir_world, toward_sun)
			: 0.0;
		float max_sunray_distance = max(params.sunrays_extra.x, EPSILON) * (exaggerated ? 1.35 : 1.0);
		float sunray_segment_m = min(water_path_m, max_sunray_distance);
		if (sunray_segment_m > EPSILON) {
			vec3 tap_point_0; vec3 tap_point_1; vec3 tap_point_2; vec3 tap_point_3;
			vec3 tap_entry_0; vec3 tap_entry_1; vec3 tap_entry_2; vec3 tap_entry_3;
			vec3 tap_transmittance_0; vec3 tap_transmittance_1;
			vec3 tap_transmittance_2; vec3 tap_transmittance_3;
			float tap_pattern_0; float tap_pattern_1; float tap_pattern_2; float tap_pattern_3;
			bool tap_valid_0 = false; bool tap_valid_1 = false;
			bool tap_valid_2 = false; bool tap_valid_3 = false;
			if (sun_direction_valid) {
				tap_valid_0 = evaluate_sunray_tap(params.camera.xyz, view_ray_world, sunray_segment_m,
						params.medium.x, toward_sun, params.absorption.rgb, params.medium.w,
						one_tap_benchmark ? 0.5 : TAP_0, force_pattern_debug, tap_point_0, tap_entry_0,
					tap_transmittance_0, tap_pattern_0);
				if (!one_tap_benchmark) {
						tap_valid_1 = evaluate_sunray_tap(params.camera.xyz, view_ray_world, sunray_segment_m,
							params.medium.x, toward_sun, params.absorption.rgb, params.medium.w, TAP_1,
							force_pattern_debug, tap_point_1, tap_entry_1, tap_transmittance_1, tap_pattern_1);
						tap_valid_2 = evaluate_sunray_tap(params.camera.xyz, view_ray_world, sunray_segment_m,
							params.medium.x, toward_sun, params.absorption.rgb, params.medium.w, TAP_2,
							force_pattern_debug, tap_point_2, tap_entry_2, tap_transmittance_2, tap_pattern_2);
						tap_valid_3 = evaluate_sunray_tap(params.camera.xyz, view_ray_world, sunray_segment_m,
							params.medium.x, toward_sun, params.absorption.rgb, params.medium.w, TAP_3,
							force_pattern_debug, tap_point_3, tap_entry_3, tap_transmittance_3, tap_pattern_3);
				}
			}
			valid_tap_count = (tap_valid_0 ? 1 : 0) + (tap_valid_1 ? 1 : 0)
				+ (tap_valid_2 ? 1 : 0) + (tap_valid_3 ? 1 : 0);
			if (tap_valid_0) {
				sample_point_debug += tap_point_0;
				light_entry_debug += tap_entry_0;
				pattern_debug += tap_pattern_0;
				shaft_integral += tap_pattern_0 * tap_transmittance_0 * max(params.sunrays.w, 0.0) * (sunray_segment_m * 0.25);
			}
			if (tap_valid_1) {
				sample_point_debug += tap_point_1;
				light_entry_debug += tap_entry_1;
				pattern_debug += tap_pattern_1;
				shaft_integral += tap_pattern_1 * tap_transmittance_1 * max(params.sunrays.w, 0.0) * (sunray_segment_m * 0.25);
			}
			if (tap_valid_2) {
				sample_point_debug += tap_point_2;
				light_entry_debug += tap_entry_2;
				pattern_debug += tap_pattern_2;
				shaft_integral += tap_pattern_2 * tap_transmittance_2 * max(params.sunrays.w, 0.0) * (sunray_segment_m * 0.25);
			}
			if (tap_valid_3) {
				sample_point_debug += tap_point_3;
				light_entry_debug += tap_entry_3;
				pattern_debug += tap_pattern_3;
				shaft_integral += tap_pattern_3 * tap_transmittance_3 * max(params.sunrays.w, 0.0) * (sunray_segment_m * 0.25);
			}
			if (valid_tap_count > 0) {
				sample_point_debug /= float(valid_tap_count);
				light_entry_debug /= float(valid_tap_count);
				pattern_debug /= float(valid_tap_count);
			}
			float build_up = 1.0 - exp(-max(params.sunrays.w, 0.0) * sunray_segment_m * (exaggerated ? 0.50 : 0.25));
			float density_path = max(params.sunrays.w, 0.0) * sunray_segment_m;
			float integration_normalizer = 1.0 / max(1.0, density_path);
			depth_response = clamp(build_up, 0.0, 1.0);
			float final_gain = max(params.sun.w, 0.0) * params.state.x
				* max(params.sunrays.y, 0.0) * phase_response * depth_response * integration_normalizer;
			if (exaggerated) final_gain *= 4.0;
			sunray_contribution = max(shaft_integral * final_gain, vec3(0.0));
			float sunray_luma = dot(sunray_contribution, vec3(0.2126, 0.7152, 0.0722));
			float luma_limit = exaggerated ? 2.0 : 0.75;
			if (sunray_luma > luma_limit) sunray_contribution *= luma_limit / sunray_luma;
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
	} else if (debug_mode == 4) {
		color.rgb = vec3(params.camera.w, params.state.x, 0.0);
	} else if (debug_mode == 13) {
		color.rgb = vec3(phase_response);
	} else if (debug_mode == 14) {
		color.rgb = vec3(pattern_debug);
	} else if (debug_mode == 15) {
		color.rgb = vec3(depth_response);
	} else if (debug_mode == 16) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 17) {
		color.rgb = valid_tap_count > 0 ? vec3(1.0,
			clamp(length(sample_point_debug - params.camera.xyz) / max(water_path_m, EPSILON), 0.0, 1.0), 0.0) : vec3(0.0);
	} else if (debug_mode == 18) {
		float entry_plane_error = abs(light_entry_debug.y - params.medium.x);
		color.rgb = valid_tap_count > 0
			? vec3(pattern_debug, clamp(entry_plane_error * 100.0, 0.0, 1.0), 1.0 - pattern_debug)
			: vec3(0.0);
	} else if (debug_mode == 20) {
		color.rgb = vec3(float(valid_tap_count) / 4.0);
	} else if (debug_mode == 21) {
		color.rgb = vec3(1.0) - exp(-max(shaft_integral, vec3(0.0)));
	} else if (debug_mode == 22) {
		color.rgb = sunray_contribution;
	} else if (water_path_m > EPSILON) {
		vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m);
		float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		// Existing isotropic medium scattering stays intact; sunrays are an
		// additional directional term and never replace this result.
		color.rgb = color.rgb * transmittance
			+ max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.absorption.w, 0.0)
			+ sunray_contribution;
	}
	imageStore(color_image, pixel, color);
}

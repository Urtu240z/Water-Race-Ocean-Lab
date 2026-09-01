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
	vec4 sun_color; // rgb, unused
	vec4 sunrays; // enabled, strength, anisotropy, density
	vec4 sunrays_pattern; // scale, contrast, animation speed, time
	vec4 sunrays_extra; // maximum distance, unused
} params;

const float EPSILON = 0.00001;

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

float sunrays_pattern(vec3 surface_world) {
	if (params.state.w < 0.5 || params.sunrays_pattern.y <= EPSILON) return 0.5;
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
	float shaped = smoothstep(0.38, 0.76, pattern);
	float contrast = clamp(params.sunrays_pattern.y / 1.4, 0.0, 1.0);
	return mix(0.5, 0.35 + 0.65 * shaped, contrast);
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
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001 && reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m)) water_path_m = 0.0;
	vec3 sample_point = vec3(0.0);
	vec3 light_entry = vec3(0.0);
	bool sample_point_valid = false;
	bool light_entry_valid = false;
	float phase_response = 0.0;
	float depth_response = 0.0;
	float shaft_pattern = 0.5;
	float sample_distance_debug = 0.0;
	vec3 sunray_contribution = vec3(0.0);
	bool sunrays_debug = debug_mode >= 13 && debug_mode <= 18;
	if (params.sunrays.x > 0.5 || sunrays_debug) {
		vec3 sample_world = scene_world;
		if (!scene_valid) reconstruct_world(uv, 0.0, sample_world);
		vec3 view_ray_world = sample_world - params.camera.xyz;
		float view_ray_length = length(view_ray_world);
		bool view_valid = finite_vec3(sample_world) && view_ray_length > EPSILON
			&& !isnan(view_ray_length) && !isinf(view_ray_length);
		if (view_valid) {
			view_ray_world /= view_ray_length;
			float sample_distance = clamp(water_path_m * 0.5, 0.0, water_path_m);
			sample_distance_debug = sample_distance;
			sample_point = params.camera.xyz + view_ray_world * sample_distance;
			sample_point_valid = water_path_m > EPSILON && finite_vec3(sample_point)
				&& sample_point.y < params.medium.x + EPSILON
				&& sample_distance <= water_path_m + EPSILON;
			vec3 toward_sun = params.sun.xyz;
			float sun_length = length(toward_sun);
			bool sun_direction_valid = finite_vec3(toward_sun) && sun_length > EPSILON
				&& !isnan(sun_length) && !isinf(sun_length);
			if (sun_direction_valid) toward_sun /= sun_length;
			// params.sun.xyz points from water toward the sun. Light physically
			// travels into the water along light_into_water = -toward_sun.
			float denom = toward_sun.y;
			if (sample_point_valid && sun_direction_valid && abs(denom) > EPSILON) {
				float light_distance = (params.medium.x - sample_point.y) / denom;
				vec3 projected_entry = sample_point + toward_sun * light_distance;
				light_entry_valid = light_distance >= 0.0
					&& !isnan(light_distance) && !isinf(light_distance)
					&& finite_vec3(projected_entry);
				if (light_entry_valid) light_entry = projected_entry;
			}
			vec3 view_dir_world = -view_ray_world;
			phase_response = sun_direction_valid
				? sunrays_phase_response(view_dir_world, toward_sun)
				: 0.0;
			if (water_path_m > EPSILON) {
				float path_for_sunrays = min(water_path_m, max(params.sunrays_extra.x, EPSILON));
				float build_up = 1.0 - exp(-max(params.sunrays.w, 0.0) * path_for_sunrays);
				vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0))
					* max(params.medium.w, 0.0) * path_for_sunrays);
				float trans_luma = dot(transmittance, vec3(0.2126, 0.7152, 0.0722));
				float max_sunray_distance = max(params.sunrays_extra.x, EPSILON);
				float far_fade = 1.0 - smoothstep(max_sunray_distance * 0.35,
					max_sunray_distance, water_path_m);
				depth_response = clamp(build_up * trans_luma * far_fade, 0.0, 1.0);
				shaft_pattern = light_entry_valid ? sunrays_pattern(light_entry) : 0.5;
				vec3 sunray_color = params.sun_color.rgb * max(params.sun.w, 0.0)
					* params.state.x * params.sunrays.y * phase_response
					* depth_response * shaft_pattern;
				float sunray_luma = dot(sunray_color, vec3(0.2126, 0.7152, 0.0722));
				if (sunray_luma > 0.75) sunray_color *= 0.75 / sunray_luma;
				sunray_contribution = max(sunray_color, vec3(0.0));
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
		color.rgb = vec3(shaft_pattern);
	} else if (debug_mode == 15) {
		color.rgb = vec3(depth_response);
	} else if (debug_mode == 16) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 17) {
		color.rgb = sample_point_valid
			? vec3(1.0, clamp(sample_distance_debug / max(water_path_m, EPSILON), 0.0, 1.0), 0.0)
			: vec3(0.0, 0.0, 0.0);
	} else if (debug_mode == 18) {
		color.rgb = light_entry_valid ? vec3(sunrays_pattern(light_entry)) : vec3(0.0);
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

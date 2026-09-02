shader_type spatial;

// Depth testing is disabled so fragments behind the seabed reach the shader;
// geometry_edge_softness_m then fades them against the sampled scene depth.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled;

uniform sampler2D sediment_field_texture : repeat_disable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec2 sediment_field_origin_xz = vec2(0.0);
uniform vec2 sediment_field_extent_m = vec2(1.0);
uniform vec4 particle_color : source_color = vec4(0.32, 0.27, 0.16, 0.06);
uniform float strength = 1.0;
uniform float alpha_multiplier = 1.0;
uniform float size_multiplier = 1.0;
uniform float geometry_edge_softness_m = 1.0;
uniform float distance_fade_start_m = 36.0;
uniform float distance_fade_end_m = 72.0;
uniform float sea_level_y = 0.0;
uniform vec3 camera_world_position = vec3(0.0);
uniform vec3 optical_absorption_coeff_rgb = vec3(0.35, 0.14, 0.10);
uniform float optical_absorption_scale = 1.0;
uniform float optical_max_distance_m = 120.0;
uniform float optical_compensation_max = 4.0;
uniform bool optical_compensation_enabled = true;
uniform float field_threshold = 0.10;
uniform float field_contrast = 0.75;
uniform bool wisps = false;
// 0 = production; 1/2 = Stage 2/3 plumbing; 3..6 = production alpha
// components; 7 = production output exaggerated only.
uniform int debug_mode = 0;

varying float particle_distance_m;
varying float particle_field_density;
varying float particle_lifecycle_fade;
varying float particle_view_depth;
varying vec3 particle_world_position;

float sample_density(vec3 world_position) {
	vec2 uv = (world_position.xz - sediment_field_origin_xz) / max(sediment_field_extent_m, vec2(0.001));
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	return inside * clamp(texture(sediment_field_texture, clamp(uv, vec2(0.0), vec2(1.0))).r, 0.0, 1.0);
}

void vertex() {
	vec3 particle_center_world = MODEL_MATRIX[3].xyz;
	float particle_width = length(MODEL_MATRIX[0].xyz) * max(size_multiplier, 0.01);
	float particle_height = length(MODEL_MATRIX[1].xyz) * max(size_multiplier, 0.01);
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	vec3 billboard_world = particle_center_world
		+ camera_right * VERTEX.x * particle_width
		+ camera_up * VERTEX.y * particle_height;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(billboard_world, 1.0);
	particle_distance_m = distance(camera_world_position, particle_center_world);
	particle_field_density = sample_density(particle_center_world);
	particle_lifecycle_fade = clamp(length(MODEL_MATRIX[2].xyz), 0.0, 1.0);
	particle_view_depth = max(-(VIEW_MATRIX * vec4(billboard_world, 1.0)).z, 0.0);
	particle_world_position = particle_center_world;
}

float optical_water_path(vec3 world_position) {
	vec3 segment = world_position - camera_world_position;
	float segment_length = length(segment);
	if (segment_length <= 0.00001 || isnan(segment_length) || isinf(segment_length)) return 0.0;
	if (world_position.y < sea_level_y) return segment_length;
	if (abs(segment.y) <= 0.00001) return 0.0;
	float surface_fraction = (sea_level_y - camera_world_position.y) / segment.y;
	return clamp(surface_fraction, 0.0, 1.0) * segment_length;
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radius = length(centered_uv);
	float angle = atan(centered_uv.y, centered_uv.x);
	float irregular_edge = 1.0
		+ 0.10 * sin(angle * 3.0 + 0.9)
		+ 0.06 * sin(angle * 7.0 - 1.3)
		+ 0.035 * sin(angle * 11.0 + 2.1);
	float soft_shape = 1.0 - smoothstep(0.55 * irregular_edge, irregular_edge, radius);
	soft_shape *= smoothstep(0.0, 0.25, soft_shape);
	if (wisps) {
		float filament = 1.0 - smoothstep(0.18, 0.72, abs(centered_uv.y + 0.18 * sin(centered_uv.x * 4.0)));
		soft_shape *= filament;
	}
	if (debug_mode == 1) {
		// Stage 2: process-shader candidates only. Do not sample the field or use
		// production density/alpha, so a missing candidate cannot be mistaken for
		// subtle production art direction.
		ALBEDO = vec3(0.02, 1.0, 0.16);
		ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
	} else if (debug_mode == 2) {
		// Stage 3: the same world->field UV mapping as production. Red proves a
		// valid candidate outside the field; bright green proves a field match.
		bool matched = particle_field_density >= field_threshold;
		ALBEDO = matched ? vec3(0.02, 1.0, 0.16) : vec3(1.0, 0.025, 0.02);
		ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
	} else {
		float density = smoothstep(field_threshold, 1.0, particle_field_density);
		density = pow(max(density, 0.0), max(field_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(
			distance_fade_start_m,
			max(distance_fade_end_m, distance_fade_start_m + 0.001),
			particle_distance_m);
		float geometry_fade = 1.0;
		float scene_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		bool scene_depth_valid = scene_raw_depth > 0.000001
			&& scene_raw_depth <= 1.000001
			&& !isnan(scene_raw_depth) && !isinf(scene_raw_depth);
		float optical_max_distance = max(optical_max_distance_m, 0.001);
		vec3 optical_absorption = max(optical_absorption_coeff_rgb, vec3(0.0))
			* max(optical_absorption_scale, 0.0);
		float particle_water_path = min(optical_water_path(particle_world_position), optical_max_distance);
		vec3 particle_transmittance = exp(-optical_absorption * particle_water_path);
		float background_water_path = optical_max_distance;
		if (scene_depth_valid) {
			vec4 scene_view_position = INV_PROJECTION_MATRIX * vec4(
				SCREEN_UV * 2.0 - 1.0,
				scene_raw_depth,
				1.0);
			if (abs(scene_view_position.w) > 0.000001) {
				vec3 scene_world_position = (INV_VIEW_MATRIX * (scene_view_position / scene_view_position.w)).xyz;
				float scene_distance = distance(camera_world_position, scene_world_position);
				if (!isnan(scene_distance) && !isinf(scene_distance)) {
					background_water_path = min(optical_water_path(scene_world_position), optical_max_distance);
				}
			}
		}
		vec3 background_transmittance = exp(-optical_absorption * background_water_path);
		vec3 compensation = vec3(1.0);
		bool compensation_active = optical_compensation_enabled;
		if (debug_mode == 12) compensation_active = false;
		if (debug_mode == 13) compensation_active = true;
		if (compensation_active) {
			// POST_TRANSPARENT multiplies the already-composited pixel by
			// T_background. Pre-multiplying only the particle color by
			// T_particle/T_background leaves its final contribution at T_particle.
			compensation = particle_transmittance / max(background_transmittance, vec3(0.02));
			compensation = clamp(compensation, vec3(0.0), vec3(max(optical_compensation_max, 1.0)));
		}
		if (geometry_edge_softness_m > 0.001) {
			if (scene_depth_valid) {
				vec4 edge_scene_view_position = INV_PROJECTION_MATRIX * vec4(
					SCREEN_UV * 2.0 - 1.0,
					scene_raw_depth,
					1.0);
				float scene_view_depth = max(-edge_scene_view_position.z / max(edge_scene_view_position.w, 0.000001), 0.0);
				float depth_gap = scene_view_depth - particle_view_depth;
				geometry_fade = smoothstep(
					-geometry_edge_softness_m,
					geometry_edge_softness_m,
					depth_gap);
			}
		}
		float alpha_final = soft_shape * density * distance_fade * geometry_fade
			* particle_lifecycle_fade * particle_color.a * strength * max(alpha_multiplier, 0.0);
		if (debug_mode == 14) {
			ALBEDO = vec3(clamp(background_water_path / optical_max_distance, 0.0, 1.0));
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 15) {
			ALBEDO = vec3(clamp(particle_water_path / optical_max_distance, 0.0, 1.0));
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 16) {
			float depth_delta_normalized = clamp((background_water_path - particle_water_path) / optical_max_distance, -1.0, 1.0);
			ALBEDO = depth_delta_normalized >= 0.0
				? vec3(0.0, depth_delta_normalized, 0.0)
				: vec3(-depth_delta_normalized, 0.0, 0.0);
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 8) {
			ALBEDO = particle_transmittance;
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 9) {
			ALBEDO = background_transmittance;
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 10) {
			ALBEDO = compensation / max(optical_compensation_max, 1.0);
			ALPHA = clamp(soft_shape * 0.92, 0.0, 1.0);
		} else if (debug_mode == 11) {
			ALBEDO = vec3(1.0);
			ALPHA = clamp(alpha_final, 0.0, 1.0);
		} else if (debug_mode == 3) {
			// Component views are white with their real value as opacity. This keeps
			// zero-valued candidates transparent instead of drawing black quads.
			ALBEDO = vec3(1.0);
			ALPHA = clamp(density, 0.0, 1.0);
		} else if (debug_mode == 4) {
			ALBEDO = vec3(1.0);
			ALPHA = clamp(soft_shape, 0.0, 1.0);
		} else if (debug_mode == 5) {
			ALBEDO = vec3(1.0);
			ALPHA = clamp(distance_fade, 0.0, 1.0);
		} else if (debug_mode == 6) {
			// Raw production alpha before the safety clamp: no boosted display value.
			ALBEDO = vec3(1.0);
			ALPHA = clamp(alpha_final, 0.0, 1.0);
		} else {
			float visual_alpha = alpha_final * (debug_mode == 7 ? 5.0 : 1.0);
			ALBEDO = clamp(particle_color.rgb * compensation, vec3(0.0), vec3(4.0));
			ALPHA = clamp(visual_alpha, 0.0, 0.35);
		}
	}
}

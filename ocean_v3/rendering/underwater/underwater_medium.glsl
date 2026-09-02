#[compute]
#version 450

// Ocean V3 underwater medium. Sunrays use the pre-lattice light-space field:
// world-fixed longitudinal slabs integrate a continuous beam field transverse to L.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // xy viewport, z wave depth fade, w legacy segment mode
	vec4 camera; // xyz, binary underwater state
	vec4 medium; // sea level, transition width, max distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // underwater factor, debug mode, enabled, wave modulation enabled
	vec4 light; // xyz light_into_water: physical photon travel sun -> water, w energy
	vec4 sun_color; // rgb, wave intensity strength
	vec4 sunrays; // enabled, strength, anisotropy, density
	vec4 sunrays_pattern; // scale, contrast, animation speed, time
	vec4 sunrays_extra; // maximum distance, length variation, wave width strength, phase-debug constant
} params;

const float EPSILON = 0.00001;
const float SUNRAY_WORLD_SLICE_SPACING_M = 14.0;
const float SUNRAY_BROAD_RIBBON_WIDTH_M = 16.0;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	// The backend projection already contains Godot's Y convention; do not flip it.
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
	float cos_theta = clamp(dot(view_to_camera_dir, light_into_water), -1.0, 1.0);
	float g = clamp(params.sunrays.z, 0.0, 0.95);
	float denom = 1.0 + g * g - 2.0 * g * cos_theta;
	float phase = (1.0 - g * g) / max(pow(denom, 1.5), 0.001);
	float forward_denom = 1.0 + g * g - 2.0 * g;
	float forward_phase = (1.0 - g * g) / max(pow(forward_denom, 1.5), 0.001);
	float forward_gate = smoothstep(-0.15, 0.35, cos_theta);
	return clamp(phase / max(forward_phase, 0.001) * forward_gate, 0.0, 1.0);
}

bool sunrays_stable_light_basis(vec3 world_position, vec3 light_into_water,
		out vec2 stable_light_coord, out vec3 stable_side_axis, out vec3 stable_in_plane_axis) {
	// The basis is fixed by L and WORLD_UP, so both shaft shape and identity stay in world space.
	stable_light_coord = vec2(0.0);
	stable_side_axis = vec3(0.0);
	stable_in_plane_axis = vec3(0.0);
	if (!finite_vec3(light_into_water) || length(light_into_water) <= EPSILON) return false;
	vec3 l = normalize(light_into_water);
	vec3 side = cross(vec3(0.0, 1.0, 0.0), l);
	if (!finite_vec3(side) || length(side) <= EPSILON) {
		vec3 reference = abs(l.z) < 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
		side = cross(reference, l);
	}
	if (!finite_vec3(side) || length(side) <= EPSILON) return false;
	side = normalize(side);
	vec3 in_plane = cross(l, side);
	if (!finite_vec3(in_plane) || length(in_plane) <= EPSILON) return false;
	in_plane = normalize(in_plane);
	stable_side_axis = side;
	stable_in_plane_axis = in_plane;
	stable_light_coord = vec2(dot(world_position, side), dot(world_position, in_plane));
	return !any(isnan(stable_light_coord)) && !any(isinf(stable_light_coord));
}

float sunrays_wave_focus(vec3 light_entry, float wave_time) {
	float primary = sin(dot(light_entry.xz, vec2(0.31, 0.19)) + wave_time * 1.10);
	float secondary = sin(dot(light_entry.xz, vec2(-0.17, 0.28)) - wave_time * 1.70 + 1.83);
	float tertiary = cos(dot(light_entry.xz, vec2(0.09, -0.12)) + wave_time * 0.55 + 0.61);
	float raw_focus = 0.5 + 0.5 * (primary * 0.52 + secondary * 0.33 + tertiary * 0.15);
	return smoothstep(0.16, 0.84, clamp(raw_focus, 0.0, 1.0));
}

void sunrays_wave_modulation(vec3 light_entry, vec3 sample_point, out float wave_focus,
		out float width_factor, out float intensity_factor) {
	wave_focus = 0.5;
	width_factor = 1.0;
	intensity_factor = 1.0;
	if (params.state.w < 0.5) return;
	int debug_mode = int(params.state.y + 0.5);
	bool wave_exaggerated = debug_mode == 28;
	float wave_time = params.sunrays_pattern.w * (wave_exaggerated ? 1.0 : max(params.sunrays_pattern.z, 0.0));
	wave_focus = sunrays_wave_focus(light_entry, wave_time);
	float depth_fade_m = wave_exaggerated ? 1000.0 : max(params.viewport.z, EPSILON);
	float depth_below_surface_m = max(params.medium.x - sample_point.y, 0.0);
	float depth_envelope = wave_exaggerated ? 1.0 : 1.0 - smoothstep(0.0, depth_fade_m, depth_below_surface_m);
	float centered_focus = wave_focus * 2.0 - 1.0;
	float intensity_strength = wave_exaggerated ? 1.0 : clamp(params.sun_color.w, 0.0, 0.45);
	float width_strength = wave_exaggerated ? 0.40 : clamp(params.sunrays_extra.z, 0.0, 0.20);
	intensity_factor = clamp(1.0 + centered_focus * intensity_strength * depth_envelope, 0.50, 1.50);
	width_factor = clamp(1.0 + centered_focus * width_strength * depth_envelope, 0.60, 1.40);
}

float sunrays_beam_field(vec2 stable_light_coord, float width_factor, bool exaggerated,
		out float broad_ribbon_envelope) {
	float scale = max(params.sunrays_pattern.x, 0.01);
	float broad_phase = stable_light_coord.x * (0.72 * scale) + sin(stable_light_coord.y * 0.13) * 0.24;
	float medium_phase = stable_light_coord.x * (2.17 * scale) + stable_light_coord.y * 0.18 + 1.37;
	float narrow_phase = stable_light_coord.x * (3.49 * scale) - stable_light_coord.y * 0.08 + 0.61;
	float safe_width = max(width_factor, 0.01);
	float broad = pow(max(0.0, 0.5 + 0.5 * cos(broad_phase)), 2.1 / safe_width);
	float medium = pow(max(0.0, 0.5 + 0.5 * sin(medium_phase)), 4.2 / safe_width);
	float narrow = pow(max(0.0, 0.5 + 0.5 * cos(narrow_phase)), 8.0 / safe_width);
	float slow_intensity = 0.84 + 0.16 * (0.5 + 0.5 * sin(stable_light_coord.y * 0.09));
	float ridges = clamp((broad * 0.82 + medium * 0.30 + narrow * 0.12) * slow_intensity, 0.0, 1.0);
	float center_warp = sin(stable_light_coord.x * 0.05 + 1.7) * 3.0
		+ sin(stable_light_coord.x * 0.021 - 0.8) * 5.0;
	float in_plane_local = stable_light_coord.y - center_warp;
	broad_ribbon_envelope = 1.0 - smoothstep(SUNRAY_BROAD_RIBBON_WIDTH_M * 0.65,
		SUNRAY_BROAD_RIBBON_WIDTH_M, abs(in_plane_local));
	float contrast = exaggerated ? 1.0 : clamp(params.sunrays_pattern.y / 1.4, 0.0, 1.0);
	float low_value = exaggerated ? 0.10 : 0.30;
	return mix(0.5, low_value + (1.0 - low_value) * ridges, contrast) * broad_ribbon_envelope;
}

float sunrays_reach_factor(vec2 beam_coord) {
	float longitudinal_wave = sin(beam_coord.x * 0.23 + sin(beam_coord.y * 0.09) * 0.35);
	float diagonal_wave = sin(beam_coord.x * 0.11 + beam_coord.y * 0.05 + 1.21);
	return clamp(0.5 + 0.5 * (longitudinal_wave * 0.60 + diagonal_wave * 0.40), 0.0, 1.0);
}

bool world_slice_interval(vec3 camera_world, vec3 view_ray_world, float sunray_segment_m,
		vec3 light_into_water, int slice_id, out float interval_begin_m, out float interval_end_m) {
	interval_begin_m = 0.0;
	interval_end_m = 0.0;
	if (sunray_segment_m <= EPSILON || !finite_vec3(light_into_water)) return false;
	float longitudinal_at_camera = dot(camera_world, light_into_water);
	float longitudinal_per_m = dot(view_ray_world, light_into_water);
	float slice_min = float(slice_id) * SUNRAY_WORLD_SLICE_SPACING_M;
	float slice_max = slice_min + SUNRAY_WORLD_SLICE_SPACING_M;
	if (abs(longitudinal_per_m) <= EPSILON) {
		if (longitudinal_at_camera < slice_min || longitudinal_at_camera > slice_max) return false;
		interval_end_m = sunray_segment_m;
		return true;
	}
	float t_a = (slice_min - longitudinal_at_camera) / longitudinal_per_m;
	float t_b = (slice_max - longitudinal_at_camera) / longitudinal_per_m;
	interval_begin_m = max(0.0, min(t_a, t_b));
	interval_end_m = min(sunray_segment_m, max(t_a, t_b));
	return interval_end_m - interval_begin_m > EPSILON;
}

bool evaluate_sunray_world_slice(vec3 camera_world, vec3 view_ray_world,
		float interval_begin_m, float interval_end_m, float sea_level, vec3 light_into_water,
		vec3 absorption, float absorption_scale, bool exaggerated, out vec3 sample_point,
		out vec3 light_entry, out vec3 transmittance, out float pattern, out vec2 stable_light_coord,
		out vec3 stable_side_axis, out vec3 stable_in_plane_axis, out float broad_ribbon_envelope,
		out float shaft_field, out float reach_factor, out float reach_envelope,
		out float shaft_with_reach, out float wave_focus, out float wave_width,
		out float wave_intensity, out float direction_alignment) {
	sample_point = camera_world + view_ray_world * (0.5 * (interval_begin_m + interval_end_m));
	light_entry = vec3(0.0); transmittance = vec3(0.0); pattern = 0.0; stable_light_coord = vec2(0.0);
	stable_side_axis = vec3(0.0); stable_in_plane_axis = vec3(0.0); broad_ribbon_envelope = 0.0;
	shaft_field = 0.0; reach_factor = 0.0; reach_envelope = 0.0; shaft_with_reach = 0.0;
	wave_focus = 0.5; wave_width = 1.0; wave_intensity = 1.0; direction_alignment = -1.0;
	if (interval_end_m - interval_begin_m <= EPSILON || !finite_vec3(sample_point)) return false;
	if (!finite_vec3(light_into_water) || length(light_into_water) <= EPSILON) return false;
	light_into_water = normalize(light_into_water);
	vec3 toward_surface = -light_into_water;
	float denom = toward_surface.y;
	if (abs(denom) <= EPSILON) return false;
	float light_distance = (sea_level - sample_point.y) / denom;
	if (light_distance < 0.0 || isnan(light_distance) || isinf(light_distance)) return false;
	light_entry = sample_point + toward_surface * light_distance;
	if (!finite_vec3(light_entry) || abs(light_entry.y - sea_level) > 0.01) return false;
	float sun_water_path = length(light_entry - sample_point);
	if (isnan(sun_water_path) || isinf(sun_water_path)) return false;
	direction_alignment = dot(normalize(sample_point - light_entry), light_into_water);
	if (direction_alignment < 0.99 || isnan(direction_alignment) || isinf(direction_alignment)) return false;
	float effective_absorption_scale = max(absorption_scale, 0.0) * (exaggerated ? 0.20 : 1.0);
	transmittance = exp(-max(absorption, vec3(0.0)) * effective_absorption_scale * sun_water_path);
	if (!finite_vec3(transmittance)) return false;
	sunrays_wave_modulation(light_entry, sample_point, wave_focus, wave_width, wave_intensity);
	if (!sunrays_stable_light_basis(sample_point, light_into_water, stable_light_coord,
			stable_side_axis, stable_in_plane_axis)) return false;
	shaft_field = sunrays_beam_field(stable_light_coord, wave_width, exaggerated, broad_ribbon_envelope);
	reach_factor = sunrays_reach_factor(stable_light_coord);
	float variable_ratio = mix(0.35, 1.0, reach_factor);
	float length_variation = clamp(params.sunrays_extra.y, 0.0, 1.0);
	float shaft_max_reach = max(params.sunrays_extra.x, EPSILON) * mix(1.0, variable_ratio, length_variation);
	float fade_start_ratio = 0.75;
	reach_envelope = 1.0 - smoothstep(shaft_max_reach * fade_start_ratio, shaft_max_reach, sun_water_path);
	shaft_with_reach = shaft_field * reach_envelope;
	pattern = shaft_with_reach * wave_intensity;
	return !isnan(pattern) && !isinf(pattern);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y || params.state.z < 0.5) return;
	int debug_mode = int(params.state.y + 0.5);
	bool transmittance_bypass = debug_mode == 45;
	vec4 color = imageLoad(color_image, pixel);
	if (debug_mode == 4) { color.rgb = vec3(params.camera.w, params.state.x, 0.0); imageStore(color_image, pixel, color); return; }
	if (params.camera.w < 0.5) return;
	vec3 light_into_water = params.light.xyz;
	float light_length = length(light_into_water);
	bool light_valid = finite_vec3(light_into_water) && light_length > EPSILON && !isnan(light_length) && !isinf(light_length);
	if (light_valid) light_into_water /= light_length;
	if (debug_mode == 19) {
		vec3 toward_surface = -light_into_water;
		color.rgb = light_valid ? vec3(0.5 + 0.5 * toward_surface.y, 0.5 + 0.5 * light_into_water.y, 1.0) : vec3(0.0);
		imageStore(color_image, pixel, color); return;
	}
	if (debug_mode == 30) { color.rgb = light_valid ? light_into_water * 0.5 + 0.5 : vec3(0.0); imageStore(color_image, pixel, color); return; }
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001 && reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.z);
	if (isnan(water_path_m) || isinf(water_path_m)) water_path_m = 0.0;
	float phase_response = 0.0; float depth_response = 0.0; float pattern_debug = 0.0;
	vec2 stable_light_coord_debug = vec2(0.0); vec3 stable_side_axis_debug = vec3(0.0);
	vec3 stable_in_plane_axis_debug = vec3(0.0); float broad_ribbon_envelope_debug = 0.0; float world_slice_id_debug = 0.0;
	float wave_focus_debug = 0.5; float wave_width_debug = 1.0; float wave_modulation_debug = 1.0;
	float shaft_field_debug = 0.0; float reach_factor_debug = 0.0;
	float reach_envelope_debug = 0.0; float shaft_with_reach_debug = 0.0;
	float direction_alignment_debug = -1.0; vec3 view_ray_debug = vec3(0.0); bool view_ray_valid = false;
	vec3 sample_point_debug = vec3(0.0); vec3 light_entry_debug = vec3(0.0); vec3 shaft_integral = vec3(0.0);
	int valid_tap_count = 0; vec3 sunray_contribution = vec3(0.0);
	float sunray_segment_debug_m = 0.0; float sunray_segment_source_debug = 0.0;
	bool sunrays_debug = debug_mode >= 13 && debug_mode <= 46;
	bool exaggerated = debug_mode == 22;
	bool force_pattern_debug = debug_mode == 14 || debug_mode == 18 || (debug_mode >= 23 && debug_mode <= 29) || exaggerated;
	if (params.sunrays.x > 0.5 || sunrays_debug) {
		vec3 ray_reference_world = vec3(0.0);
		bool ray_reference_valid = reconstruct_world(uv, 0.0, ray_reference_world);
		vec3 view_ray_world = ray_reference_world - params.camera.xyz;
		float view_ray_length = length(view_ray_world);
		bool view_valid = ray_reference_valid && finite_vec3(view_ray_world) && view_ray_length > EPSILON && !isnan(view_ray_length) && !isinf(view_ray_length);
		if (view_valid) {
			view_ray_world /= view_ray_length; view_ray_debug = view_ray_world; view_ray_valid = true;
			phase_response = light_valid ? sunrays_phase_response(-view_ray_world, light_into_water) : 0.0;
			bool analytic_surface_hit;
			float analytic_surface_distance_m = distance_to_plane(params.camera.xyz, view_ray_world, params.medium.x, analytic_surface_hit);
			float segment_base_m = analytic_surface_hit ? analytic_surface_distance_m : water_path_m;
			sunray_segment_source_debug = analytic_surface_hit ? 1.0 : (segment_base_m > EPSILON ? 2.0 : 0.0);
			float max_sunray_distance = max(params.sunrays_extra.x, EPSILON) * (exaggerated ? 1.35 : 1.0);
			if (max_sunray_distance <= segment_base_m + EPSILON) sunray_segment_source_debug = 3.0;
			float sunray_segment_m = min(segment_base_m, max_sunray_distance);
			sunray_segment_debug_m = sunray_segment_m;
			if (sunray_segment_m > EPSILON && light_valid) {
				float integrated_length_m = 0.0;
				float longitudinal_begin = dot(params.camera.xyz, light_into_water);
				float longitudinal_end = dot(params.camera.xyz + view_ray_world * sunray_segment_m, light_into_water);
				int first_slice_id = int(floor(min(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
				int last_slice_id = int(floor(max(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
				for (int slice_offset = 0; slice_offset < 4; slice_offset++) {
					int slice_id = first_slice_id + slice_offset;
					if (slice_id > last_slice_id) break;
					float interval_begin_m; float interval_end_m;
					if (!world_slice_interval(params.camera.xyz, view_ray_world, sunray_segment_m, light_into_water, slice_id, interval_begin_m, interval_end_m)) continue;
					vec3 slice_point; vec3 slice_entry; vec3 slice_transmittance; float slice_pattern; vec2 slice_stable_light_coord;
					vec3 slice_stable_side_axis; vec3 slice_stable_in_plane_axis; float slice_broad_ribbon_envelope;
					float slice_shaft_field; float slice_reach_factor; float slice_reach_envelope; float slice_shaft_with_reach;
					float slice_wave_focus; float slice_wave_width; float slice_wave_intensity; float slice_direction_alignment;
					if (!evaluate_sunray_world_slice(params.camera.xyz, view_ray_world, interval_begin_m, interval_end_m,
							params.medium.x, light_into_water, params.absorption.rgb, params.medium.w, force_pattern_debug,
							slice_point, slice_entry, slice_transmittance, slice_pattern, slice_stable_light_coord,
							slice_stable_side_axis, slice_stable_in_plane_axis, slice_broad_ribbon_envelope,
							slice_shaft_field, slice_reach_factor, slice_reach_envelope, slice_shaft_with_reach,
							slice_wave_focus, slice_wave_width, slice_wave_intensity, slice_direction_alignment)) continue;
					float slice_length_m = interval_end_m - interval_begin_m;
					valid_tap_count += 1; integrated_length_m += slice_length_m;
					sample_point_debug += slice_point * slice_length_m; light_entry_debug += slice_entry * slice_length_m;
					pattern_debug += slice_pattern * slice_length_m; stable_light_coord_debug += slice_stable_light_coord * slice_length_m;
					stable_side_axis_debug += slice_stable_side_axis * slice_length_m;
					stable_in_plane_axis_debug += slice_stable_in_plane_axis * slice_length_m;
					broad_ribbon_envelope_debug += slice_broad_ribbon_envelope * slice_length_m;
					shaft_field_debug += slice_shaft_field * slice_length_m; reach_factor_debug += slice_reach_factor * slice_length_m;
					reach_envelope_debug += slice_reach_envelope * slice_length_m; shaft_with_reach_debug += slice_shaft_with_reach * slice_length_m;
					world_slice_id_debug += float(slice_id) * slice_length_m;
					wave_focus_debug += (slice_wave_focus - 0.5) * slice_length_m;
					wave_width_debug += (slice_wave_width - 1.0) * slice_length_m;
					wave_modulation_debug += (slice_wave_intensity - 1.0) * slice_length_m;
					direction_alignment_debug += (slice_direction_alignment + 1.0) * slice_length_m;
					shaft_integral += slice_pattern * slice_transmittance * max(params.sunrays.w, 0.0) * slice_length_m;
				}
				if (integrated_length_m > EPSILON) {
					sample_point_debug /= integrated_length_m; light_entry_debug /= integrated_length_m; pattern_debug /= integrated_length_m;
					stable_light_coord_debug /= integrated_length_m;
					vec3 averaged_stable_side_axis = stable_side_axis_debug / integrated_length_m;
					stable_side_axis_debug = length(averaged_stable_side_axis) > EPSILON ? normalize(averaged_stable_side_axis) : vec3(0.0);
					vec3 averaged_stable_in_plane_axis = stable_in_plane_axis_debug / integrated_length_m;
					stable_in_plane_axis_debug = length(averaged_stable_in_plane_axis) > EPSILON ? normalize(averaged_stable_in_plane_axis) : vec3(0.0);
					broad_ribbon_envelope_debug /= integrated_length_m;
					world_slice_id_debug /= integrated_length_m;
					shaft_field_debug /= integrated_length_m; reach_factor_debug /= integrated_length_m;
					reach_envelope_debug /= integrated_length_m; shaft_with_reach_debug /= integrated_length_m;
					wave_focus_debug = 0.5 + (wave_focus_debug - 0.5) / integrated_length_m;
					wave_width_debug = 1.0 + (wave_width_debug - 1.0) / integrated_length_m;
					wave_modulation_debug = 1.0 + (wave_modulation_debug - 1.0) / integrated_length_m;
					direction_alignment_debug = -1.0 + (direction_alignment_debug + 1.0) / integrated_length_m;
				}
				float density_path = max(params.sunrays.w, 0.0) * integrated_length_m;
				float integration_normalizer = 1.0 / max(1.0, density_path);
				depth_response = integrated_length_m > EPSILON ? 1.0 : 0.0;
				float final_gain = max(params.light.w, 0.0) * params.state.x * max(params.sunrays.y, 0.0)
					* phase_response * depth_response * integration_normalizer;
				if (exaggerated) final_gain *= 4.0;
				sunray_contribution = max(shaft_integral * final_gain, vec3(0.0));
				float sunray_luma = dot(sunray_contribution, vec3(0.2126, 0.7152, 0.0722));
				float luma_limit = (exaggerated ? 2.0 : 0.75) * max(1.0, wave_modulation_debug);
				if (sunray_luma > luma_limit) sunray_contribution *= luma_limit / sunray_luma;
			}
		}
	}
	if (debug_mode == 1) color.rgb = vec3(water_path_m / max(params.medium.z, EPSILON));
	else if (debug_mode == 2) color.rgb = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m);
	else if (debug_mode == 3) { float response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m); color.rgb = max(params.scattering.rgb, vec3(0.0)) * response * max(params.absorption.w, 0.0); }
	else if (debug_mode == 13) color.rgb = vec3(phase_response);
	else if (debug_mode == 14) color.rgb = valid_tap_count > 0 ? vec3(0.5 + 0.5 * sin(stable_light_coord_debug.x * 0.72), 0.5 + 0.5 * sin(stable_light_coord_debug.y * 0.72), 1.0) : vec3(0.0);
	else if (debug_mode == 15) color.rgb = vec3(depth_response);
	else if (debug_mode == 16 || debug_mode == 22 || debug_mode == 28) color.rgb = sunray_contribution;
	else if (debug_mode == 17) color.rgb = valid_tap_count > 0 ? vec3(1.0, clamp(length(sample_point_debug - params.camera.xyz) / max(sunray_segment_debug_m, EPSILON), 0.0, 1.0), 0.0) : vec3(0.0);
	else if (debug_mode == 18) { float entry_plane_error = abs(light_entry_debug.y - params.medium.x); color.rgb = valid_tap_count > 0 ? vec3(pattern_debug, clamp(entry_plane_error * 100.0, 0.0, 1.0), 1.0 - pattern_debug) : vec3(0.0); }
	else if (debug_mode == 20) color.rgb = vec3(float(valid_tap_count) / 4.0);
	else if (debug_mode == 21) color.rgb = vec3(1.0) - exp(-max(shaft_integral, vec3(0.0)));
	else if (debug_mode == 23) color.rgb = vec3(pattern_debug);
	else if (debug_mode == 24) color.rgb = valid_tap_count > 0 ? vec3(fract(world_slice_id_debug * 0.1618034), float(valid_tap_count) / 4.0, 1.0) : vec3(0.0);
	else if (debug_mode == 25) color.rgb = vec3(wave_focus_debug);
	else if (debug_mode == 26) color.rgb = valid_tap_count > 0 ? vec3(0.5 + (wave_width_debug - 1.0) / 0.20) : vec3(0.0);
	else if (debug_mode == 27) color.rgb = valid_tap_count > 0 ? vec3(clamp(0.5 + (wave_modulation_debug - 1.0) / 0.90, 0.0, 1.0)) : vec3(0.0);
	else if (debug_mode == 29) { float alignment_color = clamp(0.5 + 0.5 * direction_alignment_debug, 0.0, 1.0); color.rgb = valid_tap_count > 0 ? vec3(1.0 - alignment_color, alignment_color, 0.0) : vec3(0.0); }
	else if (debug_mode == 31) color.rgb = scene_valid ? 0.5 + 0.5 * sin(scene_world * vec3(0.071, 0.113, 0.097)) : vec3(0.0);
	else if (debug_mode == 32) color.rgb = view_ray_valid ? view_ray_debug * 0.5 + 0.5 : vec3(0.0);
	else if (debug_mode == 33) color.rgb = vec3(shaft_field_debug);
	else if (debug_mode == 34) color.rgb = vec3(reach_factor_debug);
	else if (debug_mode == 35) color.rgb = vec3(reach_envelope_debug);
	else if (debug_mode == 36) color.rgb = vec3(shaft_with_reach_debug);
	else if (debug_mode == 37) color.rgb = valid_tap_count > 0 ? stable_side_axis_debug * 0.5 + 0.5 : vec3(0.0);
	else if (debug_mode == 38) color.rgb = valid_tap_count > 0 ? stable_in_plane_axis_debug * 0.5 + 0.5 : vec3(0.0);
	else if (debug_mode == 39) color.rgb = vec3(broad_ribbon_envelope_debug);
	else if (debug_mode == 40) color.rgb = vec3(shaft_field_debug);
	else if (debug_mode == 41) color.rgb = vec3(0.0);
	else if (debug_mode == 42) color.rgb = sunray_segment_source_debug == 1.0 ? vec3(0.0, 1.0, 0.0) : sunray_segment_source_debug == 2.0 ? vec3(1.0, 0.0, 0.0) : sunray_segment_source_debug == 3.0 ? vec3(0.0, 0.0, 1.0) : vec3(0.0);
	else if (debug_mode == 43 || debug_mode == 44) color.rgb = sunray_contribution;
	else if (debug_mode == 46) color.rgb = vec3(clamp(sunray_segment_debug_m / max(params.sunrays_extra.x, EPSILON), 0.0, 1.0));
	else if (water_path_m > EPSILON) {
		vec3 transmittance = transmittance_bypass ? vec3(1.0) : exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.w, 0.0) * water_path_m);
		float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
		color.rgb = color.rgb * transmittance + max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.absorption.w, 0.0) + sunray_contribution;
	}
	imageStore(color_image, pixel, color);
}

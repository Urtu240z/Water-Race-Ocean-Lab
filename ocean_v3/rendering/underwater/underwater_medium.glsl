#[compute]
#version 450

// Simple binary medium: a flat sea-level interface and one POST_TRANSPARENT pass.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // xy viewport size, z wave depth fade, w unused
	vec4 camera; // xyz, binary underwater state
	vec4 medium; // sea level, transition width, max distance, absorption scale
	vec4 absorption; // rgb, scattering strength
	vec4 scattering; // rgb, scattering density
	vec4 state; // underwater factor, debug mode, enabled, wave modulation enabled
	vec4 light; // xyz physical photon travel: sun -> water, w energy
	vec4 sun_color; // rgb, wave intensity strength
	vec4 sunrays; // enabled, strength, anisotropy, density
	vec4 sunrays_pattern; // scale, contrast, animation speed, time
	vec4 sunrays_extra; // maximum distance, benchmark tap count, wave width strength, unused
} params;

const float EPSILON = 0.00001;
// Legacy fixed global slabs along light_into_water, retained for explicit A/B
// diagnostics. Production uses the transverse lattice below.
const float SUNRAY_WORLD_SLICE_SPACING_M = 14.0;
// World-anchored transverse lattice spacing. This resolves the broad (~8.7 m)
// and medium (~2.9 m) beam frequencies without tying samples to camera UV.
const float SUNRAY_TRANSVERSE_LATTICE_SPACING_M = 3.2;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	// The render projection already carries Godot's backend Y correction. UV
	// identifies the current color pixel, so it must map directly to its NDC
	// ray. Flipping NDC Y here mirrors the ray while pitching the camera and
	// makes world-anchored slabs swim independently of scene depth.
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
	// Temporary A/B diagnostic. This leaves geometry, slabs and all production
	// behavior untouched unless explicitly enabled from OceanV3.
	if (params.sunrays_extra.w > 0.5) return 1.0;
	// HG keeps the directional lobe cheap while the extra gate makes the back
	// side effectively dark enough for underwater gameplay.
	// Scattering angle between incoming photon travel and outgoing sample-to-camera.
	float cos_theta = clamp(dot(view_to_camera_dir, light_into_water), -1.0, 1.0);
	float g = clamp(params.sunrays.z, 0.0, 0.95);
	float denom = 1.0 + g * g - 2.0 * g * cos_theta;
	float phase = (1.0 - g * g) / max(pow(denom, 1.5), 0.001);
	float forward_denom = 1.0 + g * g - 2.0 * g;
	float forward_phase = (1.0 - g * g) / max(pow(forward_denom, 1.5), 0.001);
	float forward_gate = smoothstep(-0.15, 0.35, cos_theta);
	return clamp(phase / max(forward_phase, 0.001) * forward_gate, 0.0, 1.0);
}

bool build_light_basis(vec3 light_into_water, out vec3 u, out vec3 v) {
	if (!finite_vec3(light_into_water) || length(light_into_water) <= EPSILON) return false;
	vec3 l = normalize(light_into_water);
	vec3 reference = abs(l.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	u = cross(reference, l);
	if (!finite_vec3(u) || length(u) <= EPSILON) return false;
	u = normalize(u);
	v = cross(l, u);
	if (!finite_vec3(v) || length(v) <= EPSILON) return false;
	v = normalize(v);
	return finite_vec3(u) && finite_vec3(v);
}

bool sunrays_beam_coord(vec3 world_position, vec3 light_into_water, out vec2 beam_coord) {
	// The physical light direction points into the water.  U/V span only the
	// transverse plane, so P and P + L * d retain the same beam coordinate.
	vec3 u; vec3 v;
	if (!build_light_basis(light_into_water, u, v)) return false;
	beam_coord = vec2(dot(world_position, u), dot(world_position, v));
	return !any(isnan(beam_coord)) && !any(isinf(beam_coord));
}

float sunrays_wave_focus(vec3 light_entry, float wave_time) {
	// Cheap coherent surface proxy: fixed world directions and the ocean render
	// time give each light-entry point its own evolving focus response. It is
	// deliberately not evaluated from camera position, screen UV, or tap index.
	// 1.10/1.70 rad/s make the broad and medium response legible at the
	// production speed, while the 0.55 rad/s term keeps a slower drift.
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

float sunrays_beam_field(vec3 sample_world, vec3 light_into_water, float width_factor,
		bool exaggerated, out vec2 beam_coord) {
	beam_coord = vec2(0.0);
	if (!sunrays_beam_coord(sample_world, light_into_water, beam_coord)) return 0.0;
	float scale = max(params.sunrays_pattern.x, 0.01);
	// Meter-space ridges: broad 8.7 m shafts, medium 2.9 m shafts, and a
	// restrained 1.8 m secondary line. The only warp varies slowly across V.
	float broad_phase = beam_coord.x * (0.72 * scale)
		+ sin(beam_coord.y * 0.13) * 0.24;
	float medium_phase = beam_coord.x * (2.17 * scale)
		+ beam_coord.y * 0.18 + 1.37;
	float narrow_phase = beam_coord.x * (3.49 * scale)
		- beam_coord.y * 0.08 + 0.61;
	// Changing ridge exponents breathes each shaft around its stable center;
	// beam_coord is never offset or translated.
	float safe_width = max(width_factor, 0.01);
	float broad = pow(max(0.0, 0.5 + 0.5 * cos(broad_phase)), 2.1 / safe_width);
	float medium = pow(max(0.0, 0.5 + 0.5 * sin(medium_phase)), 4.2 / safe_width);
	float narrow = pow(max(0.0, 0.5 + 0.5 * cos(narrow_phase)), 8.0 / safe_width);
	float slow_intensity = 0.84 + 0.16 * (0.5 + 0.5 * sin(beam_coord.y * 0.09));
	float ridges = clamp((broad * 0.82 + medium * 0.30 + narrow * 0.12) * slow_intensity, 0.0, 1.0);
	float contrast = exaggerated ? 1.0 : clamp(params.sunrays_pattern.y / 1.4, 0.0, 1.0);
	float low_value = exaggerated ? 0.10 : 0.30;
	return mix(0.5, low_value + (1.0 - low_value) * ridges, contrast);
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

bool transverse_lattice_plane_t(vec3 camera_world, vec3 view_ray_world,
		vec3 axis, float spacing_m, int lattice_id, out float t_m) {
	t_m = 0.0;
	float denominator = dot(view_ray_world, axis);
	if (abs(denominator) <= EPSILON) return false;
	float plane = float(lattice_id) * spacing_m;
	t_m = (plane - dot(camera_world, axis)) / denominator;
	return !isnan(t_m) && !isinf(t_m);
}

bool evaluate_sunray_world_slice(vec3 camera_world, vec3 view_ray_world,
		float interval_begin_m, float interval_end_m, float sample_t_m, float sea_level, vec3 light_into_water,
		vec3 absorption, float absorption_scale, bool exaggerated, out vec3 sample_point,
		out vec3 light_entry, out vec3 transmittance, out float pattern, out vec2 beam_coord,
		out float wave_focus, out float wave_width, out float wave_intensity,
		out float direction_alignment) {
	// Legacy slabs pass their midpoint; transverse lattice samples pass the exact
	// world-plane intersection while the interval supplies its integration weight.
	sample_point = camera_world + view_ray_world * sample_t_m;
	light_entry = vec3(0.0);
	transmittance = vec3(0.0);
	pattern = 0.0;
	beam_coord = vec2(0.0);
	wave_focus = 0.5;
	wave_width = 1.0;
	wave_intensity = 1.0;
	direction_alignment = -1.0;
	if (interval_end_m - interval_begin_m <= EPSILON || sample_t_m < 0.0 || !finite_vec3(sample_point)) return false;
	if (!finite_vec3(light_into_water) || length(light_into_water) <= EPSILON) return false;
	light_into_water = normalize(light_into_water);
	vec3 toward_surface = -light_into_water;
	float denom = toward_surface.y;
	float light_distance = (sea_level - sample_point.y) / denom;
	if (light_distance < 0.0 || isnan(light_distance) || isinf(light_distance)) return false;
	light_entry = sample_point + toward_surface * light_distance;
	if (!finite_vec3(light_entry) || abs(light_entry.y - sea_level) > 0.01) return false;
	float sun_water_path = length(light_entry - sample_point);
	if (sun_water_path < 0.0 || isnan(sun_water_path) || isinf(sun_water_path)) return false;
	// light_entry is found by tracing toward the surface. The physical path
	// from that entry into water is exactly light_into_water.
	vec3 actual_travel = normalize(sample_point - light_entry);
	vec3 expected_travel = light_into_water;
	direction_alignment = dot(actual_travel, expected_travel);
	if (direction_alignment < 0.99 || isnan(direction_alignment) || isinf(direction_alignment)) return false;
	float effective_absorption_scale = max(absorption_scale, 0.0) * (exaggerated ? 0.20 : 1.0);
	transmittance = exp(-max(absorption, vec3(0.0)) * effective_absorption_scale * sun_water_path);
	if (!finite_vec3(transmittance)) return false;
	sunrays_wave_modulation(light_entry, sample_point, wave_focus, wave_width, wave_intensity);
	pattern = sunrays_beam_field(sample_point, light_into_water, wave_width, exaggerated, beam_coord)
		* wave_intensity;
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
		vec3 light_into_water = params.light.xyz;
		float light_length = length(light_into_water);
		bool light_valid = finite_vec3(light_into_water) && light_length > EPSILON
			&& !isnan(light_length) && !isinf(light_length);
		if (light_valid) light_into_water /= light_length;
		vec3 toward_sun = -light_into_water;
		// Red encodes toward_sun.y and green encodes light_into_water.y;
		// 0.5 is zero, values above/below it are positive/negative.
		color.rgb = light_valid
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
	vec2 beam_coord_debug = vec2(0.0);
	float world_slice_id_debug = 0.0;
	float lattice_id_debug = 0.0;
	float sample_set_id_debug = 0.0;
	float transverse_axis_u_debug = 0.0;
	float transverse_axis_v_debug = 0.0;
	vec3 transverse_sample_point_debug = vec3(0.0);
	vec4 sample_weights_debug = vec4(0.0);
	float wave_focus_debug = 0.5;
	float wave_width_debug = 1.0;
	float wave_modulation_debug = 1.0;
	float direction_alignment_debug = -1.0;
	vec3 view_ray_debug = vec3(0.0);
	bool view_ray_debug_valid = false;
	vec3 sample_point_debug = vec3(0.0);
	vec3 light_entry_debug = vec3(0.0);
	vec3 shaft_integral = vec3(0.0);
	int valid_tap_count = 0;
	vec3 sunray_contribution = vec3(0.0);
	bool sunrays_debug = debug_mode >= 13 && debug_mode <= 41;
	bool exaggerated = debug_mode == 22;
	// A/B modes 37/38 and the continuity diagnostics must not alter pattern
	// tuning; legacy modes 24-36 retain their historical forced-pattern view.
	bool force_pattern_debug = debug_mode == 14 || debug_mode == 18
		|| (debug_mode >= 23 && debug_mode <= 36) || exaggerated;
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
			view_ray_debug = view_ray_world;
			view_ray_debug_valid = true;
			vec3 light_into_water = params.light.xyz;
			float light_length = length(light_into_water);
			bool light_direction_valid = finite_vec3(light_into_water) && light_length > EPSILON
				&& !isnan(light_length) && !isinf(light_length);
			if (light_direction_valid) light_into_water /= light_length;
			vec3 view_to_camera_dir = -view_ray_world;
		phase_response = light_direction_valid
			? sunrays_phase_response(view_to_camera_dir, light_into_water)
			: 0.0;
		float max_sunray_distance = max(params.sunrays_extra.x, EPSILON) * (exaggerated ? 1.35 : 1.0);
		float sunray_segment_m = min(water_path_m, max_sunray_distance);
		if (sunray_segment_m > EPSILON) {
			float integrated_length_m = 0.0;
			if (light_direction_valid) {
				// Arrays hold at most four world-anchored samples. Production uses
				// transverse planes; debug mode 37 exposes the legacy longitudinal A/B.
				float sample_t[4]; float sample_weight[4]; int sample_axis[4]; int sample_lattice_id[4];
				int sample_count = 0;
				float du = 0.0; float dv = 0.0;
				for (int clear_index = 0; clear_index < 4; clear_index++) {
					sample_t[clear_index] = 0.0; sample_weight[clear_index] = 0.0;
					sample_axis[clear_index] = -1; sample_lattice_id[clear_index] = 0;
				}
				bool legacy_longitudinal = debug_mode == 24 || debug_mode == 37;
				if (legacy_longitudinal) {
					float longitudinal_begin = dot(params.camera.xyz, light_into_water);
					float longitudinal_end = dot(params.camera.xyz + view_ray_world * sunray_segment_m, light_into_water);
					int first_slice_id = int(floor(min(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
					int last_slice_id = int(floor(max(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
					if (one_tap_benchmark) {
						first_slice_id = int(floor(0.5 * float(first_slice_id + last_slice_id)));
						last_slice_id = first_slice_id;
					}
					for (int slice_offset = 0; slice_offset < 4; slice_offset++) {
						int slice_id = first_slice_id + slice_offset;
						if (slice_id > last_slice_id || sample_count >= 4) break;
						float interval_begin_m; float interval_end_m;
						if (!world_slice_interval(params.camera.xyz, view_ray_world, sunray_segment_m,
								light_into_water, slice_id, interval_begin_m, interval_end_m)) continue;
						sample_t[sample_count] = 0.5 * (interval_begin_m + interval_end_m);
						sample_weight[sample_count] = interval_end_m - interval_begin_m;
						sample_lattice_id[sample_count] = slice_id;
						sample_count += 1;
					}
				} else {
					vec3 u; vec3 v;
					if (build_light_basis(light_into_water, u, v)) {
						du = abs(dot(view_ray_world, u));
						dv = abs(dot(view_ray_world, v));
						float dominance = du / max(du + dv, EPSILON);
						float u_blend = smoothstep(0.38, 0.62, dominance);
						bool transition = dominance > 0.38 && dominance < 0.62;
						// U receives the blend as dominance rises; V receives the
						// complement. The previous implementation inverted these.
						float u_mix = u_blend;
						float v_mix = 1.0 - u_blend;
						int u_budget = transition ? 2 : (u_mix >= 0.5 ? 4 : 0);
						int v_budget = transition ? 2 : (v_mix > 0.5 ? 4 : 0);
						transverse_axis_u_debug = u_mix;
						transverse_axis_v_debug = v_mix;
						vec3 reference_world_point = params.camera.xyz + view_ray_world * (0.5 * sunray_segment_m);
						for (int axis_pass = 0; axis_pass < 2; axis_pass++) {
							vec3 axis = axis_pass == 0 ? u : v;
							float axis_mix = axis_pass == 0 ? u_mix : v_mix;
							int budget = axis_pass == 0 ? u_budget : v_budget;
							if (budget <= 0 || axis_mix <= EPSILON) continue;
							float denominator = dot(view_ray_world, axis);
							float abs_denominator = abs(denominator);
							if (abs_denominator <= EPSILON) continue;
							// Four consecutive IDs are anchored to a continuous world
							// coordinate. Cubic weights smoothly hand off k..k+2 to
							// k+1..k+3 when frac crosses an integer boundary.
							float lattice_coord = dot(reference_world_point, axis) / SUNRAY_TRANSVERSE_LATTICE_SPACING_M;
							int base_id = int(floor(lattice_coord));
							float lattice_frac = fract(lattice_coord);
							sample_set_id_debug += float(base_id) * axis_mix;
							for (int axis_offset = 0; axis_offset < 4; axis_offset++) {
								if (axis_offset >= budget || sample_count >= 4) break;
								float lattice_weight = budget == 4
									? (axis_offset == 0 ? pow(1.0 - lattice_frac, 3.0) / 6.0
									: axis_offset == 1 ? (3.0 * pow(lattice_frac, 3.0) - 6.0 * lattice_frac * lattice_frac + 4.0) / 6.0
									: axis_offset == 2 ? (-3.0 * pow(lattice_frac, 3.0) + 3.0 * lattice_frac * lattice_frac + 3.0 * lattice_frac + 1.0) / 6.0
									: pow(lattice_frac, 3.0) / 6.0)
									: (axis_offset == 0 ? 1.0 - lattice_frac : lattice_frac);
								int lattice_id = budget == 4 ? base_id - 1 + axis_offset : base_id + axis_offset;
								float lattice_t;
								if (!transverse_lattice_plane_t(params.camera.xyz, view_ray_world,
										axis, SUNRAY_TRANSVERSE_LATTICE_SPACING_M, lattice_id, lattice_t)) continue;
								float edge_width_m = min(sunray_segment_m,
									SUNRAY_TRANSVERSE_LATTICE_SPACING_M / max(abs_denominator, 0.05));
								float edge_weight = smoothstep(0.0, max(edge_width_m, EPSILON), lattice_t)
									* smoothstep(0.0, max(edge_width_m, EPSILON), sunray_segment_m - lattice_t);
								float weighted_slot = max(lattice_weight, 0.0) * axis_mix * edge_weight;
								sample_t[sample_count] = clamp(lattice_t, 0.0, sunray_segment_m);
								sample_weight[sample_count] = weighted_slot * sunray_segment_m;
								sample_weights_debug[sample_count] = weighted_slot;
								sample_axis[sample_count] = axis_pass;
								sample_lattice_id[sample_count] = lattice_id;
								sample_count += 1;
							}
						}
					}
					if (sample_count == 0) {
						// A short segment or a ray parallel to L can cross no plane;
						// retain one deterministic midpoint so the beam does not vanish.
						sample_t[0] = 0.5 * sunray_segment_m;
						sample_weight[0] = sunray_segment_m;
						sample_count = 1;
					}
				}
				for (int sample_index = 0; sample_index < 4; sample_index++) {
					if (sample_index >= sample_count || sample_weight[sample_index] <= EPSILON) continue;
					float interval_begin_m = max(0.0, sample_t[sample_index] - 0.5 * sample_weight[sample_index]);
					float interval_end_m = min(sunray_segment_m, sample_t[sample_index] + 0.5 * sample_weight[sample_index]);
					vec3 slice_point; vec3 slice_entry; vec3 slice_transmittance;
					float slice_pattern; vec2 slice_beam_coord;
					float slice_wave_focus; float slice_wave_width; float slice_wave_intensity;
					float slice_direction_alignment;
					if (!evaluate_sunray_world_slice(params.camera.xyz, view_ray_world,
							interval_begin_m, interval_end_m, sample_t[sample_index], params.medium.x, light_into_water,
							params.absorption.rgb, params.medium.w, force_pattern_debug, slice_point,
							slice_entry, slice_transmittance, slice_pattern, slice_beam_coord,
							slice_wave_focus, slice_wave_width, slice_wave_intensity,
							slice_direction_alignment)) continue;
					float slice_length_m = sample_weight[sample_index];
					valid_tap_count += 1;
					integrated_length_m += slice_length_m;
					sample_point_debug += slice_point * slice_length_m;
					light_entry_debug += slice_entry * slice_length_m;
					pattern_debug += slice_pattern * slice_length_m;
					beam_coord_debug += slice_beam_coord * slice_length_m;
					if (sample_axis[sample_index] < 0) {
						world_slice_id_debug += float(sample_lattice_id[sample_index]) * slice_length_m;
					} else {
						lattice_id_debug += float(sample_lattice_id[sample_index]) * slice_length_m;
						transverse_sample_point_debug += slice_point * slice_length_m;
					}
					wave_focus_debug += (slice_wave_focus - 0.5) * slice_length_m;
					wave_width_debug += (slice_wave_width - 1.0) * slice_length_m;
					wave_modulation_debug += (slice_wave_intensity - 1.0) * slice_length_m;
					direction_alignment_debug += (slice_direction_alignment + 1.0) * slice_length_m;
					shaft_integral += slice_pattern * slice_transmittance
						* max(params.sunrays.w, 0.0) * slice_length_m;
				}
			}
			if (integrated_length_m > EPSILON) {
				sample_point_debug /= integrated_length_m;
				light_entry_debug /= integrated_length_m;
				pattern_debug /= integrated_length_m;
				beam_coord_debug /= integrated_length_m;
				world_slice_id_debug /= integrated_length_m;
				lattice_id_debug /= integrated_length_m;
				sample_set_id_debug /= max(transverse_axis_u_debug + transverse_axis_v_debug, EPSILON);
				transverse_sample_point_debug /= integrated_length_m;
				wave_focus_debug = 0.5 + (wave_focus_debug - 0.5) / integrated_length_m;
				wave_width_debug = 1.0 + (wave_width_debug - 1.0) / integrated_length_m;
				wave_modulation_debug = 1.0 + (wave_modulation_debug - 1.0) / integrated_length_m;
				direction_alignment_debug = -1.0 + (direction_alignment_debug + 1.0) / integrated_length_m;
			}
			// Do not create a second brightness ramp along the camera ray. That
			// screen-space build-up made the apparent shaft follow view_ray_world
			// instead of its physical surface-entry -> light_into_water path. The
			// only longitudinal profile is the per-slice Beer-Lambert transport
			// from light_entry to sample_point above.
			float density_path = max(params.sunrays.w, 0.0) * integrated_length_m;
			float integration_normalizer = 1.0 / max(1.0, density_path);
			depth_response = integrated_length_m > EPSILON ? 1.0 : 0.0;
			float final_gain = max(params.light.w, 0.0) * params.state.x
				* max(params.sunrays.y, 0.0) * phase_response * depth_response * integration_normalizer;
			if (exaggerated) final_gain *= 4.0;
			sunray_contribution = max(shaft_integral * final_gain, vec3(0.0));
			float sunray_luma = dot(sunray_contribution, vec3(0.2126, 0.7152, 0.0722));
			// Preserve the per-slice wave gain through the safety cap. Previously a
			// strong lab ray could hit this fixed ceiling every frame, flattening the
			// positive half of the 0.65–1.35 modulation before final output.
			float luma_limit = (exaggerated ? 2.0 : 0.75) * max(1.0, wave_modulation_debug);
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
		color.rgb = valid_tap_count > 0
			? vec3(0.5 + 0.5 * sin(beam_coord_debug.x * 0.72),
				0.5 + 0.5 * sin(beam_coord_debug.y * 0.72), 1.0)
			: vec3(0.0);
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
	} else if (debug_mode == 23) {
		color.rgb = vec3(pattern_debug);
	} else if (debug_mode == 24) {
		// Encodes the fixed light-space slab ID. It changes only when the ray
		// crosses a world slab boundary, never from a camera-relative tap fraction.
		color.rgb = valid_tap_count > 0
			? vec3(fract(world_slice_id_debug * 0.1618034), float(valid_tap_count) / 4.0, 1.0)
			: vec3(0.0);
	} else if (debug_mode == 25) {
		color.rgb = vec3(wave_focus_debug);
	} else if (debug_mode == 26) {
		color.rgb = valid_tap_count > 0 ? vec3(0.5 + (wave_width_debug - 1.0) / 0.20) : vec3(0.0);
	} else if (debug_mode == 27) {
		color.rgb = valid_tap_count > 0
			? vec3(clamp(0.5 + (wave_modulation_debug - 1.0) / 0.90, 0.0, 1.0))
			: vec3(0.0);
	} else if (debug_mode == 28) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 29) {
		float alignment_color = clamp(0.5 + 0.5 * direction_alignment_debug, 0.0, 1.0);
		color.rgb = valid_tap_count > 0
			? vec3(1.0 - alignment_color, alignment_color, 0.0)
			: vec3(0.0);
	} else if (debug_mode == 30) {
		vec3 light_into_water = params.light.xyz;
		float light_length = length(light_into_water);
		bool light_valid = finite_vec3(light_into_water) && light_length > EPSILON
			&& !isnan(light_length) && !isinf(light_length);
		if (light_valid) light_into_water /= light_length;
		color.rgb = light_valid ? light_into_water * 0.5 + 0.5 : vec3(0.0);
	} else if (debug_mode == 31) {
		// A low-frequency world-space encoding: the same visible world point
		// keeps its color while the camera pitches, independent of screen UV.
		color.rgb = scene_valid
			? 0.5 + 0.5 * sin(scene_world * vec3(0.071, 0.113, 0.097))
			: vec3(0.0);
	} else if (debug_mode == 32) {
		color.rgb = view_ray_debug_valid ? view_ray_debug * 0.5 + 0.5 : vec3(0.0);
	} else if (debug_mode == 33) {
		// Red=U-axis contribution, green=V-axis contribution; yellow is the
		// smooth dominance transition where both transverse quadratures are used.
		float axis_total = transverse_axis_u_debug + transverse_axis_v_debug;
		color.rgb = valid_tap_count > 0 && axis_total > EPSILON
			? vec3(transverse_axis_u_debug / axis_total, transverse_axis_v_debug / axis_total, 0.0)
			: vec3(0.0);
	} else if (debug_mode == 34) {
		color.rgb = valid_tap_count > 0
			? vec3(fract(lattice_id_debug * 0.1618034), float(valid_tap_count) / 4.0, 1.0)
			: vec3(0.0);
	} else if (debug_mode == 35) {
		float axis_total = transverse_axis_u_debug + transverse_axis_v_debug;
		color.rgb = valid_tap_count > 0 && axis_total > EPSILON
			? vec3(transverse_axis_u_debug / axis_total, transverse_axis_v_debug / axis_total, 0.0)
			: vec3(0.0);
	} else if (debug_mode == 36) {
		// World-anchored sample-point encoding; it remains fixed when the camera
		// moves over the same lattice planes.
		color.rgb = valid_tap_count > 0
			? fract(abs(transverse_sample_point_debug) * vec3(0.031, 0.037, 0.043))
			: vec3(0.0);
	} else if (debug_mode == 37) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 38) {
		color.rgb = sunray_contribution;
	} else if (debug_mode == 39) {
		// The continuous world reference selects this base ID; neighbouring IDs
		// are handed off by weights rather than replacing the sample set abruptly.
		color.rgb = valid_tap_count > 0
			? vec3(fract(sample_set_id_debug * 0.1618034), float(valid_tap_count) / 4.0, 1.0)
			: vec3(0.0);
	} else if (debug_mode == 40) {
		color.rgb = sample_weights_debug.rgb;
		color.a = sample_weights_debug.a;
	} else if (debug_mode == 41) {
		color.rgb = vec3(float(valid_tap_count) / 4.0);
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

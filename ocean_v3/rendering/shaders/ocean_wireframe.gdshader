shader_type spatial;
render_mode wireframe, cull_disabled, unshaded;

uniform sampler2D displacement_long_coastal : repeat_enable, filter_linear;
uniform sampler2D displacement_long_remainder : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D coastal_field_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_warp_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_warp_jacobian_texture : repeat_disable, filter_linear;
uniform float domain_long_coastal_m = 512.0;
uniform float domain_long_remainder_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 short_fade_range_m = vec2(24.0, 80.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 320.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec3 band_mask = vec3(1.0);
uniform bool module_enabled = true;
uniform bool clipmap_lod_debug = false;
uniform bool periodicity_debug = false;
uniform bool coastal_propagation_enabled = false;
uniform bool coastal_transform_enabled = false;
uniform bool coastal_monochromatic_debug = false;
uniform bool coastal_warp_enabled = false;
uniform int coastal_composition_debug = 0;
uniform int coastal_warp_effect_debug = 0;
uniform bool coastal_forced_warp_debug = false;
uniform vec2 coastal_forced_warp_offset_xz = vec2(37.0, 23.0);
uniform float coastal_debug_gain = 1.0;
uniform bool coastal_delta_heatmap = false;
uniform int coastal_debug_field = 0;
uniform float coastal_monochromatic_amplitude_m = 0.35;
uniform vec2 coastal_origin_xz = vec2(0.0);
uniform vec2 coastal_extent_m = vec2(1.0);
uniform vec2 coastal_incoming_direction_xz = vec2(1.0, 0.0);
uniform vec2 coastal_warp_origin_xz = vec2(0.0);
uniform vec2 coastal_warp_extent_m = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform bool shore_stabilization_enabled = true;
uniform vec2 shore_vertical_depth_range_m = vec2(0.25, 6.0);
uniform vec2 shore_horizontal_depth_range_m = vec2(0.75, 12.0);
uniform float coastal_min_valid_depth_m = 0.25;
uniform float coastal_k0_rad_m = 0.392699;
uniform float coastal_omega_rad_s = 1.962;
uniform float coastal_time_s = 0.0;
instance uniform float clipmap_level = 0.0;
uniform float lod_morph_ratio : hint_range(0.05, 0.30, 0.01) = 0.12;
uniform bool lod_geomorph_enabled = true;
uniform bool clipmap_lod_morph_debug = false;
instance uniform float clipmap_spacing_m = 0.25;
instance uniform float clipmap_next_spacing_m = 0.0;
instance uniform float clipmap_outer_extent_m = 16.0;
instance uniform float clipmap_inner_extent_m = 0.0;

varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying float clipmap_lod_morph_alpha;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

float distance_fade(vec2 fade_range, float distance_to_camera) {
	return 1.0 - smoothstep(fade_range.x, fade_range.y, distance_to_camera);
}

vec3 level_color(float level) {
	float wave = fract(level * 0.61803398875);
	return mix(vec3(0.12, 0.85, 0.95), vec3(0.95, 0.25, 0.12), wave);
}

float periodic_grid(vec2 world_xz, float domain_size_m) {
	vec2 cell = abs(fract(world_xz / domain_size_m + 0.5) - 0.5);
	return smoothstep(0.485, 0.5, max(cell.x, cell.y));
}

vec2 coastal_uv(vec2 world_xz) {
	return (world_xz - coastal_origin_xz) / max(coastal_extent_m, vec2(0.0001));
}

float shore_data_inside(vec2 uv) {
	return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
}

void shore_weights_from_depth(float depth_m, out float vertical_weight, out float horizontal_weight) {
	float depth = max(depth_m, 0.0);
	float water_presence = smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), depth);
	float vertical_curve = smoothstep(
		min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y),
		max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), depth);
	float horizontal_curve = smoothstep(
		min(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y),
		max(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), depth);
	vertical_weight = water_presence * vertical_curve;
	horizontal_weight = water_presence * horizontal_curve;
}

void shore_stabilization_weights(vec2 world_xz, vec4 metrics_data,
		out float vertical_weight, out float horizontal_weight) {
	vertical_weight = 1.0;
	horizontal_weight = 1.0;
	if (!shore_stabilization_enabled || !coastal_propagation_enabled) return;
	float inside = shore_data_inside(coastal_uv(world_xz));
	float local_vertical;
	float local_horizontal;
	shore_weights_from_depth(metrics_data.r, local_vertical, local_horizontal);
	vertical_weight = mix(1.0, local_vertical, inside);
	horizontal_weight = mix(1.0, local_horizontal, inside);
}

float coastal_render_confidence(vec2 uv, vec4 field_data) {
	if (!coastal_propagation_enabled || !coastal_transform_enabled) return 0.0;
	return shore_data_inside(uv) * clamp(field_data.a, 0.0, 1.0);
}

bool has_coastal_data(vec2 uv, vec4 field_data) {
	return coastal_propagation_enabled && coastal_transform_enabled && uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 && field_data.a > 0.5;
}

vec4 warp_deep_sample(vec2 world_xz) {
	vec2 uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	vec2 uv_clamped = clamp(uv, vec2(0.0), vec2(1.0));
	vec4 warp = textureLod(coastal_warp_texture, uv_clamped, 0.0);
	float det_j = warp.b;
	float confidence = smoothstep(0.0, coastal_warp_detj_safe, det_j);
	confidence *= warp.a;
	confidence *= step(uv.x, 1.0) * step(uv.y, 1.0) * step(0.0, uv.x) * step(0.0, uv.y);
	return vec4(warp.xy, confidence, 0.0);
}

float clipmap_lod_morph_factor(vec2 clipmap_local_xz) {
	if (clipmap_next_spacing_m <= 0.0 || clipmap_outer_extent_m <= 0.0) return 0.0;
	float distance_metric = max(abs(clipmap_local_xz.x), abs(clipmap_local_xz.y));
	float morph_start = clipmap_outer_extent_m * (1.0 - clamp(lod_morph_ratio, 0.0, 1.0));
	return smoothstep(morph_start, clipmap_outer_extent_m, distance_metric);
}

void vertex() {
	vec2 fine_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 clipmap_origin_xz = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xz;
	vec2 clipmap_local_xz = fine_world_xz - clipmap_origin_xz;
	float lod_alpha = clipmap_lod_morph_factor(clipmap_local_xz);
	vec2 morphed_local_xz = clipmap_local_xz;
	if (lod_geomorph_enabled) {
		float coarse_spacing = max(clipmap_next_spacing_m, clipmap_spacing_m * 2.0);
		vec2 coarse_local_xz = floor(clipmap_local_xz / coarse_spacing + vec2(0.5)) * coarse_spacing;
		float inner_boundary_delta = abs(max(abs(clipmap_local_xz.x), abs(clipmap_local_xz.y)) - clipmap_inner_extent_m);
		float inner_boundary_morph = (clipmap_inner_extent_m > 0.0)
			? 1.0 - smoothstep(0.0, max(clipmap_spacing_m * 0.25, 0.0001), inner_boundary_delta)
			: 0.0;
		float geomorph_alpha = lod_alpha * (1.0 - inner_boundary_morph);
		morphed_local_xz = mix(clipmap_local_xz, coarse_local_xz, geomorph_alpha);
	}
	vec2 world_xz = clipmap_origin_xz + morphed_local_xz;
	vec3 base_vertex = VERTEX;
	if (lod_geomorph_enabled) {
		base_vertex.xz = morphed_local_xz;
	}
	clipmap_lod_morph_alpha = lod_alpha;
	ocean_world_xz = world_xz;
	coastal_field = vec4(0.0, 1.0, 0.0, 0.0);
	coastal_metrics = vec4(0.0);
	if (module_enabled) {
		float distance_to_camera = distance(world_xz, camera_world_xz);
		float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
		float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
		float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
		vec2 coast_uv = coastal_uv(world_xz);
		coastal_field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
		coastal_metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
		float shore_vertical_weight;
		float shore_horizontal_weight;
		shore_stabilization_weights(world_xz, coastal_metrics, shore_vertical_weight, shore_horizontal_weight);
		bool coast_active = has_coastal_data(coast_uv, coastal_field);
		float render_confidence = coastal_render_confidence(coast_uv, coastal_field);
		bool coast_render_active = render_confidence > 0.001;
		vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
		if (coast_render_active && coastal_forced_warp_debug && coastal_warp_effect_debug != 2) {
			warp_sample = vec4(world_xz + coastal_forced_warp_offset_xz, 1.0, 0.0);
		} else if (coast_render_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
			warp_sample = warp_deep_sample(world_xz);
		}
		vec2 deep_xz = warp_sample.xy;
		float warp_confidence = warp_sample.z * render_confidence;
		vec3 long_coastal_warped = textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb;
		vec3 long_coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb;
		vec3 long_coastal = mix(long_coastal_open, long_coastal_warped, warp_confidence);
		float effective_shoaling = 1.0;
		if (coast_render_active) {
			if (coastal_warp_effect_debug == 2) effective_shoaling = coastal_field.g;
			else if (coastal_warp_effect_debug == 0) effective_shoaling = mix(1.0, coastal_field.g, warp_confidence);
		}
		long_coastal *= effective_shoaling;
		vec3 long_remainder = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb;
		float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
		float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
		float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
		float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
		vec3 displacement = long_coastal * coastal_weight * coastal_gain + long_remainder * remainder_weight;
		displacement += textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb * mid_weight * mid_short_weight;
		displacement += textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb * short_weight * mid_short_weight;
		if (coastal_monochromatic_debug && coast_active) {
			float phase = dot(world_xz, coastal_incoming_direction_xz) * coastal_k0_rad_m + coastal_field.r - coastal_omega_rad_s * coastal_time_s;
			displacement = vec3(0.0, coastal_monochromatic_amplitude_m * coastal_field.g * cos(phase), 0.0);
		}
		displacement.xz *= shore_horizontal_weight;
		displacement.y *= shore_vertical_weight;
		VERTEX = base_vertex + displacement;
	} else {
		VERTEX = base_vertex;
	}
}

void fragment() {
	vec3 color = clipmap_lod_debug ? level_color(clipmap_level) : vec3(0.68, 0.91, 1.0);
	if (clipmap_lod_morph_debug) {
		color = vec3(clipmap_lod_morph_alpha);
	}
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_coastal_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}
	if (coastal_debug_field > 0 && coastal_propagation_enabled) {
		float value = 0.0;
		if (coastal_debug_field == 1) value = coastal_metrics.r / 12.0;
		else if (coastal_debug_field == 2) value = coastal_metrics.g / 32.0;
		else if (coastal_debug_field == 3) value = coastal_metrics.b / 8.0;
		else if (coastal_debug_field == 4) value = coastal_metrics.a / 8.0;
		else if (coastal_debug_field == 5) value = (coastal_field.g - 1.0) * 8.0;
		else if (coastal_debug_field == 6) value = abs(coastal_field.r) / 6.2831853;
		else if (coastal_debug_field == 9) value = clamp(max(coastal_metrics.r, 0.0) / max(shore_horizontal_depth_range_m.y, 0.001), 0.0, 1.0);
		else if (coastal_debug_field == 10) {
			float vertical_weight;
			float horizontal_weight;
			shore_stabilization_weights(ocean_world_xz, coastal_metrics, vertical_weight, horizontal_weight);
			value = vertical_weight;
		} else if (coastal_debug_field == 11) {
			float vertical_weight;
			float horizontal_weight;
			shore_stabilization_weights(ocean_world_xz, coastal_metrics, vertical_weight, horizontal_weight);
			value = horizontal_weight;
		}
		color = mix(vec3(0.02, 0.05, 0.12), vec3(0.95, 0.8, 0.18), clamp(value, 0.0, 1.0));
	}
	ALBEDO = color;
}

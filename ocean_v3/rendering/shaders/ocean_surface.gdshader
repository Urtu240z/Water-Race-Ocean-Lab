shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long_coastal : repeat_enable, filter_linear;
uniform sampler2D displacement_long_remainder : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long_coastal : repeat_enable, filter_linear;
uniform sampler2D normal_long_remainder : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D coastal_field_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics_texture : repeat_disable, filter_linear;
uniform sampler2D coastal_phase_texture : repeat_disable, filter_linear;
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
uniform int debug_mode = 0;
uniform bool module_enabled = true;
uniform bool clipmap_lod_debug = false;
uniform bool periodicity_debug = false;
uniform bool coastal_propagation_enabled = false;
uniform bool coastal_transform_enabled = false;
uniform bool coastal_monochromatic_debug = false;
uniform bool coastal_eikonal_phase_debug = false;
uniform bool coastal_warp_enabled = false;
// 3B.2B diagnóstico: 0 FULL, 1 LONG, 2 COASTAL, 3 REMAINDER, 4 MID+SHORT.
uniform int coastal_composition_debug = 0;
// 0 WARP+SHOALING, 1 WARP_ONLY, 2 SHOALING_ONLY.
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
uniform float coastal_k0_rad_m = 0.392699;
uniform float coastal_omega_rad_s = 1.962;
uniform float coastal_time_s = 0.0;
uniform vec3 base_color : source_color = vec3(0.18, 0.34, 0.44);
uniform vec3 slope_valley_color : source_color = vec3(0.02, 0.06, 0.12);
uniform vec3 slope_crest_color : source_color = vec3(0.95, 0.98, 1.0);
instance uniform float clipmap_level = 0.0;

varying vec3 derived_normal;
varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying vec4 coastal_phase_data;
varying float coastal_mono_phase;
varying float coastal_mono_active;
varying float coastal_warp_delta_m;

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

float distance_fade(vec2 fade_range, float distance_to_camera) {
	return 1.0 - smoothstep(fade_range.x, fade_range.y, distance_to_camera);
}

vec2 slope_from_normal(vec3 ocean_normal) {
	return -ocean_normal.xz / max(ocean_normal.y, 0.0001);
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

bool has_coastal_data(vec2 uv, vec4 field_data) {
	return coastal_propagation_enabled && uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0 && field_data.a > 0.5;
}

// 3B.2B: warp world -> deep con blend de confianza.
// Devuelve vec4(deep_x, deep_z, confidence, 0). confidence = 1 en SAFE,
// suave 0..1 en NEAR_CAUSTIC, 0 en inválido/fuera/folded.
vec4 warp_deep_sample(vec2 world_xz) {
	vec2 uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	vec2 uv_clamped = clamp(uv, vec2(0.0), vec2(1.0));
	vec4 warp = textureLod(coastal_warp_texture, uv_clamped, 0.0);
	float det_j = warp.b;
	// Blend suave según el Jacobiano: SAFE -> 1, NEAR_CAUSTIC -> 0..1, folded -> 0.
	// warp.a (valid 0/1, interpolado en bordes por filter_linear) apaga el warp
	// fuera de la zona válida con fade natural (evita seams).
	float confidence = smoothstep(0.0, coastal_warp_detj_safe, det_j);
	confidence *= warp.a;
	// Fuera del rectángulo del warp: sin warp (confidence 0).
	confidence *= step(uv.x, 1.0) * step(uv.y, 1.0) * step(0.0, uv.x) * step(0.0, uv.y);
	return vec4(warp.xy, confidence, 0.0);
}

vec4 warp_jacobian_sample(vec2 world_xz) {
	vec2 uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	return textureLod(coastal_warp_jacobian_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	ocean_world_xz = world_xz;
	coastal_mono_phase = 0.0;
	coastal_mono_active = 0.0;
	coastal_warp_delta_m = 0.0;
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	vec2 coast_uv = coastal_uv(world_xz);
	coastal_field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	coastal_metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	coastal_phase_data = textureLod(coastal_phase_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, coastal_field);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	float phase_offset = coastal_field.r;
	float shoaling = coastal_field.g;

	// 3B.2B: LONG se compone de LONG_COASTAL (posiblemente warpeada) +
	// LONG_REMAINDER (siempre open). El warp sólo aplica a LONG_COASTAL.
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_forced_warp_debug && coastal_warp_effect_debug != 2) {
		// Prueba de cadena de textura/binding: no es una solución física.
		warp_sample = vec4(world_xz + coastal_forced_warp_offset_xz, 1.0, 0.0);
	} else if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z;
	vec4 warp_jacobian = vec4(1.0, 0.0, 0.0, 1.0);
	if (coast_transform_active && coastal_warp_enabled && !coastal_forced_warp_debug && coastal_warp_effect_debug != 2) {
		warp_jacobian = warp_jacobian_sample(world_xz);
	}
	// LONG_COASTAL: sampleo en deep (si warp activo) con blend -> open (sin warp).
	vec3 long_coastal_warped = textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal = mix(long_coastal_open, long_coastal_warped, warp_confidence);
	coastal_warp_delta_m = length(long_coastal_warped - long_coastal_open);
	float effective_shoaling = 1.0;
	if (coast_transform_active) {
		if (coastal_warp_effect_debug == 2) effective_shoaling = shoaling; // DEBUG: shoaling sin warp.
		else if (coastal_warp_effect_debug == 0) effective_shoaling = mix(1.0, shoaling, warp_confidence);
	}
	long_coastal *= effective_shoaling;
	// LONG_REMAINDER: siempre open-ocean.
	vec3 long_remainder = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb;
	vec3 long_displacement = long_coastal + long_remainder;
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
	vec3 displacement = long_coastal * coastal_weight * coastal_gain + long_remainder * remainder_weight;
	displacement += mid_displacement * mid_weight * mid_short_weight + short_displacement * short_weight * mid_short_weight;

	// Normales en slope space: slope_total = suma de slopes por banda.
	vec3 long_coastal_normal_warped = normalize(textureLod(normal_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb);
	vec3 long_coastal_normal_open = normalize(textureLod(normal_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb);
	vec2 slope_open = slope_from_normal(long_coastal_normal_open);
	vec2 slope_deep = slope_from_normal(long_coastal_normal_warped);
	// Heightfield/choppy approximation: s_world = J^T * s_deep. No reconstruye
	// los tangentes 3D completos del desplazamiento FFT, pero respeta el warp 2D.
	vec2 slope_warped_world = vec2(
		warp_jacobian.r * slope_deep.x + warp_jacobian.b * slope_deep.y,
		warp_jacobian.g * slope_deep.x + warp_jacobian.a * slope_deep.y
	);
	vec2 slope_coastal = mix(slope_open, slope_warped_world, warp_confidence);
	vec2 slope = slope_coastal * coastal_weight * effective_shoaling * coastal_gain;
	vec3 long_remainder_normal = normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb);
	slope += slope_from_normal(long_remainder_normal) * remainder_weight;
	slope += slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb)) * mid_weight * mid_short_weight;
	slope += slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb)) * short_weight * mid_short_weight;
	vec3 ocean_normal = normalize(vec3(-slope.x, 1.0, -slope.y));

	if (coastal_monochromatic_debug) {
		// Instrumento 3B/3B.1: onda mono (no FFT), referencia para el transform.
		bool eikonal_active = coastal_eikonal_phase_debug && coast_active && coastal_phase_data.a > 0.5;
		float mono_phase_offset = coast_transform_active ? phase_offset : 0.0;
		float mono_shoaling = coast_transform_active ? shoaling : 1.0;
		float mono_k = coast_transform_active ? coastal_field.b : coastal_k0_rad_m;
		vec2 mono_direction = coastal_incoming_direction_xz;
		float phase = dot(world_xz, coastal_incoming_direction_xz) * coastal_k0_rad_m + mono_phase_offset - coastal_omega_rad_s * coastal_time_s;
		if (eikonal_active) {
			phase = coastal_phase_data.r - coastal_omega_rad_s * coastal_time_s;
			mono_direction = normalize(coastal_phase_data.gb);
			mono_k = coastal_field.b;
		}
		if (coastal_eikonal_phase_debug && coast_active && coastal_phase_data.a <= 0.5) {
			mono_shoaling = 0.0; // shadow/unreached: sin ola inventada.
		}
		long_displacement = vec3(0.0, coastal_monochromatic_amplitude_m * mono_shoaling * cos(phase), 0.0);
		displacement = long_displacement * long_weight;
		vec2 mono_gradient = -mono_direction * coastal_monochromatic_amplitude_m * mono_shoaling * mono_k * sin(phase);
		ocean_normal = normalize(vec3(-mono_gradient.x, 1.0, -mono_gradient.y));
		coastal_mono_phase = phase;
		coastal_mono_active = 1.0;
	}

	if (!module_enabled) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	} else if (debug_mode == 1) {
		// HEIGHT ONLY: sin desplazamiento horizontal, para evaluar choppiness.
		displacement.xz = vec2(0.0);
	}
	VERTEX += displacement;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}


void fragment() {
	vec3 color = base_color;
	if (debug_mode == 2) {
		color = normalize(derived_normal) * 0.5 + 0.5;
	} else if (debug_mode == 3) {
		vec3 n = normalize(derived_normal);

		vec2 slope = -n.xz / max(n.y, 0.05);
		vec2 slope_dir = normalize(vec2(0.7, -0.7));

		float signed_slope = dot(slope, slope_dir);
		float shade = clamp(0.5 + signed_slope * 5.0, 0.0, 1.0);

		color = mix(slope_valley_color, slope_crest_color, shade);
	}
	if (coastal_mono_active > 0.5) {
		float crest = 0.5 + 0.5 * cos(coastal_mono_phase);
		float crest_line = smoothstep(0.88, 0.985, crest);
		color = mix(vec3(0.005, 0.025, 0.12), vec3(0.03, 0.34, 0.68), pow(crest, 1.6));
		color = mix(color, vec3(0.78, 1.0, 1.0), crest_line);
	}
	if (coastal_debug_field > 0 && coastal_propagation_enabled) {
		float value = 0.0;
		if (coastal_debug_field == 1) value = coastal_metrics.r / 12.0;
		else if (coastal_debug_field == 2) value = coastal_metrics.g / 32.0;
		else if (coastal_debug_field == 3) value = coastal_metrics.b / 8.0;
		else if (coastal_debug_field == 4) value = coastal_metrics.a / 8.0;
		else if (coastal_debug_field == 5) value = (coastal_field.g - 1.0) * 8.0;
		else if (coastal_debug_field == 6) value = abs(coastal_field.r) / 6.2831853;
		else if (coastal_debug_field == 7) value = coastal_field.b;
		else if (coastal_debug_field == 8) value = coastal_phase_data.a;
		color = mix(vec3(0.02, 0.05, 0.12), vec3(0.95, 0.8, 0.18), clamp(value, 0.0, 1.0));
	}
	if (coastal_delta_heatmap) {
		float delta_value = clamp(coastal_warp_delta_m * 8.0, 0.0, 1.0);
		color = mix(vec3(0.0, 0.0, 0.02), vec3(1.0, 0.08, 0.0), delta_value);
	}

	if (clipmap_lod_debug) {
		color = level_color(clipmap_level);
	}
	if (periodicity_debug) {
		float lines = max(periodic_grid(ocean_world_xz, domain_long_coastal_m), max(periodic_grid(ocean_world_xz, domain_mid_m), periodic_grid(ocean_world_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}

	bool unlit = debug_mode >= 2 || clipmap_lod_debug || periodicity_debug || coastal_debug_field > 0 || coastal_mono_active > 0.5 || coastal_delta_heatmap;
	if (unlit) {
		ALBEDO = vec3(0.0);
		EMISSION = color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else {
		ALBEDO = color;
		EMISSION = vec3(0.0);
		ROUGHNESS = 0.42;
		SPECULAR = 0.35;
	}
}

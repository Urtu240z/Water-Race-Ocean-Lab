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
// Phase 4A: detector GPU de pre-break. Apagado salvo instrumento debug / 4B.
// 0 OFF, 1 DEPTH, 2 STEEPNESS, 3 CRESTNESS, 4 PREBREAK.
uniform int breaking_debug_mode = 0;
// Hs de LONG completo en deep water y fracción de energía del split COASTAL.
// Se derivan de SeaStateConfig + H0 split; no son altura instantánea.
uniform float breaking_long_hs_m = 0.50;
uniform float breaking_coastal_energy_fraction = 0.50;
uniform float breaking_depth_gamma = 0.78;
uniform vec2 breaking_depth_ratio_range = vec2(0.55, 1.0);
uniform vec2 breaking_steepness_range = vec2(0.28, 0.42);
uniform vec2 breaking_crest_spacing_lambda_range_m = vec2(0.25, 2.0);
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
// 4C-S3: takeover mask debug (FORCE_LIP). Oculta el FFT base bajo el patch.
uniform bool breaker_takeover_debug_enabled = false;
uniform vec2 breaker_takeover_anchor_xz = vec2(0.0);
uniform vec2 breaker_takeover_direction_xz = vec2(1.0, 0.0);
uniform float breaker_takeover_length_m = 16.0;
uniform float breaker_takeover_width_m = 5.0;
uniform float breaker_takeover_stage = 0.0;
uniform float breaker_takeover_inner = 0.75;
uniform float breaker_takeover_feather = 0.15;
// 4C-S3.1: ventana longitudinal localizada (q normalizado en [0,1]).
uniform float breaker_takeover_start = 0.30;
uniform float breaker_takeover_core_start = 0.40;
uniform float breaker_takeover_core_end = 0.72;
uniform float breaker_takeover_end = 0.82;
uniform float breaker_takeover_forward_sign = -1.0;
// 4C-S3.2: banda longitudinal estrecha de seam (q_profile). La ventana S3.1
// actúa sólo como bounding window; la ocultación real vive en esta banda.
uniform float breaker_takeover_seam_center = 0.56;
uniform float breaker_takeover_seam_half_width = 0.10;
uniform float breaker_takeover_seam_feather = 0.06;
// 4C-S3.3: profundidad de submerge (depresión vertical) bajo la seam S3.2.
uniform float breaker_takeover_submerge_hs = 0.30;
// 5A: visual quality pass / living surface. Tunables agrupados y bien nombrados.
uniform float ocean_foam_strength = 1.0;      // crest/flow/patch foam global.
uniform float ocean_redistribution = 1.0;     // secondary-peak instability / streaks.
uniform float ocean_directional_flow = 1.0;   // orientación de la piel (streaks).
uniform float ocean_nearshore_boost = 1.0;    // enriquecimiento nearshore.
uniform float ocean_detail_boost = 1.0;       // piel SHORT / microdetalle.
uniform vec3 ocean_color_deep = vec3(0.014, 0.075, 0.15);
uniform vec3 ocean_color_shallow = vec3(0.05, 0.32, 0.33);
uniform float ocean_fresnel_strength = 1.0;
uniform bool ocean_quality_debug = false;

varying vec3 derived_normal;
varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying vec4 coastal_phase_data;
varying float coastal_mono_phase;
varying float coastal_mono_active;
varying float coastal_warp_delta_m;
varying vec4 breaking_indices; // depth, steepness, crestness, final prebreak.
varying vec2 slope_long;   // 5A: pendiente LONG (swell dominante).
varying vec2 slope_mid;    // 5A: pendiente MID.
varying vec2 slope_short;  // 5A: pendiente SHORT (piel).
varying float long_height; // 5A: altura LONG en este vértice (para curvatura).

// Detector GPU de pre-break (4A) y funciones compartidas con el takeover 4B:
// spectrum_uv, distance_fade, slope_from_normal, coastal_uv, has_coastal_data,
// warp_deep_sample, warp_jacobian_sample, coastal_long_state, long_height_at,
// breaking_local_state_at, prebreak_indices_at y los perfiles del labio 4B.
#include "res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc"

vec3 level_color(float level) {
	float wave = fract(level * 0.61803398875);
	return mix(vec3(0.12, 0.85, 0.95), vec3(0.95, 0.25, 0.12), wave);
}

float periodic_grid(vec2 world_xz, float domain_size_m) {
	vec2 cell = abs(fract(world_xz / domain_size_m + 0.5) - 0.5);
	return smoothstep(0.485, 0.5, max(cell.x, cell.y));
}

// 4C-S3.2: seam suppression estrecha. La ventana exterior S3.1 se conserva como
// bounding window (ya no define un core de ocultación); la ocultación real es una
// banda longitudinal simétrica alrededor de seam_center en q_profile. El lateral
// conserva el fade inner/feather existente. S3.3 resuelve la ocultación en
// vertex() como submerge vertical (sin discard).
float breaker_takeover_mask(vec2 world_xz) {
	vec2 direction = normalize(breaker_takeover_direction_xz);
	vec2 tangent = vec2(-direction.y, direction.x);
	vec2 delta = world_xz - breaker_takeover_anchor_xz;
	float local_s = dot(delta, direction);
	float local_v = dot(delta, tangent);

	float q = local_s / max(breaker_takeover_length_m, 0.001) + 0.5;
	float q_profile = breaker_takeover_forward_sign > 0.0 ? q : 1.0 - q;

	// Ventana exterior S3.1: bounding window.
	float outer_longitudinal_window = smoothstep(breaker_takeover_start, breaker_takeover_core_start, q_profile)
		* (1.0 - smoothstep(breaker_takeover_core_end, breaker_takeover_end, q_profile));

	// Banda longitudinal estrecha de seam (simétrica respecto al centro).
	float seam_distance = abs(q_profile - breaker_takeover_seam_center);
	float seam_mask = 1.0 - smoothstep(
		breaker_takeover_seam_half_width,
		breaker_takeover_seam_half_width + breaker_takeover_seam_feather,
		seam_distance);

	float half_width = 0.5 * breaker_takeover_width_m;
	float fade_v0 = breaker_takeover_inner * half_width;
	float fade_v1 = max(fade_v0 + 0.001, (breaker_takeover_inner + breaker_takeover_feather) * half_width);
	float lateral_mask = 1.0 - smoothstep(fade_v0, fade_v1, abs(local_v));

	return clamp(outer_longitudinal_window * seam_mask * lateral_mask, 0.0, 1.0);
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	ocean_world_xz = world_xz;
	coastal_mono_phase = 0.0;
	coastal_mono_active = 0.0;
	coastal_warp_delta_m = 0.0;
	breaking_indices = vec4(0.0);
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
	long_height = long_displacement.y; // 5A: referencia de altura LONG para curvatura.
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
	vec3 displacement = long_coastal * coastal_weight * coastal_gain + long_remainder * remainder_weight;
	displacement += mid_displacement * mid_weight * mid_short_weight + short_displacement * short_weight * mid_short_weight;

	// Normales en slope space: slope_total = suma de slopes por banda. 5A: se
	// separan LONG/MID/SHORT para la jerarquía y la inestabilidad de picos.
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
	vec3 long_remainder_normal = normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb);
	vec3 mid_normal = normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb);
	vec3 short_normal = normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb);
	slope_long = slope_coastal * coastal_weight * effective_shoaling * coastal_gain
		+ slope_from_normal(long_remainder_normal) * remainder_weight;
	slope_mid = slope_from_normal(mid_normal) * mid_weight * mid_short_weight;
	slope_short = slope_from_normal(short_normal) * short_weight * mid_short_weight;
	vec2 slope = slope_long + slope_mid + slope_short;
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

	// Ruta estrictamente opt-in. No hay compute global, readback ni OceanQuery:
	// sólo fetches adicionales en los vértices renderizados por el debug / futuro 4B.
	if (breaking_debug_mode > 0 && !coastal_monochromatic_debug) {
		breaking_indices = prebreak_indices_at(world_xz, coast_uv, coastal_field, coastal_metrics, coastal_phase_data);
	}

	if (!module_enabled) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	} else if (debug_mode == 1) {
		// HEIGHT ONLY: sin desplazamiento horizontal, para evaluar choppiness.
		displacement.xz = vec2(0.0);
	}

	// 4C-S3.3: submerge takeover. En vez de discard, hunde verticalmente el FFT
	// bajo la seam S3.2 (fade suave de la propia máscara). No toca xz/choppiness.
	if (breaker_takeover_debug_enabled) {
		float take_strength = smoothstep(0.35, 0.70, breaker_takeover_stage);
		float takeover = breaker_takeover_mask(world_xz) * take_strength;
		float takeover_submerge_m = max(0.15, breaking_long_hs_m * breaker_takeover_submerge_hs);
		displacement.y -= takeover_submerge_m * takeover;
	}

	VERTEX += displacement;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}


// 5A: hash y value-noise baratos para streaks/foam (sin texturas nuevas).
float ocean_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float ocean_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = ocean_hash(i);
	float b = ocean_hash(i + vec2(1.0, 0.0));
	float c = ocean_hash(i + vec2(0.0, 1.0));
	float d = ocean_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float ocean_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * ocean_noise(p);
		p = p * 2.03 + vec2(17.7, 9.1);
		a *= 0.5;
	}
	return v;
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
	if (breaking_debug_mode > 0) {
		float value = breaking_indices.x;
		if (breaking_debug_mode == 2) value = breaking_indices.y;
		else if (breaking_debug_mode == 3) value = breaking_indices.z;
		else if (breaking_debug_mode == 4) value = breaking_indices.w;
		// Azul (0) -> cian -> amarillo -> rojo (1), visible tanto desde top como grazing.
		vec3 heat = mix(vec3(0.01, 0.03, 0.12), vec3(0.0, 0.80, 0.90), smoothstep(0.0, 0.45, value));
		heat = mix(heat, vec3(1.0, 0.86, 0.08), smoothstep(0.35, 0.72, value));
		heat = mix(heat, vec3(1.0, 0.06, 0.02), smoothstep(0.70, 1.0, value));
		color = heat;
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

	// 4C-S3.3: el takeover ya no descarta fragmentos del FFT. La ocultación se
	// resuelve en vertex() hundiendo verticalmente el océano bajo la seam S3.2.

	bool unlit = debug_mode >= 2 || clipmap_lod_debug || periodicity_debug || coastal_debug_field > 0 || breaking_debug_mode > 0 || coastal_mono_active > 0.5 || coastal_delta_heatmap;
	if (unlit) {
		ALBEDO = vec3(0.0);
		EMISSION = color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else {
		// ===== 5A: living surface / ocean look =====
		vec3 N = normalize(derived_normal);
		vec3 N_view = normalize((VIEW_MATRIX * vec4(N, 0.0)).xyz);
		float ndotv = abs(dot(N_view, VIEW)); // 0 rasante, 1 nadir.

		// Pendiente total + dirección de máxima pendiente.
		vec2 slope_total = -N.xz / max(N.y, 0.02);
		float slope_mag = length(slope_total);
		vec2 slope_dir = slope_total / max(slope_mag, 0.001);

		// Escala de swell para curvatura (wavelength costera o fallback deep).
		float swell_lambda = coastal_metrics.g > 0.5 ? coastal_metrics.g : (TAU / max(coastal_k0_rad_m, 0.001));
		float eps = swell_lambda * 0.09;
		float h_c = long_height;
		float h_l = long_height_at(ocean_world_xz - slope_dir * eps);
		float h_r = long_height_at(ocean_world_xz + slope_dir * eps);
		float curv = h_l - 2.0 * h_c + h_r; // negativo = cresta (convexo arriba).
		float asym = abs(h_l - h_r);         // asimetría: hacia qué valle cae.

		// Jerarquía por banda.
		float long_mag = length(slope_long);
		float mid_mag = length(slope_mid);
		float short_mag = length(slope_short);
		float total_mag = max(long_mag + mid_mag + short_mag, 0.001);
		float swell_dominance = long_mag / total_mag;
		float worked = (mid_mag + short_mag * ocean_detail_boost) / total_mag;

		float local_hs = max(breaking_long_hs_m, 0.05);

		// Forma local: pico / cara / asimetría.
		float peak = smoothstep(-0.10 * local_hs, -0.005 * local_hs, curv);
		float steep = smoothstep(0.05, 0.32, slope_mag);
		float asym_norm = asym / max(local_hs, 0.001);

		// Inestabilidad de pico secundario: pico débil + empinado + asimétrico.
		float instability = peak * steep * smoothstep(0.08, 0.38, asym_norm) * ocean_redistribution;

		// Presencia costera (sólo donde hay datos de propagación).
		float coastal_presence = step(0.5, coastal_field.a);
		float depth_m = coastal_metrics.r;
		float nearshore = coastal_presence * (1.0 - smoothstep(1.0, 12.0, depth_m)) * ocean_nearshore_boost;

		// Foam de cresta: picos energéticos y caras empinadas.
		float crest_foam = peak * steep * ocean_foam_strength * mix(0.5, 1.0, swell_dominance);

		// Foam de flujo / streaks: caras + picos que se desparraman.
		vec2 flow_coord = ocean_world_xz * 0.9;
		float along = dot(flow_coord, slope_dir);
		float across = dot(flow_coord, vec2(-slope_dir.y, slope_dir.x));
		float streak = ocean_fbm(vec2(along * 0.55, across * 1.9)); // estirado a lo largo del flujo.
		float flow_foam = (steep * (0.35 + 0.65 * streak) * 0.5 + instability * (0.4 + 0.6 * streak)) * ocean_foam_strength * ocean_directional_flow;
		flow_foam *= (1.0 + 0.9 * nearshore);

		// Patch foam: zonas muy trabajadas (mid/short dominando).
		float patch_foam = steep * smoothstep(0.45, 0.85, worked) * streak * ocean_foam_strength;

		float foam = clamp(crest_foam + flow_foam + patch_foam, 0.0, 1.0);

		// Color: deep -> shallow por nearshore + sombreado de forma.
		vec3 water_color = mix(ocean_color_deep, ocean_color_shallow, clamp(nearshore, 0.0, 1.0));
		float form_shade = clamp(0.58 + 0.9 * (h_c - (h_l + h_r) * 0.5) / max(local_hs, 0.05) - 0.35 * slope_mag, 0.0, 1.0);
		water_color *= mix(0.82, 1.14, form_shade);

		// Fresnel + cielo rasante (VIEW en view-space; y ≈ componente vertical).
		float fresnel = pow(1.0 - ndotv, 4.0) * ocean_fresnel_strength;
		vec3 sky = mix(vec3(0.18, 0.30, 0.40), vec3(0.72, 0.85, 0.95), clamp(VIEW.y * 1.5 + 0.2, 0.0, 1.0));
		water_color = mix(water_color, sky, clamp(fresnel * 0.55, 0.0, 1.0));

		// Foam color (blanco-cálido) y roughness aparente.
		vec3 foam_color = mix(vec3(0.70, 0.80, 0.84), vec3(0.98, 0.99, 1.0), 0.65);
		float base_rough = mix(0.34, 0.62, clamp(short_mag * 3.0, 0.0, 1.0));
		float roughness = mix(base_rough, 0.78, clamp(foam * 0.6, 0.0, 1.0));

		ALBEDO = mix(water_color, foam_color, foam);
		EMISSION = foam_color * clamp(foam - 0.35, 0.0, 1.0) * 0.22;
		ROUGHNESS = roughness;
		SPECULAR = 0.5;

		if (ocean_quality_debug) {
			// Debug opcional: R=crest foam, G=flow foam, B=instability.
			ALBEDO = vec3(0.0);
			EMISSION = vec3(crest_foam, flow_foam, instability);
			ROUGHNESS = 1.0;
			SPECULAR = 0.0;
		}
	}
}

// ocean_breaking_common.gdshaderinc
// Funciones COMPARTIDAS del detector GPU de pre-break (Phase 4A) y del
// takeover de geometría local de breaker (Phase 4B).
//
// Este include NO declara uniforms: cada shader que lo incluya debe declarar
// ANTES del include los siguientes uniforms (mismos nombres/tipos que
// ocean_surface.gdshader):
//   sampler2D displacement_long_coastal, displacement_long_remainder,
//             displacement_mid, displacement_short
//   sampler2D normal_long_coastal, normal_long_remainder, normal_mid,
//             normal_short
//   sampler2D coastal_field_texture, coastal_metrics_texture,
//             coastal_phase_texture, coastal_warp_texture,
//             coastal_warp_jacobian_texture
//   float  domain_long_coastal_m, domain_long_remainder_m,
//          domain_mid_m, domain_short_m, coastal_warp_detj_safe,
//          coastal_k0_rad_m, breaking_long_hs_m,
//          breaking_coastal_energy_fraction, breaking_depth_gamma,
//          coastal_debug_gain
//   vec2   camera_world_xz, short_fade_range_m, mid_fade_range_m,
//          long_fade_range_m, coastal_origin_xz, coastal_extent_m,
//          coastal_incoming_direction_xz, coastal_warp_origin_xz,
//          coastal_warp_extent_m, breaking_depth_ratio_range,
//          breaking_steepness_range, breaking_crest_spacing_lambda_range_m
//   vec3   band_mask
//   bool   module_enabled, coastal_propagation_enabled,
//          coastal_transform_enabled, coastal_monochromatic_debug,
//          coastal_warp_enabled
//   int    coastal_composition_debug
//
// La ruta de detección samplea SOLO la macroestructura LONG real:
// LONG_COASTAL (warped/shoaled) + LONG_REMAINDER (open). MID/SHORT entran
// únicamente en surface_displacement_break/surface_slope_break (integración
// visual del ribetón con la superficie base), jamás en el trigger.

vec2 spectrum_uv(vec2 world_xz, float domain_size_m) {
	return fract(world_xz / domain_size_m + vec2(0.5));
}

float distance_fade(vec2 fade_range, float distance_to_camera) {
	return 1.0 - smoothstep(fade_range.x, fade_range.y, distance_to_camera);
}

vec2 slope_from_normal(vec3 ocean_normal) {
	return -ocean_normal.xz / max(ocean_normal.y, 0.0001);
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

// Estado costero mínimo para re-samplear LONG alrededor de una cresta. Mantiene
// exactamente la misma cadena visual: world -> deep (warp/confianza) + shoaling.
vec4 coastal_long_state(vec2 world_xz) {
	vec2 uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
	bool active = has_coastal_data(uv, field_data) && coastal_transform_enabled;
	vec4 warp = vec4(world_xz, 0.0, 0.0);
	if (active && coastal_warp_enabled) {
		warp = warp_deep_sample(world_xz);
	}
	float shoaling = active ? mix(1.0, field_data.g, warp.z) : 1.0;
	return vec4(warp.xy, warp.z, shoaling);
}

float long_height_at(vec2 world_xz) {
	vec4 state = coastal_long_state(world_xz);
	float coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).y;
	float coastal_deep = textureLod(displacement_long_coastal, spectrum_uv(state.xy, domain_long_coastal_m), 0.0).y;
	float coastal_height = mix(coastal_open, coastal_deep, state.z) * state.w;
	float remainder_height = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).y;
	return coastal_height + remainder_height;
}

// 4B: estado escalar local del modelo de energía de 4A, sin muestras de cresta.
// Devuelve vec4(amplitude_m, wavelength_m, local_k, local_hs).
// Réplica CPU: BreakerRibbonPool.estimate_local_hs / depth pressure.
vec4 breaking_local_state_at(vec2 world_xz, vec2 coast_uv, vec4 field_data) {
	float coastal_fraction = clamp(breaking_coastal_energy_fraction, 0.0, 1.0);
	float confidence = coastal_long_state(world_xz).z;
	float shoaling = mix(1.0, field_data.g, confidence);
	float local_hs = breaking_long_hs_m * sqrt(max(0.0, (1.0 - coastal_fraction) + coastal_fraction * shoaling * shoaling));
	float amplitude = max(0.5 * local_hs, 0.01);
	float k_deep = max(coastal_k0_rad_m, 0.0001);
	float k_coastal = max(field_data.b, k_deep);
	float local_k = mix(k_deep, k_coastal, coastal_fraction * confidence);
	float wavelength = TAU / local_k;
	return vec4(amplitude, wavelength, local_k, local_hs);
}

vec4 prebreak_indices_at(vec2 world_xz, vec2 coast_uv, vec4 field_data, vec4 metrics_data, vec4 phase_data) {
	// El alcance de 4A es rompiente costera: sin propagation/batimetría válida
	// no existe una profundidad local que pueda inventar un trigger. Esto hace
	// que Coastal OFF elimine por completo la influencia del banco.
	if (!has_coastal_data(coast_uv, field_data)) return vec4(0.0);
	// Aproximación documentada de Phase 4A: Hs_LONG local se obtiene de la
	// energía espectral LONG de deep water, repartida por el split y escalada
	// por shoaling. H = Hs (no eta instantánea); a = H / 2 para ka.
	vec4 local_state = breaking_local_state_at(world_xz, coast_uv, field_data);
	float amplitude = local_state.x;
	float wavelength = local_state.y;
	float local_k = local_state.z;
	float local_hs = local_state.w;
	float depth_m = max(metrics_data.r, 0.001);
	float depth_ratio = local_hs / max(breaking_depth_gamma * depth_m, 0.001);
	float depth_pressure = smoothstep(breaking_depth_ratio_range.x, breaking_depth_ratio_range.y, depth_ratio);
	float steepness_pressure = smoothstep(breaking_steepness_range.x, breaking_steepness_range.y, local_k * amplitude);

	// La cresta sí procede de las muestras dinámicas del FFT real LONG:
	// LONG_COASTAL warped + shoaled, más LONG_REMAINDER open. MID/SHORT no entran.
	vec2 propagation = phase_data.gb;
	if (dot(propagation, propagation) < 0.25) propagation = coastal_incoming_direction_xz;
	propagation = normalize(propagation);
	float eta_0 = long_height_at(world_xz);
	// Crestness MULTIESCALA normalizado: el LONG real es de banda ancha; tres
	// espaciados (lambda/16, lambda/8, lambda/4) con el MISMO criterio.
	// Cada escala se reescala a la respuesta sinusoidal de s1 para que s2/s3 no
	// ganen ventaja por samplear más lejos; los thresholds NO cambian.
	float spacing_ref = clamp(wavelength / 16.0, breaking_crest_spacing_lambda_range_m.x, breaking_crest_spacing_lambda_range_m.y);
	float response_ref = max(1.0 - cos(local_k * spacing_ref), 1.0e-4);
	float crestness = 0.0;
	for (int scale = 0; scale < 3; scale++) {
		float spacing = spacing_ref;
		if (scale == 1) {
			spacing = clamp(wavelength / 8.0, 0.5, 4.0);
		} else if (scale == 2) {
			spacing = clamp(wavelength / 4.0, 1.0, 8.0);
		}
		float response_i = max(1.0 - cos(local_k * spacing), 1.0e-4);
		float scale_to_ref = response_ref / response_i;
		float eta_minus = long_height_at(world_xz - propagation * spacing);
		float eta_plus = long_height_at(world_xz + propagation * spacing);
		float neighbor_rise = min(eta_0 - eta_minus, eta_0 - eta_plus);
		float curvature_down = 2.0 * eta_0 - eta_minus - eta_plus;
		float neighbor_equiv = neighbor_rise * scale_to_ref;
		float curvature_equiv = curvature_down * scale_to_ref;
		float crest_rise = smoothstep(0.012 * amplitude, 0.075 * amplitude, neighbor_equiv);
		float crest_curve = smoothstep(0.025 * amplitude, 0.15 * amplitude, curvature_equiv);
		crestness = max(crestness, crest_rise * crest_curve);
	}

	// Sólo pre-break costero en 4A: steepness modula el potencial de profundidad,
	// pero no habilita whitecaps en mar profundo.
	float prebreak = crestness * depth_pressure * mix(0.35, 1.0, steepness_pressure);
	return vec4(depth_pressure, steepness_pressure, crestness, prebreak);
}

// 4B: muestreo de la superficie base COMPLETA (LONG_COASTAL warped+shoaled,
// LONG_REMAINDER, MID y SHORT) con los mismos pesos/fades/composición que el
// clipmap. El ribetón se apoya en esta superficie para integrarse con la ola
// visible; la detección (trigger) sigue siendo LONG-only vía prebreak_indices_at.
vec3 surface_displacement_break(vec2 world_xz, vec2 coast_uv, vec4 field_data, float distance_to_camera) {
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z;
	vec3 long_coastal_warped = textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal = mix(long_coastal_open, long_coastal_warped, warp_confidence);
	float effective_shoaling = 1.0;
	if (coast_transform_active) {
		effective_shoaling = mix(1.0, field_data.g, warp_confidence);
	}
	long_coastal *= effective_shoaling;
	vec3 long_remainder = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb;
	vec3 mid_displacement = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb;
	vec3 short_displacement = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb;
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
	vec3 displacement = long_coastal * coastal_weight * coastal_gain + long_remainder * remainder_weight;
	displacement += mid_displacement * mid_weight * mid_short_weight + short_displacement * short_weight * mid_short_weight;
	return displacement;
}

vec2 surface_slope_break(vec2 world_xz, vec2 coast_uv, vec4 field_data, float distance_to_camera) {
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z;
	vec3 long_coastal_normal_warped = normalize(textureLod(normal_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb);
	vec3 long_coastal_normal_open = normalize(textureLod(normal_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb);
	vec2 slope_open = slope_from_normal(long_coastal_normal_open);
	vec2 slope_deep = slope_from_normal(long_coastal_normal_warped);
	// Heightfield/choppy approximation: s_world = J^T * s_deep. No reconstruye
	// los tangentes 3D completos del desplazamiento FFT, pero respeta el warp 2D.
	vec4 jacobian = warp_jacobian_sample(world_xz);
	vec2 slope_warped_world = vec2(
		jacobian.r * slope_deep.x + jacobian.b * slope_deep.y,
		jacobian.g * slope_deep.x + jacobian.a * slope_deep.y
	);
	vec2 slope_coastal = mix(slope_open, slope_warped_world, warp_confidence);
	float effective_shoaling = 1.0;
	if (coast_transform_active) {
		effective_shoaling = mix(1.0, field_data.g, warp_confidence);
	}
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
	vec2 slope = slope_coastal * coastal_weight * effective_shoaling * coastal_gain;
	vec3 long_remainder_normal = normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb);
	slope += slope_from_normal(long_remainder_normal) * remainder_weight;
	slope += slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb)) * mid_weight * mid_short_weight;
	slope += slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb)) * short_weight * mid_short_weight;
	return slope;
}

// --- 4B: perfiles del labio, fade de borde y envolvente de takeover. ---
// u/v son las coordenadas del ribetón: u ∈ [0,1] (0 = borde de aguas profundas,
// 1 = borde hacia costa), v ∈ [0,1] (ancho). El centro del labio (cresta) cae
// en u = 0.545 (mix(-0.6, 0.5, u) == 0).
// Réplicas CPU: BreakerRibbonPool.lip_lift_profile / lip_advance_profile /
// edge_fade / breaker_envelope (mismas fórmulas, para validación y HUD).
const float BREAKER_CREST_U = 0.545;

float breaker_lift_profile(float u) {
	// Proto-labio localizado: sube rápido justo antes de la cresta, máximo en
	// u=0.545 y cae rápido justo después. Activo ~0.40..0.68, energía ~0.48..0.62.
	float rise = smoothstep(0.40, BREAKER_CREST_U, u);
	float fall = 1.0 - smoothstep(BREAKER_CREST_U, 0.68, u);
	return rise * fall;
}

float breaker_advance_profile(float u) {
	// Adelantamiento horizontal localizado DELANTE de la cresta: 0 detrás,
	// pequeño en la cresta, pico justo delante (~0.63) y de vuelta a 0 antes
	// del borde final. No adelanta toda la cinta.
	float rise = smoothstep(BREAKER_CREST_U, BREAKER_CREST_U + 0.08, u);
	float fall = 1.0 - smoothstep(BREAKER_CREST_U + 0.08, BREAKER_CREST_U + 0.20, u);
	return rise * fall;
}

float breaker_edge_fade(float u, float v) {
	float uf = smoothstep(0.02, 0.12, u) * (1.0 - smoothstep(0.88, 0.98, u));
	float vf = smoothstep(0.04, 0.22, v) * (1.0 - smoothstep(0.78, 0.96, v));
	return uf * vf;
}

float breaker_envelope(float prebreak) {
	// Sin histéresis ni umbral binario: el campo 4A ya es continuo, esto sólo
	// comprime el rango útil. prebreak 0 -> 0, prebreak >= 0.5 -> 1.
	return smoothstep(0.05, 0.5, prebreak);
}

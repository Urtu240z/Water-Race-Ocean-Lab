vec4 prebreak_indices_at(vec2 world_xz, vec2 coast_uv, vec4 field_data, vec4 metrics_data, vec4 phase_data) {
	// El alcance de 4A es rompiente costera: sin propagation/batimetrÃ­a vÃ¡lida
	// no existe una profundidad local que pueda inventar un trigger. Esto hace
	// que Coastal OFF elimine por completo la influencia del banco.
	if (!has_coastal_data(coast_uv, field_data)) return vec4(0.0);
	// AproximaciÃ³n documentada de Phase 4A: Hs_LONG local se obtiene de la
	// energÃ­a espectral LONG de deep water, repartida por el split y escalada
	// por shoaling. H = Hs (no eta instantÃ¡nea); a = H / 2 para ka.
	vec4 local_state = breaking_local_state_at(world_xz, coast_uv, field_data);
	float amplitude = local_state.x;
	float wavelength = local_state.y;
	float local_k = local_state.z;
	float local_hs = local_state.w;
	float depth_m = max(metrics_data.r, 0.001);
	float depth_ratio = local_hs / max(breaking_depth_gamma * depth_m, 0.001);
	float depth_pressure = smoothstep(breaking_depth_ratio_range.x, breaking_depth_ratio_range.y, depth_ratio);
	float steepness_pressure = smoothstep(breaking_steepness_range.x, breaking_steepness_range.y, local_k * amplitude);

	// La cresta sÃ­ procede de las muestras dinÃ¡micas del FFT real LONG:
	// LONG_COASTAL warped + shoaled, mÃ¡s LONG_REMAINDER open. MID/SHORT no entran.
	vec2 propagation = phase_data.gb;
	if (dot(propagation, propagation) < 0.25) propagation = coastal_incoming_direction_xz;
	propagation = normalize(propagation);
	float spacing = clamp(wavelength / 16.0, breaking_crest_spacing_lambda_range_m.x, breaking_crest_spacing_lambda_range_m.y);
	float eta_minus = long_height_at(world_xz - propagation * spacing);
	float eta_0 = long_height_at(world_xz);
	float eta_plus = long_height_at(world_xz + propagation * spacing);
	float neighbor_rise = min(eta_0 - eta_minus, eta_0 - eta_plus);
	float curvature_down = 2.0 * eta_0 - eta_minus - eta_plus;
	float crest_rise = smoothstep(0.012 * amplitude, 0.075 * amplitude, neighbor_rise);
	float crest_curve = smoothstep(0.025 * amplitude, 0.15 * amplitude, curvature_down);
	float crestness = crest_rise * crest_curve;

	// SÃ³lo pre-break costero en 4A: steepness modula el potencial de profundidad,
	// pero no habilita whitecaps en mar profundo.
	float prebreak = crestness * depth_pressure * mix(0.35, 1.0, steepness_pressure);
	return vec4(depth_pressure, steepness_pressure, crestness, prebreak);
}

// 4B: muestreo de la superficie base COMPLETA (LONG_COASTAL warped+shoaled,
// LONG_REMAINDER, MID y SHORT) con los mismos pesos/fades/composiciÃ³n que el
// clipmap. El ribetÃ³n se apoya en esta superficie para integrarse con la ola
// visible; la detecciÃ³n (trigger) sigue siendo LONG-only vÃ­a prebreak_indices_at.
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
// u/v son las coordenadas del ribetÃ³n: u âˆˆ [0,1] (0 = borde de aguas profundas,
// 1 = borde hacia costa), v âˆˆ [0,1] (ancho). El centro del labio (cresta) cae
// en u = 0.545 (mix(-0.6, 0.5, u) == 0).
// RÃ©plicas CPU: BreakerRibbonPool.lip_lift_profile / lip_advance_profile /
// edge_fade / breaker_envelope (mismas fÃ³rmulas, para validaciÃ³n y HUD).
const float BREAKER_CREST_U = 0.545;

float breaker_lift_profile(float u) {
	float rise = smoothstep(0.06, BREAKER_CREST_U, u);
	float fall = 1.0 - smoothstep(BREAKER_CREST_U, BREAKER_CREST_U + 0.26, u);
	return rise * fall;
}

float breaker_advance_profile(float u) {
	// El adelantamiento horizontal nace en la cresta y pica justo delante de
	// ella (labio que empieza a volcarse); 0 detrÃ¡s y en el borde final.
	float rise = smoothstep(BREAKER_CREST_U, BREAKER_CREST_U + 0.16, u);
	float fall = 1.0 - smoothstep(BREAKER_CREST_U + 0.16, 0.90, u);
	return rise * fall;
}

float breaker_edge_fade(float u, float v) {
	float uf = smoothstep(0.02, 0.12, u) * (1.0 - smoothstep(0.88, 0.98, u));
	float vf = smoothstep(0.04, 0.22, v) * (1.0 - smoothstep(0.78, 0.96, v));
	return uf * vf;
}

float breaker_envelope(float prebreak) {
	// Sin histÃ©resis ni umbral binario: el campo 4A ya es continuo, esto sÃ³lo
	// comprime el rango Ãºtil. prebreak 0 -> 0, prebreak >= 0.5 -> 1.
	return smoothstep(0.05, 0.5, prebreak);
}

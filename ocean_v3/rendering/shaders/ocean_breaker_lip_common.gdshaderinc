// Funciones específicas del ribbon breaker_lip.
// No se incluyen desde ocean_surface: el clipmap base no necesita esta ruta.

// 4B: muestreo de la superficie base COMPLETA (LONG_COASTAL warped+shoaled,
// LONG_REMAINDER, MID y SHORT) para integrar el ribetón con la ola visible.
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

// u/v son las coordenadas del ribbon: u longitudinal y v transversal.
float breaker_edge_fade(float u, float v) {
	float uf = smoothstep(0.02, 0.12, u) * (1.0 - smoothstep(0.88, 0.98, u));
	float vf = smoothstep(0.04, 0.22, v) * (1.0 - smoothstep(0.78, 0.96, v));
	return uf * vf;
}

float breaker_envelope(float prebreak) {
	// El campo PREBREAK es continuo: no se introduce un umbral binario.
	return smoothstep(0.05, 0.5, prebreak);
}

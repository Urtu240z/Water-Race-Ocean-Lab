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
//   int    sea_state_zone_count
//   vec4   sea_state_zone_data0[8], sea_state_zone_data1[8],
//          sea_state_zone_data2[8]
//   bool   module_enabled, coastal_propagation_enabled,
//          coastal_transform_enabled, coastal_monochromatic_debug,
//          coastal_warp_enabled
//   int    coastal_composition_debug
//
// Phase 5R.2: OPEN_BREAK evalúa LONG + MID en mar abierto; DEPTH_BREAK mantiene
// el mecanismo costero LONG. SHORT no entra en ningún trigger geométrico. La
// integración visual del ribetón vive en el include específico de breaker_lip.

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

void breaking_zone_sdf(vec2 point, vec2 center, vec2 axis, vec2 half_extents,
		out float sdf) {
	vec2 safe_axis = dot(axis, axis) > 0.000001 ? normalize(axis) : vec2(1.0, 0.0);
	vec2 tangent = vec2(-safe_axis.y, safe_axis.x);
	vec2 local_point = vec2(dot(point - center, safe_axis), dot(point - center, tangent));
	vec2 q = abs(local_point) - half_extents;
	vec2 outside = max(q, vec2(0.0));
	sdf = length(outside) + min(max(q.x, q.y), 0.0);
}

// Same sequential zone composition as OceanQuery/ocean_surface, restricted to
// the LONG amplitude and choppiness that physically drive PREBREAK.
void breaking_zone_state(vec2 point, out float long_amplitude, out float choppiness) {
	long_amplitude = 1.0;
	choppiness = 1.0;
	for (int index = 0; index < 8; index++) {
		if (index >= sea_state_zone_count) break;
		vec4 zone0 = sea_state_zone_data0[index];
		vec4 zone1 = sea_state_zone_data1[index];
		vec4 target = sea_state_zone_data2[index];
		float sdf;
		breaking_zone_sdf(point, zone0.xy, zone0.zw, zone1.xy, sdf);
		float feather = max(zone1.z, 0.0);
		float local_weight = 0.0;
		if (feather <= 0.000001 || sdf <= 0.0) {
			local_weight = 1.0;
		} else if (sdf < feather) {
			local_weight = 1.0 - smoothstep(0.0, 1.0, sdf / feather);
		}
		float weight = clamp(local_weight * clamp(zone1.w, 0.0, 1.0), 0.0, 1.0);
		if (weight <= 0.0) continue;
		long_amplitude = mix(long_amplitude, target.x, weight);
		choppiness = mix(choppiness, target.w, weight);
	}
}

float breaking_zone_activity(vec2 world_xz) {
	float long_amplitude;
	float choppiness;
	breaking_zone_state(world_xz, long_amplitude, choppiness);
	return clamp(long_amplitude * (0.5 + 0.5 * choppiness), 0.0, 1.0);
}

float long_height_at(vec2 world_xz) {
	vec4 state = coastal_long_state(world_xz);
	float coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).y;
	float coastal_deep = textureLod(displacement_long_coastal, spectrum_uv(state.xy, domain_long_coastal_m), 0.0).y;
	float coastal_height = mix(coastal_open, coastal_deep, state.z) * state.w;
	float remainder_height = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).y;
	float local_long_amplitude;
	float local_choppiness;
	breaking_zone_state(world_xz, local_long_amplitude, local_choppiness);
	return (coastal_height + remainder_height) * local_long_amplitude;
}

float mid_height_at(vec2 world_xz) {
	return textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).y;
}

float breaking_reference_wavelength(float min_wavelength_m, float max_wavelength_m) {
	return sqrt(max(min_wavelength_m, 0.05) * max(max_wavelength_m, min_wavelength_m));
}

// Returns crestness and the measured face slope of one actual FFT band. The
// signal is sampled along that band's configured propagation direction, not by
// distance to shore or a procedural mask.
vec2 open_band_crest_and_slope(vec2 world_xz, vec2 propagation, float wavelength,
		float amplitude, bool is_mid) {
	vec2 direction = dot(propagation, propagation) > 0.25 ? normalize(propagation) : vec2(1.0, 0.0);
	float height_center = is_mid ? mid_height_at(world_xz) : long_height_at(world_xz);
	float crestness = 0.0;
	float face_slope = 0.0;
	for (int scale = 0; scale < 2; scale++) {
		float spacing = wavelength * (scale == 0 ? 0.125 : 0.25);
		spacing = clamp(spacing, is_mid ? 0.20 : 0.50, is_mid ? 3.0 : 8.0);
		float height_minus = is_mid ? mid_height_at(world_xz - direction * spacing) : long_height_at(world_xz - direction * spacing);
		float height_plus = is_mid ? mid_height_at(world_xz + direction * spacing) : long_height_at(world_xz + direction * spacing);
		float neighbor_rise = min(height_center - height_minus, height_center - height_plus);
		float curvature_down = 2.0 * height_center - height_minus - height_plus;
		float crest_rise = smoothstep(0.016 * amplitude, 0.10 * amplitude, neighbor_rise);
		float crest_curve = smoothstep(0.030 * amplitude, 0.20 * amplitude, curvature_down);
		crestness = max(crestness, crest_rise * crest_curve);
		face_slope = max(face_slope, abs(height_plus - height_minus) / max(2.0 * spacing, 0.001));
	}
	return vec2(crestness, face_slope);
}

// Returns vec2(LONG contribution, MID contribution), each in [0,1]. It uses
// actual FFT displacement/crest geometry. SHORT deliberately has no sample in
// this function, so it cannot create a main geometric breaker candidate.
vec2 open_break_components_at(vec2 world_xz) {
	float long_wavelength = breaking_reference_wavelength(breaking_long_min_wavelength_m, breaking_long_max_wavelength_m);
	float mid_wavelength = breaking_reference_wavelength(breaking_mid_min_wavelength_m, breaking_mid_max_wavelength_m);
	float long_amplitude = max(0.5 * breaking_long_hs_m, 0.01);
	float mid_amplitude = max(0.5 * breaking_mid_hs_m, 0.01);
	vec2 long_geometry = open_band_crest_and_slope(world_xz, breaking_long_direction_xz, long_wavelength, long_amplitude, false);
	vec2 mid_geometry = open_band_crest_and_slope(world_xz, breaking_mid_direction_xz, mid_wavelength, mid_amplitude, true);
	float long_k = TAU / max(long_wavelength, 0.05);
	float mid_k = TAU / max(mid_wavelength, 0.05);
	float long_steepness = max(long_geometry.y, long_k * long_amplitude);
	float mid_steepness = max(mid_geometry.y, mid_k * mid_amplitude);
	float long_steepness_score = smoothstep(0.10, 0.30, long_steepness);
	float mid_steepness_score = smoothstep(0.08, 0.24, mid_steepness);
	float long_signal = long_geometry.x * long_steepness_score;
	float mid_signal = mid_geometry.x * mid_steepness_score;
	return clamp(vec2(long_signal, mid_signal), vec2(0.0), vec2(1.0));
}

float open_break_at(vec2 world_xz) {
	vec2 components = open_break_components_at(world_xz);
	// Probabilistic/smooth union: either band can qualify and reinforcement is
	// monotonic, while the result remains in [0,1].
	return components.x + components.y - components.x * components.y;
}

// 4B: estado escalar local del modelo de energía de 4A, sin muestras de cresta.
// Devuelve vec4(amplitude_m, wavelength_m, local_k, local_hs).
// Réplica CPU: BreakerRibbonPool.estimate_local_hs / depth pressure.
vec4 breaking_local_state_at(vec2 world_xz, vec2 coast_uv, vec4 field_data) {
	float coastal_fraction = clamp(breaking_coastal_energy_fraction, 0.0, 1.0);
	float confidence = coastal_long_state(world_xz).z;
	float shoaling = mix(1.0, field_data.g, confidence);
	float local_hs = breaking_long_hs_m * sqrt(max(0.0, (1.0 - coastal_fraction) + coastal_fraction * shoaling * shoaling));
	float local_long_amplitude;
	float local_choppiness;
	breaking_zone_state(world_xz, local_long_amplitude, local_choppiness);
	local_hs *= local_long_amplitude;
	float amplitude = max(0.5 * local_hs, 0.01);
	float k_deep = max(coastal_k0_rad_m, 0.0001);
	float k_coastal = max(field_data.b, k_deep);
	float local_k = mix(k_deep, k_coastal, coastal_fraction * confidence);
	float wavelength = TAU / local_k;
	return vec4(amplitude, wavelength, local_k, local_hs);
}

vec4 depth_break_indices_at(vec2 world_xz, vec2 coast_uv, vec4 field_data, vec4 metrics_data, vec4 phase_data) {
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
	float local_long_amplitude;
	float local_choppiness;
	breaking_zone_state(world_xz, local_long_amplitude, local_choppiness);
	float depth_m = max(metrics_data.r, 0.001);
	float depth_ratio = local_hs / max(breaking_depth_gamma * depth_m, 0.001);
	float depth_pressure = smoothstep(breaking_depth_ratio_range.x, breaking_depth_ratio_range.y, depth_ratio);
	float steepness_pressure = smoothstep(breaking_steepness_range.x, breaking_steepness_range.y, local_k * amplitude * local_choppiness);

	// La cresta sí procede de las muestras dinámicas del FFT real LONG:
	// LONG_COASTAL warped + shoaled, más LONG_REMAINDER open. MID/SHORT no entran.
	vec2 propagation = phase_data.gb;
	if (dot(propagation, propagation) < 0.25) propagation = coastal_incoming_direction_xz;
	propagation = normalize(propagation);
	float eta_0 = long_height_at(world_xz);
	// Crestness MULTIESCALA: el LONG real es de banda ancha y una única escala
	// lambda/16 sólo capta crestas de ese ancho. Tres espaciados (lambda/16,
	// lambda/8, lambda/4) con el MISMO criterio; se toma el máximo.
	// Umbrales sin reescalar por escala: ya están normalizados por amplitude
	// (fracción de a_local) y en una sinusoidal la respuesta 1-cos(k*s) alcanza
	// el mismo rango [0.012, 0.075] en la cresta coincidente de cada escala.
	float crestness = 0.0;
	for (int scale = 0; scale < 3; scale++) {
		float spacing = clamp(wavelength / 16.0, breaking_crest_spacing_lambda_range_m.x, breaking_crest_spacing_lambda_range_m.y);
		if (scale == 1) {
			spacing = clamp(wavelength / 8.0, 0.5, 4.0);
		} else if (scale == 2) {
			spacing = clamp(wavelength / 4.0, 1.0, 8.0);
		}
		float eta_minus = long_height_at(world_xz - propagation * spacing);
		float eta_plus = long_height_at(world_xz + propagation * spacing);
		float neighbor_rise = min(eta_0 - eta_minus, eta_0 - eta_plus);
		float curvature_down = 2.0 * eta_0 - eta_minus - eta_plus;
		float crest_rise = smoothstep(0.012 * amplitude, 0.075 * amplitude, neighbor_rise);
		float crest_curve = smoothstep(0.025 * amplitude, 0.15 * amplitude, curvature_down);
		crestness = max(crestness, crest_rise * crest_curve);
	}

	// Sólo pre-break costero en 4A: steepness modula el potencial de profundidad,
	// pero no habilita whitecaps en mar profundo.
	float prebreak = crestness * depth_pressure * mix(0.35, 1.0, steepness_pressure)
		* breaking_zone_activity(world_xz);
	return vec4(depth_pressure, steepness_pressure, crestness, prebreak);
}

float depth_break_at(vec2 world_xz, vec2 coast_uv, vec4 field_data, vec4 metrics_data, vec4 phase_data) {
	return depth_break_indices_at(world_xz, coast_uv, field_data, metrics_data, phase_data).w;
}

// Legacy Phase 4A API retained for the existing PREBREAK debug and force-lip
// diagnostics. Its fourth component is now explicitly DEPTH_BREAK.
vec4 prebreak_indices_at(vec2 world_xz, vec2 coast_uv, vec4 field_data, vec4 metrics_data, vec4 phase_data) {
	return depth_break_indices_at(world_xz, coast_uv, field_data, metrics_data, phase_data);
}

// x = OPEN_BREAK, y = DEPTH_BREAK, z = BREAK_ONSET. DEPTH_BREAK is exactly
// zero without valid Coastal data; OPEN_BREAK never samples that validity gate.
vec3 breaking_onset_signals_at(vec2 world_xz) {
	vec2 uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
	vec4 metrics_data = textureLod(coastal_metrics_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
	vec4 phase_data = textureLod(coastal_phase_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
	float open_break = open_break_at(world_xz);
	float depth_break = depth_break_at(world_xz, uv, field_data, metrics_data, phase_data);
	float onset = open_break + depth_break - open_break * depth_break;
	return clamp(vec3(open_break, depth_break, onset), vec3(0.0), vec3(1.0));
}

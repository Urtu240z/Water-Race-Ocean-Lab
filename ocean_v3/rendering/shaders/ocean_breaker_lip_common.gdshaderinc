// Funciones del host del ribbon breaker_lip y su geometría específica.
// No se incluyen desde ocean_surface: el clipmap base mantiene su propia ruta.

// S5: misma composición de la geometría vertex de ocean_surface:
// LONG_COASTAL warped+shoaled, LONG_REMAINDER, MID/SHORT, sea-state zones y
// envelope final de shoreline. El perfil del breaker se añade después, sin
// volver a multiplicar su altura por el shore weight.
float breaker_render_confidence(vec2 uv, vec4 field_data) {
	if (!coastal_propagation_enabled || !coastal_transform_enabled) return 0.0;
	return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0)
		* clamp(field_data.a, 0.0, 1.0);
}

void breaker_sea_state_sdf(vec2 point, vec2 center, vec2 axis, vec2 half_extents,
		out float sdf, out vec2 sdf_gradient) {
	vec2 safe_axis = dot(axis, axis) > 0.000001 ? normalize(axis) : vec2(1.0, 0.0);
	vec2 tangent = vec2(-safe_axis.y, safe_axis.x);
	vec2 local_point = vec2(dot(point - center, safe_axis), dot(point - center, tangent));
	vec2 q = abs(local_point) - half_extents;
	vec2 outside = max(q, vec2(0.0));
	float outside_length = length(outside);
	sdf = outside_length + min(max(q.x, q.y), 0.0);
	vec2 gradient_local = vec2(0.0);
	if (outside_length > 0.000001) gradient_local = normalize(vec2(sign(local_point.x) * outside.x, sign(local_point.y) * outside.y));
	else if (q.x > q.y) gradient_local = vec2(sign(local_point.x), 0.0);
	else gradient_local = vec2(0.0, sign(local_point.y));
	sdf_gradient = safe_axis * gradient_local.x + tangent * gradient_local.y;
}

void breaker_sea_state_state(vec2 point, out float long_amplitude, out float mid_amplitude,
		out float short_amplitude, out float choppiness, out vec2 grad_long,
		out vec2 grad_mid, out vec2 grad_short, out vec2 grad_chop,
		out float foam_multiplier) {
	long_amplitude = 1.0; mid_amplitude = 1.0; short_amplitude = 1.0; choppiness = 1.0;
	grad_long = vec2(0.0); grad_mid = vec2(0.0); grad_short = vec2(0.0); grad_chop = vec2(0.0);
	foam_multiplier = 1.0;
	for (int index = 0; index < 8; index++) {
		if (index >= sea_state_zone_count) break;
		vec4 zone0 = sea_state_zone_data0[index];
		vec4 zone1 = sea_state_zone_data1[index];
		vec4 target = sea_state_zone_data2[index];
		float target_foam = sea_state_zone_data3[index].x;
		float sdf; vec2 sdf_gradient;
		breaker_sea_state_sdf(point, zone0.xy, zone0.zw, zone1.xy, sdf, sdf_gradient);
		float feather = max(zone1.z, 0.0);
		float local_weight = 0.0; vec2 grad_weight = vec2(0.0);
		if (feather <= 0.000001 || sdf <= 0.0) local_weight = 1.0;
		else if (sdf < feather) {
			float t = clamp(sdf / feather, 0.0, 1.0);
			local_weight = 1.0 - smoothstep(0.0, 1.0, t);
			grad_weight = sdf_gradient * (-6.0 * t * (1.0 - t) / feather);
		}
		float weight = clamp(local_weight * clamp(zone1.w, 0.0, 1.0), 0.0, 1.0);
		if (weight <= 0.0) continue;
		grad_weight *= clamp(zone1.w, 0.0, 1.0);
		float old_long = long_amplitude; float old_mid = mid_amplitude; float old_short = short_amplitude; float old_chop = choppiness; float old_foam = foam_multiplier;
		long_amplitude = mix(old_long, target.x, weight); mid_amplitude = mix(old_mid, target.y, weight);
		short_amplitude = mix(old_short, target.z, weight); choppiness = mix(old_chop, target.w, weight);
		foam_multiplier = mix(old_foam, clamp(target_foam, 0.0, 2.0), weight);
		grad_long = grad_long * (1.0 - weight) + (target.x - old_long) * grad_weight;
		grad_mid = grad_mid * (1.0 - weight) + (target.y - old_mid) * grad_weight;
		grad_short = grad_short * (1.0 - weight) + (target.z - old_short) * grad_weight;
		grad_chop = grad_chop * (1.0 - weight) + (target.w - old_chop) * grad_weight;
	}
}

vec3 breaker_sea_state_displacement(vec3 value, float amplitude, float choppiness) {
	value.y *= amplitude;
	value.xz *= amplitude * choppiness;
	return value;
}

void breaker_shore_weights(vec2 world_xz, vec4 metrics_data,
		out float vertical_weight, out float horizontal_weight, out vec2 vertical_gradient) {
	vertical_weight = 1.0;
	horizontal_weight = 1.0;
	vertical_gradient = vec2(0.0);
	if (!shore_stabilization_enabled || !coastal_propagation_enabled) return;
	vec2 uv = coastal_uv(world_xz);
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	float depth = max(metrics_data.r, 0.0);
	float presence = smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), depth);
	float v0 = smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), depth) * presence;
	float h0 = smoothstep(min(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), max(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), depth) * presence;
	vertical_weight = mix(1.0, v0, inside);
	horizontal_weight = mix(1.0, h0, inside);
	float step_m = max(coastal_cell_size_m, 0.25);
	vec4 mx = textureLod(coastal_metrics_texture, clamp(coastal_uv(world_xz - vec2(step_m, 0.0)), vec2(0.0), vec2(1.0)), 0.0);
	vec4 px = textureLod(coastal_metrics_texture, clamp(coastal_uv(world_xz + vec2(step_m, 0.0)), vec2(0.0), vec2(1.0)), 0.0);
	vec4 mz = textureLod(coastal_metrics_texture, clamp(coastal_uv(world_xz - vec2(0.0, step_m)), vec2(0.0), vec2(1.0)), 0.0);
	vec4 pz = textureLod(coastal_metrics_texture, clamp(coastal_uv(world_xz + vec2(0.0, step_m)), vec2(0.0), vec2(1.0)), 0.0);
	float v_mx = smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(mx.r, 0.0)) * smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), max(mx.r, 0.0));
	float v_px = smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(px.r, 0.0)) * smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), max(px.r, 0.0));
	float v_mz = smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(mz.r, 0.0)) * smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), max(mz.r, 0.0));
	float v_pz = smoothstep(min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), max(pz.r, 0.0));
	vertical_gradient = vec2((v_px - v_mx) / (2.0 * step_m), (v_pz - v_mz) / (2.0 * step_m)) * inside;
}

vec3 surface_displacement_break(vec2 world_xz, vec2 coast_uv, vec4 field_data, float distance_to_camera) {
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float render_confidence = breaker_render_confidence(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && render_confidence > 0.001;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z * render_confidence;
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
	float zone_long_amplitude;
	float zone_mid_amplitude;
	float zone_short_amplitude;
	float zone_choppiness;
	vec2 zone_grad_long;
	vec2 zone_grad_mid;
	vec2 zone_grad_short;
	vec2 zone_grad_chop;
	float zone_foam_multiplier;
	breaker_sea_state_state(world_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);
	long_coastal = breaker_sea_state_displacement(long_coastal, zone_long_amplitude, zone_choppiness);
	long_remainder = breaker_sea_state_displacement(long_remainder, zone_long_amplitude, zone_choppiness);
	mid_displacement = breaker_sea_state_displacement(mid_displacement, zone_mid_amplitude, zone_choppiness);
	short_displacement = breaker_sea_state_displacement(short_displacement, zone_short_amplitude, zone_choppiness);
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;
	vec3 displacement = long_coastal * coastal_weight * coastal_gain + long_remainder * remainder_weight;
	float short_geometry_weight = short_weight * short_geometry_strength;
	displacement += mid_displacement * mid_weight * mid_short_weight + short_displacement * short_geometry_weight * mid_short_weight;
	// Same crest sharpening as the OceanSurface vertex path, before the final
	// shoreline product rule.
	float swell_lambda = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0).g > 0.5 ? textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0).g : (TAU / max(coastal_k0_rad_m, 0.001));
	float eps = max(swell_lambda * 0.12, 1.5);
	vec2 sdir = normalize(coastal_incoming_direction_xz + vec2(0.0001, 0.0));
	float l_c = long_height_at(world_xz);
	float l_l = long_height_at(world_xz - sdir * eps);
	float l_r = long_height_at(world_xz + sdir * eps);
	float curv_long = l_l - 2.0 * l_c + l_r;
	float m_c = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).y;
	float m_l = textureLod(displacement_mid, spectrum_uv(world_xz - sdir * eps, domain_mid_m), 0.0).y;
	float m_r = textureLod(displacement_mid, spectrum_uv(world_xz + sdir * eps, domain_mid_m), 0.0).y;
	float curv_mid = m_l - 2.0 * m_c + m_r;
	float local_hs = max(breaking_long_hs_m, 0.05);
	float crest_long = clamp(-curv_long / local_hs, 0.0, 2.0) * ocean_crest_sharpen_long_weight;
	float crest_mid = clamp(-curv_mid / max(local_hs * 0.4, 0.02), 0.0, 2.0) * ocean_crest_sharpen_mid_weight;
	float crestness = crest_long + crest_mid;
	float face_slope = abs(l_r - l_l) / (2.0 * eps);
	float compression = smoothstep(0.03, 0.22, face_slope);
	float sharpen = smoothstep(ocean_crest_sharpen_threshold, ocean_crest_sharpen_threshold + 0.25, crestness) * compression * band_mask.x * ocean_crest_sharpen_strength;
	displacement.y += sharpen * ocean_crest_sharpen_max_gain * local_hs * zone_long_amplitude;
	displacement.xz *= 1.0 + sharpen * ocean_crest_sharpen_max_gain * 0.35 * zone_long_amplitude * zone_choppiness;
	float shore_vertical_weight;
	float shore_horizontal_weight;
	vec2 shore_vertical_gradient;
	breaker_shore_weights(world_xz, textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0), shore_vertical_weight, shore_horizontal_weight, shore_vertical_gradient);
	displacement.xz *= shore_horizontal_weight;
	displacement.y *= shore_vertical_weight;
	return displacement;
}

vec2 surface_slope_break(vec2 world_xz, vec2 coast_uv, vec4 field_data, float distance_to_camera) {
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float render_confidence = breaker_render_confidence(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && render_confidence > 0.001;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z * render_confidence;
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
	float zone_long_amplitude;
	float zone_mid_amplitude;
	float zone_short_amplitude;
	float zone_choppiness;
	vec2 zone_grad_long;
	vec2 zone_grad_mid;
	vec2 zone_grad_short;
	vec2 zone_grad_chop;
	float zone_foam_multiplier;
	breaker_sea_state_state(world_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);
	float long_coastal_height = mix(
		textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).y,
		textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).y,
		warp_confidence) * effective_shoaling;
	float long_remainder_height = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).y;
	float mid_height = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).y;
	float short_height = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).y;
	vec2 slope = (slope_coastal * zone_long_amplitude * effective_shoaling + long_coastal_height * zone_grad_long) * coastal_weight * coastal_gain;
	vec3 long_remainder_normal = normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb);
	slope += (slope_from_normal(long_remainder_normal) * zone_long_amplitude + long_remainder_height * zone_grad_long) * remainder_weight;
	slope += (slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb)) * zone_mid_amplitude + mid_height * zone_grad_mid) * mid_weight * mid_short_weight;
	slope += (slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb)) * zone_short_amplitude + short_height * zone_grad_short) * short_weight * mid_short_weight * short_vertex_normal_strength;
	float swell_lambda = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0).g > 0.5 ? textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0).g : (TAU / max(coastal_k0_rad_m, 0.001));
	float eps = max(swell_lambda * 0.12, 1.5);
	vec2 sdir = normalize(coastal_incoming_direction_xz + vec2(0.0001, 0.0));
	float l_c = long_height_at(world_xz);
	float l_l = long_height_at(world_xz - sdir * eps);
	float l_r = long_height_at(world_xz + sdir * eps);
	float curv_long = l_l - 2.0 * l_c + l_r;
	float m_c = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).y;
	float m_l = textureLod(displacement_mid, spectrum_uv(world_xz - sdir * eps, domain_mid_m), 0.0).y;
	float m_r = textureLod(displacement_mid, spectrum_uv(world_xz + sdir * eps, domain_mid_m), 0.0).y;
	float curv_mid = m_l - 2.0 * m_c + m_r;
	float local_hs = max(breaking_long_hs_m, 0.05);
	float crest_long = clamp(-curv_long / local_hs, 0.0, 2.0) * ocean_crest_sharpen_long_weight;
	float crest_mid = clamp(-curv_mid / max(local_hs * 0.4, 0.02), 0.0, 2.0) * ocean_crest_sharpen_mid_weight;
	float crestness = crest_long + crest_mid;
	float face_slope = abs(l_r - l_l) / (2.0 * eps);
	float compression = smoothstep(0.03, 0.22, face_slope);
	float sharpen = smoothstep(ocean_crest_sharpen_threshold, ocean_crest_sharpen_threshold + 0.25, crestness) * compression * band_mask.x * ocean_crest_sharpen_strength;
	slope *= 1.0 + sharpen * ocean_crest_sharpen_max_gain * 0.5;
	float shore_vertical_weight;
	float shore_horizontal_weight;
	vec2 shore_vertical_gradient;
	vec4 metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	breaker_shore_weights(world_xz, metrics, shore_vertical_weight, shore_horizontal_weight, shore_vertical_gradient);
	float shore_height = long_coastal_height * coastal_weight * coastal_gain + long_remainder_height * remainder_weight + mid_height * mid_weight * mid_short_weight + short_height * short_weight * mid_short_weight;
	shore_height += sharpen * ocean_crest_sharpen_max_gain * local_hs * zone_long_amplitude;
	slope = slope * shore_vertical_weight + shore_height * shore_vertical_gradient;
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

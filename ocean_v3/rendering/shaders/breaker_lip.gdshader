shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// ===== Phase 4B/4C: geometría local del labio (takeover + overturn/plunge) =====
// El ribetón (ribbon) es una tira de malla reutilizable anclada a un slot del
// pool (BreakerRibbonPool). TODO el cálculo vive aquí en GPU:
//   - el trigger es el campo PREBREAK de 4A (LONG_COASTAL + LONG_REMAINDER;
//     MID/SHORT jamás deciden el nacimiento);
//   - la superficie base se integra con el clipmap (mismas cascadas/fades);
//   - 4B: el labio levanta y adelanta según la envolvente de takeover;
//   - 4C: el frente vuelca (overturn) y la nariz baja (plunge);
//   - 4C-S1: FORCE_LIP usa la cross-section aprobada horneada en LUT.
// No hay readback GPU->CPU ni OceanQuery en esta ruta.

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
uniform bool module_enabled = true;
uniform bool coastal_propagation_enabled = false;
uniform bool coastal_transform_enabled = false;
uniform bool coastal_monochromatic_debug = false;
uniform bool coastal_warp_enabled = false;
uniform int coastal_composition_debug = 0;
uniform float coastal_debug_gain = 1.0;
uniform float breaking_long_hs_m = 0.50;
uniform float breaking_coastal_energy_fraction = 0.50;
uniform float breaking_depth_gamma = 0.78;
uniform vec2 breaking_depth_ratio_range = vec2(0.55, 1.0);
uniform vec2 breaking_steepness_range = vec2(0.28, 0.42);
uniform vec2 breaking_crest_spacing_lambda_range_m = vec2(0.25, 2.0);
uniform vec2 coastal_origin_xz = vec2(0.0);
uniform vec2 coastal_extent_m = vec2(1.0);
uniform vec2 coastal_incoming_direction_xz = vec2(1.0, 0.0);
uniform vec2 coastal_warp_origin_xz = vec2(0.0);
uniform vec2 coastal_warp_extent_m = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform float coastal_k0_rad_m = 0.392699;
// Parámetros propios del takeover 4B.
uniform float sea_level_y = 0.0;
uniform float breaker_lift_fraction = 0.55;
uniform float breaker_advance_fraction = 0.45;
uniform float breaker_lip_slope = 0.7;
// 4C: ángulo máximo de curl en producción (PREBREAK alto). FORCE_LIP usa ~115°.
uniform float breaker_curl_angle_deg = 90.0;
// 4C-S2: LUT de cross-section aprobada (horneada offline). R = x_norm ABSOLUTO,
// G = (y - y_stage0)/HEIGHT_REF, B = d(x_norm)/du, A = dG/du. Sólo FORCE_LIP.
uniform sampler2D breaker_profile_lut : repeat_disable, filter_linear;
uniform float breaker_profile_debug_stage = 1.0;
uniform float breaker_profile_height_hs = 2.0;
uniform float breaker_profile_length_scale = 0.65;
uniform float breaker_profile_forward_sign = -1.0;
uniform vec2 breaker_fade_range_m = vec2(6.0, 200.0);
// 0 LIP, 1 TAKEOVER, 2 REGION, 3 FORCE_LIP, 4 OFF.
uniform int breaker_debug_mode = 0;
// Apariencia de agua para LIP (idéntica a ocean_surface).
uniform vec3 base_color : source_color = vec3(0.18, 0.34, 0.44);
// Por instancia: cada slot del pool tiene su anchor, dirección, longitud y ancho.
instance uniform vec2 anchor_xz;
instance uniform vec2 direction_xz;
instance uniform float ribbon_id;
instance uniform float ribbon_wavelength_m;
instance uniform float ribbon_width_m;

varying float breaker_alpha;
varying float breaker_env;
varying float breaker_u;
varying float breaker_v;

// Detector GPU compartido (campo PREBREAK 4A + perfiles del labio 4B). Incluido
// después de los uniforms para que las funciones compartidas puedan referenciarlos.
#include "res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc"

vec3 breaker_heat(float value) {
	vec3 heat = mix(vec3(0.01, 0.03, 0.12), vec3(0.0, 0.80, 0.90), smoothstep(0.0, 0.45, value));
	heat = mix(heat, vec3(1.0, 0.86, 0.08), smoothstep(0.35, 0.72, value));
	heat = mix(heat, vec3(1.0, 0.06, 0.02), smoothstep(0.70, 1.0, value));
	return heat;
}

vec3 breaker_hsv2rgb(float h, float s, float v) {
	vec3 p = abs(fract(vec3(h) + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return v * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

vec3 breaker_region_color(float id, float u) {
	// Hue estable por slot; la nariz (u alta, hacia la costa) se marca en blanco
	// para leer la dirección de propagación de un vistazo.
	vec3 color = breaker_hsv2rgb(fract(id * 0.61803398875), 0.72, 1.0);
	if (u > 0.66) {
		color = mix(color, vec3(1.0, 1.0, 1.0), 0.85);
	}
	return color;
}

void vertex() {
	vec2 direction = normalize(direction_xz);
	vec2 tangent = vec2(-direction.y, direction.x);
	float u = UV.x;
	float v = UV.y;
	// Malla plantilla unitaria: u∈[0,1] -> -0.6λ..+0.5λ (profundo -> costa),
	// v∈[0,1] -> ancho centrado en el anchor. El labio (cresta) cae en u≈0.545.
	float u_world = mix(-0.6, 0.5, u) * ribbon_wavelength_m;
	float v_world = (v - 0.5) * ribbon_width_m;
	// 4C-S2: en FORCE_LIP la base FFT se samplea en la posición REST de la LUT
	// (stage 0), para que el stage 0 quede exactamente pegado al FFT.
	float profile_length = ribbon_wavelength_m * breaker_profile_length_scale;
	float source_start = -0.5 * profile_length;
	float source_end = 0.5 * profile_length;
	float s_rest = u_world;
	if (breaker_debug_mode == 3) {
		vec4 rest_profile = textureLod(breaker_profile_lut, vec2(u, 0.0), 0.0);
		float rest_x = breaker_profile_forward_sign > 0.0 ? rest_profile.r : 1.0 - rest_profile.r;
		s_rest = mix(source_start, source_end, rest_x);
	}
	vec2 P0 = anchor_xz + direction * s_rest + tangent * v_world;

	vec2 coast_uv = coastal_uv(P0);
	vec4 field_data = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	vec4 metrics_data = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	vec4 phase_data = textureLod(coastal_phase_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	float dist = distance(P0, camera_world_xz);

	// Trigger LONG-only: el MISMO campo PREBREAK de 4A evaluado en el vértice.
	vec4 indices = prebreak_indices_at(P0, coast_uv, field_data, metrics_data, phase_data);
	vec4 local_state = breaking_local_state_at(P0, coast_uv, field_data);
	float envelope = breaker_envelope(indices.w);
	float local_hs = local_state.w;
	// FORCE_LIP (debug): envelope fijado a 1 sólo para ver la geometría de
	// takeover; no modifica el campo PREBREAK ni es ruta de producción.
	if (breaker_debug_mode == 3) {
		envelope = 1.0;
	}

	// Superficie base: idéntica al clipmap (4 cascadas, warp, shoaling, fades,
	// composición y band_mask). Con envelope 0 el ribetón queda pegado a la ola
	// visible y su alpha cae a 0: no hay stain ni z-fighting.
	vec3 disp = surface_displacement_break(P0, coast_uv, field_data, dist);
	vec2 slope = surface_slope_break(P0, coast_uv, field_data, dist);

	// Modos: LIP/TAKEOVER (producción) = curl 4B/4C antiguo. FORCE_LIP (debug) =
	// cross-section LUT aprobada (x_norm absoluto). REGION = plana sin deformar.
	bool use_lut_profile = breaker_debug_mode == 3;
	bool deform_old = breaker_debug_mode == 0 || breaker_debug_mode == 1;

	// --- FORCE_LIP: target desde la LUT (x_norm absoluto + forward sign) ---
	float s_target = u_world;
	float y_profile = 0.0;
	float dx_norm_du = 0.0;
	float dGdu = 0.0;
	if (use_lut_profile) {
		vec4 profile = textureLod(breaker_profile_lut, vec2(u, clamp(breaker_profile_debug_stage, 0.0, 1.0)), 0.0);
		float target_x = breaker_profile_forward_sign > 0.0 ? profile.r : 1.0 - profile.r;
		s_target = mix(source_start, source_end, target_x);
		y_profile = profile.g * local_hs * breaker_profile_height_hs;
		dx_norm_du = profile.b;
		if (breaker_profile_forward_sign < 0.0) {
			dx_norm_du = -dx_norm_du;
		}
		dGdu = profile.a;
	}

	// --- Curl 4B/4C antiguo (LIP/TAKEOVER), sin cambios de producción ---
	float lift = 0.0;
	float advance = 0.0;
	float curl_angle = 0.0;
	if (deform_old) {
		lift = envelope * local_hs * breaker_lift_fraction * breaker_lift_profile(u);
		advance = envelope * local_hs * breaker_advance_fraction * breaker_advance_profile(u);
		float curl_env = smoothstep(0.25, 1.0, envelope);
		float curl_angle_max = curl_env * radians(breaker_curl_angle_deg);
		curl_angle = -curl_angle_max * breaker_curl_profile(u);
	}

	float u_world_h = mix(-0.6, 0.5, BREAKER_HINGE_U) * ribbon_wavelength_m;
	float lift_h = 0.0;
	float advance_h = 0.0;
	if (deform_old) {
		lift_h = envelope * local_hs * breaker_lift_fraction * breaker_lift_profile(BREAKER_HINGE_U);
		advance_h = envelope * local_hs * breaker_advance_fraction * breaker_advance_profile(BREAKER_HINGE_U);
	}
	float s0 = u_world + advance;
	float y0 = lift;
	float s_h = u_world_h + advance_h;
	float y_h = lift_h;
	float ds = s0 - s_h;
	float dy = y0 - y_h;
	float cos_a = cos(curl_angle);
	float sin_a = sin(curl_angle);
	float ds_rot = ds * cos_a - dy * sin_a;
	float dy_rot = ds * sin_a + dy * cos_a;
	float s_final_old = s_h + ds_rot;
	float y_final_old = y_h + dy_rot;

	float region_debug_offset = (breaker_debug_mode == 2) ? 0.15 : 0.0;

	vec3 world_pos;
	if (use_lut_profile) {
		world_pos = vec3(
			anchor_xz.x + direction.x * s_target + tangent.x * v_world + disp.x,
			sea_level_y + disp.y + y_profile,
			anchor_xz.y + direction.y * s_target + tangent.y * v_world + disp.z
		);
	} else if (deform_old) {
		world_pos = vec3(
			anchor_xz.x + direction.x * s_final_old + tangent.x * v_world + disp.x,
			sea_level_y + disp.y + y_final_old + region_debug_offset,
			anchor_xz.y + direction.y * s_final_old + tangent.y * v_world + disp.z
		);
	} else {
		// REGION: plantilla plana pegada a la superficie.
		world_pos = vec3(
			anchor_xz.x + direction.x * u_world + tangent.x * v_world + disp.x,
			sea_level_y + disp.y + region_debug_offset,
			anchor_xz.y + direction.y * u_world + tangent.y * v_world + disp.z
		);
	}

	vec3 normal_final;
	if (use_lut_profile) {
		// Normal del perfil LUT a partir de d(x_norm)/du y dG/du (permite overhang).
		float ds_du = profile_length * dx_norm_du;
		float dy_du = local_hs * breaker_profile_height_hs * dGdu;
		float slope_dir = dot(slope, direction);
		float slope_tan = dot(slope, tangent);
		vec3 tang_u = vec3(direction.x * ds_du, slope_dir * ds_du + dy_du, direction.y * ds_du);
		vec3 tang_v = vec3(tangent.x * ribbon_width_m, slope_tan * ribbon_width_m, tangent.y * ribbon_width_m);
		vec3 n = cross(tang_v, tang_u);
		if (dot(n, n) > 1.0e-8) {
			normal_final = normalize(n);
		} else {
			normal_final = normalize(vec3(-slope.x, 1.0, -slope.y));
		}
	} else if (deform_old) {
		float slope_profile = max(breaker_lift_profile(u), breaker_advance_profile(u));
		vec2 slope2 = slope + direction * (envelope * breaker_lip_slope * slope_profile);
		vec3 normal0 = normalize(vec3(-slope2.x, 1.0, -slope2.y));
		float n_d = dot(normal0.xz, direction);
		float n_t = dot(normal0.xz, tangent);
		float n_y = normal0.y;
		float n_d_r = n_d * cos_a - n_y * sin_a;
		float n_y_r = n_d * sin_a + n_y * cos_a;
		vec2 n_xz_r = direction * n_d_r + tangent * n_t;
		normal_final = normalize(vec3(n_xz_r.x, n_y_r, n_xz_r.y));
	} else {
		normal_final = normalize(vec3(-slope.x, 1.0, -slope.y));
	}

	VERTEX = world_pos;
	NORMAL = normal_final;

	// REGION (debug): siempre visible (independiente de PREBREAK/envelope) para
	// inspeccionar los slots; el resto conserva la envolvente de takeover.
	float alpha;
	if (breaker_debug_mode == 2) {
		alpha = breaker_edge_fade(u, v) * distance_fade(breaker_fade_range_m, dist) * 0.75;
	} else {
		alpha = envelope * breaker_edge_fade(u, v) * distance_fade(breaker_fade_range_m, dist);
	}
	if (coastal_monochromatic_debug || !module_enabled) {
		alpha = 0.0; // instrumento mono / módulo apagado: ningún breaker.
	}
	breaker_alpha = alpha;
	breaker_env = envelope;
	breaker_u = u;
	breaker_v = v;
}

void fragment() {
	float alpha = breaker_alpha;
	vec3 albedo = vec3(0.0);
	vec3 emission = vec3(0.0);
	float roughness = 0.3;
	float specular = 0.0;

	if (breaker_debug_mode == 0) {
		// LIP (producción): aspecto de agua equivalente al océano normal.
		// Iluminación real sobre la NORMAL ya calculada por el breaker.
		albedo = base_color;
		emission = vec3(0.0);
		roughness = 0.42;
		specular = 0.35;
	} else if (breaker_debug_mode == 1) {
		// TAKEOVER: heatmap por intensidad de takeover (emisivo).
		emission = breaker_heat(breaker_env);
	} else if (breaker_debug_mode == 2) {
		// REGION: color por slot + nariz blanca (dirección); emisivo.
		emission = breaker_region_color(ribbon_id, breaker_u);
	} else if (breaker_debug_mode == 3) {
		// FORCE_LIP: heat emisivo muy evidente.
		emission = breaker_heat(breaker_env);
	} else {
		alpha = 0.0; // OFF.
	}

	ALBEDO = albedo;
	EMISSION = emission;
	ALPHA = alpha * 0.92;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}

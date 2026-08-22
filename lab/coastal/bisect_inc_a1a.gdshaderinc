// ocean_breaking_common.gdshaderinc
// Funciones y uniforms COMPARTIDOS del detector GPU de pre-break (Phase 4A) y
// del takeover de geometrÃ­a local de breaker (Phase 4B).
//
// Este include se procesa al inicio de cada shader (Godot exige includes antes
// del resto del cÃ³digo) y declara aquÃ­ mismo los uniforms compartidos para que
// las funciones puedan referenciarlos: cada shader que lo incluya recibe su
// propia copia textual de estas declaraciones con los mismos nombres, y por
// tanto el mÃ³dulo puede fijarlos con set_shader_parameter de forma idÃ©ntica.
//
// Los shaders que incluyan este archivo NO deben redeclarar estos uniforms
// (darÃ­a un error de duplicado); sÃ³lo declaran sus uniforms propios.
//
// La ruta de detecciÃ³n samplea SOLO la macroestructura LONG real:
// LONG_COASTAL (warped/shoaled) + LONG_REMAINDER (open). MID/SHORT entran
// Ãºnicamente en surface_displacement_break/surface_slope_break (integraciÃ³n
// visual del ribetÃ³n con la superficie base), jamÃ¡s en el trigger.

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
// Phase 4A: Hs de LONG completo en deep water y fracciÃ³n de energÃ­a del split
// COASTAL (derivados de SeaStateConfig + H0 split; no son altura instantÃ¡nea),
// mÃ¡s los rangos configurables del detector.
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
// suave 0..1 en NEAR_CAUSTIC, 0 en invÃ¡lido/fuera/folded.
vec4 warp_deep_sample(vec2 world_xz) {
	vec2 uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	vec2 uv_clamped = clamp(uv, vec2(0.0), vec2(1.0));
	vec4 warp = textureLod(coastal_warp_texture, uv_clamped, 0.0);
	float det_j = warp.b;
	// Blend suave segÃºn el Jacobiano: SAFE -> 1, NEAR_CAUSTIC -> 0..1, folded -> 0.
	// warp.a (valid 0/1, interpolado en bordes por filter_linear) apaga el warp
	// fuera de la zona vÃ¡lida con fade natural (evita seams).
	float confidence = smoothstep(0.0, coastal_warp_detj_safe, det_j);
	confidence *= warp.a;
	// Fuera del rectÃ¡ngulo del warp: sin warp (confidence 0).
	confidence *= step(uv.x, 1.0) * step(uv.y, 1.0) * step(0.0, uv.x) * step(0.0, uv.y);
	return vec4(warp.xy, confidence, 0.0);
}

vec4 warp_jacobian_sample(vec2 world_xz) {
	vec2 uv = (world_xz - coastal_warp_origin_xz) / max(coastal_warp_extent_m, vec2(0.0001));
	return textureLod(coastal_warp_jacobian_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
}

// Estado costero mÃ­nimo para re-samplear LONG alrededor de una cresta. Mantiene
// exactamente la misma cadena visual: world -> deep (warp/confianza) + shoaling.

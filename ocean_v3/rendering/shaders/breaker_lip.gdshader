shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque, unshaded;

// ===== Phase 4B: geometría local del labio (takeover geométrico) =====
// El ribetón (ribbon) es una tira de malla reutilizable anclada a un slot del
// pool (BreakerRibbonPool). TODO el cálculo vive aquí en GPU:
//   - el trigger es el campo PREBREAK de 4A (LONG_COASTAL + LONG_REMAINDER;
//     MID/SHORT jamás deciden el nacimiento);
//   - la superficie base se integra con el clipmap (mismas cascadas/fades);
//   - el labio levanta y adelanta según la envolvente de takeover.
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
uniform vec2 breaker_fade_range_m = vec2(6.0, 200.0);
// 0 LIP, 1 TAKEOVER, 2 REGION, 3 OFF.
uniform int breaker_debug_mode = 0;
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
	vec2 P0 = anchor_xz + direction * u_world + tangent * v_world;

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

	// Superficie base: idéntica al clipmap (4 cascadas, warp, shoaling, fades,
	// composición y band_mask). Con envelope 0 el ribetón queda pegado a la ola
	// visible y su alpha cae a 0: no hay stain ni z-fighting.
	vec3 disp = surface_displacement_break(P0, coast_uv, field_data, dist);
	vec2 slope = surface_slope_break(P0, coast_uv, field_data, dist);

	// Takeover: levantar y ADELANTAR (desplazamiento horizontal, no sólo Y).
	float lift = envelope * local_hs * breaker_lift_fraction * breaker_lift_profile(u);
	float advance = envelope * local_hs * breaker_advance_fraction * breaker_advance_profile(u);

	vec3 world_pos = vec3(
		P0.x + disp.x + direction.x * advance,
		sea_level_y + disp.y + lift,
		P0.y + disp.z + direction.y * advance
	);
	// Inclinación del labio hacia la costa (frente más empinado/volcable).
	slope += direction * (envelope * breaker_lip_slope);

	VERTEX = world_pos;
	NORMAL = normalize(vec3(-slope.x, 1.0, -slope.y));

	float alpha = envelope * breaker_edge_fade(u, v) * distance_fade(breaker_fade_range_m, dist);
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
	vec3 color = vec3(0.02, 0.06, 0.12);
	if (breaker_debug_mode == 0) {
		// LIP: agua con la cresta del labio resaltada.
		color = mix(vec3(0.05, 0.14, 0.26), vec3(0.82, 0.95, 1.0), breaker_env * breaker_env);
	} else if (breaker_debug_mode == 1) {
		// TAKEOVER: calor por intensidad de takeover.
		color = breaker_heat(breaker_env);
	} else if (breaker_debug_mode == 2) {
		// REGION: color por slot + nariz blanca (dirección).
		color = breaker_region_color(ribbon_id, breaker_u);
	} else {
		alpha = 0.0; // OFF.
	}
	ALBEDO = vec3(0.0);
	EMISSION = color;
	ALPHA = alpha * 0.92;
	ROUGHNESS = 0.3;
	SPECULAR = 0.0;
}

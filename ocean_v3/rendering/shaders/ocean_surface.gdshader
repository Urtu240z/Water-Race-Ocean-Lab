shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long_coastal : repeat_enable, filter_linear;
uniform sampler2D displacement_long_remainder : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long_coastal : repeat_enable, filter_linear;
uniform sampler2D normal_long_remainder : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
// Dedicated persistent R16F foam fields. Production foam is sourced here;
// normal_map.a remains only for the OLD_RAW_FOAM_256 diagnostic.
uniform sampler2D foam_long_coastal : repeat_enable, filter_linear;
uniform sampler2D foam_long_remainder : repeat_enable, filter_linear;
uniform sampler2D foam_mid : repeat_enable, filter_linear;
uniform sampler2D foam_short : repeat_enable, filter_linear;
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
uniform vec3 base_color : source_color = vec3(0.018, 0.075, 0.095);
// 5R.1: debug de forma (silueta/crest/valle/choppiness). Neutro, sin foam/emission.
uniform bool ocean_shape_debug = false;
// 5R.1C: crest sharpening por compresión/convergencia (geometría, sin lip).
uniform float ocean_crest_sharpen_strength = 1.0;
uniform float ocean_crest_sharpen_threshold = 0.15;
uniform float ocean_crest_sharpen_max_gain = 0.30;
uniform float ocean_crest_sharpen_long_weight = 1.0;
uniform float ocean_crest_sharpen_mid_weight = 0.5;
uniform bool ocean_crest_sharpen_debug = false;
// 5R.2: normal shading per-fragment + material físico de agua.
uniform bool ocean_normal_fragment = false;   // A/B: FRAGMENT (true) vs VERTEX (false).
// 5R.3A: roughness adaptativa por distancia/footprint. Cerca ~near, lejos o
// subpixel ~far. Sin texturas nuevas; sólo operaciones escalares en fragment.
uniform float ocean_roughness_near = 0.055;
uniform float ocean_roughness_far = 0.23;
uniform vec2 ocean_roughness_distance_m = vec2(80.0, 220.0);

// 5R.3B: SHORT deja de dominar la malla. LONG+MID forman el cuerpo de ola;
// SHORT conserva una aportación física pequeña y su normal VERTEX queda fuera
// por defecto para no dibujar los anillos/cuadrados del clipmap.
uniform float short_geometry_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float short_vertex_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.0;

// 5R.3B: microdetalle dedicado estilo Water Race. Estas texturas NO desplazan
// geometría: sólo rompen reflejos y specular en fragment.
// Déjalo false hasta asignar las mismas tres texturas del material de Water Race.
uniform bool surface_detail_enabled = false;
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_normal_world_size_a : hint_range(0.25, 100.0, 0.05) = 7.5;
uniform float surface_normal_world_size_b : hint_range(0.25, 100.0, 0.05) = 3.25;
uniform float surface_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.62;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a : hint_range(-3.0, 3.0, 0.01) = 0.24;
uniform float surface_flow_speed_b : hint_range(-3.0, 3.0, 0.01) = -0.17;
uniform float surface_warp_world_size : hint_range(2.0, 300.0, 0.5) = 46.0;
uniform float surface_warp_strength : hint_range(0.0, 12.0, 0.05) = 2.4;
uniform float surface_detail_fade_start : hint_range(0.0, 2000.0, 1.0) = 180.0;
uniform float surface_detail_fade_end : hint_range(1.0, 4000.0, 1.0) = 800.0;
// El microdetalle no desaparece por completo en el horizonte: los mipmaps lo
// convierten en una rugosidad estable en vez de dejar el océano liso.
uniform float surface_detail_far_strength : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform int ocean_surface_detail_quality : hint_range(0, 2, 1) = 2;

// 5R.3C: óptica base trasladada del agua de Water Race.
// Screen/depth sólo afectan al material; no tocan FFT, query, coastal ni breakers.
uniform bool water_optics_enabled = true;
uniform bool water_refraction_enabled = true;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 shallow_water_color : source_color = vec4(0.035, 0.43, 0.55, 1.0);
uniform vec4 deep_water_color : source_color = vec4(0.004, 0.055, 0.115, 1.0);
uniform vec4 horizon_water_color : source_color = vec4(0.025, 0.22, 0.34, 1.0);
uniform vec4 reflection_tint : source_color = vec4(0.36, 0.70, 0.86, 1.0);
uniform vec4 trough_tint : source_color = vec4(0.002, 0.025, 0.075, 1.0);
uniform vec4 crest_tint : source_color = vec4(0.11, 0.62, 0.68, 1.0);
uniform float absorption_density : hint_range(0.01, 2.0, 0.01) = 0.13;
uniform float maximum_optical_depth : hint_range(1.0, 100.0, 0.5) = 38.0;
uniform float shallow_depth_range : hint_range(0.1, 20.0, 0.1) = 5.5;
uniform float near_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.77;
uniform float deep_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.92;
uniform float horizon_water_alpha : hint_range(0.8, 1.0, 0.01) = 0.98;
uniform float opacity_distance_start : hint_range(0.0, 500.0, 1.0) = 80.0;
uniform float opacity_distance_end : hint_range(1.0, 1000.0, 1.0) = 220.0;
uniform float fresnel_power : hint_range(0.5, 12.0, 0.1) = 4.8;
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 0.82;
uniform float refraction_strength : hint_range(0.0, 0.05, 0.0005) = 0.009;
uniform float water_specular : hint_range(0.0, 1.0, 0.01) = 0.88;

// Persistent high-resolution FFT whitecaps. The R16F fields are updated from
// spectral Jacobian compression after each FFT assemble; controls below are
// presentation-only and do not alter water optics.
uniform bool foam_enabled = true;
uniform vec4 foam_color : source_color = vec4(0.82, 0.91, 0.90, 1.0);
uniform float foam_intensity : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float foam_threshold : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float foam_contrast : hint_range(0.1, 4.0, 0.01) = 1.35;
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform float foam_alpha_boost : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float foam_distance_fade_start : hint_range(0.0, 4000.0, 1.0) = 180.0;
uniform float foam_distance_fade_end : hint_range(1.0, 5000.0, 1.0) = 900.0;
// Reconstruct the coarse persistent alpha smoothly near the camera. This is a
// presentation filter only: normal RGB and the stored physical foam stay intact.
uniform bool foam_filter_bicubic_enabled = true;
uniform float foam_filter_fade_start : hint_range(0.0, 1000.0, 1.0) = 72.0;
uniform float foam_filter_fade_end : hint_range(1.0, 2000.0, 1.0) = 224.0;
uniform float foam_breakup_strength : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float foam_breakup_world_size : hint_range(1.0, 200.0, 0.5) = 14.0;
// Zero keeps the breakup attached to ocean_base_xz instead of crawling.
uniform float foam_breakup_speed : hint_range(-2.0, 2.0, 0.01) = 0.0;
uniform float foam_edge_softness : hint_range(0.01, 0.49, 0.01) = 0.16;
uniform bool foam_breakup_texture_ready = false;
// 0 OFF, 1 OLD_RAW_FOAM_256, 2 SHAPED, 3 COMPRESSION, 4 SPECTRAL_JACOBIAN,
// 5 SOURCE, 6 FILTERED_OLD_RAW_256, 7 HIRES_RAW_FOAM, 8 FOAM_SOURCE_HIRES.
uniform int foam_debug_mode = 0;
// Diagnostic thresholds for LONG, MID and SHORT. They are supplied by the
// active SeaStateConfig; this is not part of the production foam signal.
uniform vec3 foam_debug_whitecap_by_band = vec3(0.5, 0.5, 0.5);
uniform vec3 foam_debug_cascade_weight_by_band = vec3(1.0, 0.35, 0.0);

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

varying vec3 derived_normal;
varying vec2 ocean_base_xz;
varying vec2 ocean_world_xz;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying vec4 coastal_phase_data;
varying float coastal_mono_phase;
varying float coastal_mono_active;
varying float coastal_warp_delta_m;
varying vec4 breaking_indices; // depth, steepness, crestness, final prebreak.
varying float crest_sharpen_mask; // 5R.1C: máscara de sharpening (debug).
varying float ocean_wave_height; // 5R.3C: altura visual final para tint de cresta/valle.

// Detector GPU de pre-break (4A) y funciones compartidas con el takeover 4B:
// spectrum_uv, distance_fade, slope_from_normal, coastal_uv, has_coastal_data,
// warp_deep_sample, warp_jacobian_sample, coastal_long_state, long_height_at,
// breaking_local_state_at y prebreak_indices_at.
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
	// The FFT maps are parameterized by this undisplaced, material coordinate.
	// It must be carried to fragment() separately from the final world position.
	ocean_base_xz = world_xz;
	coastal_mono_phase = 0.0;
	coastal_mono_active = 0.0;
	coastal_warp_delta_m = 0.0;
	breaking_indices = vec4(0.0);
	crest_sharpen_mask = 0.0;
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
	// SHORT geométrico secundario: conserva su fade físico/cámara original,
	// pero a amplitud reducida para que MID defina la ola visible.
	float short_geometry_weight = short_weight * short_geometry_strength;
	displacement += mid_displacement * mid_weight * mid_short_weight
		+ short_displacement * short_geometry_weight * mid_short_weight;

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
	// SHORT no debe grabar los anillos del clipmap en la normal VERTEX.
	slope += slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb))
		* short_weight * mid_short_weight * short_vertex_normal_strength;
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

	// 5R.1C: crest sharpening por compresión/convergencia (LONG + MID).
	// Afila crestas que surgen por suma/interferencia. Sólo geometría, sin lip.
	if (ocean_crest_sharpen_strength > 0.0 && module_enabled && !coastal_monochromatic_debug) {
		float swell_lambda = coastal_metrics.g > 0.5 ? coastal_metrics.g : (TAU / max(coastal_k0_rad_m, 0.001));
		float eps = max(swell_lambda * 0.12, 1.5);
		vec2 sdir = normalize(coastal_incoming_direction_xz + vec2(0.0001, 0.0));
		float l_c = long_height_at(world_xz);
		float l_l = long_height_at(world_xz - sdir * eps);
		float l_r = long_height_at(world_xz + sdir * eps);
		float curv_long = l_l - 2.0 * l_c + l_r; // negativo = cresta.
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
		float sharpen = smoothstep(ocean_crest_sharpen_threshold, ocean_crest_sharpen_threshold + 0.25, crestness)
			* compression * band_mask.x * ocean_crest_sharpen_strength; // 5R.1D: band_mask (world-space), no camera distance.
		float gain = ocean_crest_sharpen_max_gain;
		// Elevación vertical acotada + compresión horizontal suave (narrow crest).
		displacement.y += sharpen * gain * local_hs;
		displacement.xz *= 1.0 + sharpen * gain * 0.35;
		crest_sharpen_mask = sharpen;
	}

	ocean_wave_height = displacement.y;
	vec3 displaced_vertex = VERTEX + displacement;
	ocean_world_xz = (MODEL_MATRIX * vec4(displaced_vertex, 1.0)).xz;
	VERTEX = displaced_vertex;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
}


// 5R.2: normal FFT per-pixel (LONG/MID/SHORT compuestos en fragment) con
// filtering por pixel footprint. Replica la cadena de slope del vertex.
vec3 pixel_ocean_normal(vec2 world_xz) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);

	// 5R.2B: footprint del píxel en metros de mundo (referencia del filtro y del
	// fade terminal). Tamaño REAL de texel de MID/SHORT vía textureSize (sin
	// supuesto rígido /256). Fade terminal: la cascada desaparece cuando ya es
	// claramente subpixel (equivalente al fade previo, ahora con texel real).
	float footprint = max(fwidth(world_xz.x), fwidth(world_xz.y));
	float mid_texel_m = domain_mid_m / float(textureSize(normal_mid, 0).x);
	float short_texel_m = domain_short_m / float(textureSize(normal_short, 0).x);
	short_weight *= 1.0 - smoothstep(short_texel_m, short_texel_m * 2.0, footprint);
	mid_weight *= 1.0 - smoothstep(mid_texel_m, mid_texel_m * 2.0, footprint);

	vec2 coast_uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	float shoaling = field_data.g;

	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z;
	vec4 warp_jacobian = vec4(1.0, 0.0, 0.0, 1.0);
	if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_jacobian = warp_jacobian_sample(world_xz);
	}
	float effective_shoaling = 1.0;
	if (coast_transform_active) {
		if (coastal_warp_effect_debug == 2) effective_shoaling = shoaling;
		else if (coastal_warp_effect_debug == 0) effective_shoaling = mix(1.0, shoaling, warp_confidence);
	}

	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;

	vec3 long_coastal_normal_warped = normalize(textureLod(normal_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb);
	vec3 long_coastal_normal_open = normalize(textureLod(normal_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb);
	vec2 slope_open = slope_from_normal(long_coastal_normal_open);
	vec2 slope_deep = slope_from_normal(long_coastal_normal_warped);
	vec2 slope_warped_world = vec2(warp_jacobian.r * slope_deep.x + warp_jacobian.b * slope_deep.y, warp_jacobian.g * slope_deep.x + warp_jacobian.a * slope_deep.y);
	vec2 slope_coastal = mix(slope_open, slope_warped_world, warp_confidence);
	vec2 slope = slope_coastal * coastal_weight * effective_shoaling * coastal_gain;
	slope += slope_from_normal(normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb)) * remainder_weight;

	// 5R.2B: MID con filtro espacial progresivo 4-tap en SLOPE space (no promediar
	// normales). La muestra central siempre se hace; los 4 taps extra sólo cuando
	// el filtro está activo y la cascada todavía tiene peso efectivo visible.
	vec2 mid_center_slope = slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb));
	float mid_filter_amount = smoothstep(mid_texel_m * 0.5, mid_texel_m * 1.5, footprint);
	if (mid_filter_amount > 0.001 && mid_weight * mid_short_weight > 0.001) {
		float mid_half_extent = clamp(footprint * 0.5, mid_texel_m * 0.5, mid_texel_m);
		vec2 mid_filtered = (
			slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz + vec2(mid_half_extent, mid_half_extent), domain_mid_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz + vec2(mid_half_extent, -mid_half_extent), domain_mid_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz + vec2(-mid_half_extent, mid_half_extent), domain_mid_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz + vec2(-mid_half_extent, -mid_half_extent), domain_mid_m), 0.0).rgb))
		) * 0.25;
		mid_center_slope = mix(mid_center_slope, mid_filtered, mid_filter_amount);
	}
	slope += mid_center_slope * mid_weight * mid_short_weight;

	// 5R.2B: SHORT idéntico a MID con su propio texel size (microdetalle en
	// media distancia se funde suavemente en vez de tiritar como líneas).
	vec2 short_center_slope = slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb));
	float short_filter_amount = smoothstep(short_texel_m * 0.25, short_texel_m * 1.0, footprint);
	if (short_filter_amount > 0.001 && short_weight * mid_short_weight > 0.001) {
		float short_half_extent = clamp(footprint * 0.5, short_texel_m * 0.5, short_texel_m);
		vec2 short_filtered = (
			slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz + vec2(short_half_extent, short_half_extent), domain_short_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz + vec2(short_half_extent, -short_half_extent), domain_short_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz + vec2(-short_half_extent, short_half_extent), domain_short_m), 0.0).rgb))
			+ slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz + vec2(-short_half_extent, -short_half_extent), domain_short_m), 0.0).rgb))
		) * 0.25;
		short_center_slope = mix(short_center_slope, short_filtered, short_filter_amount);
	}
	slope += short_center_slope * short_weight * mid_short_weight;

	// 5R.2: la cresta afilada 5R.1C es más empinada que la normal FFT base.
	slope *= 1.0 + crest_sharpen_mask * ocean_crest_sharpen_max_gain * 0.5;

	return normalize(vec3(-slope.x, 1.0, -slope.y));
}


// Positive cubic B-spline weights. Unlike Catmull-Rom they cannot overshoot the
// [0, 1] persistent alpha field, avoiding ringing around whitecap edges.
vec4 foam_bspline_weights(float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(
		(1.0 - 3.0 * t + 3.0 * t2 - t3) / 6.0,
		(4.0 - 6.0 * t2 + 3.0 * t3) / 6.0,
		(1.0 + 3.0 * t + 3.0 * t2 - 3.0 * t3) / 6.0,
		t3 / 6.0
	);
}


// Four hardware-bilinear taps reconstruct a 4x4 cubic B-spline footprint.
// UVs are deliberately allowed outside [0, 1]; the sampler repeat mode keeps
// the FFT domain periodic without special edge branches.
float sample_foam_bicubic(sampler2D tex, vec2 uv) {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 texel_position = uv * size - 0.5;
	vec2 cell = floor(texel_position);
	vec2 fraction = fract(texel_position);
	vec4 weight_x = foam_bspline_weights(fraction.x);
	vec4 weight_y = foam_bspline_weights(fraction.y);
	vec2 pair_x = vec2(weight_x.x + weight_x.y, weight_x.z + weight_x.w);
	vec2 pair_y = vec2(weight_y.x + weight_y.y, weight_y.z + weight_y.w);
	vec2 sample_x = vec2(
		cell.x - 1.0 + weight_x.y / max(pair_x.x, 0.00001),
		cell.x + 1.0 + weight_x.w / max(pair_x.y, 0.00001)
	);
	vec2 sample_y = vec2(
		cell.y - 1.0 + weight_y.y / max(pair_y.x, 0.00001),
		cell.y + 1.0 + weight_y.w / max(pair_y.y, 0.00001)
	);
	float sample_00 = textureLod(tex, (vec2(sample_x.x, sample_y.x) + 0.5) / size, 0.0).a;
	float sample_10 = textureLod(tex, (vec2(sample_x.y, sample_y.x) + 0.5) / size, 0.0).a;
	float sample_01 = textureLod(tex, (vec2(sample_x.x, sample_y.y) + 0.5) / size, 0.0).a;
	float sample_11 = textureLod(tex, (vec2(sample_x.y, sample_y.y) + 0.5) / size, 0.0).a;
	return clamp(
		sample_00 * pair_x.x * pair_y.x
		+ sample_10 * pair_x.y * pair_y.x
		+ sample_01 * pair_x.x * pair_y.y
		+ sample_11 * pair_x.y * pair_y.y,
		0.0,
		1.0
	);
}


float foam_filter_amount(sampler2D tex, vec2 base_xz, float domain_size_m) {
	if (!foam_filter_bicubic_enabled) {
		return 1.0;
	}
	float distance_amount = smoothstep(
		foam_filter_fade_start,
		max(foam_filter_fade_end, foam_filter_fade_start + 0.001),
		distance(base_xz, camera_world_xz)
	);
	float texel_m = domain_size_m / float(textureSize(tex, 0).x);
	float footprint_m = max(fwidth(base_xz.x), fwidth(base_xz.y));
	float footprint_amount = smoothstep(texel_m * 0.55, texel_m * 1.25, footprint_m);
	return max(distance_amount, footprint_amount);
}


float sample_foam_filtered(sampler2D tex, vec2 uv, vec2 base_xz, float domain_size_m) {
	float filter_amount = foam_filter_amount(tex, base_xz, domain_size_m);
	if (filter_amount <= 0.001) {
		return sample_foam_bicubic(tex, uv);
	}
	float bilinear = textureLod(tex, uv, 0.0).a;
	if (filter_amount >= 0.999) {
		return bilinear;
	}
	float bicubic = sample_foam_bicubic(tex, uv);
	return mix(bicubic, bilinear, filter_amount);
}


// Legacy 256² alpha composition, retained for diagnostic A/B only. Production
// uses pixel_ocean_hires_foam() below.
// SHORT spatial weights as the FFT normal path. Surface Detail is deliberately
// absent: it is decorative normal detail, not a whitecap source.
// filtered=false is retained exclusively for the OLD_RAW_FOAM_256 A/B.
float pixel_ocean_legacy_foam(vec2 world_xz, bool filtered) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);

	vec2 coast_uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	float warp_confidence = warp_sample.z;
	vec2 deep_xz = warp_sample.xy;

	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;

	vec2 coastal_uv_open = spectrum_uv(world_xz, domain_long_coastal_m);
	vec2 coastal_uv_warped = spectrum_uv(deep_xz, domain_long_coastal_m);
	float coastal_foam_open = filtered
		? sample_foam_filtered(normal_long_coastal, coastal_uv_open, world_xz, domain_long_coastal_m)
		: textureLod(normal_long_coastal, coastal_uv_open, 0.0).a;
	float coastal_foam_warped = filtered
		? sample_foam_filtered(normal_long_coastal, coastal_uv_warped, world_xz, domain_long_coastal_m)
		: textureLod(normal_long_coastal, coastal_uv_warped, 0.0).a;
	float coastal_foam = mix(coastal_foam_open, coastal_foam_warped, warp_confidence) * coastal_gain;
	vec2 remainder_uv = spectrum_uv(world_xz, domain_long_remainder_m);
	vec2 mid_uv = spectrum_uv(world_xz, domain_mid_m);
	float remainder_foam = filtered
		? sample_foam_filtered(normal_long_remainder, remainder_uv, world_xz, domain_long_remainder_m)
		: textureLod(normal_long_remainder, remainder_uv, 0.0).a;
	float mid_foam = filtered
		? sample_foam_filtered(normal_mid, mid_uv, world_xz, domain_mid_m)
		: textureLod(normal_mid, mid_uv, 0.0).a;
	// SHORT has a much smaller physical foam weight and naturally finer texels;
	// retain the existing bilinear path there to keep the near-field cost bounded.
	float short_foam = textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).a;

	// The cascade weight is already applied when each GPU alpha is grown. Do
	// not normalize by the number/weight of cascades: foam contributions add.
	const float MID_FOAM_WEIGHT = 1.0;
	const float SHORT_FOAM_WEIGHT = 1.0;
	float combined = coastal_foam * coastal_weight + remainder_foam * remainder_weight;
	combined += mid_foam * mid_weight * mid_short_weight * MID_FOAM_WEIGHT;
	combined += short_foam * short_weight * mid_short_weight * SHORT_FOAM_WEIGHT;
	return clamp(combined, 0.0, 1.0);
}


// The high-resolution field is R16F, so fetch its red channel rather than the
// legacy normal-map alpha. This retains the positive B-spline reconstruction
// for presentation without making it the mechanism that fixes foam birth.
float sample_foam_field_bicubic(sampler2D tex, vec2 uv) {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 texel_position = uv * size - 0.5;
	vec2 cell = floor(texel_position);
	vec2 fraction = fract(texel_position);
	vec4 weight_x = foam_bspline_weights(fraction.x);
	vec4 weight_y = foam_bspline_weights(fraction.y);
	vec2 pair_x = vec2(weight_x.x + weight_x.y, weight_x.z + weight_x.w);
	vec2 pair_y = vec2(weight_y.x + weight_y.y, weight_y.z + weight_y.w);
	vec2 sample_x = vec2(
		cell.x - 1.0 + weight_x.y / max(pair_x.x, 0.00001),
		cell.x + 1.0 + weight_x.w / max(pair_x.y, 0.00001)
	);
	vec2 sample_y = vec2(
		cell.y - 1.0 + weight_y.y / max(pair_y.x, 0.00001),
		cell.y + 1.0 + weight_y.w / max(pair_y.y, 0.00001)
	);
	float sample_00 = textureLod(tex, (vec2(sample_x.x, sample_y.x) + 0.5) / size, 0.0).r;
	float sample_10 = textureLod(tex, (vec2(sample_x.y, sample_y.x) + 0.5) / size, 0.0).r;
	float sample_01 = textureLod(tex, (vec2(sample_x.x, sample_y.y) + 0.5) / size, 0.0).r;
	float sample_11 = textureLod(tex, (vec2(sample_x.y, sample_y.y) + 0.5) / size, 0.0).r;
	return clamp(
		sample_00 * pair_x.x * pair_y.x
		+ sample_10 * pair_x.y * pair_y.x
		+ sample_01 * pair_x.x * pair_y.y
		+ sample_11 * pair_x.y * pair_y.y,
		0.0,
		1.0
	);
}


float sample_foam_field_filtered(sampler2D tex, vec2 uv, vec2 base_xz, float domain_size_m) {
	float filter_amount = foam_filter_amount(tex, base_xz, domain_size_m);
	if (filter_amount <= 0.001) {
		return sample_foam_field_bicubic(tex, uv);
	}
	float bilinear = textureLod(tex, uv, 0.0).r;
	if (filter_amount >= 0.999) {
		return bilinear;
	}
	return mix(sample_foam_field_bicubic(tex, uv), bilinear, filter_amount);
}


// Production composition of the high-resolution persistent field. It mirrors
// the established coastal/open/deep coordinate policy, so coastal warp and
// LONG split behavior remain unchanged while the state resolution rises.
float pixel_ocean_hires_foam(vec2 world_xz) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);

	vec2 coast_uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_transform_active = coastal_transform_enabled && has_coastal_data(coast_uv, field_data);
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	float warp_confidence = warp_sample.z;
	vec2 deep_xz = warp_sample.xy;

	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float coastal_gain = coastal_composition_debug == 2 ? coastal_debug_gain : 1.0;

	float coastal_open = sample_foam_field_filtered(foam_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), world_xz, domain_long_coastal_m);
	float coastal_warped = sample_foam_field_filtered(foam_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), world_xz, domain_long_coastal_m);
	float coastal = mix(coastal_open, coastal_warped, warp_confidence) * coastal_gain;
	float remainder = sample_foam_field_filtered(foam_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), world_xz, domain_long_remainder_m);
	float mid = sample_foam_field_filtered(foam_mid, spectrum_uv(world_xz, domain_mid_m), world_xz, domain_mid_m);
	float short = sample_foam_field_filtered(foam_short, spectrum_uv(world_xz, domain_short_m), world_xz, domain_short_m);
	float combined = coastal * coastal_weight + remainder * remainder_weight;
	combined += mid * mid_weight * mid_short_weight;
	combined += short * short_weight * mid_short_weight;
	return clamp(combined, 0.0, 1.0);
}


float jacobian_from_displacement(sampler2D displacement_map, vec2 world_xz, float domain_size_m) {
	float texel_m = domain_size_m / float(textureSize(displacement_map, 0).x);
	vec2 dx = vec2(texel_m, 0.0);
	vec2 dz = vec2(0.0, texel_m);
	float inverse_two_dx = 0.5 / max(texel_m, 0.0001);
	vec3 left = textureLod(displacement_map, spectrum_uv(world_xz - dx, domain_size_m), 0.0).rgb;
	vec3 right = textureLod(displacement_map, spectrum_uv(world_xz + dx, domain_size_m), 0.0).rgb;
	vec3 down = textureLod(displacement_map, spectrum_uv(world_xz - dz, domain_size_m), 0.0).rgb;
	vec3 up = textureLod(displacement_map, spectrum_uv(world_xz + dz, domain_size_m), 0.0).rgb;
	float dXdx = (right.x - left.x) * inverse_two_dx;
	float dZdx = (right.z - left.z) * inverse_two_dx;
	float dXdz = (up.x - down.x) * inverse_two_dx;
	float dZdz = (up.z - down.z) * inverse_two_dx;
	return (1.0 + dXdx) * (1.0 + dZdz) - dZdx * dXdz;
}


// Diagnostic only: returns (weighted current source, low-J score). Foam
// production still comes exclusively from the persistent alpha channel.
vec2 pixel_ocean_compression_debug(vec2 world_xz) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	float long_physical_weight = foam_debug_cascade_weight_by_band.x;
	float mid_physical_weight = foam_debug_cascade_weight_by_band.y;
	float short_debug_weight = short_weight * mid_short_weight * foam_debug_cascade_weight_by_band.z;

	float long_coastal_j = jacobian_from_displacement(displacement_long_coastal, world_xz, domain_long_coastal_m);
	float long_remainder_j = jacobian_from_displacement(displacement_long_remainder, world_xz, domain_long_remainder_m);
	float mid_j = jacobian_from_displacement(displacement_mid, world_xz, domain_mid_m);
	float short_j = jacobian_from_displacement(displacement_short, world_xz, domain_short_m);

	float source = max(0.0, foam_debug_whitecap_by_band.x - long_coastal_j) * coastal_weight * long_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.x - long_remainder_j) * remainder_weight * long_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.y - mid_j) * mid_weight * mid_short_weight * mid_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.z - short_j) * short_debug_weight;

	// J≈1 maps to mid-gray; J below 1 becomes brighter, J above 1 darker.
	// min() avoids hiding a localized compressed cascade in this diagnostic.
	float diagnostic_j = 1.0;
	if (coastal_weight * long_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, long_coastal_j);
	if (remainder_weight * long_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, long_remainder_j);
	if (mid_weight * mid_short_weight * mid_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, mid_j);
	if (short_debug_weight > 0.001) diagnostic_j = min(diagnostic_j, short_j);
	float low_j_score = clamp(0.5 + (1.0 - diagnostic_j) * 2.0, 0.0, 1.0);
	return vec2(clamp(source, 0.0, 1.0), low_j_score);
}


// Exact production Jacobian read back from displacement_map.a. This is a
// GPU-only debug path: unlike COMPRESSION, it does not reconstruct derivatives.
vec2 pixel_ocean_spectral_debug(vec2 world_xz) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float coastal_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 2) ? long_weight : 0.0;
	float remainder_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 1 || coastal_composition_debug == 3) ? long_weight : 0.0;
	float mid_short_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;

	vec2 coast_uv = coastal_uv(world_xz);
	vec4 field_data = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_transform_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	float warp_confidence = warp_sample.z;
	vec2 deep_xz = warp_sample.xy;

	float coastal_j_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).a;
	float coastal_j_warped = textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).a;
	float coastal_j = mix(coastal_j_open, coastal_j_warped, warp_confidence);
	float remainder_j = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).a;
	float mid_j = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).a;
	float short_j = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).a;

	float long_physical_weight = foam_debug_cascade_weight_by_band.x;
	float mid_physical_weight = foam_debug_cascade_weight_by_band.y;
	float short_physical_weight = foam_debug_cascade_weight_by_band.z;
	float source = max(0.0, foam_debug_whitecap_by_band.x - coastal_j) * coastal_weight * long_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.x - remainder_j) * remainder_weight * long_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.y - mid_j) * mid_weight * mid_short_weight * mid_physical_weight;
	source += max(0.0, foam_debug_whitecap_by_band.z - short_j) * short_weight * mid_short_weight * short_physical_weight;

	float diagnostic_j = 1.0;
	if (coastal_weight * long_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, coastal_j);
	if (remainder_weight * long_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, remainder_j);
	if (mid_weight * mid_short_weight * mid_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, mid_j);
	if (short_weight * mid_short_weight * short_physical_weight > 0.001) diagnostic_j = min(diagnostic_j, short_j);
	return vec2(diagnostic_j, clamp(source, 0.0, 1.0));
}


// Presentation-only breakup. It multiplies an existing foam mask and therefore
// cannot create foam outside the physical persistent alpha field.
float foam_breakup_mask(vec2 base_xz) {
	if (foam_breakup_strength <= 0.001 || !foam_breakup_texture_ready) {
		return 1.0;
	}
	float world_size = max(foam_breakup_world_size, 0.001);
	vec2 flow = vec2(0.43, -0.91) * coastal_time_s * foam_breakup_speed / world_size;
	float breakup_noise = texture(surface_warp_texture, base_xz / world_size + flow).r;
	float softness = clamp(foam_edge_softness, 0.01, 0.49);
	// Keep a non-zero floor. This is a continuous modulation, not a binary cutout,
	// so small RAW changes cannot turn an entire foam cell on/off.
	float breakup = mix(0.25, 1.0, smoothstep(0.5 - softness, 0.5 + softness, breakup_noise));
	return mix(1.0, breakup, foam_breakup_strength);
}


vec2 surface_safe_direction(vec2 direction, vec2 fallback) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : fallback;
}


// 5R.3B: mismo concepto de micro-normal que Water Race.
// Devuelve normal local donde XY se interpreta como slope world XZ.
vec3 sample_surface_detail(vec2 world_xz, float camera_distance) {
	vec2 warp = vec2(0.0);
	if (ocean_surface_detail_quality >= 2) {
		vec2 warp_uv = world_xz / max(surface_warp_world_size, 0.001)
			+ vec2(0.31, -0.95) * coastal_time_s * 0.035;
		warp = (texture(surface_warp_texture, warp_uv).rg * 2.0 - 1.0)
			* surface_warp_strength;
	}

	vec2 uv_a = (world_xz + warp) / max(surface_normal_world_size_a, 0.001)
		+ surface_safe_direction(surface_flow_direction_a, vec2(1.0, 0.0))
			* coastal_time_s * surface_flow_speed_a
			/ max(surface_normal_world_size_a, 0.001);
	vec2 uv_b = (world_xz - warp * 0.57) / max(surface_normal_world_size_b, 0.001)
		+ surface_safe_direction(surface_flow_direction_b, vec2(0.0, 1.0))
			* coastal_time_s * surface_flow_speed_b
			/ max(surface_normal_world_size_b, 0.001);

	vec3 normal_a = texture(surface_normal_texture_a, uv_a).xyz * 2.0 - 1.0;
	vec3 combined = normalize(normal_a);
	if (ocean_surface_detail_quality >= 1) {
		vec3 normal_b = texture(surface_normal_texture_b, uv_b).xyz * 2.0 - 1.0;
		combined = normalize(vec3(
			normal_a.xy * 0.58 + normal_b.xy * 0.42,
			max(normal_a.z * 0.58 + normal_b.z * 0.42, 0.08)
		));
	}

	float detail_distance = 1.0 - smoothstep(
		surface_detail_fade_start,
		max(surface_detail_fade_end, surface_detail_fade_start + 0.001),
		camera_distance
	);
	float detail_fade = mix(
		surface_detail_far_strength,
		1.0,
		detail_distance
	);
	return vec3(combined.xy * detail_fade, combined.z);
}


float linear_depth_from_buffer(vec2 screen_uv, float raw_depth, mat4 inverse_projection) {
	vec4 view_position = inverse_projection * vec4(
		screen_uv * 2.0 - 1.0,
		raw_depth,
		1.0
	);
	return max(-view_position.z / view_position.w, 0.0);
}


void fragment() {
	vec3 color = base_color;
	float raw_foam = pixel_ocean_hires_foam(ocean_base_xz);
	float foam_mask = 0.0;
	vec2 compression_debug = vec2(0.0);
	vec2 spectral_debug = vec2(1.0, 0.0);
	if (foam_enabled) {
		float visual_threshold = clamp(foam_threshold, 0.0, 0.999);
		float thresholded_foam = smoothstep(visual_threshold, 1.0, raw_foam);
		// Smooth monotonic response: contrast changes curvature, while intensity
		// remains a post-shape multiplier and never shifts the effective threshold.
		float shaped_mask = pow(thresholded_foam, 1.0 / max(foam_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(
			foam_distance_fade_start,
			max(foam_distance_fade_end, foam_distance_fade_start + 0.001),
			distance(ocean_world_xz, camera_world_xz)
		);
		float breakup = foam_breakup_mask(ocean_base_xz);
		foam_mask = shaped_mask * breakup * clamp(foam_intensity, 0.0, 4.0) * distance_fade;
		foam_mask = clamp(foam_mask, 0.0, 1.0);
	}
	if (foam_debug_mode == 3) {
		compression_debug = pixel_ocean_compression_debug(ocean_base_xz);
	}
	if (foam_debug_mode == 4 || foam_debug_mode == 5) {
		spectral_debug = pixel_ocean_spectral_debug(ocean_base_xz);
	}
	if (foam_debug_mode == 8) {
		// Same bilinear J source evaluated by update_foam.glsl at its high-res
		// cell centers; diagnostic only, no extra persistent texture needed.
		spectral_debug = pixel_ocean_spectral_debug(ocean_base_xz);
	}
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
		float lines = max(periodic_grid(ocean_base_xz, domain_long_coastal_m), max(periodic_grid(ocean_base_xz, domain_mid_m), periodic_grid(ocean_base_xz, domain_short_m)));
		color = mix(color, vec3(1.0, 0.85, 0.15), lines);
	}
	if (ocean_crest_sharpen_debug) {
		// 5R.1C: azul = sin sharpening, rojo = sharpening máximo.
		color = mix(vec3(0.01, 0.04, 0.10), vec3(1.0, 0.18, 0.04), clamp(crest_sharpen_mask, 0.0, 1.0));
	}

	// 4C-S3.3: el takeover ya no descarta fragmentos del FFT. La ocultación se
	// resuelve en vertex() hundiendo verticalmente el océano bajo la seam S3.2.
	if (foam_debug_mode == 1) {
		color = vec3(pixel_ocean_legacy_foam(ocean_base_xz, false));
	} else if (foam_debug_mode == 2) {
		color = vec3(foam_mask);
	} else if (foam_debug_mode == 3) {
		// Gray = J≈1, white = low J, red = current foam source > 0.
		color = vec3(compression_debug.y);
		color = mix(color, vec3(1.0, 0.08, 0.02), smoothstep(0.0, 0.15, compression_debug.x));
	} else if (foam_debug_mode == 4) {
		// Exact spectral J stored by assemble_maps: J≈1 gray, compression white.
		color = vec3(clamp(0.5 + (1.0 - spectral_debug.x) * 2.0, 0.0, 1.0));
	} else if (foam_debug_mode == 5) {
		// Current source only: black when J >= whitecap.
		color = vec3(spectral_debug.y);
	} else if (foam_debug_mode == 6) {
		color = vec3(pixel_ocean_legacy_foam(ocean_base_xz, true));
	} else if (foam_debug_mode == 7) {
		color = vec3(raw_foam);
	} else if (foam_debug_mode == 8) {
		color = vec3(spectral_debug.y);
	}

	bool unlit = foam_debug_mode > 0 || debug_mode >= 2 || clipmap_lod_debug || periodicity_debug || coastal_debug_field > 0 || breaking_debug_mode > 0 || coastal_mono_active > 0.5 || coastal_delta_heatmap || ocean_crest_sharpen_debug;
	if (unlit) {
		ALBEDO = vec3(0.0);
		EMISSION = color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (ocean_shape_debug) {
		// 5R.1: vista neutra de silueta/crest/valle/choppiness. Sin foam ni emission.
		ALBEDO = vec3(0.52, 0.56, 0.60);
		EMISSION = vec3(0.0);
		ROUGHNESS = 0.7;
		SPECULAR = 0.2;
		ALPHA = 1.0;
	} else {
		// 5R.3B/3C: VERTEX es la base de producción. FRAGMENT completo queda
		// únicamente como A/B con G. El detalle fino SIEMPRE se añade después
		// mediante normal maps por fragment, de modo que haya riqueza cerca y
		// también a distancia sin marcar la cuadrícula del clipmap.
		vec3 shading_normal_world;
		if (ocean_normal_fragment) {
			shading_normal_world = pixel_ocean_normal(ocean_base_xz);
		} else {
			shading_normal_world = normalize(derived_normal);
		}

		vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
		float camera_distance = distance(ocean_world_xz, camera_world_xz);

		// Dos normal maps + warp: detalle fino sin añadir geometría ni marcar
		// los cuadrados del clipmap.
		if (surface_detail_enabled) {
			vec3 detail_normal = sample_surface_detail(ocean_world_xz, camera_distance);
			vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
			vec3 detail_offset_view = mat3(VIEW_MATRIX) * vec3(
				detail_slope.x,
				0.0,
				detail_slope.y
			);
			visual_normal = normalize(
				visual_normal + detail_offset_view * surface_normal_strength
			);
		}
		NORMAL = visual_normal;

		if (water_optics_enabled) {
			// 5R.3C: profundidad óptica real desde el depth buffer.
			float scene_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
			bool scene_is_sky = scene_raw_depth <= 0.000001;
			float scene_linear_depth = linear_depth_from_buffer(
				SCREEN_UV,
				scene_raw_depth,
				INV_PROJECTION_MATRIX
			);
			float water_linear_depth = linear_depth_from_buffer(
				SCREEN_UV,
				FRAGCOORD.z,
				INV_PROJECTION_MATRIX
			);
			float water_thickness = scene_is_sky
				? maximum_optical_depth
				: clamp(
					scene_linear_depth - water_linear_depth,
					0.0,
					maximum_optical_depth
				);

			float absorption = 1.0 - exp(-water_thickness * absorption_density);
			float depth_factor = clamp(
				water_thickness / max(shallow_depth_range, 0.001),
				0.0,
				1.0
			);
			float water_density = max(absorption, depth_factor * 0.48);

			// Tinte suave por altura: valle profundo / cresta algo más transmisiva.
			float height_scale = max(breaking_long_hs_m * 2.0, 0.25);
			float height_position = clamp(
				0.5 + ocean_wave_height / height_scale,
				0.0,
				1.0
			);
			height_position = height_position * height_position
				* (3.0 - 2.0 * height_position);

			vec3 body_color = mix(
				shallow_water_color.rgb,
				deep_water_color.rgb,
				water_density
			);
			body_color = mix(
				body_color,
				mix(trough_tint.rgb, crest_tint.rgb, height_position),
				0.24
			);

			vec3 view_direction = normalize(VIEW);
			float facing = clamp(dot(visual_normal, view_direction), 0.0, 1.0);
			float fresnel = pow(1.0 - facing, fresnel_power);
			float distance_opacity = smoothstep(
				opacity_distance_start,
				max(opacity_distance_end, opacity_distance_start + 0.001),
				camera_distance
			);
			float reflection_factor = clamp(
				fresnel * reflection_strength + distance_opacity * 0.30,
				0.0,
				1.0
			);

			vec3 surface_color = mix(
				body_color,
				horizon_water_color.rgb,
				reflection_factor
			);
			surface_color = mix(
				surface_color,
				reflection_tint.rgb,
				reflection_factor * 0.19
			);

			// Refracción screen-space ligera. Se puede apagar de forma aislada
			// con water_refraction_enabled si causa cualquier artefacto.
			vec3 transmitted_scene = body_color;
			if (water_refraction_enabled) {
				vec2 refraction_offset = visual_normal.xy
					* refraction_strength
					* (1.0 - fresnel)
					* (1.0 - distance_opacity);
				vec2 refracted_uv = clamp(
					SCREEN_UV + refraction_offset,
					vec2(0.001),
					vec2(0.999)
				);
				vec3 refracted_scene = textureLod(
					screen_texture,
					refracted_uv,
					0.0
				).rgb;
				transmitted_scene = refracted_scene * mix(
					vec3(1.0),
					shallow_water_color.rgb,
					absorption * 0.30
				);
			}

			float body_mix = clamp(
				water_density + max(fresnel, distance_opacity) * 0.72,
				0.0,
				1.0
			);
			vec3 final_color = mix(transmitted_scene, surface_color, body_mix);

			float local_alpha = mix(
				near_water_alpha,
				deep_water_alpha,
				water_density
			);
			float final_alpha = clamp(
				mix(
					local_alpha,
					horizon_water_alpha,
					max(distance_opacity, fresnel)
				),
				0.55,
				1.0
			);

			final_color = mix(final_color, foam_color.rgb, foam_mask);
			ALBEDO = final_color;
			EMISSION = vec3(0.0);
			ROUGHNESS = mix(
				ocean_roughness_near,
				ocean_roughness_far,
				max(distance_opacity, fresnel)
			);
			ROUGHNESS = mix(ROUGHNESS, foam_roughness, foam_mask);
			SPECULAR = water_specular;
			METALLIC = 0.0;
			ALPHA = clamp(final_alpha + foam_mask * foam_alpha_boost, 0.0, 1.0);
		} else {
			// Fallback de debug: material simple sin screen/depth.
			ALBEDO = mix(base_color, foam_color.rgb, foam_mask);
			EMISSION = vec3(0.0);
			float distance_factor = smoothstep(
				ocean_roughness_distance_m.x,
				ocean_roughness_distance_m.y,
				camera_distance
			);
			ROUGHNESS = mix(
				ocean_roughness_near,
				ocean_roughness_far,
				distance_factor
			);
			ROUGHNESS = mix(ROUGHNESS, foam_roughness, foam_mask);
			SPECULAR = water_specular;
			METALLIC = 0.0;
			ALPHA = clamp(1.0 + foam_mask * foam_alpha_boost, 0.0, 1.0);
		}
	}
}

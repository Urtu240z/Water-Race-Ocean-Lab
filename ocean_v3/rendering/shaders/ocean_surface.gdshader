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
// Dedicated persistent RG16F foam fields: R=residual/history, G=fresh crest.
uniform sampler2D foam_long_coastal : repeat_enable, filter_linear;
uniform sampler2D foam_long_remainder : repeat_enable, filter_linear;
uniform sampler2D foam_mid : repeat_enable, filter_linear;
uniform sampler2D foam_short : repeat_enable, filter_linear;
uniform sampler2D surface_foam_short : repeat_enable, filter_linear;
uniform sampler2D surface_foam_jacobian : repeat_enable, filter_linear;
uniform sampler2D surface_foam_topology : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_foam_mid_fold_history : repeat_enable, filter_linear;
// Packed RGB tile: R=organic breakup, G=bubble distance-like field,
// B=microheight for the derived foam normal.
uniform sampler2D surface_foam_micro_texture : repeat_enable, filter_linear_mipmap;
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
// Local sea-state zones: data0=center.xy, axis.xz; data1=half-size.xy,
// feather, strength; data2=absolute LONG/MID/SHORT/choppiness targets.
uniform int sea_state_zone_count = 0;
uniform vec4 sea_state_zone_data0[8];
uniform vec4 sea_state_zone_data1[8];
uniform vec4 sea_state_zone_data2[8];
// data3.x = local Crest/Surface foam birth and presentation multiplier.
uniform vec4 sea_state_zone_data3[8];
uniform bool sea_state_zone_debug = false;
uniform int debug_mode = 0;
uniform bool module_enabled = true;
uniform bool perf_spectral_enabled = true;
uniform bool perf_crest_foam_solver_enabled = true;
uniform bool perf_surface_foam_solver_enabled = true;
uniform bool perf_mid_fold_history_enabled = true;
uniform bool perf_surface_foam_render_enabled = true;
uniform bool perf_prebreak_enabled = true;
uniform bool clipmap_lod_debug = false;
// X2.1 seam diagnosis only. These are opt-in and do not alter topology,
// transforms, LOD variants, or production shading when disabled.
uniform bool clipmap_flat_geometry_debug = false;
uniform bool clipmap_displaced_unlit_debug = false;
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
// Near-shore base geometry stabilization. These values are metres of baked
// depth, not propagation thresholds. The envelope is world anchored and is
// intentionally independent from warp confidence and clipmap distance.
uniform bool shore_stabilization_enabled = true;
uniform vec2 shore_vertical_depth_range_m = vec2(0.25, 6.0);
uniform vec2 shore_horizontal_depth_range_m = vec2(0.75, 12.0);
uniform float coastal_min_valid_depth_m = 0.25;
uniform float coastal_cell_size_m = 1.0;
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
uniform float surface_detail_wave_follow : hint_range(0.0, 1.0, 0.01) = 0.70;
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
uniform vec4 trough_tint : source_color = vec4(0.002, 0.025, 0.075, 1.0);
uniform vec4 crest_tint : source_color = vec4(0.11, 0.62, 0.68, 1.0);
// Legacy scalar retained for material/resource compatibility. Production
// water optics use absorption_coeff_rgb.
uniform float absorption_density : hint_range(0.01, 2.0, 0.01) = 0.13;
uniform vec3 absorption_coeff_rgb = vec3(0.35, 0.12, 0.055);
uniform float maximum_optical_depth : hint_range(1.0, 100.0, 0.5) = 38.0;
uniform float water_body_depth_start_m : hint_range(0.0, 20.0, 0.1) = 0.5;
uniform float water_body_depth_end_m : hint_range(0.1, 50.0, 0.1) = 8.0;
// Deprecated compatibility uniform. Legacy only. No production effect.
uniform float shallow_depth_range : hint_range(0.1, 20.0, 0.1) = 5.5;
uniform float near_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.77;
uniform float deep_water_alpha : hint_range(0.5, 1.0, 0.01) = 0.92;
uniform float alpha_depth_fade_start_m : hint_range(0.0, 50.0, 0.1) = 0.5;
uniform float alpha_depth_fade_end_m : hint_range(0.1, 100.0, 0.1) = 12.0;
uniform float horizon_water_alpha : hint_range(0.8, 1.0, 0.01) = 0.98;
uniform float opacity_distance_start : hint_range(0.0, 500.0, 1.0) = 80.0;
uniform float opacity_distance_end : hint_range(1.0, 1000.0, 1.0) = 220.0;
uniform float refraction_strength : hint_range(0.0, 0.05, 0.0005) = 0.009;
uniform float refraction_micro_normal_strength : hint_range(0.0, 0.5, 0.01) = 0.15;
uniform float refraction_max_offset_px : hint_range(0.0, 64.0, 1.0) = 24.0;
uniform float refraction_depth_tolerance_m : hint_range(0.0, 2.0, 0.01) = 0.35;
// R3 body polish. These controls add bounded single-pass water-column
// scattering without changing the R1 Beer-Lambert terms or the R2 ray path.
uniform vec4 scattering_color : source_color = vec4(0.02, 0.32, 0.42, 1.0);
uniform float scattering_strength : hint_range(0.0, 2.0, 0.01) = 0.45;
uniform float scattering_shallow_tint_influence : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float scattering_deep_tint_influence : hint_range(0.0, 1.0, 0.01) = 0.15;
uniform float shallow_scattering_strength : hint_range(0.0, 2.0, 0.01) = 0.5;
uniform float shallow_scattering_depth_start_m : hint_range(0.0, 20.0, 0.1) = 1.0;
uniform float shallow_scattering_depth_end_m : hint_range(0.1, 30.0, 0.1) = 8.0;
uniform float water_turbidity : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float crest_transmission_boost : hint_range(0.0, 0.5, 0.01) = 0.12;
uniform float trough_density_boost : hint_range(0.0, 0.5, 0.01) = 0.10;
uniform float transmission_detail_fade_start_m : hint_range(0.0, 100.0, 0.5) = 10.0;
uniform float transmission_detail_fade_end_m : hint_range(1.0, 150.0, 0.5) = 30.0;
uniform float transmission_max_lod : hint_range(0.0, 8.0, 0.1) = 5.0;
// Seabed transmission continuity: global bottom contribution fades by local
// bathymetric depth only after the original scene sample matches that seabed.
uniform float bottom_visibility_fade_start_m : hint_range(0.0, 50.0, 0.5) = 8.0;
uniform float bottom_visibility_fade_end_m : hint_range(0.1, 100.0, 0.5) = 20.0;
uniform float seabed_match_tolerance_start_m : hint_range(0.0, 20.0, 0.25) = 1.0;
uniform float seabed_match_tolerance_end_m : hint_range(0.1, 50.0, 0.25) = 4.0;
uniform float coastal_bathymetry_sea_level_y = 0.0;
// 0 OFF, 1 WATER_THICKNESS, 2 TRANSMITTANCE_RGB, 3 WATER_BODY_COLOR,
// 4 REFRACTION_OFFSET, 5 REFRACTION_VALIDITY, 6 SCATTERING,
// 7 WATER_BODY_FINAL, 8 TRANSMISSION_DETAIL_FADE, 9 BODY_DEPTH_FACTOR,
// 10 ALPHA_DEPTH_FACTOR, 11 SHALLOW_SCATTERING_FACTOR,
// 12 SCATTERING_TINT_INFLUENCE, 13 SHALLOW_SCATTERING_FINAL,
// 14 LOCAL_WATER_DEPTH, 15 VIEW_WATER_PATH, 16 SHALLOW_DEEP_AUTHORITY,
// 17 RAW_BATHYMETRY_FRAGMENT, 18 BATHYMETRY_DOMAIN,
// 19 COASTAL_PROPAGATION_VALIDITY, 20 RAW_SCENE_DEPTH, 21 SCENE_DEPTH_CLASS,
// 22 RAW_WATER_FRAGMENT_DEPTH, 23 BATHYMETRY_COMPARE_VERTEX_FRAGMENT,
// 24 DEBUG_SENTINEL_MAGENTA, 25 DEBUG_SENTINEL_GREEN, 26 SEABED_MATCH,
// 27 BOTTOM_DEPTH_VISIBILITY, 28 BOTTOM_TRANSMISSION_WEIGHT,
// 29 SEABED_HEIGHT_ERROR.
uniform int water_optics_debug_mode = 0;

// Physical Reflection Phase 1. Godot's shaded spatial pipeline consumes the
// final NORMAL, ROUGHNESS and SPECULAR to provide environment radiance and
// direct-light specular. SSPR and the optional near-field SSR replace part of
// environment radiance through RADIANCE; neither adds a second lighting lobe.
uniform float reflection_min_roughness : hint_range(0.0, 1.0, 0.005) = 0.035;
uniform float reflection_base_roughness : hint_range(0.0, 1.0, 0.005) = 0.055;
uniform float reflection_distance_roughness : hint_range(0.0, 1.0, 0.005) = 0.23;
uniform float reflection_detail_roughness_gain : hint_range(0.0, 1.0, 0.005) = 0.10;
uniform float reflection_distance_roughness_gain : hint_range(0.0, 1.0, 0.005) = 1.0;
uniform float reflection_pixel_footprint_gain : hint_range(0.0, 1.0, 0.005) = 1.0;
uniform float reflection_slope_variance_gain : hint_range(0.0, 1.0, 0.005) = 0.35;
uniform vec2 reflection_roughness_distance_m = vec2(80.0, 220.0);
uniform vec3 reflection_sun_direction_world = vec3(0.0, 0.0, 1.0);
// Reflection Phase 1C: local roughness shaping over existing LONG/MID crest
// curvature. The mask only concentrates the existing PBR lobe; it adds no
// emission, color boost, lighting model, texture, or physical wave energy.
uniform bool reflection_crest_specular_enabled = true;
uniform float reflection_crest_roughness_gain : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform float reflection_crest_mask_gain : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float reflection_crest_min_roughness_scale : hint_range(0.45, 1.0, 0.01) = 0.60;
uniform bool reflection_sspr_enabled = true;
uniform bool reflection_sspr_available = false;
uniform sampler2D reflection_sspr_texture : repeat_disable, filter_linear;
uniform bool reflection_sspr_raw_available = false;
uniform sampler2D reflection_sspr_raw_texture : repeat_disable, filter_linear;
uniform bool reflection_sspr_temporal_available = false;
uniform sampler2D reflection_sspr_temporal_texture : repeat_disable, filter_linear;
uniform float reflection_sspr_distortion_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float reflection_sspr_edge_fade : hint_range(0.0, 0.25, 0.005) = 0.08;
uniform float reflection_sspr_slope_fade : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform bool reflection_sspr_hole_fill_enabled = true;
uniform bool reflection_sspr_depth_available = false;
uniform sampler2D reflection_sspr_depth_texture : repeat_disable, filter_nearest;
uniform float reflection_sspr_sea_level = 0.0;
uniform bool reflection_sspr_facet_gate_enabled = true;
uniform float reflection_sspr_facet_gate_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform bool reflection_distance_blur_enabled = true;
uniform float reflection_distance_blur_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float reflection_distance_blur_reference_m : hint_range(1.0, 500.0, 1.0) = 50.0;
uniform bool reflection_near_ssr_enabled = true;
uniform float reflection_near_ssr_distance_m : hint_range(1.0, 100.0, 1.0) = 35.0;
uniform float reflection_near_ssr_ray_length_m : hint_range(25.0, 500.0, 1.0) = 200.0;
uniform float reflection_near_ssr_fade_m : hint_range(0.0, 50.0, 0.5) = 10.0;
uniform float reflection_near_ssr_thickness : hint_range(0.01, 2.0, 0.01) = 0.35;
uniform int reflection_near_ssr_quality = 1;
uniform float reflection_radiance_exposure_ev : hint_range(-2.0, 2.0, 0.05) = 0.0;
uniform float reflection_radiance_contrast : hint_range(0.5, 2.0, 0.01) = 1.0;
uniform float reflection_radiance_saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform vec4 reflection_radiance_tint : source_color = vec4(1.0);
uniform float reflection_screen_space_weight : hint_range(0.0, 1.5, 0.01) = 1.0;
uniform float reflection_environment_specular_boost : hint_range(0.5, 2.0, 0.01) = 1.0;
// 0 OFF, 1 FRESNEL, 2 SKY, 3 SUN_SPECULAR, 4 ROUGHNESS, 5 NORMAL,
// 6 SLOPE_VARIANCE, 7 SSPR_RAW, 8 SSPR_VALIDITY, 9 SSPR_DISTORTED,
// 10 SSPR_CONFIDENCE, 11 SSPR_TEMPORAL, 12 SSPR_PREFILTERED,
// 13 NEAR_SSR_ACTIVE, 14 NEAR_SSR_HIT, 15 NEAR_SSR_CONFIDENCE,
// 16 NEAR_SSR_COLOR, 17 NEAR_SSR_DEPTH_CONFIDENCE,
// 18 NEAR_SSR_DEVIATION_CONFIDENCE, 19 NEAR_SSR_BASE_CONFIDENCE,
// 20 NEAR_SSR_STEP_USAGE, 21 SSPR_FACET_CONFIDENCE.
uniform int reflection_debug_mode = 0;

// Persistent high-resolution FFT whitecaps. The RG16F fields are updated from
// spectral Jacobian compression after each FFT assemble; controls below are
// presentation-only and do not alter water optics.
uniform bool foam_enabled = true;
uniform vec4 foam_color : source_color = vec4(0.82, 0.91, 0.90, 1.0);
uniform vec4 foam_fresh_color : source_color = vec4(0.97, 0.99, 0.98, 1.0);
uniform vec4 foam_residual_color : source_color = vec4(0.82, 0.91, 0.90, 1.0);
uniform float foam_intensity : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float foam_fresh_strength : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float foam_residual_strength : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float foam_normal_strength : hint_range(0.0, 10.0, 0.01) = 1.2;
uniform float foam_fresh_normal_weight : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float foam_residual_normal_weight : hint_range(0.0, 2.0, 0.01) = 0.40;
uniform float foam_micro_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.20;
uniform float foam_threshold : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float foam_contrast : hint_range(0.1, 4.0, 0.01) = 1.35;
uniform float foam_alpha_boost : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float foam_distance_fade_start : hint_range(0.0, 4000.0, 1.0) = 180.0;
uniform float foam_distance_fade_end : hint_range(1.0, 5000.0, 1.0) = 900.0;
uniform float foam_breakup_strength : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float foam_breakup_world_size : hint_range(1.0, 200.0, 0.5) = 14.0;
// Zero keeps the breakup attached to ocean_base_xz instead of crawling.
uniform float foam_breakup_speed : hint_range(-2.0, 2.0, 0.01) = 0.0;
uniform float foam_edge_softness : hint_range(0.01, 0.49, 0.01) = 0.16;
uniform bool foam_breakup_texture_ready = false;
// Crest foam stays physically owned by its own accumulator. This only shapes
// its visible mask with the existing direct-J Surface Foam topology.
uniform bool crest_filigree_enabled = true;
uniform float crest_fresh_filigree_strength : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float crest_residual_filigree_strength : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform float crest_filigree_contrast : hint_range(0.1, 4.0, 0.01) = 1.0;
uniform float crest_filigree_threshold : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float crest_filigree_normal_influence : hint_range(0.0, 2.0, 0.01) = 0.35;
// Dedicated SHORT-J accumulator: physical birth/persistence is computed on the
// GPU; these controls only shape its material presentation.
uniform bool surface_foam_enabled = true;
// Presentation-only stochastic sampling of the existing periodic direct-J and
// history textures. It never changes the technical spectrum or its evolution.
uniform bool surface_foam_stochastic_deperiodization_enabled = true;
uniform float surface_foam_stochastic_cell_size_m : hint_range(16.0, 96.0, 0.5) = 32.0;
uniform float surface_foam_whitecap : hint_range(0.0, 1.5, 0.01) = 0.0;
uniform float surface_foam_field_domain_m : hint_range(8.0, 256.0, 0.5) = 88.0;
uniform float surface_foam_source_domain_m : hint_range(4.0, 32.0, 0.5) = 8.0;
uniform float surface_foam_ocean_coupling : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float surface_foam_distance_fade_start_m : hint_range(0.0, 2000.0, 1.0) = 200.0;
uniform float surface_foam_distance_fade_end_m : hint_range(1.0, 2000.0, 1.0) = 600.0;
uniform float surface_foam_strength : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float surface_foam_threshold_visual : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec4 surface_foam_color : source_color = vec4(0.78, 0.84, 0.82, 1.0);
uniform float surface_foam_normal_strength : hint_range(0.0, 10.0, 0.01) = 0.55;
uniform float foam_fresh_roughness : hint_range(0.0, 1.0, 0.01) = 0.95;
uniform float foam_residual_roughness : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform float surface_foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.82;
uniform float foam_fresh_specular : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform float foam_residual_specular : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float surface_foam_specular : hint_range(0.0, 1.0, 0.01) = 0.20;
// Presentation-only detail: it modulates the already persistent physical mask
// and is anchored in ocean_base_xz, never in screen or scrolling UVs.
uniform bool surface_foam_micro_detail_enabled = true;
uniform bool surface_foam_micro_texture_ready = false;
uniform float surface_foam_micro_strength : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform vec2 surface_foam_micro_scale_m = vec2(10.0, 3.2);
uniform float surface_foam_micro_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.25;
uniform float surface_foam_edge_fade_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float surface_foam_edge_fade_width : hint_range(0.01, 0.5, 0.01) = 0.14;
uniform float foam_detail_contribution : hint_range(0.0, 1.0, 0.01) = 0.35;
// 0 OFF, 1 CREST_FINAL, 2 SURFACE_HISTORY, 3 SURFACE_MACRO,
// 4 SURFACE_FINAL, 5 SURFACE_DIRECT_RAW, 6 SURFACE_DEPERIODIZED_RAW,
// 7 SURFACE_PLUS_CREST, 8 FOAM_NORMAL, 9 SURFACE_MID_FOLD,
// 10 CREST_FILIGREE_SOURCE, 11 CREST_FILIGREE_MASK,
// 12 CREST_FRESH_WEBBED, 13 CREST_RESIDUAL_WEBBED,
// 14 CREST_FRESH_RAW, 15 CREST_RESIDUAL_RAW.
uniform int foam_debug_mode = 0;

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
uniform float breaker_takeover_forward_sign = 1.0;
// S5 production takeover: one tracked world-space mask per ACTIVE breaker.
// data0 = center.xy + physical travel direction.zw; data1 = length, width,
// lifecycle stage, alpha. Arrays stay fixed at the production cap (8).
uniform int breaker_takeover_count = 0;
uniform vec4 breaker_takeover_data0[8];
uniform vec4 breaker_takeover_data1[8];
// 4C-S3.2: banda longitudinal estrecha de seam (q_profile). La ventana S3.1
// actúa sólo como bounding window; la ocultación real vive en esta banda.
uniform float breaker_takeover_seam_center = 0.56;
uniform float breaker_takeover_seam_half_width = 0.10;
uniform float breaker_takeover_seam_feather = 0.06;
// 4C-S3.3: profundidad de submerge (depresión vertical) bajo la seam S3.2.
uniform float breaker_takeover_submerge_hs = 0.38;

varying vec3 derived_normal;
varying vec2 ocean_base_xz;
varying vec2 ocean_world_xz;
varying vec3 ocean_world_position;
varying vec4 coastal_field;
varying vec4 coastal_metrics;
varying vec4 coastal_phase_data;
// Packed to stay within the Forward+ varying-location limit:
// x = reflection crest mask, y = coastal mono phase, z = coastal mono active.
varying vec3 reflection_and_mono_state;
varying float coastal_warp_delta_m;
varying vec4 breaking_indices; // depth, steepness, crestness, final prebreak.
varying float crest_sharpen_mask; // 5R.1C: máscara de sharpening (debug).
varying float ocean_wave_height; // 5R.3C: altura visual final para tint de cresta/valle.
varying vec2 surface_foam_displacement_xz; // desplazamiento físico ya calculado por vertex().
varying float shore_vertical_weight_varying;
varying float shore_horizontal_weight_varying;
varying float shore_pre_envelope_height;

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

float shore_data_inside(vec2 uv) {
	return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
}

void shore_weights_from_depth(float depth_m, out float vertical_weight, out float horizontal_weight) {
	float depth = max(depth_m, 0.0);
	float water_presence = smoothstep(0.0, max(coastal_min_valid_depth_m, 0.001), depth);
	float vertical_curve = smoothstep(
		min(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y),
		max(shore_vertical_depth_range_m.x, shore_vertical_depth_range_m.y), depth);
	float horizontal_curve = smoothstep(
		min(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y),
		max(shore_horizontal_depth_range_m.x, shore_horizontal_depth_range_m.y), depth);
	vertical_weight = water_presence * vertical_curve;
	horizontal_weight = water_presence * horizontal_curve;
}

void shore_stabilization_weights(vec2 world_xz, vec4 metrics_data,
		out float vertical_weight, out float horizontal_weight) {
	vertical_weight = 1.0;
	horizontal_weight = 1.0;
	if (!shore_stabilization_enabled || !coastal_propagation_enabled) return;
	float inside = shore_data_inside(coastal_uv(world_xz));
	float local_vertical;
	float local_horizontal;
	shore_weights_from_depth(metrics_data.r, local_vertical, local_horizontal);
	vertical_weight = mix(1.0, local_vertical, inside);
	horizontal_weight = mix(1.0, local_horizontal, inside);
}

void shore_stabilization_weights_at(vec2 world_xz,
		out float vertical_weight, out float horizontal_weight) {
	vertical_weight = 1.0;
	horizontal_weight = 1.0;
	if (!shore_stabilization_enabled || !coastal_propagation_enabled) return;
	vec2 uv = coastal_uv(world_xz);
	float inside = shore_data_inside(uv);
	vec4 metrics_data = textureLod(coastal_metrics_texture, clamp(uv, vec2(0.0), vec2(1.0)), 0.0);
	float local_vertical;
	float local_horizontal;
	shore_weights_from_depth(metrics_data.r, local_vertical, local_horizontal);
	vertical_weight = mix(1.0, local_vertical, inside);
	horizontal_weight = mix(1.0, local_horizontal, inside);
}

void shore_stabilization_weights_and_gradients(vec2 world_xz, vec4 metrics_data,
		out float vertical_weight, out float horizontal_weight,
		out vec2 vertical_gradient) {
	shore_stabilization_weights(world_xz, metrics_data, vertical_weight, horizontal_weight);
	vertical_gradient = vec2(0.0);
	if (!shore_stabilization_enabled || !coastal_propagation_enabled) return;
	float inside = shore_data_inside(coastal_uv(world_xz));
	if (inside < 0.5) return;
	float step_m = max(coastal_cell_size_m, 0.25);
	float vertical_minus;
	float horizontal_minus;
	float vertical_plus;
	float horizontal_plus;
	shore_stabilization_weights_at(world_xz - vec2(step_m, 0.0), vertical_minus, horizontal_minus);
	shore_stabilization_weights_at(world_xz + vec2(step_m, 0.0), vertical_plus, horizontal_plus);
	vertical_gradient.x = (vertical_plus - vertical_minus) / (2.0 * step_m);
	shore_stabilization_weights_at(world_xz - vec2(0.0, step_m), vertical_minus, horizontal_minus);
	shore_stabilization_weights_at(world_xz + vec2(0.0, step_m), vertical_plus, horizontal_plus);
	vertical_gradient.y = (vertical_plus - vertical_minus) / (2.0 * step_m);
}

// field_data.a is propagation validity, not water presence. It is still a
// useful soft confidence for the render transition, while has_coastal_data()
// remains the discrete validity gate used by the phase/breaking diagnostics.
float coastal_render_confidence(vec2 uv, vec4 field_data) {
	if (!coastal_propagation_enabled || !coastal_transform_enabled) return 0.0;
	return shore_data_inside(uv) * clamp(field_data.a, 0.0, 1.0);
}

vec2 shore_weight_gradient_from_fragment(vec2 world_xz, float weight) {
	vec2 world_dx = dFdx(world_xz);
	vec2 world_dy = dFdy(world_xz);
	float weight_dx = dFdx(weight);
	float weight_dy = dFdy(weight);
	float determinant = world_dx.x * world_dy.y - world_dx.y * world_dy.x;
	if (abs(determinant) < 0.00001) return vec2(0.0);
	return vec2(
		(weight_dx * world_dy.y - world_dx.y * weight_dy) / determinant,
		(world_dx.x * weight_dy - weight_dx * world_dy.x) / determinant);
}

void sea_state_zone_sdf(vec2 point, vec2 center, vec2 axis, vec2 half_extents,
		out float sdf, out vec2 sdf_gradient) {
	vec2 safe_axis = normalize(axis);
	if (dot(safe_axis, safe_axis) < 0.000001) safe_axis = vec2(1.0, 0.0);
	vec2 tangent = vec2(-safe_axis.y, safe_axis.x);
	vec2 local_point = vec2(dot(point - center, safe_axis), dot(point - center, tangent));
	vec2 q = abs(local_point) - half_extents;
	vec2 outside = max(q, vec2(0.0));
	float outside_length = length(outside);
	sdf = outside_length + min(max(q.x, q.y), 0.0);
	vec2 gradient_local = vec2(0.0);
	if (outside_length > 0.000001) {
		gradient_local = normalize(vec2(sign(local_point.x) * outside.x, sign(local_point.y) * outside.y));
	} else if (q.x > q.y) {
		gradient_local = vec2(sign(local_point.x), 0.0);
	} else {
		gradient_local = vec2(0.0, sign(local_point.y));
	}
	sdf_gradient = safe_axis * gradient_local.x + tangent * gradient_local.y;
}

void sea_state_zone_state(vec2 point, out float long_amplitude, out float mid_amplitude,
		out float short_amplitude, out float choppiness, out vec2 grad_long,
		out vec2 grad_mid, out vec2 grad_short, out vec2 grad_chop,
		out float foam_multiplier) {
	long_amplitude = 1.0;
	mid_amplitude = 1.0;
	short_amplitude = 1.0;
	choppiness = 1.0;
	grad_long = vec2(0.0);
	grad_mid = vec2(0.0);
	grad_short = vec2(0.0);
	grad_chop = vec2(0.0);
	foam_multiplier = 1.0;
	for (int index = 0; index < 8; index++) {
		if (index >= sea_state_zone_count) break;
		vec4 zone0 = sea_state_zone_data0[index];
		vec4 zone1 = sea_state_zone_data1[index];
		vec4 target = sea_state_zone_data2[index];
		float target_foam = sea_state_zone_data3[index].x;
		float sdf;
		vec2 sdf_gradient;
		sea_state_zone_sdf(point, zone0.xy, zone0.zw, zone1.xy, sdf, sdf_gradient);
		float feather = max(zone1.z, 0.0);
		float local_weight = 0.0;
		vec2 grad_weight = vec2(0.0);
		if (feather <= 0.000001 || sdf <= 0.0) {
			local_weight = 1.0;
		} else if (sdf < feather) {
			float t = clamp(sdf / feather, 0.0, 1.0);
			local_weight = 1.0 - smoothstep(0.0, 1.0, t);
			grad_weight = sdf_gradient * (-6.0 * t * (1.0 - t) / feather);
		}
		float weight = clamp(local_weight * clamp(zone1.w, 0.0, 1.0), 0.0, 1.0);
		if (weight <= 0.0) continue;
		grad_weight *= clamp(zone1.w, 0.0, 1.0);
		float old_long = long_amplitude;
		float old_mid = mid_amplitude;
		float old_short = short_amplitude;
		float old_chop = choppiness;
		float old_foam = foam_multiplier;
		long_amplitude = mix(old_long, target.x, weight);
		mid_amplitude = mix(old_mid, target.y, weight);
		short_amplitude = mix(old_short, target.z, weight);
		choppiness = mix(old_chop, target.w, weight);
		foam_multiplier = mix(old_foam, clamp(target_foam, 0.0, 2.0), weight);
		grad_long = grad_long * (1.0 - weight) + (target.x - old_long) * grad_weight;
		grad_mid = grad_mid * (1.0 - weight) + (target.y - old_mid) * grad_weight;
		grad_short = grad_short * (1.0 - weight) + (target.z - old_short) * grad_weight;
		grad_chop = grad_chop * (1.0 - weight) + (target.w - old_chop) * grad_weight;
	}
}

float sea_state_zone_foam_activity(float long_amplitude, float mid_amplitude,
		float short_amplitude, float choppiness, float foam_multiplier) {
	// Long owns the broad crest energy; the shorter bands and choppiness add
	// detail without allowing a calm-zone multiplier to create foam by itself.
	float band_activity = clamp(
		0.65 * long_amplitude + 0.25 * mid_amplitude + 0.10 * short_amplitude,
		0.0, 2.0);
	float chop_activity = clamp(0.5 + 0.5 * choppiness, 0.0, 1.5);
	return clamp(foam_multiplier * band_activity * chop_activity, 0.0, 1.0);
}


float sea_state_zone_calmness(float long_amplitude, float mid_amplitude,
		float short_amplitude, float choppiness) {
	// The local values already include the zone's SDF feather and strength.
	// Clamping each term makes out-of-range authored multipliers incapable of
	// producing negative calmness or a reflection discontinuity at the edge.
	float long_calm = 1.0 - clamp(long_amplitude, 0.0, 1.0);
	float mid_calm = 1.0 - clamp(mid_amplitude, 0.0, 1.0);
	float short_calm = 1.0 - clamp(short_amplitude, 0.0, 1.0);
	float chop_calm = 1.0 - clamp(choppiness, 0.0, 1.0);
	return clamp(
		0.35 * long_calm + 0.25 * mid_calm + 0.15 * short_calm + 0.25 * chop_calm,
		0.0, 1.0);
}


const float WATER_IOR = 1.333;
const float WATER_F0 = 0.020373;
// Godot 4.7 maps dielectric SPECULAR to F0 as 0.16 * SPECULAR^2.
// sqrt(0.020373 / 0.16) gives the exact input for water IOR 1.333.
const float WATER_SPECULAR_LEVEL = 0.356835;


float physical_water_fresnel(vec3 normal, vec3 view_direction) {
	float n_dot_v = clamp(dot(normalize(normal), normalize(view_direction)), 0.0, 1.0);
	return WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - n_dot_v, 5.0);
}


vec2 reflection_unresolved_detail_metrics(vec2 world_xz, float footprint,
		float mid_amplitude, float short_amplitude) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float mid_texel_m = domain_mid_m / float(textureSize(normal_mid, 0).x);
	float short_texel_m = domain_short_m / float(textureSize(normal_short, 0).x);
	float mid_subpixel = smoothstep(mid_texel_m * 0.5, mid_texel_m * 2.0, footprint);
	float short_subpixel = smoothstep(short_texel_m * 0.5, short_texel_m * 2.0, footprint);

	vec2 mid_slope = slope_from_normal(normalize(textureLod(normal_mid,
		spectrum_uv(world_xz, domain_mid_m), 0.0).rgb));
	vec2 mid_average = vec2(0.0);
	for (int index = 0; index < 4; index++) {
		vec2 offset = index == 0 ? vec2(1.0, 1.0) : index == 1 ? vec2(1.0, -1.0) : index == 2 ? vec2(-1.0, 1.0) : vec2(-1.0, -1.0);
		mid_average += slope_from_normal(normalize(textureLod(normal_mid,
			spectrum_uv(world_xz + offset * mid_texel_m, domain_mid_m), 0.0).rgb));
	}
	mid_average *= 0.25;

	vec2 short_slope = slope_from_normal(normalize(textureLod(normal_short,
		spectrum_uv(world_xz, domain_short_m), 0.0).rgb));
	vec2 short_average = vec2(0.0);
	for (int index = 0; index < 4; index++) {
		vec2 offset = index == 0 ? vec2(1.0, 1.0) : index == 1 ? vec2(1.0, -1.0) : index == 2 ? vec2(-1.0, 1.0) : vec2(-1.0, -1.0);
		short_average += slope_from_normal(normalize(textureLod(normal_short,
			spectrum_uv(world_xz + offset * short_texel_m, domain_short_m), 0.0).rgb));
	}
	short_average *= 0.25;

	float mid_variance = dot(mid_slope - mid_average, mid_slope - mid_average);
	float short_variance = dot(short_slope - short_average, short_slope - short_average);
	float mid_detail = 0.35 * mid_weight * clamp(mid_amplitude, 0.0, 2.0) * mid_subpixel;
	float short_detail = 0.65 * short_weight * clamp(short_amplitude, 0.0, 2.0) * short_subpixel;
	float detail_energy = clamp(mid_detail + short_detail, 0.0, 1.0);
	float weighted_variance = 0.35 * mid_weight * mid_variance + 0.65 * short_weight * short_variance;
	float variance_weight = 0.35 * mid_weight + 0.65 * short_weight;
	float slope_variance = clamp(weighted_variance / max(variance_weight, 0.001), 0.0, 1.0);
	return vec2(detail_energy, slope_variance);
}


float physical_ocean_roughness(float distance_to_camera, float footprint,
		vec2 unresolved_detail_metrics) {
	float distance_factor = smoothstep(
		reflection_roughness_distance_m.x,
		max(reflection_roughness_distance_m.y, reflection_roughness_distance_m.x + 0.001),
		distance_to_camera);
	float footprint_factor = smoothstep(0.5, 2.0, footprint / max(reflection_roughness_distance_m.x, 0.001));
	float distance_contribution = clamp(distance_factor * reflection_distance_roughness_gain, 0.0, 1.0);
	float footprint_contribution = clamp(footprint_factor * reflection_pixel_footprint_gain, 0.0, 1.0);
	float distance_range = max(reflection_distance_roughness - reflection_base_roughness, 0.0);
	float detail_roughness = unresolved_detail_metrics.x * reflection_detail_roughness_gain;
	float slope_roughness = unresolved_detail_metrics.y * reflection_slope_variance_gain;
	float spatial_roughness = reflection_base_roughness
		+ distance_range * max(distance_contribution, footprint_contribution)
		+ detail_roughness + slope_roughness;
	return clamp(max(reflection_min_roughness, spatial_roughness), 0.0, 1.0);
}


float reflection_crest_shaped_roughness(float base_roughness,
		float crest_mask, vec2 unresolved_detail_metrics) {
	if (!reflection_crest_specular_enabled) {
		return base_roughness;
	}
	// MID/SHORT slope variance breaks a long macro highlight into local pieces.
	// It only attenuates the crest support; it never creates highlight coverage.
	float detail_variation = clamp(
		0.45 * unresolved_detail_metrics.x + 0.55 * unresolved_detail_metrics.y,
		0.0,
		1.0
	);
	float detail_fragmentation = smoothstep(0.05, 0.65, detail_variation);
	float shaped_crest = clamp(crest_mask * reflection_crest_mask_gain, 0.0, 1.0);
	shaped_crest *= mix(1.0, 0.68, detail_fragmentation);
	float min_scale = clamp(reflection_crest_min_roughness_scale, 0.45, 1.0);
	float roughness_scale = 1.0 - shaped_crest
		* clamp(reflection_crest_roughness_gain, 0.0, 1.0)
		* (1.0 - min_scale);
	return max(reflection_min_roughness, base_roughness * roughness_scale);
}


vec2 reflection_sspr_distorted_uv(vec2 planar_uv, vec3 macro_normal_view,
		vec3 view_direction, float camera_distance, vec3 flat_normal_view,
		vec2 projection_scale, out float distortion_confidence) {
	vec3 planar_reflection = normalize(reflect(-view_direction, flat_normal_view));
	vec3 wave_reflection = normalize(reflect(-view_direction, macro_normal_view));
	float planar_z = max(abs(planar_reflection.z), 0.12);
	float wave_z = max(abs(wave_reflection.z), 0.12);
	vec2 planar_ray = planar_reflection.xy / planar_z;
	vec2 wave_ray = wave_reflection.xy / wave_z;
	vec2 projected_delta = (wave_ray - planar_ray) * projection_scale * 0.5;
	float view_grazing = 1.0 - abs(dot(view_direction, flat_normal_view));
	float view_factor = smoothstep(0.08, 0.78, view_grazing);
	float distance_factor = clamp(
		camera_distance / max(camera_distance + reflection_roughness_distance_m.x, 0.001),
		0.15,
		1.0
	);
	float footprint = max(fwidth(ocean_world_xz.x), fwidth(ocean_world_xz.y));
	float footprint_factor = clamp(
		footprint / max(reflection_roughness_distance_m.x * 0.01, 0.001),
		0.0,
		1.0
	);
	float scale = reflection_sspr_distortion_strength
		* mix(0.65, 1.0, view_factor)
		* distance_factor
		* mix(0.80, 1.0, footprint_factor);
	vec2 distortion = projected_delta * scale;
	// Keep this falloff continuous. A thresholded confidence made tiny changes
	// in micro-detail cross a validity boundary and amplified temporal flicker.
	distortion_confidence = exp(-length(distortion) * 2.5);
	return planar_uv + distortion;
}


float reflection_sspr_edge_confidence(vec2 uv) {
	if (reflection_sspr_edge_fade <= 0.0001) {
		return 1.0;
	}
	float distance_to_edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	return smoothstep(0.0, reflection_sspr_edge_fade, distance_to_edge);
}


float reflection_sspr_slope_confidence(vec3 final_normal_world) {
	float up_alignment = clamp(dot(normalize(final_normal_world), vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
	float slope = 1.0 - up_alignment;
	return 1.0 - smoothstep(reflection_sspr_slope_fade, 1.0, slope);
}


bool reflection_sspr_source_from_depth(vec2 uv, float raw_depth,
		mat4 inverse_projection, mat4 inverse_view, float sea_level,
		out vec3 source_world) {
	source_world = vec3(0.0);
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001 ||
			isnan(raw_depth) || isinf(raw_depth)) {
		return false;
	}
	vec4 virtual_view = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(virtual_view.w) <= 0.000001 || any(isnan(virtual_view)) || any(isinf(virtual_view))) {
		return false;
	}
	virtual_view /= virtual_view.w;
	vec4 virtual_world = inverse_view * vec4(virtual_view.xyz, 1.0);
	if (abs(virtual_world.w) <= 0.000001 || any(isnan(virtual_world)) || any(isinf(virtual_world))) {
		return false;
	}
	virtual_world /= virtual_world.w;
	source_world = virtual_world.xyz;
	source_world.y = 2.0 * sea_level - source_world.y;
	if (any(isnan(source_world)) || any(isinf(source_world))) {
		source_world = vec3(0.0);
		return false;
	}
	return true;
}


float reflection_sspr_facet_confidence(vec3 macro_reflection_ray_world,
		vec3 direction_to_source_world, float roughness) {
	float alignment = clamp(dot(
		normalize(macro_reflection_ray_world),
		normalize(direction_to_source_world)
	), -1.0, 1.0);
	float roughness_lobe = smoothstep(0.0, 0.85, clamp(roughness, 0.0, 1.0));
	float threshold_low = mix(0.93, 0.45, roughness_lobe);
	float threshold_high = mix(0.99, 0.82, roughness_lobe);
	float alignment_aa = max(fwidth(alignment), 0.015);
	return smoothstep(
		threshold_low - alignment_aa,
		threshold_high + alignment_aa,
		alignment
	);
}


float reflection_distance_blur_lod(float roughness, float source_distance_m,
		float mip_max) {
	float safe_roughness = clamp(roughness, 0.0, 1.0);
	float base_lod = safe_roughness * mip_max;
	if (!reflection_distance_blur_enabled) {
		return clamp(base_lod, 0.0, mip_max);
	}
	float roughness_weight = pow(safe_roughness, 1.25);
	float distance_ratio = max(source_distance_m, 0.0)
		/ max(reflection_distance_blur_reference_m, 0.001);
	float distance_lod = reflection_distance_blur_strength
		* roughness_weight * log2(1.0 + distance_ratio);
	return clamp(base_lod + distance_lod, 0.0, mip_max);
}


float reflection_final_roughness(float base_roughness, float surface_foam_mask_value,
		float foam_residual_mask_value, float foam_fresh_mask_value) {
	float result = base_roughness;
	result = mix(result, surface_foam_roughness, surface_foam_mask_value);
	result = mix(result, foam_residual_roughness, foam_residual_mask_value);
	result = mix(result, foam_fresh_roughness, foam_fresh_mask_value);
	return result;
}


vec3 reflection_grade_radiance(vec3 radiance) {
	// Final art direction is applied to the fully composed screen-space
	// radiance. Keep it in linear HDR and leave diagnostic reflection modes raw.
	radiance *= exp2(reflection_radiance_exposure_ev);
	float luminance = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
	float safe_luminance = max(luminance, 0.000001);
	float contrast_luminance = max(
		0.0,
		pow(safe_luminance, reflection_radiance_contrast)
	);
	radiance *= contrast_luminance / safe_luminance;
	float saturation_luminance = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
	radiance = mix(vec3(saturation_luminance), radiance, reflection_radiance_saturation);
	return radiance * reflection_radiance_tint.rgb;
}


float sun_specular_brdf(vec3 normal, vec3 view_direction, float roughness) {
	vec3 light_direction = normalize(reflection_sun_direction_world);
	vec3 half_vector = normalize(light_direction + view_direction);
	float n_dot_v = max(dot(normal, view_direction), 0.001);
	float n_dot_l = max(dot(normal, light_direction), 0.0);
	float n_dot_h = max(dot(normal, half_vector), 0.0);
	float v_dot_h = max(dot(view_direction, half_vector), 0.0);
	if (n_dot_l <= 0.0 || n_dot_h <= 0.0) return 0.0;
	float alpha = max(roughness * roughness, 0.0025);
	float alpha_squared = alpha * alpha;
	float distribution_denominator = n_dot_h * n_dot_h * (alpha_squared - 1.0) + 1.0;
	float distribution = alpha_squared / max(3.14159265 * distribution_denominator * distribution_denominator, 0.0001);
	float geometry_k = alpha * 0.5;
	float geometry_view = n_dot_v / (n_dot_v * (1.0 - geometry_k) + geometry_k);
	float geometry_light = n_dot_l / (n_dot_l * (1.0 - geometry_k) + geometry_k);
	float fresnel = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - v_dot_h, 5.0);
	return clamp(distribution * geometry_view * geometry_light * fresnel / max(4.0 * n_dot_v, 0.001), 0.0, 1.0);
}

vec3 sea_state_zone_displacement(vec3 value, float amplitude, float choppiness) {
	value.y *= amplitude;
	value.xz *= amplitude * choppiness;
	return value;
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

float breaker_takeover_production_mask(vec2 world_xz) {
	float result = 0.0;
	for (int index = 0; index < 8; index++) {
		if (index >= breaker_takeover_count) break;
		vec4 data0 = breaker_takeover_data0[index];
		vec4 data1 = breaker_takeover_data1[index];
		vec2 direction = normalize(data0.zw);
		vec2 tangent = vec2(-direction.y, direction.x);
		vec2 delta = world_xz - data0.xy;
		float length_m = max(data1.x, 0.001);
		float width_m = max(data1.y, 0.001);
		float q = dot(delta, direction) / length_m + 0.5;
		float lateral = abs(dot(delta, tangent)) / (0.5 * width_m);
		float longitudinal = smoothstep(0.06, 0.22, q) * (1.0 - smoothstep(0.78, 0.96, q));
		float lateral_fade = 1.0 - smoothstep(0.76, 1.12, lateral);
		float stage = smoothstep(0.10, 0.42, data1.z);
		float mask = longitudinal * lateral_fade * stage * clamp(data1.w, 0.0, 1.0);
		result = max(result, mask);
	}
	return clamp(result, 0.0, 1.0);
}

void vertex() {
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	// The FFT maps are parameterized by this undisplaced, material coordinate.
	// It must be carried to fragment() separately from the final world position.
	ocean_base_xz = world_xz;
	reflection_and_mono_state = vec3(0.0);
	coastal_warp_delta_m = 0.0;
	breaking_indices = vec4(0.0);
	crest_sharpen_mask = 0.0;
	shore_vertical_weight_varying = 1.0;
	shore_horizontal_weight_varying = 1.0;
	shore_pre_envelope_height = 0.0;
	coastal_field = vec4(0.0);
	coastal_metrics = vec4(0.0);
	coastal_phase_data = vec4(0.0);
	if (!perf_spectral_enabled) {
		ocean_world_xz = world_xz;
		ocean_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		ocean_wave_height = 0.0;
		surface_foam_displacement_xz = vec2(0.0);
		derived_normal = vec3(0.0, 1.0, 0.0);
		NORMAL = derived_normal;
	} else {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	vec2 coast_uv = coastal_uv(world_xz);
	coastal_field = textureLod(coastal_field_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	coastal_metrics = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	coastal_phase_data = textureLod(coastal_phase_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	vec2 shore_vertical_gradient;
	shore_stabilization_weights_and_gradients(world_xz, coastal_metrics,
		shore_vertical_weight_varying, shore_horizontal_weight_varying,
		shore_vertical_gradient);
	bool coast_active = has_coastal_data(coast_uv, coastal_field);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	float render_confidence = coastal_render_confidence(coast_uv, coastal_field);
	bool coast_render_active = render_confidence > 0.001;
	float phase_offset = coastal_field.r;
	float shoaling = coastal_field.g;

	// 3B.2B: LONG se compone de LONG_COASTAL (posiblemente warpeada) +
	// LONG_REMAINDER (siempre open). El warp sólo aplica a LONG_COASTAL.
	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_render_active && coastal_forced_warp_debug && coastal_warp_effect_debug != 2) {
		// Prueba de cadena de textura/binding: no es una solución física.
		warp_sample = vec4(world_xz + coastal_forced_warp_offset_xz, 1.0, 0.0);
	} else if (coast_render_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z * render_confidence;
	vec4 warp_jacobian = vec4(1.0, 0.0, 0.0, 1.0);
	if (coast_render_active && coastal_warp_enabled && !coastal_forced_warp_debug && coastal_warp_effect_debug != 2) {
		warp_jacobian = warp_jacobian_sample(world_xz);
	}
	// LONG_COASTAL: sampleo en deep (si warp activo) con blend -> open (sin warp).
	vec3 long_coastal_warped = textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal_open = textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb;
	vec3 long_coastal = mix(long_coastal_open, long_coastal_warped, warp_confidence);
	coastal_warp_delta_m = length(long_coastal_warped - long_coastal_open);
	float effective_shoaling = 1.0;
	if (coast_render_active) {
		if (coastal_warp_effect_debug == 2) effective_shoaling = shoaling; // DEBUG: shoaling sin warp.
		else if (coastal_warp_effect_debug == 0) effective_shoaling = mix(1.0, shoaling, warp_confidence);
	}
	long_coastal *= effective_shoaling;
	// LONG_REMAINDER: siempre open-ocean.
	vec3 long_remainder = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb;
	vec3 long_displacement = long_coastal + long_remainder;
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
	sea_state_zone_state(world_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);
	float long_coastal_height = long_coastal.y;
	float long_remainder_height = long_remainder.y;
	float mid_height = mid_displacement.y;
	float short_height = short_displacement.y;
	long_coastal = sea_state_zone_displacement(long_coastal, zone_long_amplitude, zone_choppiness);
	long_remainder = sea_state_zone_displacement(long_remainder, zone_long_amplitude, zone_choppiness);
	mid_displacement = sea_state_zone_displacement(mid_displacement, zone_mid_amplitude, zone_choppiness);
	short_displacement = sea_state_zone_displacement(short_displacement, zone_short_amplitude, zone_choppiness);
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
	vec2 slope = (slope_coastal * zone_long_amplitude * effective_shoaling + long_coastal_height * zone_grad_long)
		* coastal_weight * coastal_gain;
	vec3 long_remainder_normal = normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb);
	slope += (slope_from_normal(long_remainder_normal) * zone_long_amplitude + long_remainder_height * zone_grad_long) * remainder_weight;
	slope += (slope_from_normal(normalize(textureLod(normal_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rgb)) * zone_mid_amplitude + mid_height * zone_grad_mid) * mid_weight * mid_short_weight;
	// SHORT no debe grabar los anillos del clipmap en la normal VERTEX.
	slope += (slope_from_normal(normalize(textureLod(normal_short, spectrum_uv(world_xz, domain_short_m), 0.0).rgb)) * zone_short_amplitude + short_height * zone_grad_short)
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
		float mono_height = long_displacement.y;
		long_displacement = sea_state_zone_displacement(long_displacement, zone_long_amplitude, zone_choppiness);
		displacement = long_displacement * long_weight;
		vec2 mono_gradient = -mono_direction * coastal_monochromatic_amplitude_m * mono_shoaling * mono_k * sin(phase) * zone_long_amplitude
			+ mono_height * zone_grad_long;
		slope = mono_gradient;
		ocean_normal = normalize(vec3(-mono_gradient.x, 1.0, -mono_gradient.y));
		reflection_and_mono_state.y = phase;
		reflection_and_mono_state.z = 1.0;
	}

	// Ruta estrictamente opt-in. No hay compute global, readback ni OceanQuery:
	// sólo fetches adicionales en los vértices renderizados por el debug / futuro 4B.
	if (perf_prebreak_enabled && breaking_debug_mode > 0 && !coastal_monochromatic_debug) {
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

	// 5R.1C / Reflection 1C: ambos consumidores reutilizan la misma medida de
	// convexidad LONG+MID. La modulación de roughness no cambia la geometría.
	bool crest_shape_data_needed = module_enabled && !coastal_monochromatic_debug
		&& (ocean_crest_sharpen_strength > 0.0 || reflection_crest_specular_enabled);
	if (crest_shape_data_needed) {
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
		float crest_convexity = smoothstep(
			ocean_crest_sharpen_threshold * 0.8,
			ocean_crest_sharpen_threshold + 0.30,
			crestness
		);
		// Mantiene soporte en el ápice (donde la pendiente es baja) y sólo añade
		// una ligera preferencia por el frente/espalda inclinados de la cresta.
		float crest_slope_presence = smoothstep(0.0, 0.20, face_slope);
		float crest_support = crest_convexity
			* mix(0.76, 1.0, crest_slope_presence)
			* band_mask.x;
		reflection_and_mono_state.x = clamp(crest_support, 0.0, 1.0);

		if (ocean_crest_sharpen_strength > 0.0) {
			float sharpen = smoothstep(ocean_crest_sharpen_threshold, ocean_crest_sharpen_threshold + 0.25, crestness)
				* compression * band_mask.x * ocean_crest_sharpen_strength; // 5R.1D: band_mask (world-space), no camera distance.
			float gain = ocean_crest_sharpen_max_gain;
			// Elevación vertical acotada + compresión horizontal suave (narrow crest).
			displacement.y += sharpen * gain * local_hs * zone_long_amplitude;
			displacement.xz *= 1.0 + sharpen * gain * 0.35 * zone_long_amplitude * zone_choppiness;
			crest_sharpen_mask = sharpen;
		}
	}

	// Shoreline is the final geometry envelope. It limits both the base FFT and
	// any crest sharpening added above, while keeping the breaker detector on
	// the pre-stabilized wave. The product rule keeps the vertex normal aligned
	// with height_final = vertical_weight * height.
	shore_pre_envelope_height = displacement.y;
	displacement.xz *= shore_horizontal_weight_varying;
	displacement.y *= shore_vertical_weight_varying;
	vec2 shore_final_slope = slope * shore_vertical_weight_varying
		+ shore_pre_envelope_height * shore_vertical_gradient;
	ocean_normal = !module_enabled ? vec3(0.0, 1.0, 0.0) : normalize(vec3(-shore_final_slope.x, 1.0, -shore_final_slope.y));
	// Production handoff is deliberately after the shoreline envelope: the
	// stabilized FFT remains the host, while only the tracked breaker footprint
	// is submerged. Alpha/stage make both borders temporal and spatially smooth.
	if (module_enabled && breaker_takeover_count > 0) {
		float production_takeover = breaker_takeover_production_mask(world_xz);
		float takeover_submerge_m = max(0.15, breaking_long_hs_m * breaker_takeover_submerge_hs);
		displacement.y -= takeover_submerge_m * production_takeover;
	}
	if (clipmap_flat_geometry_debug) {
		displacement = vec3(0.0);
		ocean_normal = vec3(0.0, 1.0, 0.0);
	}
	ocean_wave_height = displacement.y;
	vec3 displaced_vertex = VERTEX + displacement;
	ocean_world_xz = (MODEL_MATRIX * vec4(displaced_vertex, 1.0)).xz;
	ocean_world_position = (MODEL_MATRIX * vec4(displaced_vertex, 1.0)).xyz;
	surface_foam_displacement_xz = ocean_world_xz - world_xz;
	VERTEX = displaced_vertex;
	NORMAL = ocean_normal;
	derived_normal = ocean_normal;
	}
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
	vec4 metrics_data = textureLod(coastal_metrics_texture, clamp(coast_uv, vec2(0.0), vec2(1.0)), 0.0);
	bool coast_active = has_coastal_data(coast_uv, field_data);
	bool coast_transform_active = coastal_transform_enabled && coast_active;
	float render_confidence = coastal_render_confidence(coast_uv, field_data);
	bool coast_render_active = render_confidence > 0.001;
	float shoaling = field_data.g;

	vec4 warp_sample = vec4(world_xz, 0.0, 0.0);
	if (coast_render_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_sample = warp_deep_sample(world_xz);
	}
	vec2 deep_xz = warp_sample.xy;
	float warp_confidence = warp_sample.z * render_confidence;
	vec4 warp_jacobian = vec4(1.0, 0.0, 0.0, 1.0);
	if (coast_render_active && coastal_warp_enabled && coastal_warp_effect_debug != 2) {
		warp_jacobian = warp_jacobian_sample(world_xz);
	}
	float effective_shoaling = 1.0;
	if (coast_render_active) {
		if (coastal_warp_effect_debug == 2) effective_shoaling = shoaling;
		else if (coastal_warp_effect_debug == 0) effective_shoaling = mix(1.0, shoaling, warp_confidence);
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
	sea_state_zone_state(world_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);
	float pixel_long_coastal_height = mix(
		textureLod(displacement_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).y,
		textureLod(displacement_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).y,
		warp_confidence
	) * effective_shoaling;
	float pixel_long_remainder_height = textureLod(displacement_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).y;
	float pixel_mid_height = textureLod(displacement_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).y;
	float pixel_short_height = textureLod(displacement_short, spectrum_uv(world_xz, domain_short_m), 0.0).y;

	vec3 long_coastal_normal_warped = normalize(textureLod(normal_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rgb);
	vec3 long_coastal_normal_open = normalize(textureLod(normal_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rgb);
	vec2 slope_open = slope_from_normal(long_coastal_normal_open);
	vec2 slope_deep = slope_from_normal(long_coastal_normal_warped);
	vec2 slope_warped_world = vec2(warp_jacobian.r * slope_deep.x + warp_jacobian.b * slope_deep.y, warp_jacobian.g * slope_deep.x + warp_jacobian.a * slope_deep.y);
	vec2 slope_coastal = mix(slope_open, slope_warped_world, warp_confidence);
	vec2 slope = (slope_coastal * zone_long_amplitude * effective_shoaling + pixel_long_coastal_height * zone_grad_long)
		* coastal_weight * coastal_gain;
	slope += (slope_from_normal(normalize(textureLod(normal_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rgb)) * zone_long_amplitude + pixel_long_remainder_height * zone_grad_long) * remainder_weight;

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
	slope += (mid_center_slope * zone_mid_amplitude + pixel_mid_height * zone_grad_mid) * mid_weight * mid_short_weight;

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
	slope += (short_center_slope * zone_short_amplitude + pixel_short_height * zone_grad_short) * short_weight * mid_short_weight;

	// 5R.2: la cresta afilada 5R.1C es más empinada que la normal FFT base.
	slope *= 1.0 + crest_sharpen_mask * ocean_crest_sharpen_max_gain * 0.5;
	float shore_vertical_weight;
	float shore_horizontal_weight;
	shore_stabilization_weights(world_xz, metrics_data, shore_vertical_weight, shore_horizontal_weight);
	vec2 shore_vertical_gradient = shore_weight_gradient_from_fragment(world_xz, shore_vertical_weight);
	// Same product rule as the vertex path. The horizontal envelope changes
	// geometry topology, while the normal follows the vertical height envelope.
	slope = slope * shore_vertical_weight + shore_pre_envelope_height * shore_vertical_gradient;

	return normalize(vec3(-slope.x, 1.0, -slope.y));
}


// Production composition of the high-resolution persistent field. It mirrors
// the established coastal/open/deep coordinate policy while MID/SHORT provide
// a small non-saturating detail contribution.
vec4 pixel_ocean_crest_foam(vec2 world_xz) {
	float distance_to_camera = distance(world_xz, camera_world_xz);
	float long_weight = band_mask.x * distance_fade(long_fade_range_m, distance_to_camera);
	float mid_weight = band_mask.y * distance_fade(mid_fade_range_m, distance_to_camera);
	float short_weight = band_mask.z * distance_fade(short_fade_range_m, distance_to_camera);
	float zone_long_amplitude;
	float zone_mid_amplitude;
	float zone_short_amplitude;
	float zone_choppiness;
	vec2 zone_grad_long;
	vec2 zone_grad_mid;
	vec2 zone_grad_short;
	vec2 zone_grad_chop;
	float zone_foam_multiplier;
	sea_state_zone_state(world_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);

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

	vec2 coastal_open = textureLod(foam_long_coastal, spectrum_uv(world_xz, domain_long_coastal_m), 0.0).rg;
	vec2 coastal_warped = textureLod(foam_long_coastal, spectrum_uv(deep_xz, domain_long_coastal_m), 0.0).rg;
	vec2 coastal = mix(coastal_open, coastal_warped, warp_confidence) * coastal_gain;
	vec2 remainder = textureLod(foam_long_remainder, spectrum_uv(world_xz, domain_long_remainder_m), 0.0).rg;
	vec2 mid = textureLod(foam_mid, spectrum_uv(world_xz, domain_mid_m), 0.0).rg;
	vec2 short = textureLod(foam_short, spectrum_uv(world_xz, domain_short_m), 0.0).rg;
	float zone_foam_activity = sea_state_zone_foam_activity(
		zone_long_amplitude, zone_mid_amplitude, zone_short_amplitude,
		zone_choppiness, zone_foam_multiplier);

	vec2 long_base = clamp(coastal * coastal_weight + remainder * remainder_weight, 0.0, 1.0);
	// MID and SHORT remain physical contributors, but their addition is
	// complementary rather than linear so they cannot turn the whole field white.
	vec2 mid_detail = mid * (mid_weight * mid_short_weight) * foam_detail_contribution * 0.55;
	vec2 short_detail = short * (short_weight * mid_short_weight) * foam_detail_contribution * 0.30;
	vec2 detail_foam = 1.0 - (1.0 - mid_detail) * (1.0 - short_detail);
	vec2 combined = 1.0 - (1.0 - long_base) * (1.0 - detail_foam);
	// Existing residual is allowed a longer tail than fresh birth, while both
	// remain attached to the same local wave-state activity.
	combined *= vec2(mix(zone_foam_activity, 1.0, 0.25), zone_foam_activity);
	return vec4(clamp(combined, 0.0, 1.0), 0.5, 1.0);
}


const float SURFACE_FOAM_NEAR_END_M = 80.0;
const float SURFACE_FOAM_MID_END_M = 160.0;

float surface_foam_distance_weight(float distance_to_camera) {
	return 1.0 - smoothstep(
		surface_foam_distance_fade_start_m,
		max(surface_foam_distance_fade_end_m, surface_foam_distance_fade_start_m + 0.001),
		distance_to_camera
	);
}

float surface_foam_weight(float distance_to_camera) {
	// Dedicated distance policy. It deliberately does not inherit clipmap band
	// masks or short_fade_range_m, which made the persistent field read as a
	// texel block when the camera crossed a clipmap boundary.
	float composition_weight = (coastal_composition_debug == 0 || coastal_composition_debug == 4) ? 1.0 : 0.0;
	return surface_foam_distance_weight(distance_to_camera) * composition_weight;
}


// Native 512² source topology: no field resampling or presentation weight.
float surface_foam_direct_j_at(vec2 sample_position) {
	float jacobian = textureLod(
		surface_foam_jacobian,
		spectrum_uv(sample_position, surface_foam_source_domain_m),
		0.0
	).r;
	if (isnan(jacobian) || isinf(jacobian)) {
		jacobian = 1.0;
	}
	return jacobian;
}


float surface_foam_direct_j_raw_at(vec2 sample_position) {
	return max(0.0, surface_foam_whitecap - surface_foam_direct_j_at(sample_position));
}

vec2 surface_foam_topology_at(vec2 sample_position, vec2 world_dx, vec2 world_dy) {
	vec2 uv = spectrum_uv(sample_position, surface_foam_source_domain_m);
	return textureGrad(surface_foam_topology, uv, world_dx / surface_foam_source_domain_m * 0.5, (world_dy / surface_foam_source_domain_m) * 0.5).rg;
}


// Deterministic triangular world-space lattice. Each fragment blends the three
// vertex-owned transforms of its triangle, so cells meet continuously without
// a hard floor(world / cell) boundary. The hash has no time or camera input.
float surface_foam_stochastic_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


float surface_foam_stochastic_rotation_angle(vec2 lattice_vertex) {
	float index = floor(surface_foam_stochastic_hash12(lattice_vertex + vec2(17.0, 31.0)) * 8.0);
	if (index < 0.5) return 0.29670597; // 17 degrees
	if (index < 1.5) return 0.71558499; // 41 degrees
	if (index < 2.5) return 1.27409035; // 73 degrees
	if (index < 3.5) return 1.90240888; // 109 degrees
	if (index < 4.5) return 2.39110108; // 137 degrees
	if (index < 5.5) return 2.84488668; // 163 degrees
	if (index < 6.5) return 3.68264472; // 211 degrees
	return 4.48549618; // 257 degrees
}


float surface_foam_stochastic_scale(vec2 lattice_vertex) {
	return mix(0.91, 1.09, surface_foam_stochastic_hash12(lattice_vertex + vec2(89.0, 37.0)));
}


vec2 surface_foam_stochastic_rotate(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}


vec2 surface_foam_stochastic_transform_delta(vec2 delta, vec2 lattice_vertex) {
	delta *= surface_foam_stochastic_scale(lattice_vertex);
	delta = surface_foam_stochastic_rotate(delta, surface_foam_stochastic_rotation_angle(lattice_vertex));
	if (surface_foam_stochastic_hash12(lattice_vertex + vec2(47.0, 11.0)) > 0.5) delta.x *= -1.0;
	return delta;
}


vec2 surface_foam_lattice_vertex_world(vec2 lattice_vertex) {
	float cell_m = max(surface_foam_stochastic_cell_size_m, 0.001);
	return vec2(
		(lattice_vertex.x + 0.5 * lattice_vertex.y) * cell_m,
		lattice_vertex.y * (0.8660254037844386 * cell_m)
	);
}


vec2 surface_foam_stochastic_sample_position(vec2 world_xz, vec2 lattice_vertex, float domain_m) {
	vec2 vertex_world = surface_foam_lattice_vertex_world(lattice_vertex);
	vec2 local = world_xz - vertex_world;
	vec2 transformed = surface_foam_stochastic_rotate(
		local * surface_foam_stochastic_scale(lattice_vertex),
		surface_foam_stochastic_rotation_angle(lattice_vertex)
	);
	if (surface_foam_stochastic_hash12(lattice_vertex + vec2(47.0, 11.0)) > 0.5) {
		transformed.x = -transformed.x;
	}
	vec2 phase = vec2(
		surface_foam_stochastic_hash12(lattice_vertex + vec2(7.0, 53.0)),
		surface_foam_stochastic_hash12(lattice_vertex + vec2(71.0, 19.0))
	) * domain_m;
	return vertex_world + transformed + phase;
}


void surface_foam_stochastic_triangle(vec2 world_xz, out vec2 v0, out vec2 v1, out vec2 v2, out vec3 weights) {
	float cell_m = max(surface_foam_stochastic_cell_size_m, 0.001);
	// e0=(cell,0), e1=(cell/2,sqrt(3)*cell/2): world -> triangular lattice.
	vec2 lattice = vec2(
		world_xz.x / cell_m - world_xz.y / (1.7320508075688772 * cell_m),
		world_xz.y / (0.8660254037844386 * cell_m)
	);
	vec2 cell = floor(lattice);
	vec2 f = fract(lattice);
	if (f.x + f.y <= 1.0) {
		v0 = cell;
		v1 = cell + vec2(1.0, 0.0);
		v2 = cell + vec2(0.0, 1.0);
		weights = vec3(1.0 - f.x - f.y, f.x, f.y);
	} else {
		v0 = cell + vec2(1.0, 1.0);
		v1 = cell + vec2(0.0, 1.0);
		v2 = cell + vec2(1.0, 0.0);
		weights = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
	}
	// Smooth, normalized barycentric ownership keeps the value and its fade
	// continuous at every triangle edge without adding a noise texture.
	weights = weights * weights * (3.0 - 2.0 * weights);
	weights /= max(weights.x + weights.y + weights.z, 0.00001);
}


// Surface Foam and Crest Filigree share this exact Direct-J sampling work.
// Each keeps its own post-sample whitecap threshold; never blend J first.
void surface_foam_shared_direct_topologies(vec2 world_xz, out float surface_raw, out float crest_raw) {
	if (surface_foam_stochastic_deperiodization_enabled) {
		vec2 v0; vec2 v1; vec2 v2; vec3 weights;
		surface_foam_stochastic_triangle(world_xz, v0, v1, v2, weights);
		vec2 dx = dFdx(world_xz); vec2 dy = dFdy(world_xz);
		vec2 p0 = surface_foam_stochastic_sample_position(world_xz, v0, surface_foam_source_domain_m);
		vec2 p1 = surface_foam_stochastic_sample_position(world_xz, v1, surface_foam_source_domain_m);
		vec2 p2 = surface_foam_stochastic_sample_position(world_xz, v2, surface_foam_source_domain_m);
		vec2 t0 = surface_foam_topology_at(p0, surface_foam_stochastic_transform_delta(dx, v0), surface_foam_stochastic_transform_delta(dy, v0));
		vec2 t1 = surface_foam_topology_at(p1, surface_foam_stochastic_transform_delta(dx, v1), surface_foam_stochastic_transform_delta(dy, v1));
		vec2 t2 = surface_foam_topology_at(p2, surface_foam_stochastic_transform_delta(dx, v2), surface_foam_stochastic_transform_delta(dy, v2));
		vec2 topology = t0 * weights.x + t1 * weights.y + t2 * weights.z;
		surface_raw = topology.r; crest_raw = topology.g;
	} else {
		vec2 topology = surface_foam_topology_at(world_xz, dFdx(world_xz), dFdy(world_xz));
		surface_raw = topology.r; crest_raw = topology.g;
	}
}


vec2 surface_foam_stochastic_field_unweighted(vec2 world_xz) {
	vec2 v0; vec2 v1; vec2 v2; vec3 weights;
	surface_foam_stochastic_triangle(world_xz, v0, v1, v2, weights);
	vec2 field0 = textureLod(surface_foam_short, spectrum_uv(surface_foam_stochastic_sample_position(world_xz, v0, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	vec2 field1 = textureLod(surface_foam_short, spectrum_uv(surface_foam_stochastic_sample_position(world_xz, v1, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	vec2 field2 = textureLod(surface_foam_short, spectrum_uv(surface_foam_stochastic_sample_position(world_xz, v2, surface_foam_field_domain_m), surface_foam_field_domain_m), 0.0).rg;
	return field0 * weights.x + field1 * weights.y + field2 * weights.z;
}


// The field is temporal support, not the near visible silhouette. It uses the
// same stable lattice when stochastic deperiodization is enabled, then applies
// existing distance/composition policy only at final presentation.
vec2 pixel_ocean_surface_foam_field_unweighted(vec2 world_xz) {
	return surface_foam_stochastic_deperiodization_enabled
		? surface_foam_stochastic_field_unweighted(world_xz)
		: textureLod(surface_foam_short, spectrum_uv(world_xz, surface_foam_field_domain_m), 0.0).rg;
}


float surface_foam_macro_from_topology(float raw_topology, float history_envelope) {
	float persistent_gate = smoothstep(0.015, 0.32, history_envelope);
	float temporal_envelope = mix(0.46, 1.0, persistent_gate);
	return clamp(raw_topology * 2.05 * temporal_envelope, 0.0, 1.0);
}


// The Surface Foam macro remains an unsaturated, direct-J filament source.
// The history envelope above stabilizes its intensity but never replaces the
// topology, so Crest Foam inherits branches rather than the 88 m field shape.
float crest_filigree_source_from_macro(float crest_macro) {
	float thresholded = smoothstep(
		crest_filigree_threshold,
		max(1.0, crest_filigree_threshold + 0.001),
		clamp(crest_macro, 0.0, 1.0)
	);
	return pow(thresholded, 1.0 / max(crest_filigree_contrast, 0.1));
}


vec2 surface_foam_visual_xz() {
	// The vertex path already includes the physical horizontal FFT displacement
	// and any active coastal warp. This is a coordinate remap only: no new fetch.
	return ocean_base_xz + surface_foam_displacement_xz * clamp(surface_foam_ocean_coupling, 0.0, 1.0);
}


int surface_foam_lod(float camera_distance) {
	return camera_distance < SURFACE_FOAM_NEAR_END_M ? 0 : camera_distance < SURFACE_FOAM_MID_END_M ? 1 : 2;
}


float surface_foam_micro_thresholded(vec2 world_xz, float camera_distance, float physical_mask, float base_threshold, out float breakup_value, out vec2 microheight_gradient) {
	// Far is history-only: no micro fetch, no bubble work and no derivative
	// reconstruction. Mid gets one RGB sample; Near gets at most two.
	breakup_value = 0.5;
	microheight_gradient = vec2(0.0);
	int lod = surface_foam_lod(camera_distance);
	float history_shaped = smoothstep(base_threshold, 1.0, physical_mask);
	if (lod >= 2 || !surface_foam_micro_detail_enabled || !surface_foam_micro_texture_ready || physical_mask <= 0.00001) {
		return history_shaped;
	}
	vec2 world_dx = dFdx(world_xz);
	vec2 world_dy = dFdy(world_xz);
	vec2 medium_uv = world_xz / max(surface_foam_micro_scale_m.x, 0.5);
	vec2 medium_dx = world_dx / max(surface_foam_micro_scale_m.x, 0.5);
	vec2 medium_dy = world_dy / max(surface_foam_micro_scale_m.x, 0.5);
	vec3 medium = textureGrad(surface_foam_micro_texture, medium_uv, medium_dx, medium_dy).rgb;
	vec3 combined = medium;
	if (lod == 0) {
		mat2 rotation = mat2(vec2(0.70710678, -0.70710678), vec2(0.70710678, 0.70710678));
		vec2 fine_uv = rotation * world_xz / max(surface_foam_micro_scale_m.y, 0.5) + vec2(0.371, 0.619);
		vec2 fine_dx = rotation * world_dx / max(surface_foam_micro_scale_m.y, 0.5);
		vec2 fine_dy = rotation * world_dy / max(surface_foam_micro_scale_m.y, 0.5);
		vec3 fine = textureGrad(surface_foam_micro_texture, fine_uv, fine_dx, fine_dy).rgb;
		combined = mix(medium, fine, 0.38);
	}
	breakup_value = combined.r;
	// B is the packed microheight. Its derivatives provide the subtle foam
	// normal without an additional texture fetch.
	microheight_gradient = vec2(dFdx(combined.b), dFdy(combined.b));
	float near_weight = lod == 0 ? 1.0 : 0.45;
	float edge_factor = 4.0 * physical_mask * (1.0 - physical_mask);
	float threshold_offset = (combined.r - 0.5) * surface_foam_micro_strength * near_weight * (0.35 + 0.65 * edge_factor);
	float softness = max(fwidth(physical_mask) * 1.5, 0.018);
	float shaped = smoothstep(base_threshold + threshold_offset - softness, base_threshold + threshold_offset + softness, physical_mask);
	// Bubble interiors are deliberately sparse: only a fraction of the
	// distance-field interior can open, and only where the physical mask exists.
	float bubble_aa = max(fwidth(combined.g) * 1.5, 0.02);
	float bubble_ring = 1.0 - smoothstep(0.16 - bubble_aa, 0.16 + bubble_aa, abs(combined.g - 0.5));
	float bubble_hole = bubble_ring * smoothstep(0.56, 0.88, combined.r) * (lod == 0 ? 0.18 : 0.12);
	return shaped * (1.0 - bubble_hole * smoothstep(0.30, 0.82, physical_mask));

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


// The detail carrier is blended between the final displaced position and the
// undisplaced water/material coordinate. This keeps the control optical-only:
// it follows the wave parametrization without changing FFT geometry or energy.
vec2 surface_detail_carrier_xz() {
	return mix(
		ocean_world_xz,
		ocean_base_xz,
		clamp(surface_detail_wave_follow, 0.0, 1.0)
	);
}


// 5R.3B: mismo concepto de micro-normal que Water Race.
// Devuelve normal local donde XY se interpreta como slope world XZ.
// carrier_xz is intentionally separate from the independent flow terms so a
// future local coastal direction can be introduced without rewriting sampling.
vec3 sample_surface_detail(vec2 carrier_xz, float camera_distance) {
	vec2 warp = vec2(0.0);
	if (ocean_surface_detail_quality >= 2) {
		vec2 warp_uv = carrier_xz / max(surface_warp_world_size, 0.001)
			+ vec2(0.31, -0.95) * coastal_time_s * 0.035;
		warp = (texture(surface_warp_texture, warp_uv).rg * 2.0 - 1.0)
			* surface_warp_strength;
	}

	vec2 uv_a = (carrier_xz + warp) / max(surface_normal_world_size_a, 0.001)
		+ surface_safe_direction(surface_flow_direction_a, vec2(1.0, 0.0))
			* coastal_time_s * surface_flow_speed_a
			/ max(surface_normal_world_size_a, 0.001);
	vec2 uv_b = (carrier_xz - warp * 0.57) / max(surface_normal_world_size_b, 0.001)
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


bool water_optics_world_position_from_depth(vec2 screen_uv, float raw_depth,
		mat4 inverse_projection, mat4 inverse_view, out vec3 world_position) {
	world_position = vec3(0.0);
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001 ||
			isnan(raw_depth) || isinf(raw_depth)) {
		return false;
	}
	vec4 view_position = inverse_projection * vec4(screen_uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.000001 || any(isnan(view_position)) || any(isinf(view_position))) {
		return false;
	}
	view_position /= view_position.w;
	vec4 world_position_h = inverse_view * vec4(view_position.xyz, 1.0);
	if (abs(world_position_h.w) <= 0.000001 || any(isnan(world_position_h)) || any(isinf(world_position_h))) {
		return false;
	}
	world_position = world_position_h.xyz / world_position_h.w;
	if (any(isnan(world_position)) || any(isinf(world_position))) {
		world_position = vec3(0.0);
		return false;
	}
	return true;
}


const float WATER_OPTICS_EPSILON = 0.0001;
const float WATER_OPTICS_EDGE_FADE_UV = 0.02;
const float WATER_OPTICS_FOREGROUND_MARGIN_M = 0.10;
const float WATER_OPTICS_TOLERANCE_THICKNESS_FACTOR = 0.08;


vec2 water_optics_project_view_position(vec3 view_position, mat4 projection,
		out bool valid) {
	vec4 clip_position = projection * vec4(view_position, 1.0);
	if (clip_position.w <= WATER_OPTICS_EPSILON
			|| any(isnan(clip_position)) || any(isinf(clip_position))) {
		valid = false;
		return vec2(0.0);
	}
	vec2 uv = clip_position.xy / clip_position.w * 0.5 + 0.5;
	valid = !(any(isnan(uv)) || any(isinf(uv)));
	return uv;
}


float water_optics_edge_confidence(vec2 uv) {
	float distance_to_edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	return smoothstep(0.0, WATER_OPTICS_EDGE_FADE_UV, distance_to_edge);
}


const int NEAR_SSR_COARSE_STEPS = 16;
const int NEAR_SSR_REFINEMENT_STEPS = 3;
const float NEAR_SSR_START_EPSILON_M = 0.05;


vec2 near_ssr_project_view_position(vec3 view_position, mat4 projection,
		out bool valid) {
	vec4 clip_position = projection * vec4(view_position, 1.0);
	if (clip_position.w <= 0.0001) {
		valid = false;
		return vec2(0.0);
	}
	vec2 uv = clip_position.xy / clip_position.w * 0.5 + 0.5;
	valid = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
	return uv;
}


float near_ssr_depth_delta(vec3 ray_view_position, vec2 uv,
		mat4 inverse_projection, out bool valid) {
	float raw_depth = textureLod(depth_texture, uv, 0.0).r;
	// Forward+ reversed-Z clear depth is zero: sky is not a ray hit.
	if (raw_depth <= 0.000001) {
		valid = false;
		return 0.0;
	}
	float scene_depth = linear_depth_from_buffer(uv, raw_depth, inverse_projection);
	valid = scene_depth > 0.0;
	return -ray_view_position.z - scene_depth;
}


vec3 reflection_near_ssr(vec3 water_position_view, vec3 macro_normal_view,
		vec3 view_direction, vec3 flat_normal_view, float camera_distance,
		float final_roughness, mat4 projection, mat4 inverse_projection,
		out float active_mask, out float confidence, out float hit_mask,
		out float depth_confidence, out float deviation_confidence,
		out float base_confidence, out float step_usage,
		out float hit_distance_output) {
	active_mask = 0.0;
	confidence = 0.0;
	hit_mask = 0.0;
	depth_confidence = 0.0;
	deviation_confidence = 0.0;
	base_confidence = 0.0;
	step_usage = 0.0;
	hit_distance_output = 0.0;
	float distance_limit = max(reflection_near_ssr_distance_m, 0.001);
	float distance_fade = 1.0 - smoothstep(
		max(distance_limit - reflection_near_ssr_fade_m, 0.0),
		distance_limit,
		camera_distance
	);
	float roughness_fade = 1.0 - smoothstep(0.55, 0.90, final_roughness);
	if (!reflection_near_ssr_enabled || camera_distance >= distance_limit
			|| distance_fade <= 0.001 || roughness_fade <= 0.001) {
		return vec3(0.0);
	}

	vec3 planar_ray = normalize(reflect(-view_direction, flat_normal_view));
	vec3 macro_ray = normalize(reflect(-view_direction, macro_normal_view));
	float ray_deviation = 1.0 - clamp(dot(planar_ray, macro_ray), 0.0, 1.0);
	float deviation_fade = smoothstep(0.002, 0.08, ray_deviation);
	deviation_confidence = deviation_fade;
	// Flat water takes the existing SSPR path without paying for a raymarch.
	if (deviation_fade <= 0.001 || macro_ray.z >= -0.001) {
		return vec3(0.0);
	}
	float potential_confidence = clamp(
		distance_fade * roughness_fade * deviation_fade,
		0.0,
		1.0
	);
	base_confidence = potential_confidence;
	if (potential_confidence < 0.01) {
		return vec3(0.0);
	}

	active_mask = 1.0;
	float start_distance = NEAR_SSR_START_EPSILON_M;
	float ray_length = max(reflection_near_ssr_ray_length_m, 25.0);
	int max_coarse_steps = NEAR_SSR_COARSE_STEPS;
	int max_refinement_steps = NEAR_SSR_REFINEMENT_STEPS;
	if (reflection_near_ssr_quality <= 0) {
		max_coarse_steps = 8;
		max_refinement_steps = 2;
	} else if (reflection_near_ssr_quality == 1) {
		max_coarse_steps = 12;
		max_refinement_steps = 2;
	}
	float adaptive_signal = max(distance_fade, deviation_fade);
	float adaptive_budget = mix(0.75, 1.0, adaptive_signal);
	int effective_coarse_steps = int(ceil(float(max_coarse_steps) * adaptive_budget));
	if (effective_coarse_steps < 4) {
		effective_coarse_steps = 4;
	}
	int effective_refinement_steps = max_refinement_steps;
	if (adaptive_budget < 0.90 && effective_refinement_steps > 2) {
		effective_refinement_steps -= 1;
	}
	float previous_distance = start_distance;
	float previous_delta = -reflection_near_ssr_thickness;
	float bracket_low = 0.0;
	float bracket_high = 0.0;
	vec2 bracket_high_uv = vec2(0.0);
	float bracket_high_delta = 0.0;
	bool bracket_found = false;
	int coarse_steps_used = 0;
	for (int step = 0; step < NEAR_SSR_COARSE_STEPS; step++) {
		if (step >= effective_coarse_steps) {
			break;
		}
		coarse_steps_used = step + 1;
		float normalized_step = float(step + 1) / float(effective_coarse_steps);
		float ray_distance = start_distance + ray_length * normalized_step * normalized_step;
		vec3 ray_position = water_position_view + macro_ray * ray_distance;
		bool uv_valid = false;
		vec2 ray_uv = near_ssr_project_view_position(ray_position, projection, uv_valid);
		if (!uv_valid) {
			break;
		}
		bool depth_valid = false;
		float depth_delta = near_ssr_depth_delta(
				ray_position, ray_uv, inverse_projection, depth_valid);
		if (!depth_valid) {
			previous_distance = ray_distance;
			previous_delta = -reflection_near_ssr_thickness;
			continue;
		}
		if ((depth_delta >= 0.0 && depth_delta <= reflection_near_ssr_thickness)
				|| (previous_delta < 0.0 && depth_delta > reflection_near_ssr_thickness)) {
			bracket_low = previous_distance;
			bracket_high = ray_distance;
			bracket_high_uv = ray_uv;
			bracket_high_delta = depth_delta;
			bracket_found = true;
			break;
		}
		previous_distance = ray_distance;
		previous_delta = depth_delta;
	}
	step_usage = clamp(
		float(coarse_steps_used) / float(max_coarse_steps),
		0.0,
		1.0
	);
	if (!bracket_found) {
		return vec3(0.0);
	}

	float hit_distance = bracket_high;
	vec2 hit_uv = bracket_high_uv;
	float hit_delta = bracket_high_delta;
	for (int refinement = 0; refinement < NEAR_SSR_REFINEMENT_STEPS; refinement++) {
		if (refinement >= effective_refinement_steps) {
			break;
		}
		float test_distance = (bracket_low + bracket_high) * 0.5;
		vec3 test_position = water_position_view + macro_ray * test_distance;
		bool uv_valid = false;
		vec2 test_uv = near_ssr_project_view_position(test_position, projection, uv_valid);
		if (!uv_valid) {
			bracket_high = test_distance;
			continue;
		}
		bool depth_valid = false;
		float test_delta = near_ssr_depth_delta(
				test_position, test_uv, inverse_projection, depth_valid);
		if (depth_valid && test_delta >= 0.0) {
			bracket_high = test_distance;
			hit_distance = test_distance;
			hit_uv = test_uv;
			hit_delta = test_delta;
		} else {
			bracket_low = test_distance;
		}
	}
	float edge_fade = smoothstep(
		0.0,
		0.08,
		min(min(hit_uv.x, 1.0 - hit_uv.x), min(hit_uv.y, 1.0 - hit_uv.y))
	);
	float travel_fade = 1.0 - smoothstep(0.0, ray_length, hit_distance);
	// A refined crossing is already a valid intersection. Depth only rejects
	// clearly incompatible thickness, instead of demanding a nearly zero delta.
	depth_confidence = 1.0 - smoothstep(
		max(reflection_near_ssr_thickness * 0.75, 0.001),
		max(reflection_near_ssr_thickness * 1.5, 0.002),
		abs(hit_delta)
	);
	base_confidence = clamp(distance_fade * edge_fade * roughness_fade, 0.0, 1.0);
	float travel_confidence = mix(0.82, 1.0, travel_fade);
	float bracket_width = max(bracket_high - bracket_low, 0.0);
	float bracket_confidence = 1.0 - smoothstep(
		ray_length * 0.05,
		ray_length * 0.20,
		bracket_width
	);
	confidence = clamp(
		base_confidence * depth_confidence * travel_confidence
			* mix(0.90, 1.0, bracket_confidence),
		0.0,
		1.0
	);
	hit_mask = 1.0;
	hit_distance_output = hit_distance;
	ivec2 screen_size = textureSize(screen_texture, 0);
	float screen_mip_max = max(log2(float(max(screen_size.x, screen_size.y))), 0.0);
	float screen_lod = reflection_distance_blur_lod(
		final_roughness, hit_distance, screen_mip_max);
	return textureLod(screen_texture, hit_uv, screen_lod).rgb;
}


// Recover dFoam/dWorldXZ from derivatives already available in fragment. This
// adds no foam texture reads and falls back safely at grazing/degenerate pixels.
vec2 foam_gradient_world(vec2 foam_value, vec2 world_xz) {
	vec2 world_dx = dFdx(world_xz);
	vec2 world_dy = dFdy(world_xz);
	float foam_dx = dFdx(foam_value.x);
	float foam_dy = dFdy(foam_value.x);
	float determinant = world_dx.x * world_dy.y - world_dx.y * world_dy.x;
	if (abs(determinant) < 0.00001) {
		return vec2(0.0);
	}
	return vec2(
		(foam_dx * world_dy.y - world_dx.y * foam_dy) / determinant,
		(world_dx.x * foam_dy - foam_dx * world_dy.x) / determinant
	);
}


void fragment() {
	// Routing sentinels intentionally run before foam, depth, screen, bathymetry,
	// scattering and reflection work. They prove the complete Inspector -> CPU
	// -> material -> rendered clipmap -> fragment route without any data inputs.
	if (water_optics_debug_mode == 24) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		EMISSION = vec3(1.0, 0.0, 1.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		RADIANCE = vec4(0.0);
		ALPHA = 1.0;
	}
	else if (water_optics_debug_mode == 25) {
		ALBEDO = vec3(0.0, 1.0, 0.0);
		EMISSION = vec3(0.0, 1.0, 0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		RADIANCE = vec4(0.0);
		ALPHA = 1.0;
	}
	else {
		vec3 color = base_color;
	vec4 hires_foam_composition = vec4(0.0);
	if (perf_crest_foam_solver_enabled) {
		hires_foam_composition = pixel_ocean_crest_foam(ocean_base_xz);
	}
	vec2 surface_foam_world_xz = surface_foam_visual_xz();
	vec2 raw_foam_channels = hires_foam_composition.xy;
	float raw_residual = clamp(raw_foam_channels.r * foam_residual_strength, 0.0, 1.0);
	float raw_fresh = clamp(raw_foam_channels.g * foam_fresh_strength, 0.0, 1.0);
	float raw_foam = 1.0 - (1.0 - raw_residual) * (1.0 - raw_fresh);
	vec2 surface_foam_field_unweighted = vec2(0.0);
	if (perf_surface_foam_solver_enabled && perf_surface_foam_render_enabled) {
		surface_foam_field_unweighted = pixel_ocean_surface_foam_field_unweighted(surface_foam_world_xz);
	}
	float zone_long_amplitude;
	float zone_mid_amplitude;
	float zone_short_amplitude;
	float zone_choppiness;
	vec2 zone_grad_long;
	vec2 zone_grad_mid;
	vec2 zone_grad_short;
	vec2 zone_grad_chop;
	float zone_foam_multiplier;
	sea_state_zone_state(ocean_base_xz, zone_long_amplitude, zone_mid_amplitude,
		zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
		zone_grad_short, zone_grad_chop, zone_foam_multiplier);
	float zone_foam_activity = sea_state_zone_foam_activity(
		zone_long_amplitude, zone_mid_amplitude, zone_short_amplitude,
		zone_choppiness, zone_foam_multiplier);
	float zone_calmness = sea_state_zone_calmness(
		zone_long_amplitude, zone_mid_amplitude, zone_short_amplitude, zone_choppiness);
	// Debug values use the same stable macronormal and local state as production;
	// Surface Detail is intentionally excluded because it is visual distortion,
	// not physical wave activity.
	float debug_camera_distance = distance(ocean_world_xz, camera_world_xz);
	float debug_footprint = max(fwidth(ocean_world_xz.x), fwidth(ocean_world_xz.y));
	vec2 debug_reflection_metrics = vec2(0.0);
	if (perf_spectral_enabled) {
		debug_reflection_metrics = reflection_unresolved_detail_metrics(
			ocean_base_xz, debug_footprint, zone_mid_amplitude, zone_short_amplitude);
	}
	float debug_slope_variance = debug_reflection_metrics.y;
	float debug_reflection_roughness = physical_ocean_roughness(
		debug_camera_distance, debug_footprint, debug_reflection_metrics);
	debug_reflection_roughness = reflection_crest_shaped_roughness(
		debug_reflection_roughness, reflection_and_mono_state.x, debug_reflection_metrics);
	float debug_sun_specular = 0.0;
	// Keep Surface Foam's independent history/topology intact; only its
	// presentation contribution is locally attenuated by the zone state.
	float surface_foam_raw_topology = 0.0;
	float surface_foam_macro = 0.0;
	float crest_filigree_raw_topology = 0.0;
	float crest_filigree_macro = 0.0;
	float surface_foam_shaped = 0.0;
	float surface_foam_final_no_micro = 0.0;
	float surface_foam_final_no_edge = 0.0;
	float surface_foam_micro_noise = 0.5;
	float surface_foam_edge_fade = 0.0;
	float foam_mask = 0.0;
	float foam_fresh_mask = 0.0;
	float foam_residual_mask = 0.0;
	float crest_foam_mask = 0.0;
	float surface_foam_mask = 0.0;
	float surface_foam_mid_fold_history_value = 0.0;
	float crest_filigree_source = 0.0;
	float crest_filigree_mask = 0.0;
	float crest_fresh_webbed = 0.0;
	float crest_residual_webbed = 0.0;
	vec2 foam_shape_gradient = vec2(0.0);
	vec2 surface_foam_microheight_gradient = vec2(0.0);
	float surface_foam_camera_distance = 0.0;
	// One shared Direct-J sampling pass supplies both post-threshold topologies.
	// The temporal field remains the common envelope, never a second history.
	if (foam_enabled && perf_surface_foam_solver_enabled && perf_surface_foam_render_enabled && (surface_foam_enabled || crest_filigree_enabled)) {
		surface_foam_shared_direct_topologies(
			ocean_base_xz,
			surface_foam_raw_topology,
			crest_filigree_raw_topology
		);
		surface_foam_macro = surface_foam_macro_from_topology(
			surface_foam_raw_topology,
			surface_foam_field_unweighted.x
		);
		crest_filigree_macro = surface_foam_macro_from_topology(
			crest_filigree_raw_topology,
			surface_foam_field_unweighted.x
		);
		surface_foam_macro *= zone_foam_activity;
		crest_filigree_macro *= zone_foam_activity;
	}
	if (foam_enabled && (perf_crest_foam_solver_enabled || (perf_surface_foam_solver_enabled && perf_surface_foam_render_enabled))) {
		float visual_threshold = clamp(foam_threshold, 0.0, 0.999);
		float thresholded_foam = smoothstep(visual_threshold, 1.0, raw_foam);
		// Smooth monotonic response: contrast changes curvature, while intensity
		// remains a post-shape multiplier and never shifts the effective threshold.
		float shaped_mask = pow(thresholded_foam, 1.0 / max(foam_contrast, 0.1));
		float crest_distance_fade = 1.0 - smoothstep(
			foam_distance_fade_start,
			max(foam_distance_fade_end, foam_distance_fade_start + 0.001),
			distance(ocean_world_xz, camera_world_xz)
		);
		float breakup = foam_breakup_mask(ocean_base_xz);
		float intensity = clamp(foam_intensity, 0.0, 4.0);
		// Preserve the public response through intensity 1.0, then apply a soft
		// knee above it so high intensity cannot flatten all weak regions to white.
		float intensity_gain = intensity <= 1.0
			? intensity
			: 1.0 + (intensity - 1.0) / (1.0 + (intensity - 1.0) * 1.5);
		crest_foam_mask = clamp(shaped_mask * breakup * intensity_gain * crest_distance_fade, 0.0, 1.0);
		float raw_channel_sum = max(raw_residual + raw_fresh, 0.00001);
		foam_fresh_mask = crest_foam_mask * raw_fresh / raw_channel_sum;
		foam_residual_mask = crest_foam_mask * raw_residual / raw_channel_sum;
		crest_fresh_webbed = foam_fresh_mask;
		crest_residual_webbed = foam_residual_mask;
		if (crest_filigree_enabled) {
			crest_filigree_source = crest_filigree_source_from_macro(crest_filigree_macro);
			// The physical Crest mask is the hard support: branches cannot create
			// foam anywhere a crest accumulator did not already produce it.
			crest_filigree_mask = crest_foam_mask * crest_filigree_source;
			// Per-channel erosion, not a raw crest + pattern sum. Fresh keeps a
			// compact body while residual follows the branches and opens more holes.
			crest_fresh_webbed = foam_fresh_mask * mix(
				1.0,
				crest_filigree_source,
				clamp(crest_fresh_filigree_strength, 0.0, 1.0)
			);
			crest_residual_webbed = foam_residual_mask * mix(
				1.0,
				crest_filigree_source,
				clamp(crest_residual_filigree_strength, 0.0, 1.0)
			);
			foam_fresh_mask = crest_fresh_webbed;
			foam_residual_mask = crest_residual_webbed;
			crest_foam_mask = clamp(crest_fresh_webbed + crest_residual_webbed, 0.0, 1.0);
		}

		if (surface_foam_enabled && perf_surface_foam_solver_enabled && perf_surface_foam_render_enabled) {
			surface_foam_camera_distance = distance(surface_foam_world_xz, camera_world_xz);
			float surface_threshold = clamp(surface_foam_threshold_visual, 0.0, 0.999);
			// Direct macro is the silhouette. Strength and distance are post-shape
			// gains only; threshold/contrast cannot turn it into dots.
			surface_foam_final_no_micro = clamp(
				surface_foam_macro * surface_foam_strength * surface_foam_weight(surface_foam_camera_distance),
				0.0,
				1.0
			);
			float surface_thresholded = surface_foam_micro_thresholded(
				surface_foam_world_xz,
				surface_foam_camera_distance,
				surface_foam_macro,
				surface_threshold,
				surface_foam_micro_noise,
				surface_foam_microheight_gradient
			);
			surface_foam_shaped = surface_thresholded;
			// Micro breakup is subtractive at this stage: it can erode the current
			// macro silhouette, but cannot lower its threshold and create coverage
			// outside the physical current-core/residual support.
			surface_foam_final_no_edge = min(
				clamp(surface_foam_shaped * surface_foam_strength, 0.0, 1.0),
				surface_foam_final_no_micro
			);
			// Edge fade follows the direct macro, never the temporal envelope R.
			float edge_width = clamp(surface_foam_edge_fade_width, 0.01, 0.5);
			float edge_aa = max(fwidth(surface_foam_macro) * 1.5, 0.01);
			float edge_low = max(surface_threshold - edge_width - edge_aa, 0.0);
			float edge_high = min(surface_threshold + edge_width + edge_aa, 1.0);
			float edge_band = smoothstep(edge_low, edge_high, surface_foam_macro)
				* (1.0 - smoothstep(surface_threshold + edge_width * 0.8, surface_threshold + edge_width * 2.4 + edge_aa, surface_foam_macro));
			float edge_selector = smoothstep(0.50, 0.86, surface_foam_micro_noise);
			surface_foam_edge_fade = clamp(edge_band * edge_selector * surface_foam_edge_fade_strength, 0.0, 1.0);
			surface_foam_mask = clamp(surface_foam_final_no_edge * (1.0 - surface_foam_edge_fade), 0.0, 1.0);
			// The MID Jacobian updates this persistent eligibility field in compute.
			// Its release is physical-time based, never tied to MID render LOD/fade.
			if (perf_mid_fold_history_enabled) {
				surface_foam_mid_fold_history_value = textureLod(
					surface_foam_mid_fold_history,
					spectrum_uv(ocean_base_xz, domain_mid_m),
					0.0
				).r;
			}
			surface_foam_mask *= surface_foam_mid_fold_history_value;
		}
		foam_mask = 1.0 - (1.0 - crest_foam_mask) * (1.0 - surface_foam_mask);
		foam_shape_gradient = foam_gradient_world(vec2(foam_mask, 0.0), ocean_world_xz);
	}

	// Build the final visual normal once. The same normal feeds Godot's PBR
	// environment and direct-light lobes; FFT remains the geometry authority.
	vec3 shading_normal_world;
	if (ocean_normal_fragment && perf_spectral_enabled) {
		shading_normal_world = pixel_ocean_normal(ocean_base_xz);
	} else {
		shading_normal_world = normalize(derived_normal);
	}
	// SSPR distortion follows the filtered FFT wave normal before foam and
	// centimeter-scale surface detail are applied. PBR keeps visual_normal
	// below, including every existing foam/microdetail contribution.
	vec3 sspr_macro_normal_world = normalize(shading_normal_world);
	vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
	float camera_distance = distance(ocean_world_xz, camera_world_xz);
	float foam_normal_mask = foam_fresh_mask * foam_fresh_normal_weight
		+ foam_residual_mask * foam_residual_normal_weight
		+ surface_foam_mask * surface_foam_normal_strength
		+ crest_filigree_mask * crest_filigree_normal_influence;
	if (foam_normal_mask > 0.0001 && foam_normal_strength > 0.0) {
		vec3 foam_shape_normal_world = normalize(vec3(
			-foam_shape_gradient.x * foam_normal_strength,
			1.0,
			-foam_shape_gradient.y * foam_normal_strength
		));
		vec3 foam_shape_offset_view = mat3(VIEW_MATRIX) * vec3(
			foam_shape_normal_world.x / max(foam_shape_normal_world.y, 0.08),
			0.0,
			foam_shape_normal_world.z / max(foam_shape_normal_world.y, 0.08)
		);
		visual_normal = normalize(visual_normal + foam_shape_offset_view * foam_normal_mask);
	}
	if (surface_foam_mask > 0.0001 && surface_foam_micro_normal_strength > 0.0) {
		vec3 micro_normal_world = normalize(vec3(
			-surface_foam_microheight_gradient.x * surface_foam_micro_normal_strength,
			1.0,
			-surface_foam_microheight_gradient.y * surface_foam_micro_normal_strength
		));
		vec3 micro_offset_view = mat3(VIEW_MATRIX) * vec3(
			micro_normal_world.x / max(micro_normal_world.y, 0.08),
			0.0,
			micro_normal_world.z / max(micro_normal_world.y, 0.08)
		);
		visual_normal = normalize(visual_normal + micro_offset_view * surface_foam_mask);
	}
	vec3 surface_detail_offset_view = vec3(0.0);
	if (surface_detail_enabled) {
		vec3 detail_normal = sample_surface_detail(surface_detail_carrier_xz(), camera_distance);
		vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
		surface_detail_offset_view = mat3(VIEW_MATRIX) * vec3(
			detail_slope.x,
			0.0,
			detail_slope.y
		);
		float foam_micro_gain = 1.0 + foam_micro_normal_strength * foam_mask;
		visual_normal = normalize(visual_normal + surface_detail_offset_view * surface_normal_strength * foam_micro_gain);
	}
	NORMAL = visual_normal;

	vec3 view_direction = normalize(VIEW);
	debug_sun_specular = sun_specular_brdf(
		normalize(visual_normal), view_direction, debug_reflection_roughness);
	float fresnel = physical_water_fresnel(visual_normal, view_direction);
	float reflection_pixel_footprint = max(fwidth(ocean_world_xz.x), fwidth(ocean_world_xz.y));
	vec2 reflection_detail_metrics = vec2(0.0);
	if (perf_spectral_enabled) {
		reflection_detail_metrics = reflection_unresolved_detail_metrics(
			ocean_base_xz, reflection_pixel_footprint, zone_mid_amplitude, zone_short_amplitude);
	}
	float water_reflection_roughness = physical_ocean_roughness(
		camera_distance, reflection_pixel_footprint, reflection_detail_metrics);
	water_reflection_roughness = reflection_crest_shaped_roughness(
		water_reflection_roughness, reflection_and_mono_state.x, reflection_detail_metrics);
	float sspr_filter_roughness = reflection_final_roughness(
		water_reflection_roughness, surface_foam_mask, foam_residual_mask, foam_fresh_mask);
	vec3 final_normal_world = normalize((INV_VIEW_MATRIX * vec4(visual_normal, 0.0)).xyz);
	vec3 sspr_macro_normal_view = normalize((VIEW_MATRIX * vec4(sspr_macro_normal_world, 0.0)).xyz);
	vec3 flat_normal_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	mat4 projection_matrix = PROJECTION_MATRIX;
	mat4 inverse_projection_matrix = INV_PROJECTION_MATRIX;
	vec2 projection_scale = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
	float sspr_distortion_confidence = 0.0;
	vec2 sspr_distorted_uv = SCREEN_UV;
	vec4 sspr_distorted_sample = vec4(0.0);
	float sspr_confidence = 0.0;
	float sspr_facet_confidence = 1.0;
	if (reflection_sspr_enabled && reflection_sspr_available) {
		ivec2 sspr_size = textureSize(reflection_sspr_texture, 0);
		float sspr_mip_max = max(log2(float(max(sspr_size.x, sspr_size.y))), 0.0);
		sspr_distorted_uv = reflection_sspr_distorted_uv(
			SCREEN_UV,
			sspr_macro_normal_view,
			view_direction,
			camera_distance,
			flat_normal_view,
			projection_scale,
			sspr_distortion_confidence
		);
		float uv_inside = float(
			sspr_distorted_uv.x >= 0.0 && sspr_distorted_uv.x <= 1.0
			&& sspr_distorted_uv.y >= 0.0 && sspr_distorted_uv.y <= 1.0
		);
		vec3 sspr_source_world = vec3(0.0);
		bool sspr_source_valid = false;
		bool sspr_source_info_needed = reflection_sspr_depth_available
			&& (reflection_sspr_facet_gate_enabled || reflection_distance_blur_enabled);
		if (uv_inside > 0.5 && sspr_source_info_needed) {
			float reflected_virtual_depth = textureLod(
				reflection_sspr_depth_texture, sspr_distorted_uv, 0.0).r;
			sspr_source_valid = reflection_sspr_source_from_depth(
				sspr_distorted_uv,
				reflected_virtual_depth,
				INV_PROJECTION_MATRIX,
				INV_VIEW_MATRIX,
				reflection_sspr_sea_level,
				sspr_source_world
			);
		}
		float sspr_source_distance_m = 0.0;
		if (sspr_source_valid) {
			sspr_source_distance_m = distance(ocean_world_position, sspr_source_world);
			sspr_source_valid = sspr_source_distance_m > 0.001;
		}
		float sspr_lod = reflection_distance_blur_lod(
			sspr_filter_roughness, sspr_source_distance_m, sspr_mip_max);
		sspr_distorted_sample = textureLod(
			reflection_sspr_texture, sspr_distorted_uv, sspr_lod);
		float roughness_confidence = 1.0 - smoothstep(0.55, 0.90, water_reflection_roughness);
		float sspr_validity = sspr_distorted_sample.a;
		if (!reflection_sspr_hole_fill_enabled && sspr_validity < 0.99) {
			sspr_validity = 0.0;
		}
		sspr_confidence = clamp(
			sspr_validity
			* reflection_sspr_edge_confidence(sspr_distorted_uv)
			* sspr_distortion_confidence
			* reflection_sspr_slope_confidence(sspr_macro_normal_world)
			* roughness_confidence
			* uv_inside,
			0.0,
			1.0
		);
		if (sspr_source_valid && sspr_distorted_sample.a > 0.001
				&& reflection_sspr_facet_gate_enabled) {
			vec3 view_direction_world = normalize((INV_VIEW_MATRIX
				* vec4(view_direction, 0.0)).xyz);
			vec3 macro_reflection_ray_world = normalize(reflect(
				-view_direction_world, sspr_macro_normal_world));
			vec3 direction_to_source_world = normalize(
				sspr_source_world - ocean_world_position);
			sspr_facet_confidence = reflection_sspr_facet_confidence(
				macro_reflection_ray_world,
				direction_to_source_world,
				sspr_filter_roughness
			);
			float facet_gate = mix(
				1.0,
				sspr_facet_confidence,
				clamp(reflection_sspr_facet_gate_strength, 0.0, 1.0)
			);
			sspr_confidence *= facet_gate;
		}
	}
	vec3 water_position_view = (VIEW_MATRIX * vec4(ocean_world_position, 1.0)).xyz;
	float near_ssr_active = 0.0;
	float near_ssr_confidence = 0.0;
	float near_ssr_hit = 0.0;
	float near_ssr_depth_confidence = 0.0;
	float near_ssr_deviation_confidence = 0.0;
	float near_ssr_base_confidence = 0.0;
	float near_ssr_step_usage = 0.0;
	float near_ssr_hit_distance = 0.0;
	vec3 near_ssr_color = reflection_near_ssr(
		water_position_view,
		sspr_macro_normal_view,
		view_direction,
		flat_normal_view,
		camera_distance,
		sspr_filter_roughness,
		projection_matrix,
		inverse_projection_matrix,
		near_ssr_active,
		near_ssr_confidence,
		near_ssr_hit,
		near_ssr_depth_confidence,
		near_ssr_deviation_confidence,
		near_ssr_base_confidence,
		near_ssr_step_usage,
		near_ssr_hit_distance
	);
	// Near SSR selects radiance; it never adds a second lighting or Fresnel lobe.
	// An SSPR miss remains a partial radiance override, so the environment keeps
	// contributing continuously when both screen-space paths are uncertain.
	vec3 reflection_radiance = sspr_distorted_sample.rgb;
	float reflection_radiance_confidence = sspr_confidence;
	if (near_ssr_confidence > 0.0) {
		reflection_radiance = sspr_confidence > 0.0001
			? mix(sspr_distorted_sample.rgb, near_ssr_color, near_ssr_confidence)
			: near_ssr_color;
		reflection_radiance_confidence = max(sspr_confidence, near_ssr_confidence);
	}
	// Screen-space weight controls only fallback confidence, never radiance
	// brightness. Zero therefore restores the environment/PBR fallback.
	reflection_radiance_confidence = clamp(
		reflection_radiance_confidence * reflection_screen_space_weight,
		0.0,
		1.0
	);
	reflection_radiance = reflection_grade_radiance(reflection_radiance);
	float distance_opacity = smoothstep(
		opacity_distance_start,
		max(opacity_distance_end, opacity_distance_start + 0.001),
		camera_distance
	);
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
	if (reflection_and_mono_state.z > 0.5) {
		float crest = 0.5 + 0.5 * cos(reflection_and_mono_state.y);
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
		else if (coastal_debug_field == 9) value = clamp(max(coastal_metrics.r, 0.0) / max(shore_horizontal_depth_range_m.y, 0.001), 0.0, 1.0);
		else if (coastal_debug_field == 10) value = shore_vertical_weight_varying;
		else if (coastal_debug_field == 11) value = shore_horizontal_weight_varying;
		color = mix(vec3(0.02, 0.05, 0.12), vec3(0.95, 0.8, 0.18), clamp(value, 0.0, 1.0));
	}
	if (perf_prebreak_enabled && breaking_debug_mode > 0) {
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
	if (sea_state_zone_debug) {
		float zone_long_amplitude;
		float zone_mid_amplitude;
		float zone_short_amplitude;
		float zone_choppiness;
		vec2 zone_grad_long;
		vec2 zone_grad_mid;
		vec2 zone_grad_short;
		vec2 zone_grad_chop;
		float zone_foam_multiplier;
		sea_state_zone_state(ocean_base_xz, zone_long_amplitude, zone_mid_amplitude,
			zone_short_amplitude, zone_choppiness, zone_grad_long, zone_grad_mid,
			zone_grad_short, zone_grad_chop, zone_foam_multiplier);
		float value = clamp(zone_long_amplitude / 2.0, 0.0, 1.0);
		color = mix(vec3(0.02, 0.04, 0.16), vec3(0.08, 0.85, 0.95), smoothstep(0.0, 0.5, value));
		color = mix(color, vec3(1.0, 0.25, 0.05), smoothstep(0.5, 1.0, value));
	}

	if (foam_debug_mode == 1) {
		color = vec3(crest_foam_mask);
	} else if (foam_debug_mode == 2) {
		color = vec3(clamp(surface_foam_field_unweighted.x, 0.0, 1.0));
	} else if (foam_debug_mode == 3) {
		color = vec3(surface_foam_macro);
	} else if (foam_debug_mode == 4) {
		color = vec3(surface_foam_mask);
	} else if (foam_debug_mode == 5) {
		color = vec3(surface_foam_direct_j_raw_at(ocean_base_xz));
	} else if (foam_debug_mode == 6) {
		color = vec3(surface_foam_raw_topology);
	} else if (foam_debug_mode == 7) {
		color = vec3(foam_mask);
	} else if (foam_debug_mode == 8) {
		vec3 foam_normal_debug = normalize(vec3(-foam_shape_gradient.x * foam_normal_strength, 1.0, -foam_shape_gradient.y * foam_normal_strength));
		color = foam_normal_debug * 0.5 + 0.5;
	} else if (foam_debug_mode == 9) {
		color = vec3(surface_foam_mid_fold_history_value);
	} else if (foam_debug_mode == 10) {
		color = vec3(crest_filigree_source);
	} else if (foam_debug_mode == 11) {
		color = vec3(crest_filigree_mask);
	} else if (foam_debug_mode == 12) {
		color = vec3(crest_fresh_webbed);
	} else if (foam_debug_mode == 13) {
		color = vec3(crest_residual_webbed);
	} else if (foam_debug_mode == 14) {
		color = vec3(raw_foam_channels.g);
	} else if (foam_debug_mode == 15) {
		color = vec3(raw_foam_channels.r);
	}
	if (reflection_debug_mode == 1) {
		color = vec3(fresnel);
	} else if (reflection_debug_mode == 2) {
		// SKY is rendered by the same PBR environment path below.
		color = vec3(0.0);
	} else if (reflection_debug_mode == 3) {
		color = vec3(debug_sun_specular);
	} else if (reflection_debug_mode == 4) {
		color = vec3(debug_reflection_roughness);
	} else if (reflection_debug_mode == 5) {
		color = visual_normal * 0.5 + 0.5;
	} else if (reflection_debug_mode == 6) {
		color = vec3(debug_slope_variance);
	} else if (reflection_debug_mode == 7) {
		if (reflection_sspr_raw_available) {
			color = textureLod(reflection_sspr_raw_texture, SCREEN_UV, 0.0).rgb;
		} else {
			color = textureLod(reflection_sspr_texture, SCREEN_UV, 0.0).rgb;
		}
	} else if (reflection_debug_mode == 8) {
		if (reflection_sspr_raw_available) {
			color = vec3(textureLod(reflection_sspr_raw_texture, SCREEN_UV, 0.0).a);
		} else {
			color = vec3(textureLod(reflection_sspr_texture, SCREEN_UV, 0.0).a);
		}
	} else if (reflection_debug_mode == 9) {
		color = sspr_distorted_sample.rgb;
	} else if (reflection_debug_mode == 10) {
		color = vec3(sspr_confidence);
	} else if (reflection_debug_mode == 11) {
		if (reflection_sspr_temporal_available) {
			color = textureLod(reflection_sspr_temporal_texture, SCREEN_UV, 0.0).rgb;
		} else {
			color = textureLod(reflection_sspr_texture, SCREEN_UV, 0.0).rgb;
		}
	} else if (reflection_debug_mode == 12) {
		color = textureLod(reflection_sspr_texture, SCREEN_UV, 0.0).rgb;
	} else if (reflection_debug_mode == 13) {
		color = vec3(near_ssr_active);
	} else if (reflection_debug_mode == 14) {
		color = vec3(near_ssr_hit);
	} else if (reflection_debug_mode == 15) {
		color = vec3(near_ssr_confidence);
	} else if (reflection_debug_mode == 16) {
		color = near_ssr_color;
	} else if (reflection_debug_mode == 17) {
		color = vec3(near_ssr_depth_confidence);
	} else if (reflection_debug_mode == 18) {
		color = vec3(near_ssr_deviation_confidence);
	} else if (reflection_debug_mode == 19) {
		color = vec3(near_ssr_base_confidence);
	} else if (reflection_debug_mode == 20) {
		color = vec3(near_ssr_step_usage);
	} else if (reflection_debug_mode == 21) {
		color = vec3(sspr_facet_confidence);
	}

	bool unlit = sea_state_zone_debug || foam_debug_mode > 0 || (reflection_debug_mode > 0 && reflection_debug_mode != 2) || debug_mode >= 2 || clipmap_lod_debug || periodicity_debug || coastal_debug_field > 0 || breaking_debug_mode > 0 || reflection_and_mono_state.z > 0.5 || coastal_delta_heatmap || ocean_crest_sharpen_debug;
	if (unlit) {
		ALBEDO = vec3(0.0);
		EMISSION = color;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		RADIANCE = vec4(0.0);
		ALPHA = 1.0;
	} else if (ocean_shape_debug) {
		// 5R.1: vista neutra de silueta/crest/valle/choppiness. Sin foam ni emission.
		ALBEDO = vec3(0.52, 0.56, 0.60);
		EMISSION = vec3(0.0);
		ROUGHNESS = 0.7;
		SPECULAR = 0.2;
		ALPHA = 1.0;
	} else if (reflection_debug_mode == 2) {
		// Environment debug: black albedo isolates the environment reflection
		// lobe. SPECULAR is opened only for this diagnostic view.
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.0);
		ROUGHNESS = water_reflection_roughness;
		SPECULAR = 1.0;
		METALLIC = 0.0;
		ALPHA = 1.0;
	} else {
		// 5R.3B/3C: VERTEX es la base de producción. FRAGMENT completo queda
		// únicamente como A/B con G. El detalle fino SIEMPRE se añade después
		// mediante normal maps por fragment, de modo que haya riqueza cerca y
		// también a distancia sin marcar la cuadrícula del clipmap.
		float effective_water_specular = clamp(
			WATER_SPECULAR_LEVEL * reflection_environment_specular_boost,
			0.0,
			1.0
		);
		if (water_optics_enabled) {
			// 5R.3C: profundidad óptica real desde el depth buffer.
			float scene_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
			bool scene_is_sky = scene_raw_depth <= 0.000001;
			bool scene_raw_depth_valid = scene_raw_depth > 0.000001
				&& scene_raw_depth <= 1.000001
				&& !isnan(scene_raw_depth) && !isinf(scene_raw_depth);
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
			bool scene_depth_valid = scene_raw_depth_valid
				&& scene_linear_depth > WATER_OPTICS_EPSILON
				&& !isnan(scene_linear_depth) && !isinf(scene_linear_depth);
			bool water_depth_valid = water_linear_depth > WATER_OPTICS_EPSILON
				&& !isnan(water_linear_depth) && !isinf(water_linear_depth);
			vec3 scene_world_position = vec3(0.0);
			bool scene_world_position_valid = scene_depth_valid
				&& water_optics_world_position_from_depth(
					SCREEN_UV,
					scene_raw_depth,
					INV_PROJECTION_MATRIX,
					INV_VIEW_MATRIX,
					scene_world_position
				);
			// Fragment diagnostics and production bathymetry intentionally bypass the
			// interpolated Coastal metrics varying. One direct metrics sample is now
			// the local-depth authority; mode 19 additionally samples field validity
			// so propagation coverage can be inspected without coupling it to depth.
			vec2 diagnostic_bathymetry_uv = coastal_uv(ocean_base_xz);
			float diagnostic_bathymetry_domain = shore_data_inside(diagnostic_bathymetry_uv);
			vec4 bathymetry_fragment_sample = textureLod(
				coastal_metrics_texture,
				clamp(diagnostic_bathymetry_uv, vec2(0.0), vec2(1.0)),
				0.0
			);
			float raw_bathymetry_m = bathymetry_fragment_sample.r;
			vec4 raw_field_fragment_sample = vec4(0.0);
			if (water_optics_debug_mode == 19) {
				raw_field_fragment_sample = textureLod(
					coastal_field_texture,
					clamp(diagnostic_bathymetry_uv, vec2(0.0), vec2(1.0)),
					0.0
				);
			}
			vec3 scene_depth_class_color = vec3(0.0, 0.0, 1.0);
			if (scene_is_sky || !scene_raw_depth_valid) {
				scene_depth_class_color = vec3(1.0, 0.0, 0.0);
			} else if (scene_depth_valid) {
				scene_depth_class_color = vec3(0.0, 1.0, 0.0);
			}
			// Keep physical water distance separate from the bounded value used by
			// stability-sensitive R2 and artistic saturation controls. For the sky or
			// an invalid depth sample, maximum_optical_depth remains the conservative
			// finite fallback because no scene bottom distance is available.
			// VIEW-RAY OPTICAL PATH: this is camera-dependent water distance, not
			// bathymetric depth. It remains the authority for transmission and optics.
			float view_water_path_m = scene_is_sky
				? max(maximum_optical_depth, 0.0)
				: scene_depth_valid && water_depth_valid
				? max(scene_linear_depth - water_linear_depth, 0.0)
				: max(maximum_optical_depth, 0.0);
			float bounded_view_water_path_m = min(
				view_water_path_m,
				max(maximum_optical_depth, 0.0)
			);
			// LOCAL/BATHYMETRIC DEPTH: the direct fragment metrics.r sample is the
			// baked seabed depth in metres. Domain membership is the spatial authority;
			// field.a remains propagation validity only and is deliberately excluded.
			// A zero-metre shoreline sample is valid and must not be rejected by value.
			vec2 local_depth_coastal_uv = diagnostic_bathymetry_uv;
			float local_depth_edge_distance_m = max(min(
				min(
					local_depth_coastal_uv.x * coastal_extent_m.x,
					(1.0 - local_depth_coastal_uv.x) * coastal_extent_m.x
				),
				min(
					local_depth_coastal_uv.y * coastal_extent_m.y,
					(1.0 - local_depth_coastal_uv.y) * coastal_extent_m.y
				)
			), 0.0);
			float local_depth_edge_confidence = smoothstep(
				0.0,
				max(coastal_cell_size_m * 2.0, 0.001),
				local_depth_edge_distance_m
			);
			float local_depth_confidence = diagnostic_bathymetry_domain * local_depth_edge_confidence;
			bool local_depth_sample_valid = !isnan(raw_bathymetry_m)
				&& !isinf(raw_bathymetry_m)
				&& raw_bathymetry_m >= 0.0;
			bool local_water_depth_valid = local_depth_sample_valid
				&& local_depth_confidence > 0.001;
			if (!local_water_depth_valid) {
				local_depth_confidence = 0.0;
			}
			float coastal_local_depth_m = max(raw_bathymetry_m, 0.0);
			float local_deep_fallback_m = max(
				maximum_optical_depth,
				max(
					max(water_body_depth_end_m, alpha_depth_fade_end_m),
					max(shallow_scattering_depth_end_m, 20.0)
				) + 1.0
			);
			float local_water_depth_m = mix(
				local_deep_fallback_m,
				coastal_local_depth_m,
				local_depth_confidence
			);
			// BathymetryData is baked as sea_level_y - top_surface_y. Use that
			// same sea-level convention, not the instantaneous FFT crest height.
			float expected_seabed_y = coastal_bathymetry_sea_level_y
				- max(local_water_depth_m, 0.0);
			float seabed_height_error_m = scene_world_position_valid
				? abs(scene_world_position.y - expected_seabed_y)
				: max(seabed_match_tolerance_end_m, 10.0);
			float seabed_match = 0.0;
			if (scene_world_position_valid && local_water_depth_valid) {
				seabed_match = 1.0 - smoothstep(
					seabed_match_tolerance_start_m,
					max(seabed_match_tolerance_end_m, seabed_match_tolerance_start_m + 0.001),
					seabed_height_error_m
				);
			}
			float bottom_depth_visibility = 1.0 - smoothstep(
				bottom_visibility_fade_start_m,
				max(bottom_visibility_fade_end_m, bottom_visibility_fade_start_m + 0.001),
				local_water_depth_m
			);
			float seabed_transmission_weight = mix(
				1.0,
				bottom_depth_visibility,
				seabed_match
			);

			// R1 Beer-Lambert uses the view-ray path without the old optical depth
			// clamp, so 25-50 m continues to attenuate instead of plateauing.
			vec3 transmittance_rgb = exp(
				-max(absorption_coeff_rgb, vec3(0.0)) * view_water_path_m
			);
			vec3 absorbed_rgb = vec3(1.0) - transmittance_rgb;
			// View-path saturation only: this is deliberately not a shallow/deep
			// authority, even though it modulates the volume response.
			float view_path_saturation_factor = clamp(
				bounded_view_water_path_m / max(maximum_optical_depth, 0.001),
				0.0,
				1.0
			);
			float body_depth_factor = smoothstep(
				water_body_depth_start_m,
				max(water_body_depth_end_m, water_body_depth_start_m + 0.001),
				local_water_depth_m
			);

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
				body_depth_factor
			);
			body_color = mix(
				body_color,
				mix(trough_tint.rgb, crest_tint.rgb, height_position),
				0.24
			);

			// Reuse the transmitted screen sample at a depth-dependent mip level to
			// suppress recognizable deep-bottom geometry while retaining broad color.
			// The turbidity contribution is depth-gated so very shallow water stays at
			// essentially LOD 0 even when the water is optically cloudy.
			float transmission_detail_fade = smoothstep(
				transmission_detail_fade_start_m,
				max(transmission_detail_fade_end_m, transmission_detail_fade_start_m + 0.001),
				view_water_path_m
			);
			float turbidity_factor = smoothstep(
				0.0,
				1.0,
				clamp(water_turbidity * 0.75, 0.0, 1.0)
			);
			float turbidity_depth_gate = smoothstep(2.0, 10.0, view_water_path_m);
			float turbidity_detail_fade = turbidity_factor * turbidity_depth_gate;
			float transmission_blur_factor = clamp(
				mix(
					transmission_detail_fade,
					max(transmission_detail_fade, turbidity_detail_fade),
					0.35
				),
				0.0,
				1.0
			);
			float transmission_lod = clamp(
				transmission_blur_factor * max(transmission_max_lod, 0.0),
				0.0,
				8.0
			);

			// R3: keep the R1 Beer-Lambert values pure, then derive bounded
			// production-only polish from them. Crest transmission uses the existing
			// height signal; it never changes TRANSMITTANCE_RGB debug output.
			float crest_factor = smoothstep(0.65, 1.0, height_position);
			float crest_transmission_mix = clamp(
				crest_factor * clamp(crest_transmission_boost, 0.0, 0.5),
				0.0,
				0.5
			);
			vec3 effective_transmittance_rgb = mix(
				transmittance_rgb,
				sqrt(max(transmittance_rgb, vec3(0.0))),
				crest_transmission_mix
			);
			vec3 effective_absorbed_rgb = vec3(1.0) - effective_transmittance_rgb;
			float trough_factor = 1.0 - smoothstep(0.0, 0.45, height_position);
			float trough_density_factor = 1.0 + trough_factor
				* clamp(trough_density_boost, 0.0, 0.5);

			// Turbidity is an independent scattering density in inverse metres. The
			// exponential grows with optical thickness and saturates in deep water;
			// it is deliberately not derived from absorption_coeff_rgb.
			float scattering_density_m = 0.22 * clamp(water_turbidity, 0.0, 2.0);
			float scattering_depth_response = 1.0 - exp(
				-max(scattering_density_m, 0.0) * max(view_water_path_m, 0.0)
			);
			float scattering_response = clamp(
				scattering_depth_response * mix(0.55, 1.0, view_path_saturation_factor),
				0.0,
				1.0
			);
			// Keep the volume response depth-driven, but give the artistic tint a
			// separate shallow/deep authority. Shallow water can catch the tint fully;
			// deep water keeps the deep-water base dominant with a subtle warm influence.
			float shallow_scattering_factor = 1.0 - smoothstep(
				shallow_scattering_depth_start_m,
				max(shallow_scattering_depth_end_m, shallow_scattering_depth_start_m + 0.001),
				local_water_depth_m
			);
			float scattering_tint_influence = mix(
				clamp(scattering_deep_tint_influence, 0.0, 1.0),
				clamp(scattering_shallow_tint_influence, 0.0, 1.0),
				shallow_scattering_factor
			);
			vec3 deep_scattering_base_color = deep_water_color.rgb * 0.65;
			vec3 scattering_tint = mix(
				deep_scattering_base_color,
				scattering_color.rgb,
				scattering_tint_influence
			);
			// Treat scattering as a bounded share of the absorbed body response.
			// This preserves the R1 body at strength 0 and avoids stacking the
			// deep-water color three times through transmission, body and scatter.
			float scattering_share = clamp(
				scattering_response * clamp(scattering_strength, 0.0, 2.0) * 0.35,
				0.0,
				0.45
			);
			vec3 body_component = body_color * effective_absorbed_rgb
				* (1.0 - scattering_share) * trough_density_factor;
			vec3 water_scattering = scattering_tint * effective_absorbed_rgb;
			vec3 scattering_component = water_scattering
				* scattering_share * trough_density_factor;
			float transmittance_luma = clamp(
				dot(effective_transmittance_rgb, vec3(0.2126, 0.7152, 0.0722)),
				0.0,
				1.0
			);

			vec3 surface_color = mix(
				body_color,
				horizon_water_color.rgb,
				distance_opacity
			);

			// R2: derive the refraction ray from the clean FFT macro normal and IOR.
			// Surface Detail contributes only through the already sampled detail offset;
			// foam normals deliberately stay out of this path.
			vec3 optical_scene = body_component + scattering_component;
			vec2 refraction_final_offset_px = vec2(0.0);
			float refraction_validity = 0.0;
			// This is a bounded visual shallow light lift, not a replacement for
			// volume scattering. Use a conservative fallback when refraction is off;
			// the existing refracted scene luminance refines it when already available.
			float shallow_bottom_response = 0.75;
			if (water_refraction_enabled) {
				vec2 refraction_screen_size = max(
					vec2(textureSize(screen_texture, 0)),
					vec2(1.0)
				);
				vec3 refraction_normal_view = normalize(
					sspr_macro_normal_view
					+ surface_detail_offset_view
					* surface_normal_strength
					* refraction_micro_normal_strength
				);
				vec3 incident_view = normalize(-view_direction);
				vec3 refracted_direction_view = refract(
					incident_view,
					refraction_normal_view,
					1.0 / max(WATER_IOR, WATER_OPTICS_EPSILON)
				);
				bool refraction_direction_valid = length(refracted_direction_view) > WATER_OPTICS_EPSILON
					&& !any(isnan(refracted_direction_view))
					&& !any(isinf(refracted_direction_view));
				if (refraction_direction_valid && !scene_is_sky && scene_depth_valid && water_depth_valid) {
					refracted_direction_view = normalize(refracted_direction_view);
					float target_scene_depth = min(
						scene_linear_depth,
						water_linear_depth + bounded_view_water_path_m
					);
					float direction_z = refracted_direction_view.z;
					bool direction_z_valid = abs(direction_z) > WATER_OPTICS_EPSILON
						&& !isnan(direction_z) && !isinf(direction_z);
					float path_distance = 0.0;
					if (direction_z_valid) {
						path_distance = (-target_scene_depth - water_position_view.z) / direction_z;
					}
					bool path_valid = direction_z_valid
						&& path_distance >= 0.0
						&& path_distance <= max(maximum_optical_depth * 8.0, 1.0)
						&& !isnan(path_distance) && !isinf(path_distance);
					if (path_valid) {
						vec3 candidate_position_view = water_position_view
							+ refracted_direction_view * path_distance;
						bool projection_valid;
						vec2 candidate_refracted_uv = water_optics_project_view_position(
							candidate_position_view, projection_matrix, projection_valid);
						if (projection_valid) {
							// refraction_strength remains the post-geometry artistic gain;
							// its historic default 0.009 maps to nominal gain 1.
							float refraction_gain = max(refraction_strength, 0.0) / 0.009;
							candidate_refracted_uv = SCREEN_UV
								+ (candidate_refracted_uv - SCREEN_UV) * refraction_gain;
							vec2 candidate_offset_px = (candidate_refracted_uv - SCREEN_UV) * refraction_screen_size;
							float candidate_offset_length_px = length(candidate_offset_px);
							float max_offset_px = max(refraction_max_offset_px, 0.0);
							if (max_offset_px <= WATER_OPTICS_EPSILON) {
								candidate_offset_px = vec2(0.0);
							} else if (candidate_offset_length_px > max_offset_px) {
								candidate_offset_px *= max_offset_px / candidate_offset_length_px;
							}
							candidate_refracted_uv = SCREEN_UV + candidate_offset_px / refraction_screen_size;

							float edge_confidence = water_optics_edge_confidence(candidate_refracted_uv);
							vec2 candidate_depth_uv = clamp(
								candidate_refracted_uv,
								vec2(0.001),
								vec2(0.999)
							);
							// R2 adds exactly one candidate depth fetch.
							float candidate_raw_depth = textureLod(depth_texture, candidate_depth_uv, 0.0).r;
							bool candidate_raw_depth_valid = candidate_raw_depth > 0.000001
								&& candidate_raw_depth <= 1.000001
								&& !isnan(candidate_raw_depth) && !isinf(candidate_raw_depth);
							float candidate_linear_depth = linear_depth_from_buffer(
								candidate_depth_uv,
								candidate_raw_depth,
								INV_PROJECTION_MATRIX
							);
							bool candidate_depth_valid = candidate_raw_depth_valid
								&& candidate_linear_depth > WATER_OPTICS_EPSILON
								&& !isnan(candidate_linear_depth) && !isinf(candidate_linear_depth);
							float behind_water_confidence = candidate_depth_valid
								? smoothstep(
									water_linear_depth + WATER_OPTICS_FOREGROUND_MARGIN_M,
									water_linear_depth + WATER_OPTICS_FOREGROUND_MARGIN_M + 0.15,
									candidate_linear_depth
								)
								: 0.0;
							float depth_tolerance = max(
								refraction_depth_tolerance_m,
								bounded_view_water_path_m * WATER_OPTICS_TOLERANCE_THICKNESS_FACTOR
							);
							float closer_error = candidate_depth_valid
								? max(scene_linear_depth - candidate_linear_depth, 0.0)
								: depth_tolerance + 1.0;
							float discontinuity_confidence = candidate_depth_valid
								? 1.0 - smoothstep(depth_tolerance, depth_tolerance + 0.25, closer_error)
								: 0.0;
							refraction_validity = clamp(
								edge_confidence
								* behind_water_confidence
								* discontinuity_confidence,
								0.0,
								1.0
							);
							refraction_final_offset_px = candidate_offset_px * refraction_validity;
						}
					}
				}
				vec2 final_refracted_uv = clamp(
					SCREEN_UV + refraction_final_offset_px / refraction_screen_size,
					vec2(0.001),
					vec2(0.999)
				);
				vec3 refracted_scene = textureLod(
					screen_texture,
					final_refracted_uv,
					transmission_lod
				).rgb;
				float bottom_luma = dot(
					max(refracted_scene, vec3(0.0)),
					vec3(0.2126, 0.7152, 0.0722)
				);
				shallow_bottom_response = mix(
					0.5,
					1.0,
					clamp(bottom_luma, 0.0, 1.0)
				);
				// R3 optical body: refracted transmission plus one bounded body/scatter
				// response. effective_transmittance_rgb is production-only; the pure
				// R1 transmittance_rgb remains available to debug mode 2.
				vec3 transmitted_component = refracted_scene
					* effective_transmittance_rgb
					* seabed_transmission_weight;
				optical_scene = transmitted_component + body_component + scattering_component;
			}
			float shallow_light_response = shallow_scattering_factor
				* transmittance_luma
				* shallow_bottom_response;
			float shallow_scattering_share = clamp(
				shallow_light_response
				* clamp(shallow_scattering_strength, 0.0, 2.0)
				* clamp(scattering_strength, 0.0, 2.0)
				* 0.55,
				0.0,
				0.30
			);
			vec3 shallow_scattering_component = scattering_tint * shallow_scattering_share;
			optical_scene += shallow_scattering_component;

			// The existing physical Fresnel is the single optical balance between
			// transmission and the surface/body response. The refraction offset above
			// only uses (1 - fresnel) to control distortion magnitude.
			float surface_weight = 1.0 - (1.0 - fresnel) * (1.0 - distance_opacity);
			vec3 final_color = mix(optical_scene, surface_color, surface_weight);

			float alpha_depth_factor = smoothstep(
				alpha_depth_fade_start_m,
				max(alpha_depth_fade_end_m, alpha_depth_fade_start_m + 0.001),
				local_water_depth_m
			);
			float local_alpha = mix(
				near_water_alpha,
				deep_water_alpha,
				alpha_depth_factor
			);
			float final_alpha = clamp(
				mix(
					local_alpha,
					horizon_water_alpha,
					distance_opacity
				),
				0.55,
				1.0
			);

			// Foam is composited after water optics, so Fresnel/reflection cannot be
			// laid back on top of it when looking into a solar highlight.
			vec3 water_body_final_color = final_color;
			vec3 residual_foam_color = mix(foam_color.rgb, foam_residual_color.rgb, 0.65);
			final_color = mix(final_color, surface_foam_color.rgb, surface_foam_mask);
			final_color = mix(final_color, residual_foam_color, foam_residual_mask);
			final_color = mix(final_color, foam_fresh_color.rgb, foam_fresh_mask);
			if (water_optics_debug_mode == 1) {
				final_color = vec3(bounded_view_water_path_m / max(maximum_optical_depth, 0.001));
			} else if (water_optics_debug_mode == 2) {
				final_color = transmittance_rgb;
			} else if (water_optics_debug_mode == 3) {
				final_color = body_color;
			} else if (water_optics_debug_mode == 4) {
				float debug_offset_scale = max(refraction_max_offset_px, 1.0);
				vec2 signed_offset = clamp(refraction_final_offset_px / debug_offset_scale, -1.0, 1.0);
				final_color = vec3(signed_offset * 0.5 + 0.5, clamp(
					length(refraction_final_offset_px) / debug_offset_scale,
					0.0,
					1.0
				));
			} else if (water_optics_debug_mode == 5) {
				final_color = vec3(refraction_validity);
			} else if (water_optics_debug_mode == 6) {
				final_color = scattering_component;
			} else if (water_optics_debug_mode == 7) {
				final_color = water_body_final_color;
			} else if (water_optics_debug_mode == 8) {
				final_color = vec3(transmission_blur_factor);
			} else if (water_optics_debug_mode == 9) {
				final_color = vec3(body_depth_factor);
			} else if (water_optics_debug_mode == 10) {
				final_color = vec3(alpha_depth_factor);
			} else if (water_optics_debug_mode == 11) {
				final_color = vec3(shallow_scattering_factor);
			} else if (water_optics_debug_mode == 12) {
				final_color = vec3(scattering_tint_influence);
			} else if (water_optics_debug_mode == 13) {
				final_color = shallow_scattering_component;
			} else if (water_optics_debug_mode == 14) {
				// Local bathymetric depth: black at 0 m, white at 20 m or deeper.
				final_color = vec3(clamp(local_water_depth_m / 20.0, 0.0, 1.0));
			} else if (water_optics_debug_mode == 15) {
				// View path: this value changes with the camera ray by design.
				final_color = vec3(clamp(view_water_path_m / 20.0, 0.0, 1.0));
			} else if (water_optics_debug_mode == 16) {
				// Bathymetric shallow/deep authority, represented by body depth.
				final_color = vec3(body_depth_factor);
			} else if (water_optics_debug_mode == 17) {
				// Direct fragment metrics.r: black at 0 m, white at 20 m or deeper.
				final_color = vec3(clamp(max(raw_bathymetry_m, 0.0) / 20.0, 0.0, 1.0));
			} else if (water_optics_debug_mode == 18) {
				// Domain only; deliberately independent of coastal_field.a.
				final_color = vec3(diagnostic_bathymetry_domain);
			} else if (water_optics_debug_mode == 19) {
				// Direct fragment field.a: propagation validity, not bathymetry validity.
				final_color = vec3(clamp(raw_field_fragment_sample.a, 0.0, 1.0));
			} else if (water_optics_debug_mode == 20) {
				// Forward+ reversed-Z raw depth: clear/sky is approximately zero.
				final_color = vec3(clamp(scene_raw_depth, 0.0, 1.0));
			} else if (water_optics_debug_mode == 21) {
				// Red=sky/clear, green=valid scene reconstruction, blue=present but invalid.
				final_color = scene_depth_class_color;
			} else if (water_optics_debug_mode == 22) {
				// R=raw FRAGCOORD.z, G=water linear depth / 100 m, B=validity.
				final_color = vec3(
					clamp(FRAGCOORD.z, 0.0, 1.0),
					clamp(water_linear_depth / 100.0, 0.0, 1.0),
					water_depth_valid ? 1.0 : 0.0
				);
			} else if (water_optics_debug_mode == 23) {
				// Absolute vertex-varying versus fragment-sampled metrics.r, /20 m.
				final_color = vec3(clamp(abs(coastal_metrics.r - raw_bathymetry_m) / 20.0, 0.0, 1.0));
			} else if (water_optics_debug_mode == 26) {
				// White when the original scene sample matches the local seabed.
				final_color = vec3(seabed_match);
			} else if (water_optics_debug_mode == 27) {
				// White in shallow water; black once the local bottom is deep.
				final_color = vec3(bottom_depth_visibility);
			} else if (water_optics_debug_mode == 28) {
				// White when transmitted geometry is unchanged; black when seabed fades.
				final_color = vec3(seabed_transmission_weight);
			} else if (water_optics_debug_mode == 29) {
				// Height error normalized to 10 m; invalid/sky samples are white.
				final_color = vec3(clamp(seabed_height_error_m / 10.0, 0.0, 1.0));
			}
			ALBEDO = final_color;
			EMISSION = vec3(0.0);
			// Water response is established first; foam remains the final authority.
			ROUGHNESS = reflection_final_roughness(
				water_reflection_roughness, surface_foam_mask, foam_residual_mask, foam_fresh_mask);
			SPECULAR = mix(effective_water_specular, surface_foam_specular, surface_foam_mask);
			SPECULAR = mix(SPECULAR, foam_residual_specular, foam_residual_mask);
			SPECULAR = mix(SPECULAR, foam_fresh_specular, foam_fresh_mask);
			METALLIC = 0.0;
			RADIANCE = vec4(reflection_radiance, reflection_radiance_confidence);
			ALPHA = clamp(final_alpha + (foam_fresh_mask + foam_residual_mask * 0.58 + surface_foam_mask * 0.35) * foam_alpha_boost, 0.0, 1.0);
			if (water_optics_debug_mode > 0) {
				ALBEDO = final_color;
				EMISSION = final_color;
				ROUGHNESS = 1.0;
				SPECULAR = 0.0;
				RADIANCE = vec4(0.0);
				ALPHA = 1.0;
			}
		} else {
			// Fallback de debug: material simple sin screen/depth.
			vec3 residual_foam_color = mix(foam_color.rgb, foam_residual_color.rgb, 0.65);
			ALBEDO = base_color;
			ALBEDO = mix(ALBEDO, surface_foam_color.rgb, surface_foam_mask);
			ALBEDO = mix(ALBEDO, residual_foam_color, foam_residual_mask);
			ALBEDO = mix(ALBEDO, foam_fresh_color.rgb, foam_fresh_mask);
			EMISSION = vec3(0.0);
			ROUGHNESS = reflection_final_roughness(
				water_reflection_roughness, surface_foam_mask, foam_residual_mask, foam_fresh_mask);
			SPECULAR = mix(effective_water_specular, surface_foam_specular, surface_foam_mask);
			SPECULAR = mix(SPECULAR, foam_residual_specular, foam_residual_mask);
			SPECULAR = mix(SPECULAR, foam_fresh_specular, foam_fresh_mask);
			METALLIC = 0.0;
			RADIANCE = vec4(reflection_radiance, reflection_radiance_confidence);
			ALPHA = clamp(1.0 + (foam_fresh_mask + foam_residual_mask * 0.58 + surface_foam_mask * 0.35) * foam_alpha_boost, 0.0, 1.0);
		}
	}
	if (water_optics_debug_mode == 0 && (clipmap_flat_geometry_debug || clipmap_displaced_unlit_debug)) {
		// Emission-only opaque gray matches the existing unlit debug convention.
		// The displaced mode leaves vertex geometry intact; the flat mode has
		// already zeroed displacement in vertex().
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.5);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		METALLIC = 0.0;
		RADIANCE = vec4(0.0);
		NORMAL = flat_normal_view;
		ALPHA = 1.0;
	}
	}
}

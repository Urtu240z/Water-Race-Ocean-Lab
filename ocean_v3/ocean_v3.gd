@tool
class_name OceanV3
extends Node3D
## Public visual/material controls for the OceanV3 root.
## Physics, FFT and internal rendering configuration remain owned by their modules.

const WAVE_REBUILD_DEBOUNCE_MS := 150
const BASE_WAVE_PRESET_PATHS := [
	"res://ocean_v3/presets/waves/calm.tres",
	"res://ocean_v3/presets/waves/race.tres",
	"res://ocean_v3/presets/waves/rough.tres",
]
const SSPR_MANAGER_SCRIPT := preload("res://ocean_v3/reflections/ocean_sspr_manager.gd")
const CAUSTICS_MANAGER_SCRIPT := preload("res://ocean_v3/rendering/caustics/ocean_caustics_manager.gd")
const UNDERWATER_MANAGER_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_underwater_manager.gd")
const UNDERWATER_ENTER_MARGIN_M := 0.05
const UNDERWATER_EXIT_MARGIN_M := 0.05
enum UnderwaterViewerMedium { AIR, WATER, CROSSING }
const PERF_PRESET_FULL := &"FULL"
const PERF_PRESET_BASE := &"BASE"
const PERF_PRESET_NO_SSPR := &"NO_SSPR"
const PERF_PRESET_NO_FOAM := &"NO_FOAM"
const PERF_PRESET_NO_COASTAL := &"NO_COASTAL"
const PERF_PRESET_NO_BREAKERS := &"NO_BREAKERS"
const PERF_PRESET_NO_CREST_FOAM := &"NO_CREST_FOAM"
const PERF_PRESET_NO_MID_FOLD_HISTORY := &"NO_MID_FOLD_HISTORY"
var _wave_spectrum_dirty := false
var _wave_spectrum_apply_at_ms := 0
var _applying_wave_preset := false
var _applying_wave_transition := false
var _wave_transition_active := false
var _wave_transition_start_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_target_preset: OceanWavePreset = null
var _wave_transition_target_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_start_short_geometry := 0.25
var _performance_sync_pending := false
## Ephemeral A/B controls consumed only by the Ocean V3 benchmark. They are
## deliberately not exported quality settings and always default to production.
var _benchmark_diagnostic_gates: Dictionary = {}
var _performance_overlay_layer: CanvasLayer
var _performance_overlay_label: Label

@export_category("Wave Spectrum")
@export var wave_preset: OceanWavePreset:
	set(value):
		wave_preset = value
		if wave_preset != null and is_inside_tree() and not _applying_wave_transition:
			apply_selected_wave_preset()

@export_range(0.0, 60.0, 0.1) var global_wind_speed_mps := 12.0:
	set(value):
		global_wind_speed_mps = maxf(value, 0.0)
		_mark_wave_spectrum_dirty()

@export var auto_apply_wave_changes := true
@export_range(0.0, 60.0, 0.1) var wave_transition_duration_s := 10.0
@export_file("*.tres") var preset_save_path := "res://ocean_v3/presets/waves/custom_wave.tres"
@export_tool_button("Apply Selected Preset", "Reload") var apply_selected_wave_preset_button = apply_selected_wave_preset
@export_tool_button("Transition To Selected Preset", "CurvePath") var transition_to_selected_wave_preset_button = transition_to_selected_wave_preset
@export_tool_button("Apply Wave Changes", "Play") var apply_wave_changes_button = apply_wave_changes
@export_tool_button("Save Current Wave Preset", "Save") var save_current_wave_preset_button = save_current_wave_preset

@export_group("Coastal")
@export var coastal_bake_asset: CoastalBakeAsset
@export var coastal_enabled_on_start := true

@export_group("Performance Profiling")
## Instrumentation switches. They gate runtime work; they do not alter quality,
## resolutions, algorithms or the authored FULL-mode behaviour.
@export var perf_enable_spectral := true:
	set(value):
		perf_enable_spectral = value
		_request_performance_sync()
@export var perf_enable_coastal := true:
	set(value):
		perf_enable_coastal = value
		_request_performance_sync()
@export var perf_enable_crest_foam_solver := true:
	set(value):
		perf_enable_crest_foam_solver = value
		_request_performance_sync()
@export var perf_enable_surface_foam_solver := true:
	set(value):
		perf_enable_surface_foam_solver = value
		_request_performance_sync()
@export var perf_enable_mid_fold_history := true:
	set(value):
		perf_enable_mid_fold_history = value
		_request_performance_sync()
@export var perf_enable_surface_foam_render := true:
	set(value):
		perf_enable_surface_foam_render = value
		_request_performance_sync()
@export var perf_enable_prebreak := true:
	set(value):
		perf_enable_prebreak = value
		_request_performance_sync()
@export var perf_enable_breakers := true:
	set(value):
		perf_enable_breakers = value
		_request_performance_sync()
@export var perf_enable_sspr := true:
	set(value):
		perf_enable_sspr = value
		_request_performance_sync()
@export var perf_enable_refraction := true:
	set(value):
		perf_enable_refraction = value
		_request_performance_sync()
@export var perf_overlay_enabled := false:
	set(value):
		perf_overlay_enabled = value
		_update_performance_overlay_visibility()

@export_group("Wave Spectrum / LONG")
@export_range(0.0, 10.0, 0.01) var long_target_hs_m := 0.59:
	set(value): long_target_hs_m = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export_range(0.0, 4.0, 0.01) var long_choppiness := 1.0:
	set(value): long_choppiness = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export var long_wind_direction := Vector2(1.0, 0.15):
	set(value): long_wind_direction = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 12.0, 0.1) var long_directional_spread := 7.0:
	set(value): long_directional_spread = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 100000.0, 1.0) var long_fetch_length_m := 25000.0:
	set(value): long_fetch_length_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var long_swell := 0.8:
	set(value): long_swell = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var long_jonswap_spread := 0.05:
	set(value): long_jonswap_spread = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var long_detail := 1.0:
	set(value): long_detail = value; _mark_wave_spectrum_dirty()

@export_group("Wave Spectrum / MID")
@export_range(0.0, 10.0, 0.01) var mid_target_hs_m := 0.25:
	set(value): mid_target_hs_m = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export_range(0.0, 4.0, 0.01) var mid_choppiness := 0.7:
	set(value): mid_choppiness = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export var mid_wind_direction := Vector2(1.0, 0.3):
	set(value): mid_wind_direction = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 12.0, 0.1) var mid_directional_spread := 5.0:
	set(value): mid_directional_spread = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 100000.0, 1.0) var mid_fetch_length_m := 3000.0:
	set(value): mid_fetch_length_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var mid_swell := 0.45:
	set(value): mid_swell = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var mid_jonswap_spread := 0.35:
	set(value): mid_jonswap_spread = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var mid_detail := 1.0:
	set(value): mid_detail = value; _mark_wave_spectrum_dirty()

@export_group("Wave Spectrum / SHORT")
@export_range(0.0, 10.0, 0.01) var short_target_hs_m := 0.05:
	set(value): short_target_hs_m = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export_range(0.0, 4.0, 0.01) var short_choppiness := 0.35:
	set(value): short_choppiness = maxf(value, 0.0); _mark_wave_spectrum_dirty()
@export var short_wind_direction := Vector2(1.0, 0.45):
	set(value): short_wind_direction = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 12.0, 0.1) var short_directional_spread := 4.0:
	set(value): short_directional_spread = value; _mark_wave_spectrum_dirty()
@export_range(1.0, 100000.0, 1.0) var short_fetch_length_m := 300.0:
	set(value): short_fetch_length_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var short_swell := 0.15:
	set(value): short_swell = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var short_jonswap_spread := 0.75:
	set(value): short_jonswap_spread = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 1.0, 0.01) var short_detail := 1.0:
	set(value): short_detail = value; _mark_wave_spectrum_dirty()

@export_group("Wave Spectrum / LONG Advanced")
@export_range(0.01, 1000.0, 0.01) var long_min_wavelength_m := 16.0:
	set(value): long_min_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.01, 2000.0, 0.01) var long_max_wavelength_m := 128.0:
	set(value): long_max_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 100.0, 0.01) var long_transition_width_m := 4.0:
	set(value): long_transition_width_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 10.0, 0.01) var long_short_wave_damping_m := 0.35:
	set(value): long_short_wave_damping_m = value; _mark_wave_spectrum_dirty()

@export_group("Wave Spectrum / MID Advanced")
@export_range(0.01, 1000.0, 0.01) var mid_min_wavelength_m := 4.0:
	set(value): mid_min_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.01, 2000.0, 0.01) var mid_max_wavelength_m := 20.0:
	set(value): mid_max_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 100.0, 0.01) var mid_transition_width_m := 0.75:
	set(value): mid_transition_width_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 10.0, 0.01) var mid_short_wave_damping_m := 0.35:
	set(value): mid_short_wave_damping_m = value; _mark_wave_spectrum_dirty()

@export_group("Wave Spectrum / SHORT Advanced")
@export_range(0.01, 1000.0, 0.01) var short_min_wavelength_m := 0.5:
	set(value): short_min_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.01, 2000.0, 0.01) var short_max_wavelength_m := 5.0:
	set(value): short_max_wavelength_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 100.0, 0.01) var short_transition_width_m := 0.15:
	set(value): short_transition_width_m = value; _mark_wave_spectrum_dirty()
@export_range(0.0, 10.0, 0.01) var short_short_wave_damping_m := 0.2:
	set(value): short_short_wave_damping_m = value; _mark_wave_spectrum_dirty()

@export_group("Surface Detail")
@export var surface_detail_enabled: bool = true:
	set(value):
		surface_detail_enabled = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_detail_wave_follow: float = 0.70:
	set(value):
		surface_detail_wave_follow = value
		_request_visual_sync()

@export var surface_normal_texture_a: Texture2D:
	set(value):
		surface_normal_texture_a = value
		_request_visual_sync()

@export var surface_normal_texture_b: Texture2D:
	set(value):
		surface_normal_texture_b = value
		_request_visual_sync()

@export var surface_warp_texture: Texture2D:
	set(value):
		surface_warp_texture = value
		_request_visual_sync()

@export_range(0.25, 100.0, 0.05) var surface_normal_world_size_a: float = 7.5:
	set(value):
		surface_normal_world_size_a = value
		_request_visual_sync()

@export_range(0.25, 100.0, 0.05) var surface_normal_world_size_b: float = 3.25:
	set(value):
		surface_normal_world_size_b = value
		_request_visual_sync()

# Keep the shader's current default so attaching the root authority is visually neutral.
@export_range(0.0, 2.0, 0.01) var surface_normal_strength: float = 0.62:
	set(value):
		surface_normal_strength = value
		_request_visual_sync()

@export var surface_flow_direction_a: Vector2 = Vector2(0.82, 0.57):
	set(value):
		surface_flow_direction_a = value
		_request_visual_sync()

@export var surface_flow_direction_b: Vector2 = Vector2(-0.46, 0.89):
	set(value):
		surface_flow_direction_b = value
		_request_visual_sync()

@export_range(-3.0, 3.0, 0.01) var surface_flow_speed_a: float = 0.24:
	set(value):
		surface_flow_speed_a = value
		_request_visual_sync()

@export_range(-3.0, 3.0, 0.01) var surface_flow_speed_b: float = -0.17:
	set(value):
		surface_flow_speed_b = value
		_request_visual_sync()

@export_range(2.0, 300.0, 0.5) var surface_warp_world_size: float = 46.0:
	set(value):
		surface_warp_world_size = value
		_request_visual_sync()

# Keep the shader's current default so attaching the root authority is visually neutral.
@export_range(0.0, 12.0, 0.05) var surface_warp_strength: float = 2.4:
	set(value):
		surface_warp_strength = value
		_request_visual_sync()

@export_range(0.0, 2000.0, 1.0) var surface_detail_fade_start: float = 180.0:
	set(value):
		surface_detail_fade_start = value
		_request_visual_sync()

@export_range(1.0, 4000.0, 1.0) var surface_detail_fade_end: float = 800.0:
	set(value):
		surface_detail_fade_end = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_detail_far_strength: float = 0.18:
	set(value):
		surface_detail_far_strength = value
		_request_visual_sync()

@export_range(0, 2, 1) var ocean_surface_detail_quality: int = 2:
	set(value):
		ocean_surface_detail_quality = value
		_request_visual_sync()


@export_group("Wave Visual Geometry")
@export_range(0.0, 1.0, 0.01) var short_geometry_strength: float = 0.25:
	set(value):
		short_geometry_strength = value
		_request_visual_sync()


@export_group("Diagnostics / Spectral Bands")
@export var diagnostic_long_enabled: bool = true:
	set(value):
		diagnostic_long_enabled = value
		_sync_diagnostic_band_mask()

@export var diagnostic_mid_enabled: bool = true:
	set(value):
		diagnostic_mid_enabled = value
		_sync_diagnostic_band_mask()

@export var diagnostic_short_enabled: bool = true:
	set(value):
		diagnostic_short_enabled = value
		_sync_diagnostic_band_mask()


@export_group("Water Optics")
@export var shallow_water_color: Color = Color(0.035, 0.43, 0.55, 1.0):
	set(value):
		shallow_water_color = value
		_request_visual_sync()

@export var deep_water_color: Color = Color(0.004, 0.055, 0.115, 1.0):
	set(value):
		deep_water_color = value
		_request_visual_sync()

@export var horizon_water_color: Color = Color(0.025, 0.22, 0.34, 1.0):
	set(value):
		horizon_water_color = value
		_request_visual_sync()

@export var trough_tint: Color = Color(0.002, 0.025, 0.075, 1.0):
	set(value):
		trough_tint = value
		_request_visual_sync()

@export var crest_tint: Color = Color(0.11, 0.62, 0.68, 1.0):
	set(value):
		crest_tint = value
		_request_visual_sync()

# Legacy scalar kept for scene/resource serialization compatibility. Water
# optics production uses absorption_coeff_rgb below.
@export_range(0.01, 2.0, 0.01) var absorption_density: float = 0.13:
	set(value):
		absorption_density = value
		_request_visual_sync()

@export var absorption_coeff_rgb: Vector3 = Vector3(0.35, 0.14, 0.10):
	set(value):
		absorption_coeff_rgb = Vector3(
			maxf(value.x, 0.0),
			maxf(value.y, 0.0),
			maxf(value.z, 0.0)
		)
		_request_visual_sync()


@export_group("Underwater / Main")
@export var underwater_enabled := true:
	set(value):
		underwater_enabled = value
		_request_visual_sync()
@export_range(0.01, 1.0, 0.01, "suffix: m") var underwater_transition_width_m := 0.12:
	set(value):
		underwater_transition_width_m = clampf(value, 0.01, 1.0)
		_request_visual_sync()
@export_range(0.0, 0.2, 0.001) var underwater_waterline_feather := 0.03:
	set(value):
		underwater_waterline_feather = clampf(value, 0.0, 0.2)
		_request_visual_sync()

@export_group("Underwater / Medium")
@export_range(0.0, 4.0, 0.01) var underwater_absorption_scale := 1.0:
	set(value):
		underwater_absorption_scale = clampf(value, 0.0, 4.0)
		_request_visual_sync()
@export_color_no_alpha var underwater_scattering_color := Color(0.02, 0.32, 0.42, 1.0):
	set(value):
		underwater_scattering_color = value
		_request_visual_sync()
@export_range(0.0, 4.0, 0.01) var underwater_scattering_strength := 1.0:
	set(value):
		underwater_scattering_strength = clampf(value, 0.0, 4.0)
		_request_visual_sync()
@export_range(0.0, 2.0, 0.005) var underwater_scattering_density := 0.15:
	set(value):
		underwater_scattering_density = clampf(value, 0.0, 2.0)
		_request_visual_sync()
@export_range(1.0, 500.0, 1.0, "suffix: m") var underwater_max_optical_distance_m := 120.0:
	set(value):
		underwater_max_optical_distance_m = clampf(value, 1.0, 500.0)
		_request_visual_sync()

@export_group("Underwater / Surface")
@export_range(1.0, 1.6, 0.001) var underwater_water_ior := 1.333:
	set(value):
		underwater_water_ior = clampf(value, 1.0, 1.6)
		_request_visual_sync()
@export_range(0.0, 2.0, 0.01) var underwater_snell_strength := 1.0:
	set(value):
		underwater_snell_strength = clampf(value, 0.0, 2.0)
		_request_visual_sync()
@export_range(0.0, 2.0, 0.01) var underwater_tir_strength := 1.0:
	set(value):
		underwater_tir_strength = clampf(value, 0.0, 2.0)
		_request_visual_sync()
@export_range(0.0, 1.0, 0.01) var underwater_snell_detail_strength := 0.20:
	set(value):
		underwater_snell_detail_strength = clampf(value, 0.0, 1.0)
		_request_visual_sync()
@export_range(1.0, 500.0, 1.0, "suffix: m") var underwater_surface_projection_distance_m := 80.0:
	set(value):
		underwater_surface_projection_distance_m = clampf(value, 1.0, 500.0)
		_request_visual_sync()

@export_group("Underwater / Debug")
@export_enum("OFF", "INTERFACE_VALID", "INTERFACE_DEPTH", "INTERFACE_NORMAL", "VIEWER_MEDIUM", "PIXEL_MEDIUM", "SNELL_K", "TIR", "WATERLINE", "FINAL") var underwater_debug_mode := 0:
	set(value):
		underwater_debug_mode = clampi(value, 0, 9)
		_request_visual_sync()

@export_range(1.0, 100.0, 0.5) var maximum_optical_depth: float = 38.0:
	set(value):
		maximum_optical_depth = value
		_request_visual_sync()

# Body color depth range is independent from Beer-Lambert absorption.
@export_range(0.0, 20.0, 0.1) var water_body_depth_start_m: float = 0.5:
	set(value):
		water_body_depth_start_m = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.1, 50.0, 0.1) var water_body_depth_end_m: float = 8.0:
	set(value):
		water_body_depth_end_m = clampf(value, 0.1, 50.0)
		_request_visual_sync()

# Deprecated compatibility field. Legacy only. No production effect.
@export_range(0.1, 20.0, 0.1) var shallow_depth_range: float = 5.5:
	set(value):
		shallow_depth_range = value
		_request_visual_sync()

@export_range(0.0, 500.0, 1.0) var opacity_distance_start: float = 80.0:
	set(value):
		opacity_distance_start = value
		_request_visual_sync()

@export_range(1.0, 1000.0, 1.0) var opacity_distance_end: float = 220.0:
	set(value):
		opacity_distance_end = value
		_request_visual_sync()

@export_range(0.0, 0.5, 0.01) var refraction_micro_normal_strength: float = 0.15:
	set(value):
		refraction_micro_normal_strength = clampf(value, 0.0, 0.5)
		_request_visual_sync()

@export_range(0.0, 64.0, 1.0) var refraction_max_offset_px: float = 24.0:
	set(value):
		refraction_max_offset_px = clampf(value, 0.0, 64.0)
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var refraction_depth_tolerance_m: float = 0.35:
	set(value):
		refraction_depth_tolerance_m = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export_group("Water Optics / Refraction V2")

@export_range(0.0, 20.0, 0.01) var refraction_wave_strength: float = 1.0:
	set(value):
		refraction_wave_strength = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.0, 20.0, 0.01) var refraction_long_weight: float = 0.30:
	set(value):
		refraction_long_weight = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.0, 20.0, 0.01) var refraction_mid_weight: float = 0.55:
	set(value):
		refraction_mid_weight = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.0, 20.0, 0.01) var refraction_short_weight: float = 0.15:
	set(value):
		refraction_short_weight = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.0, 50.0, 0.1) var refraction_depth_start_m: float = 1.0:
	set(value):
		refraction_depth_start_m = clampf(value, 0.0, 50.0)
		_request_visual_sync()

@export_range(0.1, 100.0, 0.1) var refraction_depth_end_m: float = 20.0:
	set(value):
		refraction_depth_end_m = clampf(value, 0.1, 100.0)
		_request_visual_sync()

@export var scattering_color: Color = Color(0.02, 0.32, 0.42, 1.0):
	set(value):
		scattering_color = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var scattering_strength: float = 0.45:
	set(value):
		scattering_strength = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var scattering_shallow_tint_influence: float = 1.0:
	set(value):
		scattering_shallow_tint_influence = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var scattering_deep_tint_influence: float = 0.15:
	set(value):
		scattering_deep_tint_influence = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var shallow_scattering_strength: float = 0.5:
	set(value):
		shallow_scattering_strength = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export_range(0.0, 20.0, 0.1) var shallow_scattering_depth_start_m: float = 1.0:
	set(value):
		shallow_scattering_depth_start_m = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.1, 30.0, 0.1) var shallow_scattering_depth_end_m: float = 8.0:
	set(value):
		shallow_scattering_depth_end_m = clampf(value, 0.1, 30.0)
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var water_turbidity: float = 0.35:
	set(value):
		water_turbidity = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export_range(0.0, 0.5, 0.01) var crest_transmission_boost: float = 0.12:
	set(value):
		crest_transmission_boost = clampf(value, 0.0, 0.5)
		_request_visual_sync()

@export_range(0.0, 0.5, 0.01) var trough_density_boost: float = 0.10:
	set(value):
		trough_density_boost = clampf(value, 0.0, 0.5)
		_request_visual_sync()

@export_range(0.0, 100.0, 0.5) var transmission_detail_fade_start_m: float = 10.0:
	set(value):
		transmission_detail_fade_start_m = clampf(value, 0.0, 100.0)
		_request_visual_sync()

@export_range(1.0, 150.0, 0.5) var transmission_detail_fade_end_m: float = 30.0:
	set(value):
		transmission_detail_fade_end_m = clampf(value, 1.0, 150.0)
		_request_visual_sync()

@export_range(0.0, 8.0, 0.1) var transmission_max_lod: float = 5.0:
	set(value):
		transmission_max_lod = clampf(value, 0.0, 8.0)
		_request_visual_sync()

@export_group("Water Optics / Seabed Transmission")
@export_range(0.0, 50.0, 0.5) var bottom_visibility_fade_start_m: float = 6.0:
	set(value):
		bottom_visibility_fade_start_m = clampf(value, 0.0, 50.0)
		_request_visual_sync()

@export_range(0.1, 100.0, 0.5) var bottom_visibility_fade_end_m: float = 12.0:
	set(value):
		bottom_visibility_fade_end_m = clampf(value, 0.1, 100.0)
		_request_visual_sync()

@export_range(0.0, 20.0, 0.25) var seabed_match_tolerance_start_m: float = 1.0:
	set(value):
		seabed_match_tolerance_start_m = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.1, 50.0, 0.25) var seabed_match_tolerance_end_m: float = 4.0:
	set(value):
		seabed_match_tolerance_end_m = clampf(value, 0.1, 50.0)
		_request_visual_sync()

@export_group("Water Optics / Shallow Surface Relief")
@export_range(0.0, 1.0, 0.01) var shallow_fresnel_relief: float = 0.58:
	set(value):
		shallow_fresnel_relief = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 50.0, 0.1) var shallow_fresnel_depth_start_m: float = 1.5:
	set(value):
		shallow_fresnel_depth_start_m = clampf(value, 0.0, 50.0)
		_request_visual_sync()

@export_range(0.1, 100.0, 0.1) var shallow_fresnel_depth_end_m: float = 6.0:
	set(value):
		shallow_fresnel_depth_end_m = clampf(value, 0.1, 100.0)
		_request_visual_sync()

@export_group("Caustics / Main")
@export var caustics_enabled := false:
	set(value):
		caustics_enabled = value
		_request_visual_sync()

const REFERENCE_CAUSTICS_TEXTURE_PATH := "res://ocean_v3/rendering/caustics/reference_assets/caustics-generator.png"
const FALLBACK_REFERENCE_CAUSTICS_TEXTURE_PATH := "res://ocean_v3/rendering/caustics/caustics-generator.png"
const FALLBACK_CAUSTICS_TEXTURE_PATH := "res://ocean_v3/rendering/caustics/caustics_filament_tile.png"
const REFERENCE_CAUSTICS_LUMA_GRADIENT_PATH := "res://ocean_v3/rendering/caustics/reference_assets/luma_gradient.tres"
const FALLBACK_CAUSTICS_LUMA_GRADIENT_PATH := "res://ocean_v3/rendering/caustics/luma_gradient.tres"

@export var caustics_texture: Texture2D:
	set(value):
		caustics_texture = value
		_request_visual_sync()

## Larger values produce a visually larger pattern: tiling is 1.0 / scale.
@export_range(0.05, 50.0, 0.01) var caustics_scale := 4.0:
	set(value):
		caustics_scale = clampf(value, 0.05, 50.0)
		_request_visual_sync()

@export_range(-5.0, 5.0, 0.001) var caustics_speed := 0.1:
	set(value):
		caustics_speed = clampf(value, -5.0, 5.0)
		_request_visual_sync()

@export_range(0.0, 8.0, 0.01) var caustics_strength := 1.0:
	set(value):
		caustics_strength = clampf(value, 0.0, 8.0)
		_request_visual_sync()

@export_range(0.25, 8.0, 0.01) var caustics_power := 2.0:
	set(value):
		caustics_power = clampf(value, 0.25, 8.0)
		_request_visual_sync()

@export_group("Caustics / Chromatic")
@export_range(0.0, 0.02, 0.0001) var caustics_chroma_split := 0.002:
	set(value):
		caustics_chroma_split = clampf(value, 0.0, 0.02)
		_request_visual_sync()

@export_group("Caustics / Layers")
@export_range(-4.0, 4.0, 0.01) var caustics_layer_a_speed_multiplier := 0.75:
	set(value):
		caustics_layer_a_speed_multiplier = clampf(value, -4.0, 4.0)
		_request_visual_sync()

@export_range(-4.0, 4.0, 0.01) var caustics_layer_b_speed_multiplier := 1.0:
	set(value):
		caustics_layer_b_speed_multiplier = clampf(value, -4.0, 4.0)
		_request_visual_sync()

@export_range(-4.0, 4.0, 0.01) var caustics_layer_a_scale_multiplier := 1.0:
	set(value):
		caustics_layer_a_scale_multiplier = clampf(value, -4.0, 4.0)
		_request_visual_sync()

@export_range(-4.0, 4.0, 0.01) var caustics_layer_b_scale_multiplier := -1.0:
	set(value):
		caustics_layer_b_scale_multiplier = clampf(value, -4.0, 4.0)
		_request_visual_sync()

@export var caustics_layer_a_direction := Vector2(1.0, 0.0):
	set(value):
		caustics_layer_a_direction = value
		_request_visual_sync()

@export var caustics_layer_b_direction := Vector2(1.0, 0.0):
	set(value):
		caustics_layer_b_direction = value
		_request_visual_sync()

@export_group("Caustics / Lighting")
@export var caustics_luma_gradient: Texture2D:
	set(value):
		caustics_luma_gradient = value
		_request_visual_sync()

@export_range(-2.0, 2.0, 0.01) var caustics_luminance_mask_strength := 0.2:
	set(value):
		caustics_luminance_mask_strength = clampf(value, -2.0, 2.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var caustics_sun_strength := 1.0:
	set(value):
		caustics_sun_strength = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_group("Caustics / Depth")
@export_range(0.0, 20.0, 0.1) var caustics_fade_start_depth := 4.0:
	set(value):
		caustics_fade_start_depth = clampf(value, 0.0, 20.0)
		_request_visual_sync()

@export_range(0.1, 50.0, 0.1, "suffix: m") var caustics_max_depth := 6.0:
	set(value):
		caustics_max_depth = clampf(value, 0.1, 50.0)
		_request_visual_sync()

@export_group("Caustics / Spatial Fade")
## Reserved until Ocean V3 has a coherent caustics receiver volume. Depth fade
## is the active spatial constraint for the full-screen compositor pass.
@export_range(0.0, 500.0, 0.1, "suffix: m") var caustics_fade_radius := 100.0
@export_range(0.0, 1.0, 0.01) var caustics_fade_strength := 0.5

@export_group("Caustics / Debug")
@export_enum("CAUSTICS_OFF", "CAUSTICS_ON", "DEBUG_CAUSTICS_FINAL") var caustics_debug_mode := 0:
	set(value):
		caustics_debug_mode = clampi(value, 0, 2)
		_request_visual_sync()

## Legacy serialized properties only. They are intentionally hidden from the
## Inspector and do not affect the projected compositor implementation.
@export_storage var caustics_resolution := 256
@export_storage var caustics_update_rate := 30.0
@export_storage var caustics_field_extent_m := 96.0
@export_storage var caustics_texture_scale := 0.105
@export_storage var caustics_animation_speed := 0.12

@export_enum("OFF", "WATER_THICKNESS", "TRANSMITTANCE_RGB", "WATER_BODY_COLOR", "REFRACTION_OFFSET", "REFRACTION_VALIDITY", "SCATTERING", "WATER_BODY_FINAL", "TRANSMISSION_DETAIL_FADE", "BODY_DEPTH_FACTOR", "TRANSMISSION_OPTICAL_DEPTH", "SHALLOW_SCATTERING_FACTOR", "SCATTERING_TINT_INFLUENCE", "SHALLOW_SCATTERING_FINAL", "LOCAL_WATER_DEPTH", "VIEW_WATER_PATH", "SHALLOW_DEEP_AUTHORITY", "RAW_BATHYMETRY_FRAGMENT", "BATHYMETRY_DOMAIN", "COASTAL_PROPAGATION_VALIDITY", "RAW_SCENE_DEPTH", "SCENE_DEPTH_CLASS", "RAW_WATER_FRAGMENT_DEPTH", "BATHYMETRY_COMPARE_VERTEX_FRAGMENT", "DEBUG_SENTINEL_MAGENTA", "DEBUG_SENTINEL_GREEN", "SEABED_MATCH", "BOTTOM_DEPTH_VISIBILITY", "BOTTOM_TRANSMISSION_WEIGHT", "SEABED_HEIGHT_ERROR", "ORIGINAL_SEABED_MATCH", "CANDIDATE_SEABED_MATCH", "EFFECTIVE_SEABED_MATCH", "EFFECTIVE_BOTTOM_TRANSMISSION_WEIGHT", "REAL_SEABED_COVERAGE_RAW", "OPTICAL_SEABED_CONFIDENCE", "OPTICAL_LOCAL_WATER_DEPTH", "OPEN_OCEAN_NO_SEABED_MASK", "REFRACTION_SLOPE", "REFRACTION_DEPTH_FACTOR", "REFRACTION_BACKGROUND_ONLY") var water_optics_debug_mode: int = 0:
	set(value):
		var next_mode := clampi(value, 0, 40)
		if water_optics_debug_mode != next_mode:
			print("WATER_OPTICS_DEBUG_PROPERTY mode=%d" % next_mode)
		water_optics_debug_mode = next_mode
		_request_visual_sync()

@export_group("Reflection")
@export_range(0.0, 1.0, 0.005) var reflection_min_roughness: float = 0.035:
	set(value):
		reflection_min_roughness = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_base_roughness: float = 0.055:
	set(value):
		reflection_base_roughness = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_distance_roughness: float = 0.23:
	set(value):
		reflection_distance_roughness = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_detail_roughness_gain: float = 0.10:
	set(value):
		reflection_detail_roughness_gain = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_distance_roughness_gain: float = 1.0:
	set(value):
		reflection_distance_roughness_gain = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_pixel_footprint_gain: float = 1.0:
	set(value):
		reflection_pixel_footprint_gain = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.005) var reflection_slope_variance_gain: float = 0.35:
	set(value):
		reflection_slope_variance_gain = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export var reflection_roughness_distance_m: Vector2 = Vector2(80.0, 220.0):
	set(value):
		reflection_roughness_distance_m = Vector2(maxf(value.x, 0.0), maxf(value.y, value.x + 0.001))
		_request_visual_sync()

@export var reflection_sspr_enabled: bool = true:
	set(value):
		reflection_sspr_enabled = value
		_request_visual_sync()

@export_range(0.25, 1.0, 0.05) var reflection_sspr_resolution_scale: float = 0.50:
	set(value):
		reflection_sspr_resolution_scale = clampf(value, 0.25, 1.0)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var reflection_sspr_distortion_strength: float = 0.35:
	set(value):
		reflection_sspr_distortion_strength = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export_range(0.0, 0.25, 0.005) var reflection_sspr_edge_fade: float = 0.08:
	set(value):
		reflection_sspr_edge_fade = clampf(value, 0.0, 0.25)
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var reflection_sspr_slope_fade: float = 0.65:
	set(value):
		reflection_sspr_slope_fade = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export var reflection_sspr_hole_fill_enabled: bool = true:
	set(value):
		reflection_sspr_hole_fill_enabled = value
		_request_visual_sync()

@export var reflection_sspr_facet_gate_enabled: bool = true:
	set(value):
		reflection_sspr_facet_gate_enabled = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var reflection_sspr_facet_gate_strength: float = 1.0:
	set(value):
		reflection_sspr_facet_gate_strength = clampf(value, 0.0, 1.0)
		_request_visual_sync()

@export var reflection_distance_blur_enabled: bool = true:
	set(value):
		reflection_distance_blur_enabled = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var reflection_distance_blur_strength: float = 1.0:
	set(value):
		reflection_distance_blur_strength = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export_range(1.0, 500.0, 1.0) var reflection_distance_blur_reference_m: float = 50.0:
	set(value):
		reflection_distance_blur_reference_m = clampf(value, 1.0, 500.0)
		_request_visual_sync()

@export var reflection_near_ssr_enabled: bool = true:
	set(value):
		reflection_near_ssr_enabled = value
		_request_visual_sync()

@export_range(1.0, 100.0, 1.0) var reflection_near_ssr_distance_m: float = 35.0:
	set(value):
		reflection_near_ssr_distance_m = clampf(value, 1.0, 100.0)
		_request_visual_sync()

@export_range(25.0, 500.0, 1.0) var reflection_near_ssr_ray_length_m: float = 200.0:
	set(value):
		reflection_near_ssr_ray_length_m = clampf(value, 25.0, 500.0)
		_request_visual_sync()

@export_range(0.0, 50.0, 0.5) var reflection_near_ssr_fade_m: float = 10.0:
	set(value):
		reflection_near_ssr_fade_m = clampf(value, 0.0, 50.0)
		_request_visual_sync()

@export_range(0.01, 2.0, 0.01) var reflection_near_ssr_thickness: float = 0.35:
	set(value):
		reflection_near_ssr_thickness = clampf(value, 0.01, 2.0)
		_request_visual_sync()

enum NearSSRQuality { LOW, MEDIUM, HIGH }

@export_enum("LOW:0", "MEDIUM:1", "HIGH:2") var reflection_near_ssr_quality: int = NearSSRQuality.MEDIUM:
	set(value):
		reflection_near_ssr_quality = clampi(value, NearSSRQuality.LOW, NearSSRQuality.HIGH)
		_request_visual_sync()

@export var reflection_sspr_kawase_enabled: bool = false:
	set(value):
		reflection_sspr_kawase_enabled = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.05) var reflection_sspr_kawase_radius: float = 1.0:
	set(value):
		reflection_sspr_kawase_radius = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export var reflection_sspr_temporal_enabled: bool = true:
	set(value):
		reflection_sspr_temporal_enabled = value
		_request_visual_sync()

@export_range(0.0, 0.5, 0.01) var reflection_sspr_temporal_weight: float = 0.12:
	set(value):
		reflection_sspr_temporal_weight = clampf(value, 0.0, 0.5)
		_request_visual_sync()

@export_range(0.001, 0.25, 0.001) var reflection_sspr_temporal_depth_threshold: float = 0.035:
	set(value):
		reflection_sspr_temporal_depth_threshold = clampf(value, 0.001, 0.25)
		_request_visual_sync()

@export_range(-2.0, 2.0, 0.05) var reflection_radiance_exposure_ev: float = 0.0:
	set(value):
		reflection_radiance_exposure_ev = clampf(value, -2.0, 2.0)
		_request_visual_sync()

@export_range(0.5, 2.0, 0.01) var reflection_radiance_contrast: float = 1.0:
	set(value):
		reflection_radiance_contrast = clampf(value, 0.5, 2.0)
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var reflection_radiance_saturation: float = 1.0:
	set(value):
		reflection_radiance_saturation = clampf(value, 0.0, 2.0)
		_request_visual_sync()

@export var reflection_radiance_tint: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(value):
		reflection_radiance_tint = value
		_request_visual_sync()

@export_range(0.0, 1.5, 0.01) var reflection_screen_space_weight: float = 1.0:
	set(value):
		reflection_screen_space_weight = clampf(value, 0.0, 1.5)
		_request_visual_sync()

@export_range(0.5, 2.0, 0.01) var reflection_environment_specular_boost: float = 1.0:
	set(value):
		reflection_environment_specular_boost = clampf(value, 0.5, 2.0)
		_request_visual_sync()


@export_group("Whitecaps Foam")
@export var foam_enabled: bool = true:
	set(value):
		foam_enabled = value
		_request_visual_sync()

@export var foam_color: Color = Color(0.82, 0.91, 0.90, 1.0):
	set(value):
		foam_color = value
		_request_visual_sync()

@export_range(0.0, 4.0, 0.01) var foam_intensity: float = 1.0:
	set(value):
		foam_intensity = value
		_request_visual_sync()

@export var foam_fresh_color: Color = Color(0.97, 0.99, 0.98, 1.0):
	set(value):
		foam_fresh_color = value
		_request_visual_sync()

@export var foam_residual_color: Color = Color(0.82, 0.91, 0.90, 1.0):
	set(value):
		foam_residual_color = value
		_request_visual_sync()

@export_range(0.0, 4.0, 0.01) var foam_fresh_strength: float = 1.0:
	set(value):
		foam_fresh_strength = value
		_request_visual_sync()

@export_range(0.0, 4.0, 0.01) var foam_residual_strength: float = 1.0:
	set(value):
		foam_residual_strength = value
		_request_visual_sync()

@export_range(0.0, 3.0, 0.01) var foam_residual_decay_multiplier: float = 1.0:
	set(value):
		foam_residual_decay_multiplier = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var foam_deposit_strength: float = 0.72:
	set(value):
		foam_deposit_strength = value
		_request_visual_sync()

@export var foam_advection_enabled: bool = true:
	set(value):
		foam_advection_enabled = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var foam_advection_strength: float = 1.0:
	set(value):
		foam_advection_strength = value
		_request_visual_sync()

@export_enum("30 Hz:30", "45 Hz:45", "60 Hz:60") var crest_foam_update_hz: int = 60:
	set(value):
		crest_foam_update_hz = 30 if value <= 30 else 45 if value <= 45 else 60
		_request_visual_sync()

@export var crest_foam_compute_enabled := true:
	set(value):
		crest_foam_compute_enabled = value
		_request_visual_sync()

@export_range(0.0, 10.0, 0.01) var foam_normal_strength: float = 1.2:
	set(value):
		foam_normal_strength = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var foam_fresh_normal_weight: float = 1.0:
	set(value):
		foam_fresh_normal_weight = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var foam_residual_normal_weight: float = 0.40:
	set(value):
		foam_residual_normal_weight = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var foam_micro_normal_strength: float = 0.20:
	set(value):
		foam_micro_normal_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_threshold: float = 0.0:
	set(value):
		foam_threshold = value
		_request_visual_sync()

@export_range(0.1, 4.0, 0.01) var foam_contrast: float = 1.35:
	set(value):
		foam_contrast = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_roughness: float = 0.88:
	set(value):
		foam_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_alpha_boost: float = 0.18:
	set(value):
		foam_alpha_boost = value
		_request_visual_sync()

@export_range(0.0, 4000.0, 1.0) var foam_distance_fade_start: float = 180.0:
	set(value):
		foam_distance_fade_start = value
		_request_visual_sync()

@export_range(1.0, 5000.0, 1.0) var foam_distance_fade_end: float = 900.0:
	set(value):
		foam_distance_fade_end = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_breakup_strength: float = 0.45:
	set(value):
		foam_breakup_strength = value
		_request_visual_sync()

@export_range(1.0, 200.0, 0.5) var foam_breakup_world_size: float = 14.0:
	set(value):
		foam_breakup_world_size = value
		_request_visual_sync()

@export_range(-2.0, 2.0, 0.01) var foam_breakup_speed: float = 0.0:
	set(value):
		foam_breakup_speed = value
		_request_visual_sync()

@export_range(0.01, 0.49, 0.01) var foam_edge_softness: float = 0.16:
	set(value):
		foam_edge_softness = value
		_request_visual_sync()


@export_group("Whitecaps Foam / Crest Filigree")
@export var crest_filigree_enabled := true:
	set(value):
		crest_filigree_enabled = value
		_request_visual_sync()

@export_range(0.0, 1.5, 0.01) var crest_filigree_whitecap: float = 0.0:
	set(value):
		crest_filigree_whitecap = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var crest_fresh_filigree_strength := 0.22:
	set(value):
		crest_fresh_filigree_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var crest_residual_filigree_strength := 0.65:
	set(value):
		crest_residual_filigree_strength = value
		_request_visual_sync()

@export_range(0.1, 4.0, 0.01) var crest_filigree_contrast := 1.0:
	set(value):
		crest_filigree_contrast = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var crest_filigree_threshold := 0.0:
	set(value):
		crest_filigree_threshold = value
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var crest_filigree_normal_influence := 0.35:
	set(value):
		crest_filigree_normal_influence = value
		_request_visual_sync()


@export_group("Whitecaps Foam / Surface Foam")
@export var surface_foam_enabled: bool = true:
	set(value):
		surface_foam_enabled = value
		_request_visual_sync()

@export var surface_foam_stochastic_deperiodization_enabled: bool = true:
	set(value):
		surface_foam_stochastic_deperiodization_enabled = value
		_request_visual_sync()

@export_range(16.0, 96.0, 0.5) var surface_foam_stochastic_cell_size_m: float = 32.0:
	set(value):
		surface_foam_stochastic_cell_size_m = clampf(value, 16.0, 96.0)
		_request_visual_sync()

@export_range(0.0, 1.5, 0.01) var surface_foam_whitecap: float = 0.0:
	set(value):
		surface_foam_whitecap = value
		_request_visual_sync()

@export_enum("512:512", "1024:1024") var surface_foam_topology_resolution: int = 1024:
	set(value):
		surface_foam_topology_resolution = 512 if value <= 512 else 1024
		_request_visual_sync()

@export_range(0.0, 10.0, 0.001) var surface_foam_amount: float = 8.573:
	set(value):
		surface_foam_amount = value
		_request_visual_sync()

@export_enum("30 Hz:30", "45 Hz:45", "60 Hz:60") var surface_foam_update_hz: int = 30:
	set(value):
		surface_foam_update_hz = 30 if value <= 30 else 45 if value <= 45 else 60
		_request_visual_sync()

@export_range(0.02, 1.0, 0.01) var surface_foam_birth_attack_s: float = 0.16:
	set(value):
		surface_foam_birth_attack_s = value
		_request_visual_sync()

@export_range(0.1, 5.0, 0.05) var surface_foam_lifetime_s: float = 1.10:
	set(value):
		surface_foam_lifetime_s = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_birth_selectivity: float = 0.28:
	set(value):
		surface_foam_birth_selectivity = value
		_request_visual_sync()

@export_range(0.0, 1.5, 0.01) var surface_foam_evolution_speed: float = 0.35:
	set(value):
		surface_foam_evolution_speed = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_ocean_coupling: float = 0.35:
	set(value):
		surface_foam_ocean_coupling = value
		_request_visual_sync()

@export_range(0.0, 2000.0, 1.0) var surface_foam_distance_fade_start_m: float = 200.0:
	set(value):
		surface_foam_distance_fade_start_m = clampf(value, 0.0, 2000.0)
		surface_foam_distance_fade_end_m = maxf(surface_foam_distance_fade_end_m, surface_foam_distance_fade_start_m + 1.0)
		_request_visual_sync()

@export_range(1.0, 2000.0, 1.0) var surface_foam_distance_fade_end_m: float = 600.0:
	set(value):
		surface_foam_distance_fade_end_m = maxf(value, surface_foam_distance_fade_start_m + 1.0)
		_request_visual_sync()

@export_range(0.0, 4.0, 0.01) var surface_foam_strength: float = 1.0:
	set(value):
		surface_foam_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_threshold_visual: float = 0.0:
	set(value):
		surface_foam_threshold_visual = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_mid_fold_start: float = 0.10:
	set(value):
		surface_foam_mid_fold_start = clampf(value, 0.0, 1.0)
		surface_foam_mid_fold_end = maxf(surface_foam_mid_fold_end, surface_foam_mid_fold_start + 0.01)
		_request_visual_sync()

@export_range(0.01, 1.0, 0.01) var surface_foam_mid_fold_end: float = 0.24:
	set(value):
		surface_foam_mid_fold_end = maxf(value, surface_foam_mid_fold_start + 0.01)
		_request_visual_sync()

@export var surface_foam_color: Color = Color(0.78, 0.84, 0.82, 1.0):
	set(value):
		surface_foam_color = value
		_request_visual_sync()

@export_range(0.0, 10.0, 0.01) var surface_foam_normal_strength: float = 0.55:
	set(value):
		surface_foam_normal_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_fresh_roughness: float = 0.95:
	set(value):
		foam_fresh_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_residual_roughness: float = 0.88:
	set(value):
		foam_residual_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_roughness: float = 0.82:
	set(value):
		surface_foam_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_fresh_specular: float = 0.12:
	set(value):
		foam_fresh_specular = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_residual_specular: float = 0.18:
	set(value):
		foam_residual_specular = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_specular: float = 0.20:
	set(value):
		surface_foam_specular = value
		_request_visual_sync()

@export_group("Whitecaps Foam / Surface Foam Spectrum")
@export_enum("256:256", "512:512", "1024:1024") var surface_foam_fft_resolution: int = 512:
	set(value):
		surface_foam_fft_resolution = _normalize_resolution_enum(value)
		_request_visual_sync()

@export_enum("256:256", "512:512", "1024:1024") var surface_foam_field_resolution: int = 1024:
	set(value):
		surface_foam_field_resolution = _normalize_resolution_enum(value)
		_request_visual_sync()

## Real FFT period controlling Surface Foam feature morphology.
@export_range(4.0, 32.0, 0.5) var surface_foam_source_domain_m: float = 8.0:
	set(value):
		surface_foam_source_domain_m = clampf(value, 4.0, 32.0)
		_request_visual_sync()

## Persistent/history period. Source detail is deperiodized into this field.
@export_range(8.0, 256.0, 0.5) var surface_foam_field_domain_m: float = 88.0:
	set(value):
		surface_foam_field_domain_m = maxf(value, 8.0)
		_request_visual_sync()

@export_range(0.1, 200.0, 0.1) var surface_foam_depth_m: float = 20.0:
	set(value):
		surface_foam_depth_m = value
		_request_visual_sync()

@export_range(0.1, 60.0, 0.1) var surface_foam_wind_speed_mps: float = 10.0:
	set(value):
		surface_foam_wind_speed_mps = clampf(value, 0.1, 60.0)
		_request_visual_sync()

@export_range(-180.0, 180.0, 0.5) var surface_foam_wind_direction_deg: float = 110.0:
	set(value):
		surface_foam_wind_direction_deg = value
		_request_visual_sync()

@export_range(1.0, 50000.0, 1.0) var surface_foam_fetch_m: float = 6000.0:
	set(value):
		surface_foam_fetch_m = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.001) var surface_foam_swell: float = 0.779:
	set(value):
		surface_foam_swell = value
		_request_visual_sync()

# JONSWAP semantics: 0 = narrow/full Hasselmann directionality; 1 = isotropic.
@export_range(0.0, 1.0, 0.01) var surface_foam_directional_spread: float = 0.0:
	set(value):
		surface_foam_directional_spread = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_detail: float = 1.0:
	set(value):
		surface_foam_detail = value
		_request_visual_sync()

@export_group("Whitecaps Foam / Surface Foam Micro Detail")
@export var surface_foam_micro_detail: Texture2D:
	set(value):
		surface_foam_micro_detail = value
		_request_visual_sync()

@export var surface_foam_micro_detail_enabled := true:
	set(value):
		surface_foam_micro_detail_enabled = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_micro_strength := 0.45:
	set(value):
		surface_foam_micro_strength = value
		_request_visual_sync()

## World tile sizes for the dedicated foam breakup texture: medium and near.
@export var surface_foam_micro_scale := Vector2(10.0, 3.2):
	set(value):
		surface_foam_micro_scale = Vector2(maxf(value.x, 0.02), maxf(value.y, 0.01))
		_request_visual_sync()

@export_range(0.0, 2.0, 0.01) var surface_foam_micro_normal_strength := 0.25:
	set(value):
		surface_foam_micro_normal_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var surface_foam_edge_fade_strength: float = 0.35:
	set(value):
		surface_foam_edge_fade_strength = value
		_request_visual_sync()

@export_range(0.01, 0.5, 0.01) var surface_foam_edge_fade_width: float = 0.14:
	set(value):
		surface_foam_edge_fade_width = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var foam_detail_contribution: float = 0.35:
	set(value):
		foam_detail_contribution = value
		_request_visual_sync()

@export_group("Whitecaps Foam Debug")
@export_enum("OFF", "CREST_FINAL", "SURFACE_HISTORY", "SURFACE_MACRO", "SURFACE_FINAL", "SURFACE_DIRECT_RAW", "SURFACE_DEPERIODIZED_RAW", "SURFACE_PLUS_CREST", "FOAM_NORMAL", "SURFACE_MID_FOLD", "CREST_FILIGREE_SOURCE", "CREST_FILIGREE_MASK", "CREST_FRESH_WEBBED", "CREST_RESIDUAL_WEBBED", "CREST_FRESH_RAW", "CREST_RESIDUAL_RAW") var foam_debug_mode: int = 0:
	set(value):
		foam_debug_mode = clampi(value, 0, 15)
		_request_visual_sync()


var _visual_sync_pending := true
var _sea_state_zones: Array[OceanSeaStateZone3D] = []
var _sea_state_zone_descriptors: Array[Dictionary] = []
var _sea_state_zone_uniform_data0 := PackedVector4Array()
var _sea_state_zone_uniform_data1 := PackedVector4Array()
var _sea_state_zone_uniform_data2 := PackedVector4Array()
var _sea_state_zone_uniform_data3 := PackedVector4Array()
var _sea_state_zones_dirty := true
var _sea_state_zone_debug := false
var _reflection_debug_mode := 0
var _sun_direction_world := Vector3(0.0, 0.0, 1.0)
var _reflection_sspr_manager: Node
var _caustics_manager: Node
var _underwater_manager: Node
var _camera_underwater := false
var _underwater_factor := 0.0
var _camera_water_surface_y := 0.0
var _camera_water_normal := Vector3.UP
var _underwater_viewer_medium := UnderwaterViewerMedium.AIR
var _startup_started_usec := 0
var _startup_setup_usec := 0
var _startup_stable_frames := 0
var _startup_reported := false


func _ready() -> void:
	_startup_started_usec = Time.get_ticks_usec()
	add_to_group(&"ocean_v3_root")
	for node in get_tree().get_nodes_in_group(&"ocean_sea_state_zone"):
		if node is OceanSeaStateZone3D:
			register_sea_state_zone(node)
	_refresh_sea_state_zones()
	_visual_sync_pending = true
	if wave_preset != null:
		apply_selected_wave_preset()
	_configure_coastal_bake_asset()
	_sync_diagnostic_band_mask()
	if not Engine.is_editor_hint():
		_reflection_sspr_manager = SSPR_MANAGER_SCRIPT.new()
		_reflection_sspr_manager.name = &"OceanSSPRManager"
		add_child(_reflection_sspr_manager)
		_reflection_sspr_manager.configure(self, _surface_sea_level(), reflection_sspr_enabled)
		_caustics_manager = CAUSTICS_MANAGER_SCRIPT.new()
		_caustics_manager.name = &"OceanCausticsManager"
		add_child(_caustics_manager)
		_caustics_manager.configure(self, _surface_sea_level(), caustics_enabled,
			_active_caustics_texture(), _active_caustics_luma_gradient(), caustics_scale,
			caustics_speed, caustics_strength, caustics_power, caustics_chroma_split,
			caustics_layer_a_speed_multiplier, caustics_layer_b_speed_multiplier,
			caustics_layer_a_scale_multiplier, caustics_layer_b_scale_multiplier,
			caustics_layer_a_direction, caustics_layer_b_direction,
			caustics_luminance_mask_strength, caustics_sun_strength,
			caustics_fade_start_depth, caustics_max_depth, _sun_direction_world,
			caustics_debug_mode)
		_underwater_manager = UNDERWATER_MANAGER_SCRIPT.new()
		_underwater_manager.name = &"OceanUnderwaterManager"
		add_child(_underwater_manager)
		_underwater_manager.configure(self)
	_apply_performance_profile()
	_ensure_performance_overlay()
	_startup_setup_usec = Time.get_ticks_usec()
	call_deferred(&"_flush_visual_sync")


func _surface_sea_level() -> float:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	return surface.clipmap_config.sea_level_y if surface != null else 0.0


func _update_underwater_camera_state() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_camera_water_surface_y = _surface_sea_level()
		_camera_water_normal = Vector3.UP
		_camera_underwater = false
		_underwater_factor = 0.0
		_underwater_viewer_medium = UnderwaterViewerMedium.AIR
		return
	# WaterInterface V2 permits exactly one existing render-time OceanQuery: it
	# determines only the local viewer side/hysteresis. The complete projected
	# interface remains GPU-owned by the auxiliary displaced clipmap viewport.
	var sampled_height := _surface_sea_level()
	var sampled_normal := Vector3.UP
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if fft_module != null:
		var sample = fft_module.sample_water(camera.global_position, SimulationClock.get_render_time())
		if sample != null and sample.valid:
			sampled_height = sample.height
			if sample.normal.length_squared() > 0.0001:
				sampled_normal = sample.normal.normalized()
	_camera_water_surface_y = sampled_height
	_camera_water_normal = sampled_normal
	var signed_surface_distance := (camera.global_position - Vector3(camera.global_position.x, sampled_height, camera.global_position.z)).dot(sampled_normal)
	if signed_surface_distance > UNDERWATER_EXIT_MARGIN_M:
		_camera_underwater = false
		_underwater_viewer_medium = UnderwaterViewerMedium.AIR
	elif signed_surface_distance < -UNDERWATER_ENTER_MARGIN_M:
		_camera_underwater = true
		_underwater_viewer_medium = UnderwaterViewerMedium.WATER
	else:
		_underwater_viewer_medium = UnderwaterViewerMedium.CROSSING
	var half_width := maxf(underwater_transition_width_m, 0.01)
	_underwater_factor = 1.0 - smoothstep(
		-half_width,
		half_width,
		signed_surface_distance
	)


func _sync_underwater_manager() -> void:
	if _underwater_manager == null or not is_instance_valid(_underwater_manager):
		return
	_underwater_manager.set_settings({
		"enabled": underwater_enabled,
		"viewer_medium": _underwater_viewer_medium,
		"camera_factor": _underwater_factor,
		"transition_width": underwater_transition_width_m,
		"waterline_feather": underwater_waterline_feather,
		"absorption": absorption_coeff_rgb,
		"absorption_scale": underwater_absorption_scale,
		"scattering_color": underwater_scattering_color,
		"scattering_strength": underwater_scattering_strength,
		"scattering_density": underwater_scattering_density,
		"max_distance": underwater_max_optical_distance_m,
		"debug_mode": underwater_debug_mode,
	})


func _configure_coastal_bake_asset() -> void:
	if Engine.is_editor_hint():
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if fft_module == null:
		push_error("OceanV3: no se encontró OpenOceanFFT interno.")
		return
	fft_module.set_coastal_bake_asset(coastal_bake_asset, coastal_enabled_on_start)


func set_coastal_enabled(enabled: bool) -> void:
	coastal_enabled_on_start = enabled
	if Engine.is_editor_hint():
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if fft_module != null:
		fft_module.set_coastal_runtime_enabled(enabled)


func set_performance_profile(profile: Dictionary) -> void:
	## Applies only the runtime profiling gates. Authored controls remain intact.
	for key in [
		"spectral", "coastal", "crest_foam_solver", "surface_foam_solver",
		"mid_fold_history", "surface_foam_render", "prebreak", "breakers", "sspr", "refraction"
	]:
		if profile.has(key):
			set("perf_enable_%s" % key, bool(profile[key]))
	_apply_performance_profile()


func set_benchmark_diagnostic_gates(gates: Dictionary) -> void:
	## Benchmark-only: each false value removes one coherent visual block. This
	## does not change authored parameters or persist into scene resources.
	_benchmark_diagnostic_gates = gates.duplicate(true)
	_request_visual_sync()


func apply_performance_preset(preset: StringName) -> bool:
	## Presets are intentionally explicit so automated A/B tests can request them.
	var key := String(preset).to_upper().replace("-", "_").replace(" ", "_")
	var profile := _full_performance_profile()
	match key:
		"FULL":
			pass
		"BASE":
			profile = _base_performance_profile()
		"NO_SSPR":
			profile["sspr"] = false
		"NO_FOAM":
			profile["crest_foam_solver"] = false
			profile["surface_foam_solver"] = false
			profile["mid_fold_history"] = false
			profile["surface_foam_render"] = false
		"NO_CREST_FOAM":
			profile["crest_foam_solver"] = false
		"NO_MID_FOLD_HISTORY":
			profile["mid_fold_history"] = false
		"NO_COASTAL":
			profile["coastal"] = false
			profile["breakers"] = false
			profile["prebreak"] = false
		"NO_BREAKERS":
			profile["breakers"] = false
			profile["prebreak"] = false
		_:
			push_warning("OceanV3: unknown performance preset '%s'." % preset)
			return false
	set_performance_profile(profile)
	return true


func performance_preset_name() -> String:
	var current := performance_profile()
	for preset in [PERF_PRESET_FULL, PERF_PRESET_BASE, PERF_PRESET_NO_SSPR, PERF_PRESET_NO_FOAM, PERF_PRESET_NO_COASTAL, PERF_PRESET_NO_BREAKERS, PERF_PRESET_NO_CREST_FOAM, PERF_PRESET_NO_MID_FOLD_HISTORY]:
		var expected := _full_performance_profile()
		match preset:
			&"BASE": expected = _base_performance_profile()
			&"NO_SSPR": expected["sspr"] = false
			&"NO_FOAM":
				expected["crest_foam_solver"] = false
				expected["surface_foam_solver"] = false
				expected["mid_fold_history"] = false
				expected["surface_foam_render"] = false
			&"NO_CREST_FOAM": expected["crest_foam_solver"] = false
			&"NO_MID_FOLD_HISTORY": expected["mid_fold_history"] = false
			&"NO_COASTAL":
				expected["coastal"] = false
				expected["breakers"] = false
				expected["prebreak"] = false
			&"NO_BREAKERS":
				expected["breakers"] = false
				expected["prebreak"] = false
		if current == expected:
			return String(preset)
	return "CUSTOM"


func performance_profile() -> Dictionary:
	return {
		"spectral": perf_enable_spectral,
		"coastal": perf_enable_coastal,
		"crest_foam_solver": perf_enable_crest_foam_solver,
		"surface_foam_solver": perf_enable_surface_foam_solver,
		"mid_fold_history": perf_enable_mid_fold_history,
		"surface_foam_render": perf_enable_surface_foam_render,
		"prebreak": perf_enable_prebreak,
		"breakers": perf_enable_breakers,
		"sspr": perf_enable_sspr,
		"refraction": perf_enable_refraction,
	}


func toggle_performance_overlay() -> void:
	perf_overlay_enabled = not perf_overlay_enabled


func _full_performance_profile() -> Dictionary:
	return {
		"spectral": true, "coastal": true, "crest_foam_solver": true,
		"surface_foam_solver": true, "mid_fold_history": true, "surface_foam_render": true,
		"prebreak": true, "breakers": true, "sspr": true, "refraction": true,
	}


func _base_performance_profile() -> Dictionary:
	## Minimum valid surface: spectral surface only, with optional runtime passes off.
	return {
		"spectral": true, "coastal": false, "crest_foam_solver": false,
		"surface_foam_solver": false, "mid_fold_history": false, "surface_foam_render": false,
		"prebreak": false, "breakers": false, "sspr": false, "refraction": false,
	}


func _request_performance_sync() -> void:
	if not is_inside_tree():
		return
	if _performance_sync_pending:
		return
	_performance_sync_pending = true
	call_deferred(&"_apply_performance_profile")


func _apply_performance_profile() -> void:
	_performance_sync_pending = false
	if not is_inside_tree():
		return
	_visual_sync_pending = true
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	# OpenOceanFFTModule is intentionally runtime-only. In the editor, Godot
	# exposes the non-tool child as a placeholder instance, so do not call its
	# runtime profiling API from the @tool root.
	if not Engine.is_editor_hint() and fft_module != null and is_instance_valid(fft_module):
		fft_module.set_performance_profile(performance_profile())
	if _reflection_sspr_manager != null and is_instance_valid(_reflection_sspr_manager):
		_reflection_sspr_manager.set_enabled(reflection_sspr_enabled and perf_enable_sspr)
	_update_performance_overlay_visibility()


func _ensure_performance_overlay() -> void:
	if Engine.is_editor_hint() or _performance_overlay_layer != null:
		return
	_performance_overlay_layer = CanvasLayer.new()
	_performance_overlay_layer.name = &"OceanV3PerformanceOverlay"
	_performance_overlay_layer.layer = 100
	_performance_overlay_label = Label.new()
	_performance_overlay_label.position = Vector2(16.0, 16.0)
	_performance_overlay_label.add_theme_color_override(&"font_color", Color(0.78, 0.95, 1.0, 1.0))
	_performance_overlay_label.add_theme_color_override(&"font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	_performance_overlay_label.add_theme_constant_override(&"shadow_offset_x", 2)
	_performance_overlay_label.add_theme_constant_override(&"shadow_offset_y", 2)
	_performance_overlay_layer.add_child(_performance_overlay_label)
	add_child(_performance_overlay_layer)
	_update_performance_overlay_visibility()


func _update_performance_overlay_visibility() -> void:
	if _performance_overlay_layer == null:
		return
	_performance_overlay_layer.visible = perf_overlay_enabled


func _update_performance_overlay() -> void:
	if _performance_overlay_label == null or not perf_overlay_enabled:
		return
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / float(fps) if fps > 0 else 0.0
	var profile := performance_profile()
	var lines := PackedStringArray([
		"OCEAN V3 PERFORMANCE [%s]" % performance_preset_name(),
		"SPECTRAL       %s" % _on_off(profile["spectral"]),
		"COASTAL        %s" % _on_off(profile["coastal"]),
		"CREST FOAM     %s" % _on_off(profile["crest_foam_solver"]),
		"FOAM SOLVER    %s" % _on_off(profile["surface_foam_solver"]),
		"MID HISTORY    %s" % _on_off(profile["mid_fold_history"]),
		"FOAM RENDER    %s" % _on_off(profile["surface_foam_render"]),
		"PREBREAK       %s" % _on_off(profile["prebreak"]),
		"BREAKERS       %s" % _on_off(profile["breakers"]),
		"SSPR           %s" % _on_off(profile["sspr"]),
		"Reflection     SSPR %.2f | NearSSR %s | Facet %s | DistBlur %s | Kawase %s" % [
			reflection_sspr_resolution_scale,
			_reflection_near_ssr_quality_name(),
			_on_off(reflection_sspr_facet_gate_enabled),
			_on_off(reflection_distance_blur_enabled),
			_on_off(reflection_sspr_kawase_enabled)
		],
		"REFRACTION     %s" % _on_off(profile["refraction"]),
		"FPS %d | Frame %.2f ms" % [fps, frame_ms],
		"CPU process %.2f ms | physics %.2f ms" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		],
	])
	_performance_overlay_label.text = "\n".join(lines)


func _on_off(value: bool) -> String:
	return "ON" if value else "OFF"


func _reflection_near_ssr_quality_name() -> String:
	return ["LOW", "MEDIUM", "HIGH"][clampi(reflection_near_ssr_quality, NearSSRQuality.LOW, NearSSRQuality.HIGH)]


func coastal_enabled() -> bool:
	if Engine.is_editor_hint():
		return coastal_enabled_on_start
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	return fft_module.coastal_runtime_enabled() if fft_module != null else false


func cycle_coastal_composition_debug() -> void:
	if Engine.is_editor_hint():
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if fft_module != null:
		fft_module.cycle_coastal_composition_debug()


func coastal_composition_debug_name() -> String:
	if Engine.is_editor_hint():
		return "FULL"
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	return fft_module.coastal_composition_debug_name() if fft_module != null else "UNAVAILABLE"


func _runtime_fft_module() -> OpenOceanFFTModule:
	if Engine.is_editor_hint():
		return null
	return get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule


func _sync_diagnostic_band_mask() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.set_band_enabled(
			diagnostic_long_enabled,
			diagnostic_mid_enabled,
			diagnostic_short_enabled
		)


func toggle_ocean_enabled() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_enabled()


func cycle_ocean_debug_mode() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.cycle_debug_mode()


func cycle_ocean_band_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.cycle_band_debug()


## Temporary runtime diagnosis: forwards independent band toggles to the
## clipmap surface without changing the existing band debug cycle.
func set_ocean_band_enabled(long_enabled: bool, mid_enabled: bool, short_enabled: bool) -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.set_band_enabled(long_enabled, mid_enabled, short_enabled)


func toggle_ocean_band(band_index: int) -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_band_enabled(band_index)


func toggle_ocean_clipmap_lod_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_clipmap_lod_debug()


func toggle_ocean_clipmap_tracking_debug_mode() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_clipmap_tracking_debug_mode()


func clipmap_tracking_debug_mode_name() -> String:
	if Engine.is_editor_hint():
		return "CONTINUOUS"
	var fft_module := _runtime_fft_module()
	return fft_module.clipmap_tracking_debug_mode_name() if fft_module != null else "UNAVAILABLE"


func toggle_ocean_periodicity_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_periodicity_debug()


func cycle_ocean_spectrum_model() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.cycle_spectrum_model()


func toggle_ocean_shape_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_ocean_shape_debug()


func toggle_ocean_crest_sharpen_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_ocean_crest_sharpen_debug()


func toggle_ocean_normal_fragment() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_ocean_normal_fragment()


func toggle_breaker_ribbons_diagnostic_visibility() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_breaker_ribbons_diagnostic_visibility()


func cycle_breaker_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null and fft_module.has_method(&"cycle_breaker_debug"):
		fft_module.cycle_breaker_debug()


func cycle_breaker_debug_slot() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null and fft_module.has_method(&"cycle_breaker_debug_slot"):
		fft_module.cycle_breaker_debug_slot()


func force_spawn_selected_breaker() -> bool:
	var fft_module := _runtime_fft_module()
	if fft_module != null and fft_module.has_method(&"force_spawn_selected_breaker"):
		return bool(fft_module.force_spawn_selected_breaker())
	return false


func breaker_pool_summary() -> Dictionary:
	var fft_module := _runtime_fft_module()
	if fft_module != null and fft_module.has_method(&"breaker_pool_summary"):
		return fft_module.breaker_pool_summary()
	return {}


func breaker_tracking_snapshot() -> Array:
	var fft_module := _runtime_fft_module()
	if fft_module != null and fft_module.has_method(&"breaker_tracking_snapshot"):
		return fft_module.breaker_tracking_snapshot()
	return []


func register_sea_state_zone(zone: OceanSeaStateZone3D) -> void:
	if zone == null or _sea_state_zones.has(zone):
		return
	_sea_state_zones.append(zone)
	mark_sea_state_zones_dirty()


func unregister_sea_state_zone(zone: OceanSeaStateZone3D) -> void:
	var index := _sea_state_zones.find(zone)
	if index >= 0:
		_sea_state_zones.remove_at(index)
		mark_sea_state_zones_dirty()


func mark_sea_state_zones_dirty() -> void:
	_sea_state_zones_dirty = true
	if is_inside_tree():
		call_deferred(&"_refresh_sea_state_zones")


func toggle_sea_state_zone_debug() -> void:
	_sea_state_zone_debug = not _sea_state_zone_debug
	_request_visual_sync()


func sea_state_zone_debug_enabled() -> bool:
	return _sea_state_zone_debug


func cycle_reflection_debug() -> void:
	_reflection_debug_mode = (_reflection_debug_mode + 1) % 22
	_request_visual_sync()


func reflection_debug_name() -> String:
	return ["OFF", "FRESNEL", "SKY", "SUN_SPECULAR", "ROUGHNESS", "NORMAL", "SLOPE_VARIANCE", "SSPR_RAW", "SSPR_VALIDITY", "SSPR_DISTORTED", "SSPR_CONFIDENCE", "SSPR_TEMPORAL", "SSPR_PREFILTERED", "NEAR_SSR_ACTIVE", "NEAR_SSR_HIT", "NEAR_SSR_CONFIDENCE", "NEAR_SSR_COLOR", "NEAR_SSR_DEPTH_CONFIDENCE", "NEAR_SSR_DEVIATION_CONFIDENCE", "NEAR_SSR_BASE_CONFIDENCE", "NEAR_SSR_STEP_USAGE", "SSPR_FACET_CONFIDENCE"][_reflection_debug_mode]


func _sync_sun_direction() -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var lights := scene_root.find_children("*", "DirectionalLight3D", true, false)
	if lights.is_empty():
		return
	var sun := lights[0] as DirectionalLight3D
	if sun != null:
		# DirectionalLight3D emits along local -Z; the BRDF helper needs the
		# direction from the surface toward the light.
		_sun_direction_world = sun.global_transform.basis.z.normalized()


func _refresh_sea_state_zones() -> void:
	if not _sea_state_zones_dirty:
		return
	_sea_state_zones_dirty = false
	var live_zones: Array[OceanSeaStateZone3D] = []
	for zone in _sea_state_zones:
		if is_instance_valid(zone):
			live_zones.append(zone)
	live_zones.sort_custom(_compare_sea_state_zones)
	_sea_state_zone_descriptors.clear()
	_sea_state_zone_uniform_data0.resize(8)
	_sea_state_zone_uniform_data1.resize(8)
	_sea_state_zone_uniform_data2.resize(8)
	_sea_state_zone_uniform_data3.resize(8)
	for index in 8:
		_sea_state_zone_uniform_data0[index] = Vector4.ZERO
		_sea_state_zone_uniform_data1[index] = Vector4.ZERO
		_sea_state_zone_uniform_data2[index] = Vector4.ZERO
		_sea_state_zone_uniform_data3[index] = Vector4.ZERO
	var active_index := 0
	for zone in live_zones:
		if not zone.enabled or active_index >= 8:
			continue
		var descriptor := zone.descriptor()
		_sea_state_zone_descriptors.append(descriptor)
		var center: Vector2 = descriptor["center"]
		var axis: Vector2 = descriptor["axis"]
		var half_extents: Vector2 = descriptor["half_extents"]
		var target: Vector4 = descriptor["target"]
		_sea_state_zone_uniform_data0[active_index] = Vector4(center.x, center.y, axis.x, axis.y)
		_sea_state_zone_uniform_data1[active_index] = Vector4(half_extents.x, half_extents.y, float(descriptor["feather"]), float(descriptor["strength"]))
		_sea_state_zone_uniform_data2[active_index] = target
		_sea_state_zone_uniform_data3[active_index] = Vector4(float(descriptor["foam_generation_multiplier"]), 0.0, 0.0, 0.0)
		active_index += 1
	_sea_state_zones = live_zones
	var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if fft_module != null and not Engine.is_editor_hint():
		fft_module.set_sea_state_zones(_sea_state_zone_descriptors)
	_request_visual_sync()


func _compare_sea_state_zones(a: OceanSeaStateZone3D, b: OceanSeaStateZone3D) -> bool:
	if a.priority != b.priority:
		return a.priority < b.priority
	return str(a.get_path()) < str(b.get_path())


func _process(_delta: float) -> void:
	_update_performance_overlay()
	# This also covers the editor case where the child material is created after
	# the root setter ran while the scene was loading.
	if _visual_sync_pending:
		_sync_water_visual_parameters()
	# Sun direction can animate independently from inspector properties. Keep the
	# caustics input current without re-running the full visual material sync.
	if not Engine.is_editor_hint():
		_sync_sun_direction()
		_sync_caustics_manager()
		_update_underwater_camera_state()
		_sync_underwater_manager()
	if not _startup_reported and not _visual_sync_pending:
		# Three rendered process frames avoid calling a deferred setup frame
		# "stable" while retaining zero recurring instrumentation cost.
		_startup_stable_frames += 1
		if _startup_stable_frames >= 3:
			_startup_reported = true
			print("OCEAN STARTUP root: setup=%d ms first_stable_frame=%d ms" % [
				int(float(_startup_setup_usec - _startup_started_usec) / 1000.0),
				int(float(Time.get_ticks_usec() - _startup_started_usec) / 1000.0),
			])
	if _wave_spectrum_dirty and auto_apply_wave_changes and Time.get_ticks_msec() >= _wave_spectrum_apply_at_ms:
		apply_wave_changes()
	_update_wave_transition_exports()


func _mark_wave_spectrum_dirty() -> void:
	if _applying_wave_preset or _applying_wave_transition:
		return
	_wave_spectrum_dirty = true
	_wave_spectrum_apply_at_ms = Time.get_ticks_msec() + WAVE_REBUILD_DEBOUNCE_MS


func apply_selected_wave_preset() -> void:
	if wave_preset == null:
		push_warning("Select an OceanWavePreset before applying it.")
		return
	_applying_wave_preset = true
	global_wind_speed_mps = wave_preset.global_wind_speed_mps
	_copy_band_from_settings(wave_preset.long_band, 0)
	_copy_band_from_settings(wave_preset.mid_band, 1)
	_copy_band_from_settings(wave_preset.short_band, 2)
	short_geometry_strength = wave_preset.short_geometry_strength
	_applying_wave_preset = false
	_request_visual_sync()
	apply_wave_changes()


func transition_to_selected_wave_preset() -> void:
	transition_to_wave_preset(wave_preset, wave_transition_duration_s)


func transition_to_wave_preset(target_preset: OceanWavePreset, duration_seconds: float) -> void:
	if target_preset == null:
		push_warning("Select an OceanWavePreset before starting a transition.")
		return
	if Engine.is_editor_hint():
		push_warning("Wave preset transitions run in the game; Apply Selected Preset remains available for editor authoring.")
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT")
	if fft_module == null or not fft_module.has_method(&"transition_to_wave_spectrum_settings"):
		push_error("OpenOceanFFT does not support wave preset transitions.")
		return
	# Capture the exact visible endpoint before retargeting, rather than a stale
	# Inspector snapshot from the previous frame.
	if _wave_transition_active:
		_update_wave_transition_exports()
	_wave_transition_start_configs = _build_active_wave_configs()
	_wave_transition_start_short_geometry = short_geometry_strength
	_wave_transition_target_preset = target_preset
	_wave_transition_target_configs = target_preset.build_cascades()
	_wave_spectrum_dirty = false
	if not bool(fft_module.call(&"transition_to_wave_spectrum_settings", _wave_transition_target_configs, duration_seconds)):
		return
	if duration_seconds <= 0.0:
		_apply_transition_target_exports()
		return
	_wave_transition_active = true


func _update_wave_transition_exports() -> void:
	if not _wave_transition_active:
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT")
	if fft_module == null or not fft_module.has_method(&"wave_transition_state"):
		return
	var state: Dictionary = fft_module.call(&"wave_transition_state")
	if bool(state.get("active", false)):
		_apply_transition_exports(float(state.get("alpha", 0.0)))
		return
	if bool(state.get("preparing", false)):
		# El target aún se calcula fuera del hilo principal: los exports siguen
		# representando el mar visible hasta que GPU y OceanQuery puedan arrancar juntos.
		return
	if bool(state.get("cancelled", false)):
		_wave_transition_active = false
		_wave_transition_start_configs = []
		_wave_transition_target_preset = null
		_wave_transition_target_configs = []
		return
	_apply_transition_target_exports()


func _apply_transition_exports(alpha: float) -> void:
	if _wave_transition_target_preset == null or _wave_transition_start_configs.size() != 3:
		return
	_applying_wave_transition = true
	global_wind_speed_mps = lerpf(_wave_transition_start_configs[0].wind_speed_mps, _wave_transition_target_configs[0].wind_speed_mps, alpha)
	for index in 3:
		_copy_band_from_config(_interpolate_wave_config(_wave_transition_start_configs[index], _wave_transition_target_configs[index], alpha), index)
	short_geometry_strength = lerpf(_wave_transition_start_short_geometry, _wave_transition_target_preset.short_geometry_strength, alpha)
	_applying_wave_transition = false
	_request_visual_sync()


func _apply_transition_target_exports() -> void:
	if _wave_transition_target_preset == null:
		return
	_applying_wave_transition = true
	global_wind_speed_mps = _wave_transition_target_preset.global_wind_speed_mps
	_copy_band_from_settings(_wave_transition_target_preset.long_band, 0)
	_copy_band_from_settings(_wave_transition_target_preset.mid_band, 1)
	_copy_band_from_settings(_wave_transition_target_preset.short_band, 2)
	short_geometry_strength = _wave_transition_target_preset.short_geometry_strength
	wave_preset = _wave_transition_target_preset
	_applying_wave_transition = false
	_wave_spectrum_dirty = false
	_wave_transition_active = false
	_wave_transition_start_configs = []
	_wave_transition_target_preset = null
	_wave_transition_target_configs = []
	_request_visual_sync()


func _interpolate_wave_config(current: OpenOceanFFTConfig, target: OpenOceanFFTConfig, alpha: float) -> OpenOceanFFTConfig:
	var result := current.duplicate() as OpenOceanFFTConfig
	result.target_hs_m = lerpf(current.target_hs_m, target.target_hs_m, alpha)
	result.choppiness = lerpf(current.choppiness, target.choppiness, alpha)
	var direction := current.wind_direction.normalized().lerp(target.wind_direction.normalized(), alpha)
	result.wind_direction = direction.normalized() if direction.length_squared() > 1.0e-8 else Vector2.RIGHT
	result.directional_spread = lerpf(current.directional_spread, target.directional_spread, alpha)
	result.fetch_length_m = lerpf(current.fetch_length_m, target.fetch_length_m, alpha)
	result.swell = lerpf(current.swell, target.swell, alpha)
	result.detail = lerpf(current.detail, target.detail, alpha)
	result.jonswap_spread = lerpf(current.jonswap_spread, target.jonswap_spread, alpha)
	result.min_wavelength_m = lerpf(current.min_wavelength_m, target.min_wavelength_m, alpha)
	result.max_wavelength_m = lerpf(current.max_wavelength_m, target.max_wavelength_m, alpha)
	result.transition_width_m = lerpf(current.transition_width_m, target.transition_width_m, alpha)
	result.short_wave_damping_m = lerpf(current.short_wave_damping_m, target.short_wave_damping_m, alpha)
	return result


func _copy_band_from_config(config: OpenOceanFFTConfig, index: int) -> void:
	var band := OceanWaveBandSettings.new()
	band.copy_from(config)
	_copy_band_from_settings(band, index)


func apply_wave_changes() -> void:
	_wave_spectrum_dirty = false
	# OpenOceanFFTModule intentionally remains a runtime GPU owner. In @tool
	# scenes it is a Godot placeholder; the root exports are still authored and
	# serialized there, then the same canonical H0 route runs on the next launch.
	if Engine.is_editor_hint():
		return
	var fft_module := get_node_or_null(^"OpenOceanFFT")
	if fft_module != null and fft_module.has_method(&"set_wave_spectrum_settings"):
		fft_module.call(&"set_wave_spectrum_settings", _build_active_wave_configs())


func save_current_wave_preset() -> void:
	var target_path := preset_save_path.strip_edges()
	if target_path.is_empty() or not target_path.begins_with("res://"):
		push_error("Preset Save Path must be a res:// .tres path.")
		return
	if target_path in BASE_WAVE_PRESET_PATHS:
		push_error("Base CALM/RACE/ROUGH presets are protected; choose a custom .tres path.")
		return
	if not target_path.ends_with(".tres"):
		push_error("Preset Save Path must end in .tres.")
		return
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target_path.get_base_dir()))
	if directory_error != OK:
		push_error("Could not create preset directory for %s (error %d)." % [target_path, directory_error])
		return
	var preset := OceanWavePreset.new()
	preset.preset_name = target_path.get_file().get_basename()
	preset.global_wind_speed_mps = global_wind_speed_mps
	preset.long_band = _band_settings_from_exports(0)
	preset.mid_band = _band_settings_from_exports(1)
	preset.short_band = _band_settings_from_exports(2)
	preset.short_geometry_strength = short_geometry_strength
	var error := ResourceSaver.save(preset, target_path)
	if error != OK:
		push_error("Could not save wave preset at %s (error %d)." % [target_path, error])
		return
	wave_preset = load(target_path) as OceanWavePreset
	print("Saved OceanWavePreset: %s" % target_path)


func _build_active_wave_configs() -> Array[OpenOceanFFTConfig]:
	var preset := OceanWavePreset.new()
	preset.global_wind_speed_mps = global_wind_speed_mps
	preset.long_band = _band_settings_from_exports(0)
	preset.mid_band = _band_settings_from_exports(1)
	preset.short_band = _band_settings_from_exports(2)
	return preset.build_cascades()


func _copy_band_from_settings(band: OceanWaveBandSettings, index: int) -> void:
	if band == null:
		return
	match index:
		0:
			long_target_hs_m = band.target_hs_m
			long_choppiness = band.choppiness
			long_wind_direction = band.wind_direction
			long_directional_spread = band.directional_spread
			long_fetch_length_m = band.fetch_length_m
			long_swell = band.swell
			long_jonswap_spread = band.jonswap_spread
			long_detail = band.detail
			long_min_wavelength_m = band.min_wavelength_m
			long_max_wavelength_m = band.max_wavelength_m
			long_transition_width_m = band.transition_width_m
			long_short_wave_damping_m = band.short_wave_damping_m
		1:
			mid_target_hs_m = band.target_hs_m
			mid_choppiness = band.choppiness
			mid_wind_direction = band.wind_direction
			mid_directional_spread = band.directional_spread
			mid_fetch_length_m = band.fetch_length_m
			mid_swell = band.swell
			mid_jonswap_spread = band.jonswap_spread
			mid_detail = band.detail
			mid_min_wavelength_m = band.min_wavelength_m
			mid_max_wavelength_m = band.max_wavelength_m
			mid_transition_width_m = band.transition_width_m
			mid_short_wave_damping_m = band.short_wave_damping_m
		2:
			short_target_hs_m = band.target_hs_m
			short_choppiness = band.choppiness
			short_wind_direction = band.wind_direction
			short_directional_spread = band.directional_spread
			short_fetch_length_m = band.fetch_length_m
			short_swell = band.swell
			short_jonswap_spread = band.jonswap_spread
			short_detail = band.detail
			short_min_wavelength_m = band.min_wavelength_m
			short_max_wavelength_m = band.max_wavelength_m
			short_transition_width_m = band.transition_width_m
			short_short_wave_damping_m = band.short_wave_damping_m


func _band_settings_from_exports(index: int) -> OceanWaveBandSettings:
	var band := OceanWaveBandSettings.new()
	match index:
		0:
			band.target_hs_m = long_target_hs_m
			band.choppiness = long_choppiness
			band.wind_direction = long_wind_direction
			band.directional_spread = long_directional_spread
			band.fetch_length_m = long_fetch_length_m
			band.swell = long_swell
			band.jonswap_spread = long_jonswap_spread
			band.detail = long_detail
			band.min_wavelength_m = long_min_wavelength_m
			band.max_wavelength_m = long_max_wavelength_m
			band.transition_width_m = long_transition_width_m
			band.short_wave_damping_m = long_short_wave_damping_m
			_copy_hidden_foam_from_base_preset(band, 0)
		1:
			band.target_hs_m = mid_target_hs_m
			band.choppiness = mid_choppiness
			band.wind_direction = mid_wind_direction
			band.directional_spread = mid_directional_spread
			band.fetch_length_m = mid_fetch_length_m
			band.swell = mid_swell
			band.jonswap_spread = mid_jonswap_spread
			band.detail = mid_detail
			band.min_wavelength_m = mid_min_wavelength_m
			band.max_wavelength_m = mid_max_wavelength_m
			band.transition_width_m = mid_transition_width_m
			band.short_wave_damping_m = mid_short_wave_damping_m
			_copy_hidden_foam_from_base_preset(band, 1)
		2:
			band.target_hs_m = short_target_hs_m
			band.choppiness = short_choppiness
			band.wind_direction = short_wind_direction
			band.directional_spread = short_directional_spread
			band.fetch_length_m = short_fetch_length_m
			band.swell = short_swell
			band.jonswap_spread = short_jonswap_spread
			band.detail = short_detail
			band.min_wavelength_m = short_min_wavelength_m
			band.max_wavelength_m = short_max_wavelength_m
			band.transition_width_m = short_transition_width_m
			band.short_wave_damping_m = short_short_wave_damping_m
			_copy_hidden_foam_from_base_preset(band, 2)
	return band


func _copy_hidden_foam_from_base_preset(target: OceanWaveBandSettings, index: int) -> void:
	# Root doesn't expose legacy whitecap controls. Keep their selected preset's
	# values when authoring the spectrum, falling back to RACE if no preset exists.
	var source_preset := wave_preset
	if source_preset == null:
		source_preset = load("res://ocean_v3/presets/waves/race.tres") as OceanWavePreset
	if source_preset == null:
		return
	var source: OceanWaveBandSettings = [source_preset.long_band, source_preset.mid_band, source_preset.short_band][index]
	if source != null:
		target.foam_enabled = source.foam_enabled
		target.foam_whitecap = source.foam_whitecap
		target.foam_amount = source.foam_amount
		target.foam_decay = source.foam_decay
		target.foam_cascade_weight = source.foam_cascade_weight


func _request_visual_sync() -> void:
	_visual_sync_pending = true
	if is_inside_tree():
		call_deferred(&"_flush_visual_sync")


func _set_surface_foam_wind_speed_from_sea_state(value: float) -> void:
	# SeaState owns the preset transition, but the public export remains the
	# current editable value so a later Inspector change is not discarded.
	surface_foam_wind_speed_mps = clampf(value, 0.1, 60.0)


func _normalize_resolution_enum(value: int) -> int:
	# Godot versions differ here: some emit the explicit enum value, others emit
	# its zero-based index. Handle both so 512/1024 cannot collapse to 256.
	match value:
		0: return 256
		1: return 512
		2: return 1024
		256: return 256
		512: return 512
		1024: return 1024
	return 256 if value < 256 else 512 if value < 512 else 1024


func _flush_visual_sync() -> void:
	if not _visual_sync_pending:
		return
	_sync_water_visual_parameters()


func _active_caustics_texture() -> Texture2D:
	if caustics_texture != null:
		return caustics_texture
	for path in [REFERENCE_CAUSTICS_TEXTURE_PATH, FALLBACK_REFERENCE_CAUSTICS_TEXTURE_PATH,
			FALLBACK_CAUSTICS_TEXTURE_PATH]:
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


func _active_caustics_luma_gradient() -> Texture2D:
	if caustics_luma_gradient != null:
		return caustics_luma_gradient
	for path in [REFERENCE_CAUSTICS_LUMA_GRADIENT_PATH, FALLBACK_CAUSTICS_LUMA_GRADIENT_PATH]:
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


func _sync_caustics_manager() -> void:
	if _caustics_manager == null or not is_instance_valid(_caustics_manager):
		return
	_caustics_manager.set_settings(
		caustics_enabled,
		_surface_sea_level(),
		_active_caustics_texture(),
		_active_caustics_luma_gradient(),
		caustics_scale,
		caustics_speed,
		caustics_strength,
		caustics_power,
		caustics_chroma_split,
		caustics_layer_a_speed_multiplier,
		caustics_layer_b_speed_multiplier,
		caustics_layer_a_scale_multiplier,
		caustics_layer_b_scale_multiplier,
		caustics_layer_a_direction,
		caustics_layer_b_direction,
		caustics_luminance_mask_strength,
		caustics_sun_strength,
		caustics_fade_start_depth,
		caustics_max_depth,
		_sun_direction_world,
		caustics_debug_mode
	)
	_caustics_manager.set_time(SimulationClock.get_render_time())


func _sync_water_visual_parameters() -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material) or material.shader == null:
		return
	_sync_sun_direction()
	var effective_foam_debug_mode := foam_debug_mode

	material.set_shader_parameter(&"sea_state_zone_count", _sea_state_zone_descriptors.size())
	material.set_shader_parameter(&"sea_state_zone_data0", _sea_state_zone_uniform_data0)
	material.set_shader_parameter(&"sea_state_zone_data1", _sea_state_zone_uniform_data1)
	material.set_shader_parameter(&"sea_state_zone_data2", _sea_state_zone_uniform_data2)
	material.set_shader_parameter(&"sea_state_zone_data3", _sea_state_zone_uniform_data3)
	material.set_shader_parameter(&"sea_state_zone_debug", _sea_state_zone_debug)
	material.set_shader_parameter(&"short_geometry_strength", short_geometry_strength)

	var detail_ready := surface_detail_enabled \
		and surface_normal_texture_a != null \
		and surface_normal_texture_b != null \
		and surface_warp_texture != null
	material.set_shader_parameter(&"surface_detail_enabled", detail_ready)
	material.set_shader_parameter(&"perf_benchmark_surface_detail_enabled", bool(_benchmark_diagnostic_gates.get("surface_detail", true)))
	material.set_shader_parameter(&"perf_benchmark_crest_shape_enabled", bool(_benchmark_diagnostic_gates.get("crest_shape", true)))
	material.set_shader_parameter(&"perf_benchmark_near_ssr_enabled", bool(_benchmark_diagnostic_gates.get("near_ssr", true)))
	material.set_shader_parameter(&"perf_benchmark_optics_enabled", bool(_benchmark_diagnostic_gates.get("optics", true)))
	material.set_shader_parameter(&"perf_benchmark_refraction_wave_enabled", bool(_benchmark_diagnostic_gates.get("refraction_wave", true)))
	if detail_ready:
		material.set_shader_parameter(&"surface_normal_texture_a", surface_normal_texture_a)
		material.set_shader_parameter(&"surface_normal_texture_b", surface_normal_texture_b)
		material.set_shader_parameter(&"surface_warp_texture", surface_warp_texture)
	# Foam breakup reuses the warp texture, but remains independent from whether
	# decorative Surface Detail normals are currently enabled.
	var foam_breakup_texture_ready := surface_warp_texture != null
	if foam_breakup_texture_ready:
		material.set_shader_parameter(&"surface_warp_texture", surface_warp_texture)

	material.set_shader_parameter(&"surface_normal_world_size_a", surface_normal_world_size_a)
	material.set_shader_parameter(&"surface_normal_world_size_b", surface_normal_world_size_b)
	material.set_shader_parameter(&"surface_normal_strength", surface_normal_strength)
	material.set_shader_parameter(&"surface_detail_wave_follow", surface_detail_wave_follow)
	material.set_shader_parameter(&"surface_flow_direction_a", surface_flow_direction_a)
	material.set_shader_parameter(&"surface_flow_direction_b", surface_flow_direction_b)
	material.set_shader_parameter(&"surface_flow_speed_a", surface_flow_speed_a)
	material.set_shader_parameter(&"surface_flow_speed_b", surface_flow_speed_b)
	material.set_shader_parameter(&"surface_warp_world_size", surface_warp_world_size)
	material.set_shader_parameter(&"surface_warp_strength", surface_warp_strength)
	material.set_shader_parameter(&"surface_detail_fade_start", surface_detail_fade_start)
	material.set_shader_parameter(&"surface_detail_fade_end", surface_detail_fade_end)
	material.set_shader_parameter(&"surface_detail_far_strength", surface_detail_far_strength)
	material.set_shader_parameter(&"ocean_surface_detail_quality", ocean_surface_detail_quality)

	material.set_shader_parameter(&"shallow_water_color", shallow_water_color)
	material.set_shader_parameter(&"deep_water_color", deep_water_color)
	material.set_shader_parameter(&"horizon_water_color", horizon_water_color)
	material.set_shader_parameter(&"trough_tint", trough_tint)
	material.set_shader_parameter(&"crest_tint", crest_tint)
	material.set_shader_parameter(&"absorption_coeff_rgb", absorption_coeff_rgb)
	material.set_shader_parameter(&"underwater_transition_width_m", underwater_transition_width_m)
	material.set_shader_parameter(&"underwater_water_ior", underwater_water_ior)
	material.set_shader_parameter(&"underwater_snell_strength", underwater_snell_strength)
	material.set_shader_parameter(&"underwater_tir_strength", underwater_tir_strength)
	material.set_shader_parameter(&"underwater_snell_detail_strength", underwater_snell_detail_strength)
	material.set_shader_parameter(&"underwater_surface_projection_distance_m", underwater_surface_projection_distance_m)
	material.set_shader_parameter(&"underwater_debug_mode", underwater_debug_mode)
	# Keep the legacy parameter synchronized for old materials/resources; the
	# shader no longer uses it in the production optics path.
	material.set_shader_parameter(&"absorption_density", absorption_density)
	material.set_shader_parameter(&"maximum_optical_depth", maximum_optical_depth)
	# Legacy compatibility parameter; the production shader no longer uses it.
	material.set_shader_parameter(&"shallow_depth_range", shallow_depth_range)
	material.set_shader_parameter(&"water_body_depth_start_m", water_body_depth_start_m)
	material.set_shader_parameter(&"water_body_depth_end_m", water_body_depth_end_m)
	material.set_shader_parameter(&"opacity_distance_start", opacity_distance_start)
	material.set_shader_parameter(&"opacity_distance_end", opacity_distance_end)
	material.set_shader_parameter(&"water_refraction_enabled", perf_enable_refraction)
	material.set_shader_parameter(&"refraction_micro_normal_strength", refraction_micro_normal_strength)
	material.set_shader_parameter(&"refraction_max_offset_px", refraction_max_offset_px)
	material.set_shader_parameter(&"refraction_depth_tolerance_m", refraction_depth_tolerance_m)
	material.set_shader_parameter(&"refraction_wave_strength", refraction_wave_strength)
	material.set_shader_parameter(&"refraction_long_weight", refraction_long_weight)
	material.set_shader_parameter(&"refraction_mid_weight", refraction_mid_weight)
	material.set_shader_parameter(&"refraction_short_weight", refraction_short_weight)
	material.set_shader_parameter(&"refraction_depth_start_m", refraction_depth_start_m)
	material.set_shader_parameter(&"refraction_depth_end_m", refraction_depth_end_m)
	material.set_shader_parameter(&"scattering_color", scattering_color)
	material.set_shader_parameter(&"scattering_strength", scattering_strength)
	material.set_shader_parameter(&"scattering_shallow_tint_influence", scattering_shallow_tint_influence)
	material.set_shader_parameter(&"scattering_deep_tint_influence", scattering_deep_tint_influence)
	material.set_shader_parameter(&"shallow_scattering_strength", shallow_scattering_strength)
	material.set_shader_parameter(&"shallow_scattering_depth_start_m", shallow_scattering_depth_start_m)
	material.set_shader_parameter(&"shallow_scattering_depth_end_m", shallow_scattering_depth_end_m)
	material.set_shader_parameter(&"water_turbidity", water_turbidity)
	material.set_shader_parameter(&"crest_transmission_boost", crest_transmission_boost)
	material.set_shader_parameter(&"trough_density_boost", trough_density_boost)
	material.set_shader_parameter(&"transmission_detail_fade_start_m", transmission_detail_fade_start_m)
	material.set_shader_parameter(&"transmission_detail_fade_end_m", transmission_detail_fade_end_m)
	material.set_shader_parameter(&"transmission_max_lod", transmission_max_lod)
	material.set_shader_parameter(&"bottom_visibility_fade_start_m", bottom_visibility_fade_start_m)
	material.set_shader_parameter(&"bottom_visibility_fade_end_m", bottom_visibility_fade_end_m)
	material.set_shader_parameter(&"seabed_match_tolerance_start_m", seabed_match_tolerance_start_m)
	material.set_shader_parameter(&"seabed_match_tolerance_end_m", seabed_match_tolerance_end_m)
	material.set_shader_parameter(&"shallow_fresnel_relief", shallow_fresnel_relief)
	material.set_shader_parameter(&"shallow_fresnel_depth_start_m", shallow_fresnel_depth_start_m)
	material.set_shader_parameter(&"shallow_fresnel_depth_end_m", shallow_fresnel_depth_end_m)
	_sync_caustics_manager()
	_sync_underwater_manager()
	var bathymetry_sea_level_y := _surface_sea_level()
	if coastal_bake_asset != null:
		if Engine.is_editor_hint():
			# CoastalBakeAsset is intentionally non-tool. In the editor it can be
			# a PlaceholderScriptInstance, so read only its serialized export via
			# Object.get() and never call its script methods on this path.
			var authored_sea_level_y: Variant = coastal_bake_asset.get(&"bathymetry_sea_level_y")
			if authored_sea_level_y != null:
				bathymetry_sea_level_y = float(authored_sea_level_y)
		elif coastal_bake_asset.is_valid():
			# Runtime keeps the canonical manifest validation unchanged.
			bathymetry_sea_level_y = coastal_bake_asset.bathymetry_sea_level_y
	material.set_shader_parameter(&"coastal_bathymetry_sea_level_y", bathymetry_sea_level_y)
	var requested_debug_mode := int(water_optics_debug_mode)
	material.set_shader_parameter(&"water_optics_debug_mode", requested_debug_mode)
	material.set_shader_parameter(&"reflection_min_roughness", reflection_min_roughness)
	material.set_shader_parameter(&"reflection_base_roughness", reflection_base_roughness)
	material.set_shader_parameter(&"reflection_distance_roughness", reflection_distance_roughness)
	material.set_shader_parameter(&"reflection_detail_roughness_gain", reflection_detail_roughness_gain)
	material.set_shader_parameter(&"reflection_distance_roughness_gain", reflection_distance_roughness_gain)
	material.set_shader_parameter(&"reflection_pixel_footprint_gain", reflection_pixel_footprint_gain)
	material.set_shader_parameter(&"reflection_slope_variance_gain", reflection_slope_variance_gain)
	material.set_shader_parameter(&"reflection_roughness_distance_m", reflection_roughness_distance_m)
	material.set_shader_parameter(&"reflection_sun_direction_world", _sun_direction_world)
	material.set_shader_parameter(&"reflection_debug_mode", _reflection_debug_mode)
	material.set_shader_parameter(&"reflection_sspr_enabled", reflection_sspr_enabled and perf_enable_sspr)
	material.set_shader_parameter(&"reflection_sspr_distortion_strength", reflection_sspr_distortion_strength)
	material.set_shader_parameter(&"reflection_sspr_edge_fade", reflection_sspr_edge_fade)
	material.set_shader_parameter(&"reflection_sspr_slope_fade", reflection_sspr_slope_fade)
	material.set_shader_parameter(&"reflection_sspr_hole_fill_enabled", reflection_sspr_hole_fill_enabled)
	material.set_shader_parameter(&"reflection_sspr_facet_gate_enabled", reflection_sspr_facet_gate_enabled)
	material.set_shader_parameter(&"reflection_sspr_facet_gate_strength", reflection_sspr_facet_gate_strength)
	material.set_shader_parameter(&"reflection_distance_blur_enabled", reflection_distance_blur_enabled)
	material.set_shader_parameter(&"reflection_distance_blur_strength", reflection_distance_blur_strength)
	material.set_shader_parameter(&"reflection_distance_blur_reference_m", reflection_distance_blur_reference_m)
	material.set_shader_parameter(&"reflection_sspr_sea_level", _surface_sea_level())
	material.set_shader_parameter(&"reflection_near_ssr_enabled", reflection_near_ssr_enabled)
	material.set_shader_parameter(&"reflection_near_ssr_distance_m", reflection_near_ssr_distance_m)
	material.set_shader_parameter(&"reflection_near_ssr_ray_length_m", reflection_near_ssr_ray_length_m)
	material.set_shader_parameter(&"reflection_near_ssr_fade_m", reflection_near_ssr_fade_m)
	material.set_shader_parameter(&"reflection_near_ssr_thickness", reflection_near_ssr_thickness)
	material.set_shader_parameter(&"reflection_near_ssr_quality", reflection_near_ssr_quality)
	material.set_shader_parameter(&"reflection_radiance_exposure_ev", reflection_radiance_exposure_ev)
	material.set_shader_parameter(&"reflection_radiance_contrast", reflection_radiance_contrast)
	material.set_shader_parameter(&"reflection_radiance_saturation", reflection_radiance_saturation)
	material.set_shader_parameter(&"reflection_radiance_tint", reflection_radiance_tint)
	material.set_shader_parameter(&"reflection_screen_space_weight", reflection_screen_space_weight)
	material.set_shader_parameter(&"reflection_environment_specular_boost", reflection_environment_specular_boost)
	if _reflection_sspr_manager != null and is_instance_valid(_reflection_sspr_manager):
		_reflection_sspr_manager.set_enabled(reflection_sspr_enabled and perf_enable_sspr)
		_reflection_sspr_manager.set_ocean_level(_surface_sea_level())
		_reflection_sspr_manager.set_resolution_scale(reflection_sspr_resolution_scale)
		_reflection_sspr_manager.set_temporal_settings(
			reflection_sspr_temporal_enabled,
			reflection_sspr_temporal_weight,
			reflection_sspr_temporal_depth_threshold)
		_reflection_sspr_manager.set_kawase_enabled(reflection_sspr_kawase_enabled)
		_reflection_sspr_manager.set_kawase_radius(reflection_sspr_kawase_radius)

	material.set_shader_parameter(&"foam_enabled", foam_enabled)
	material.set_shader_parameter(&"foam_color", foam_color)
	material.set_shader_parameter(&"foam_fresh_color", foam_fresh_color)
	material.set_shader_parameter(&"foam_residual_color", foam_residual_color)
	material.set_shader_parameter(&"foam_fresh_strength", foam_fresh_strength)
	material.set_shader_parameter(&"foam_residual_strength", foam_residual_strength)
	material.set_shader_parameter(&"foam_normal_strength", foam_normal_strength)
	material.set_shader_parameter(&"foam_fresh_normal_weight", foam_fresh_normal_weight)
	material.set_shader_parameter(&"foam_residual_normal_weight", foam_residual_normal_weight)
	material.set_shader_parameter(&"foam_micro_normal_strength", foam_micro_normal_strength)
	material.set_shader_parameter(&"foam_intensity", foam_intensity)
	material.set_shader_parameter(&"foam_threshold", foam_threshold)
	material.set_shader_parameter(&"foam_contrast", foam_contrast)
	material.set_shader_parameter(&"foam_alpha_boost", foam_alpha_boost)
	material.set_shader_parameter(&"foam_distance_fade_start", foam_distance_fade_start)
	material.set_shader_parameter(&"foam_distance_fade_end", foam_distance_fade_end)
	material.set_shader_parameter(&"foam_breakup_strength", foam_breakup_strength)
	material.set_shader_parameter(&"foam_breakup_world_size", foam_breakup_world_size)
	material.set_shader_parameter(&"foam_breakup_speed", foam_breakup_speed)
	material.set_shader_parameter(&"foam_edge_softness", foam_edge_softness)
	material.set_shader_parameter(&"foam_breakup_texture_ready", foam_breakup_texture_ready)
	material.set_shader_parameter(&"crest_filigree_enabled", crest_filigree_enabled)
	material.set_shader_parameter(&"crest_fresh_filigree_strength", crest_fresh_filigree_strength)
	material.set_shader_parameter(&"crest_residual_filigree_strength", crest_residual_filigree_strength)
	material.set_shader_parameter(&"crest_filigree_contrast", crest_filigree_contrast)
	material.set_shader_parameter(&"crest_filigree_threshold", crest_filigree_threshold)
	material.set_shader_parameter(&"crest_filigree_normal_influence", crest_filigree_normal_influence)
	var foam_micro_texture_ready := surface_foam_micro_detail != null
	material.set_shader_parameter(&"surface_foam_micro_texture_ready", foam_micro_texture_ready)
	if foam_micro_texture_ready:
		material.set_shader_parameter(&"surface_foam_micro_texture", surface_foam_micro_detail)
	material.set_shader_parameter(&"surface_foam_enabled", surface_foam_enabled)
	# PERF-2A: MID fold history is a separate compute/render gate. When disabled,
	# the shader must use a neutral eligibility value instead of stale history.
	material.set_shader_parameter(&"perf_mid_fold_history_enabled", perf_enable_mid_fold_history)
	material.set_shader_parameter(&"surface_foam_stochastic_deperiodization_enabled", surface_foam_stochastic_deperiodization_enabled)
	material.set_shader_parameter(&"surface_foam_stochastic_cell_size_m", surface_foam_stochastic_cell_size_m)
	material.set_shader_parameter(&"surface_foam_whitecap", surface_foam_whitecap)
	material.set_shader_parameter(&"surface_foam_ocean_coupling", surface_foam_ocean_coupling)
	material.set_shader_parameter(&"surface_foam_distance_fade_start_m", surface_foam_distance_fade_start_m)
	material.set_shader_parameter(&"surface_foam_distance_fade_end_m", surface_foam_distance_fade_end_m)
	material.set_shader_parameter(&"surface_foam_strength", surface_foam_strength)
	material.set_shader_parameter(&"surface_foam_threshold_visual", surface_foam_threshold_visual)
	material.set_shader_parameter(&"surface_foam_color", surface_foam_color)
	material.set_shader_parameter(&"surface_foam_normal_strength", surface_foam_normal_strength)
	material.set_shader_parameter(&"foam_fresh_roughness", foam_fresh_roughness)
	material.set_shader_parameter(&"foam_residual_roughness", foam_residual_roughness)
	material.set_shader_parameter(&"surface_foam_roughness", surface_foam_roughness)
	material.set_shader_parameter(&"foam_fresh_specular", foam_fresh_specular)
	material.set_shader_parameter(&"foam_residual_specular", foam_residual_specular)
	material.set_shader_parameter(&"surface_foam_specular", surface_foam_specular)
	material.set_shader_parameter(&"surface_foam_micro_detail_enabled", surface_foam_micro_detail_enabled and foam_micro_texture_ready)
	material.set_shader_parameter(&"surface_foam_micro_strength", surface_foam_micro_strength)
	material.set_shader_parameter(&"surface_foam_micro_scale_m", surface_foam_micro_scale)
	material.set_shader_parameter(&"surface_foam_micro_normal_strength", surface_foam_micro_normal_strength)
	material.set_shader_parameter(&"surface_foam_edge_fade_strength", surface_foam_edge_fade_strength)
	material.set_shader_parameter(&"surface_foam_edge_fade_width", surface_foam_edge_fade_width)
	material.set_shader_parameter(&"foam_detail_contribution", foam_detail_contribution)
	# OpenOceanFFTModule is a non-tool node, so Godot exposes it as a placeholder
	# while this @tool scene is edited. Its runtime foam transport API must only be
	# synchronized in an actual game run.
	if not Engine.is_editor_hint():
		var fft_module := get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
		if fft_module != null:
			fft_module.set_foam_transport_settings(
				foam_residual_decay_multiplier,
				foam_deposit_strength,
				foam_advection_enabled,
				foam_advection_strength
			)
			fft_module.set_crest_foam_update_hz(crest_foam_update_hz)
			fft_module.set_crest_foam_compute_enabled(crest_foam_compute_enabled)
			fft_module.set_surface_foam_settings(
				surface_foam_enabled,
				surface_foam_whitecap,
				surface_foam_amount,
				surface_foam_update_hz,
				surface_foam_birth_attack_s,
				surface_foam_lifetime_s,
				surface_foam_birth_selectivity,
				surface_foam_evolution_speed,
				surface_foam_mid_fold_start,
				surface_foam_mid_fold_end,
				surface_foam_enabled or crest_filigree_enabled,
				crest_filigree_whitecap
			)
			fft_module.set_surface_foam_spectrum_settings(
				 surface_foam_fft_resolution,
				surface_foam_field_resolution,
				surface_foam_topology_resolution,
				surface_foam_source_domain_m,
				surface_foam_field_domain_m,
				surface_foam_depth_m,
				surface_foam_wind_speed_mps,
				surface_foam_wind_direction_deg,
				surface_foam_fetch_m,
				surface_foam_swell,
				surface_foam_directional_spread,
				surface_foam_detail
			)
	material.set_shader_parameter(&"foam_debug_mode", effective_foam_debug_mode)
	# LOD debug materials are created from this fully configured material only on
	# explicit activation.  Do not enumerate and copy the complete property list
	# on every normal visual sync.

	_visual_sync_pending = false


func set_reflection_sspr_texture(texture: Texture2D, available: bool) -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material):
		return
	surface.set_surface_shader_parameter(&"reflection_sspr_texture", texture)
	surface.set_surface_shader_parameter(&"reflection_sspr_available", available)


func set_reflection_sspr_raw_texture(texture: Texture2D, available: bool) -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material):
		return
	surface.set_surface_shader_parameter(&"reflection_sspr_raw_texture", texture)
	surface.set_surface_shader_parameter(&"reflection_sspr_raw_available", available)


func set_reflection_sspr_temporal_texture(texture: Texture2D, available: bool) -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material):
		return
	surface.set_surface_shader_parameter(&"reflection_sspr_temporal_texture", texture)
	surface.set_surface_shader_parameter(&"reflection_sspr_temporal_available", available)


func set_reflection_sspr_depth_texture(texture: Texture2D, available: bool) -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material):
		return
	surface.set_surface_shader_parameter(&"reflection_sspr_depth_texture", texture)
	surface.set_surface_shader_parameter(&"reflection_sspr_depth_available", available)


func get_reflection_sspr_temporal_settings() -> Dictionary:
	return {
		"enabled": reflection_sspr_temporal_enabled,
		"weight": reflection_sspr_temporal_weight,
		"depth_threshold": reflection_sspr_temporal_depth_threshold,
	}


func get_reflection_sspr_kawase_enabled() -> bool:
	return reflection_sspr_kawase_enabled


func get_reflection_sspr_kawase_radius() -> float:
	return reflection_sspr_kawase_radius


func get_reflection_sspr_resolution_scale() -> float:
	return reflection_sspr_resolution_scale


func get_reflection_sspr_source_size() -> Vector2i:
	return _reflection_sspr_manager.get_source_size() if _reflection_sspr_manager != null else Vector2i.ZERO


func get_reflection_sspr_target_size() -> Vector2i:
	return _reflection_sspr_manager.get_target_size() if _reflection_sspr_manager != null else Vector2i.ZERO

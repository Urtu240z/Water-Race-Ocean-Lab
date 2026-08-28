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
var _wave_spectrum_dirty := false
var _wave_spectrum_apply_at_ms := 0
var _applying_wave_preset := false
var _applying_wave_transition := false
var _wave_transition_active := false
var _wave_transition_start_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_target_preset: OceanWavePreset = null
var _wave_transition_target_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_start_short_geometry := 0.25

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

@export_range(0.01, 2.0, 0.01) var absorption_density: float = 0.13:
	set(value):
		absorption_density = value
		_request_visual_sync()

@export_range(1.0, 100.0, 0.5) var maximum_optical_depth: float = 38.0:
	set(value):
		maximum_optical_depth = value
		_request_visual_sync()

@export_range(0.1, 20.0, 0.1) var shallow_depth_range: float = 5.5:
	set(value):
		shallow_depth_range = value
		_request_visual_sync()

@export_range(0.5, 1.0, 0.01) var near_water_alpha: float = 0.77:
	set(value):
		near_water_alpha = value
		_request_visual_sync()

@export_range(0.5, 1.0, 0.01) var deep_water_alpha: float = 0.92:
	set(value):
		deep_water_alpha = value
		_request_visual_sync()

@export_range(0.8, 1.0, 0.01) var horizon_water_alpha: float = 0.98:
	set(value):
		horizon_water_alpha = value
		_request_visual_sync()

@export_range(0.0, 500.0, 1.0) var opacity_distance_start: float = 80.0:
	set(value):
		opacity_distance_start = value
		_request_visual_sync()

@export_range(1.0, 1000.0, 1.0) var opacity_distance_end: float = 220.0:
	set(value):
		opacity_distance_end = value
		_request_visual_sync()

@export_range(0.0, 0.05, 0.0005) var refraction_strength: float = 0.009:
	set(value):
		refraction_strength = value
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

@export var reflection_sspr_conservative_coverage_enabled: bool = true:
	set(value):
		reflection_sspr_conservative_coverage_enabled = value
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


func _ready() -> void:
	add_to_group(&"ocean_v3_root")
	for node in get_tree().get_nodes_in_group(&"ocean_sea_state_zone"):
		if node is OceanSeaStateZone3D:
			register_sea_state_zone(node)
	_refresh_sea_state_zones()
	_visual_sync_pending = true
	if wave_preset != null:
		apply_selected_wave_preset()
	_configure_coastal_bake_asset()
	if not Engine.is_editor_hint():
		_reflection_sspr_manager = SSPR_MANAGER_SCRIPT.new()
		_reflection_sspr_manager.name = &"OceanSSPRManager"
		add_child(_reflection_sspr_manager)
		_reflection_sspr_manager.configure(self, _surface_sea_level(), reflection_sspr_enabled)
	call_deferred(&"_flush_visual_sync")


func _surface_sea_level() -> float:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	return surface.clipmap_config.sea_level_y if surface != null else 0.0


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


func toggle_ocean_clipmap_lod_debug() -> void:
	var fft_module := _runtime_fft_module()
	if fft_module != null:
		fft_module.toggle_clipmap_lod_debug()


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
	_reflection_debug_mode = (_reflection_debug_mode + 1) % 11
	_request_visual_sync()


func reflection_debug_name() -> String:
	return ["OFF", "FRESNEL", "SKY", "SUN_SPECULAR", "ROUGHNESS", "NORMAL", "SLOPE_VARIANCE", "SSPR_RAW", "SSPR_VALIDITY", "SSPR_DISTORTED", "SSPR_CONFIDENCE"][_reflection_debug_mode]


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
	# This also covers the editor case where the child material is created after
	# the root setter ran while the scene was loading.
	if _visual_sync_pending:
		_sync_water_visual_parameters()
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
	_sync_water_visual_parameters()


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
	material.set_shader_parameter(&"absorption_density", absorption_density)
	material.set_shader_parameter(&"maximum_optical_depth", maximum_optical_depth)
	material.set_shader_parameter(&"shallow_depth_range", shallow_depth_range)
	material.set_shader_parameter(&"near_water_alpha", near_water_alpha)
	material.set_shader_parameter(&"deep_water_alpha", deep_water_alpha)
	material.set_shader_parameter(&"horizon_water_alpha", horizon_water_alpha)
	material.set_shader_parameter(&"opacity_distance_start", opacity_distance_start)
	material.set_shader_parameter(&"opacity_distance_end", opacity_distance_end)
	material.set_shader_parameter(&"refraction_strength", refraction_strength)
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
	material.set_shader_parameter(&"reflection_sspr_enabled", reflection_sspr_enabled)
	material.set_shader_parameter(&"reflection_sspr_distortion_strength", reflection_sspr_distortion_strength)
	material.set_shader_parameter(&"reflection_sspr_edge_fade", reflection_sspr_edge_fade)
	material.set_shader_parameter(&"reflection_sspr_slope_fade", reflection_sspr_slope_fade)
	material.set_shader_parameter(&"reflection_sspr_hole_fill_enabled", reflection_sspr_hole_fill_enabled)
	if _reflection_sspr_manager != null and is_instance_valid(_reflection_sspr_manager):
		_reflection_sspr_manager.set_enabled(reflection_sspr_enabled)
		_reflection_sspr_manager.set_ocean_level(_surface_sea_level())
		_reflection_sspr_manager.set_temporal_settings(
			reflection_sspr_temporal_enabled,
			reflection_sspr_temporal_weight,
			reflection_sspr_temporal_depth_threshold)
		_reflection_sspr_manager.set_conservative_coverage_enabled(
			reflection_sspr_conservative_coverage_enabled)

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

	_visual_sync_pending = false


func set_reflection_sspr_texture(texture: Texture2D, available: bool) -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material):
		return
	material.set_shader_parameter(&"reflection_sspr_texture", texture)
	material.set_shader_parameter(&"reflection_sspr_available", available)


func get_reflection_sspr_temporal_settings() -> Dictionary:
	return {
		"enabled": reflection_sspr_temporal_enabled,
		"weight": reflection_sspr_temporal_weight,
		"depth_threshold": reflection_sspr_temporal_depth_threshold,
	}


func get_reflection_sspr_conservative_coverage_enabled() -> bool:
	return reflection_sspr_conservative_coverage_enabled

@tool
class_name OceanV3
extends Node3D
## Public visual/material controls for the OceanV3 root.
## Physics, FFT and internal rendering configuration remain owned by their modules.

@export_group("Surface Detail")
@export var surface_detail_enabled: bool = true:
	set(value):
		surface_detail_enabled = value
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

@export var reflection_tint: Color = Color(0.36, 0.70, 0.86, 1.0):
	set(value):
		reflection_tint = value
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

@export_range(0.5, 12.0, 0.1) var fresnel_power: float = 4.8:
	set(value):
		fresnel_power = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var reflection_strength: float = 0.82:
	set(value):
		reflection_strength = value
		_request_visual_sync()

@export_range(0.0, 0.05, 0.0005) var refraction_strength: float = 0.009:
	set(value):
		refraction_strength = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var near_roughness: float = 0.055:
	set(value):
		near_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var horizon_roughness: float = 0.23:
	set(value):
		horizon_roughness = value
		_request_visual_sync()

@export_range(0.0, 1.0, 0.01) var water_specular: float = 0.88:
	set(value):
		water_specular = value
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


@export_category("Whitecaps Foam / Crest Filigree")
@export var crest_filigree_enabled := true:
	set(value):
		crest_filigree_enabled = value
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


@export_category("Whitecaps Foam / Surface Foam")
@export var surface_foam_enabled: bool = true:
	set(value):
		surface_foam_enabled = value
		_request_visual_sync()

@export_range(0.0, 1.5, 0.01) var surface_foam_whitecap: float = 0.0:
	set(value):
		surface_foam_whitecap = value
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

@export_category("Whitecaps Foam / Surface Foam Spectrum")
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

@export_category("Whitecaps Foam / Surface Foam Micro Detail")
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

@export_category("Whitecaps Foam Debug")
@export_enum("OFF", "CREST_FINAL", "SURFACE_HISTORY", "SURFACE_MACRO", "SURFACE_FINAL", "SURFACE_DIRECT_RAW", "SURFACE_DEPERIODIZED_RAW", "SURFACE_PLUS_CREST", "FOAM_NORMAL", "SURFACE_MID_FOLD", "CREST_FILIGREE_SOURCE", "CREST_FILIGREE_MASK", "CREST_FRESH_WEBBED", "CREST_RESIDUAL_WEBBED") var foam_debug_mode: int = 0:
	set(value):
		foam_debug_mode = clampi(value, 0, 13)
		_request_visual_sync()


var _visual_sync_pending := true


func _ready() -> void:
	_visual_sync_pending = true
	call_deferred(&"_flush_visual_sync")


func _process(_delta: float) -> void:
	# This also covers the editor case where the child material is created after
	# the root setter ran while the scene was loading.
	if _visual_sync_pending:
		_sync_water_visual_parameters()


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
	var effective_foam_debug_mode := foam_debug_mode

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
	material.set_shader_parameter(&"reflection_tint", reflection_tint)
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
	material.set_shader_parameter(&"fresnel_power", fresnel_power)
	material.set_shader_parameter(&"reflection_strength", reflection_strength)
	material.set_shader_parameter(&"refraction_strength", refraction_strength)
	# The public names are intentionally editor-friendly aliases for the shader's
	# near/far adaptive roughness uniforms.
	material.set_shader_parameter(&"ocean_roughness_near", near_roughness)
	material.set_shader_parameter(&"ocean_roughness_far", horizon_roughness)
	material.set_shader_parameter(&"water_specular", water_specular)

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
	material.set_shader_parameter(&"foam_roughness", foam_roughness)
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
	material.set_shader_parameter(&"surface_foam_whitecap", surface_foam_whitecap)
	material.set_shader_parameter(&"surface_foam_ocean_coupling", surface_foam_ocean_coupling)
	material.set_shader_parameter(&"surface_foam_distance_fade_start_m", surface_foam_distance_fade_start_m)
	material.set_shader_parameter(&"surface_foam_distance_fade_end_m", surface_foam_distance_fade_end_m)
	material.set_shader_parameter(&"surface_foam_strength", surface_foam_strength)
	material.set_shader_parameter(&"surface_foam_threshold_visual", surface_foam_threshold_visual)
	material.set_shader_parameter(&"surface_foam_mid_fold_start", surface_foam_mid_fold_start)
	material.set_shader_parameter(&"surface_foam_mid_fold_end", surface_foam_mid_fold_end)
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
				surface_foam_mid_fold_end
			)
			fft_module.set_surface_foam_spectrum_settings(
				surface_foam_fft_resolution,
				surface_foam_field_resolution,
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

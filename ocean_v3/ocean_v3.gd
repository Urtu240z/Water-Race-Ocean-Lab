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

@export_range(-2.0, 2.0, 0.01) var foam_breakup_speed: float = 0.04:
	set(value):
		foam_breakup_speed = value
		_request_visual_sync()

@export_range(0.01, 0.49, 0.01) var foam_edge_softness: float = 0.16:
	set(value):
		foam_edge_softness = value
		_request_visual_sync()

@export_enum("OFF", "RAW_FOAM", "SHAPED_FOAM", "COMPRESSION", "SPECTRAL_JACOBIAN", "FOAM_SOURCE") var foam_debug_mode: int = 0:
	set(value):
		foam_debug_mode = clampi(value, 0, 5)
		foam_mask_debug = false
		_request_visual_sync()

# Serialized compatibility for scenes created with the previous boolean
# switch. It is hidden from the inspector; true maps to SHAPED_FOAM.
@export_storage var foam_mask_debug: bool = false


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


func _flush_visual_sync() -> void:
	_sync_water_visual_parameters()


func _sync_water_visual_parameters() -> void:
	var surface := get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	if surface == null or not is_instance_valid(surface):
		return
	var material := surface.get_surface_material()
	if material == null or not is_instance_valid(material) or material.shader == null:
		return

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
	var effective_foam_debug_mode := foam_debug_mode
	if foam_mask_debug and effective_foam_debug_mode == 0:
		effective_foam_debug_mode = 2
	material.set_shader_parameter(&"foam_debug_mode", effective_foam_debug_mode)

	_visual_sync_pending = false

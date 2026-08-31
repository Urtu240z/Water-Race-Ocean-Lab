class_name OceanClipmapSurfaceV4
extends Node3D
## Draws the V4 clipmap and tracks a camera. It only consumes spectral maps.

const Config := preload("res://ocean_v4/rendering/ocean_clipmap_config_v4.gd")
const MeshBuilder := preload("res://ocean_v4/rendering/ocean_clipmap_mesh_builder_v4.gd")
const BASE_SHADER := preload("res://ocean_v4/rendering/shaders/ocean_surface_base.gdshader")
const ReflectionConfig := preload("res://ocean_v4/reflections/reflection_phase_1_config_v4.gd")

@export var clipmap_config: OceanClipmapConfigV4 = Config.new()
@export var base_color := Color(0.015, 0.07, 0.10)
@export_range(0.0, 1.0, 0.01) var roughness := 0.12
@export_range(0.0, 1.0, 0.01) var specular := 0.75
@export_enum("FULL", "LONG", "MID", "SHORT") var debug_band := 0
@export var reflection_phase_1 = ReflectionConfig.new()

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _tracking_camera: Camera3D


func configure(configs: Array[OpenOceanFFTConfigV4], displacements: Array[Texture2DRD], normals: Array[Texture2DRD], coastal_state: Dictionary = {}) -> void:
	if configs.size() != 3 or displacements.size() != 4 or normals.size() != 4:
		push_error("OceanV4 needs LONG_COASTAL, LONG_REMAINDER, MID and SHORT maps.")
		return
	_material.shader = BASE_SHADER
	bind_fft_textures(configs, displacements, normals)
	bind_coastal_geometry(coastal_state)
	_material.set_shader_parameter(&"base_color", base_color)
	_material.set_shader_parameter(&"base_roughness", roughness)
	_material.set_shader_parameter(&"base_specular", specular)
	_bind_reflection_phase_1()
	_material.set_shader_parameter(&"short_fade_range_m", clipmap_config.short_fade_range_m)
	_material.set_shader_parameter(&"mid_fade_range_m", clipmap_config.mid_fade_range_m)
	_material.set_shader_parameter(&"long_fade_range_m", clipmap_config.long_fade_range_m)
	_material.set_shader_parameter(&"debug_band", debug_band)
	_rebuild_levels()


func bind_fft_textures(configs: Array[OpenOceanFFTConfigV4], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	if configs.size() != 3 or displacements.size() != 4 or normals.size() != 4:
		push_error("OceanV4 needs LONG_COASTAL, LONG_REMAINDER, MID and SHORT maps.")
		return
	_material.set_shader_parameter(&"displacement_long_coastal", displacements[0])
	_material.set_shader_parameter(&"displacement_long_remainder", displacements[1])
	_material.set_shader_parameter(&"displacement_mid", displacements[2])
	_material.set_shader_parameter(&"displacement_short", displacements[3])
	_material.set_shader_parameter(&"normal_long_coastal", normals[0])
	_material.set_shader_parameter(&"normal_long_remainder", normals[1])
	_material.set_shader_parameter(&"normal_mid", normals[2])
	_material.set_shader_parameter(&"normal_short", normals[3])
	_material.set_shader_parameter(&"domain_long_coastal_m", configs[0].domain_size_m)
	_material.set_shader_parameter(&"domain_long_remainder_m", configs[0].domain_size_m)
	_material.set_shader_parameter(&"domain_mid_m", configs[1].domain_size_m)
	_material.set_shader_parameter(&"domain_short_m", configs[2].domain_size_m)


func bind_coastal_geometry(state: Dictionary) -> void:
	var enabled := not state.is_empty()
	_material.set_shader_parameter(&"coastal_geometry_enabled", enabled)
	if not enabled:
		return
	_material.set_shader_parameter(&"coastal_field_texture", state.field)
	_material.set_shader_parameter(&"coastal_metrics_texture", state.metrics)
	_material.set_shader_parameter(&"coastal_warp_texture", state.warp)
	_material.set_shader_parameter(&"coastal_warp_jacobian_texture", state.jacobian)
	_material.set_shader_parameter(&"coastal_origin_xz", state.origin_xz)
	_material.set_shader_parameter(&"coastal_extent_m", state.extent_m)
	_material.set_shader_parameter(&"coastal_warp_origin_xz", state.warp_origin_xz)
	_material.set_shader_parameter(&"coastal_warp_extent_m", state.warp_extent_m)
	_material.set_shader_parameter(&"coastal_warp_detj_safe", state.warp_detj_safe)
	_material.set_shader_parameter(&"coastal_min_valid_depth_m", state.min_valid_depth_m)
	_material.set_shader_parameter(&"coastal_cell_size_m", state.cell_size_m)


func set_tracking_camera(camera: Camera3D) -> void:
	_tracking_camera = camera


func set_debug_band(value: int) -> void:
	debug_band = clampi(value, 0, 3)
	_material.set_shader_parameter(&"debug_band", debug_band)


func set_reflection_phase_1_enabled(enabled: bool) -> void:
	if reflection_phase_1 == null:
		push_error("OceanV4 Reflection Phase 1 configuration is missing.")
		return
	reflection_phase_1.enabled = enabled
	_bind_reflection_phase_1()


func _bind_reflection_phase_1() -> void:
	if reflection_phase_1 == null or not reflection_phase_1.is_valid():
		push_error("OceanV4 Reflection Phase 1 configuration is invalid.")
		return
	_material.set_shader_parameter(&"reflection_phase_1_enabled", reflection_phase_1.enabled)
	_material.set_shader_parameter(&"reflection_water_specular", reflection_phase_1.water_specular)
	_material.set_shader_parameter(&"reflection_min_roughness", reflection_phase_1.min_roughness)
	_material.set_shader_parameter(&"reflection_base_roughness", reflection_phase_1.base_roughness)
	_material.set_shader_parameter(&"reflection_distance_roughness", reflection_phase_1.distance_roughness)
	_material.set_shader_parameter(&"reflection_slope_roughness_gain", reflection_phase_1.slope_roughness_gain)
	_material.set_shader_parameter(&"reflection_distance_range_m", reflection_phase_1.distance_range_m)
	_material.set_shader_parameter(&"reflection_slope_range", reflection_phase_1.slope_range)


func _process(_delta: float) -> void:
	var camera := _tracking_camera if is_instance_valid(_tracking_camera) else get_viewport().get_camera_3d()
	if camera == null: return
	var spacing := clipmap_config.base_spacing_m
	global_position = Vector3(snappedf(camera.global_position.x, spacing), clipmap_config.sea_level_y, snappedf(camera.global_position.z, spacing))
	_material.set_shader_parameter(&"camera_world_xz", Vector2(camera.global_position.x, camera.global_position.z))


func _rebuild_levels() -> void:
	for level in _levels: level.queue_free()
	_levels.clear()
	if not clipmap_config.is_valid():
		push_error("OceanV4 clipmap configuration is invalid.")
		return
	for level_index in clipmap_config.level_count:
		var instance := MeshInstance3D.new()
		instance.name = "Level%d" % level_index
		instance.mesh = MeshBuilder.create_mesh(MeshBuilder.build_level(clipmap_config, level_index))
		instance.material_override = _material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = clipmap_config.extra_cull_margin_m
		add_child(instance)
		instance.set_instance_shader_parameter(&"clipmap_level", float(level_index))
		_levels.append(instance)
	print("OceanV4 surface material=%s shader=%s levels=%d" % [_material, BASE_SHADER.resource_path, _levels.size()])
	for level in _levels:
		print("OceanV4 surface %s uses base ShaderMaterial=%s" % [level.name, level.material_override == _material])

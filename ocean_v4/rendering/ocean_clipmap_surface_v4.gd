class_name OceanClipmapSurfaceV4
extends Node3D
## Draws the V4 clipmap and tracks a camera. It only consumes spectral maps.

const Config := preload("res://ocean_v4/rendering/ocean_clipmap_config_v4.gd")
const MeshBuilder := preload("res://ocean_v4/rendering/ocean_clipmap_mesh_builder_v4.gd")
const BASE_SHADER := preload("res://ocean_v4/rendering/shaders/ocean_surface_base.gdshader")

@export var clipmap_config: OceanClipmapConfigV4 = Config.new()
@export var base_color := Color(0.015, 0.07, 0.10)
@export_range(0.0, 1.0, 0.01) var roughness := 0.12
@export_range(0.0, 1.0, 0.01) var specular := 0.75
@export_enum("FULL", "LONG", "MID", "SHORT") var debug_band := 0

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _tracking_camera: Camera3D


func configure(configs: Array[OpenOceanFFTConfigV4], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	if configs.size() != 3 or displacements.size() != 3 or normals.size() != 3:
		push_error("OceanV4 needs LONG, MID and SHORT maps.")
		return
	_material.shader = BASE_SHADER
	bind_fft_textures(configs, displacements, normals)
	_material.set_shader_parameter(&"base_color", base_color)
	_material.set_shader_parameter(&"base_roughness", roughness)
	_material.set_shader_parameter(&"base_specular", specular)
	_material.set_shader_parameter(&"short_fade_range_m", clipmap_config.short_fade_range_m)
	_material.set_shader_parameter(&"mid_fade_range_m", clipmap_config.mid_fade_range_m)
	_material.set_shader_parameter(&"long_fade_range_m", clipmap_config.long_fade_range_m)
	_material.set_shader_parameter(&"debug_band", debug_band)
	_rebuild_levels()


func bind_fft_textures(configs: Array[OpenOceanFFTConfigV4], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	if configs.size() != 3 or displacements.size() != 3 or normals.size() != 3:
		push_error("OceanV4 needs LONG, MID and SHORT maps.")
		return
	_material.set_shader_parameter(&"displacement_long", displacements[0])
	_material.set_shader_parameter(&"displacement_mid", displacements[1])
	_material.set_shader_parameter(&"displacement_short", displacements[2])
	_material.set_shader_parameter(&"normal_long", normals[0])
	_material.set_shader_parameter(&"normal_mid", normals[1])
	_material.set_shader_parameter(&"normal_short", normals[2])
	_material.set_shader_parameter(&"domain_long_m", configs[0].domain_size_m)
	_material.set_shader_parameter(&"domain_mid_m", configs[1].domain_size_m)
	_material.set_shader_parameter(&"domain_short_m", configs[2].domain_size_m)


func set_tracking_camera(camera: Camera3D) -> void:
	_tracking_camera = camera


func set_debug_band(value: int) -> void:
	debug_band = clampi(value, 0, 3)
	_material.set_shader_parameter(&"debug_band", debug_band)


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

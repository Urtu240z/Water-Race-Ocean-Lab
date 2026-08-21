class_name OceanClipmapSurface
extends Node3D
## Renderer geométrico centrado en cámara; no conoce ni modifica el campo FFT.

const MeshBuilder := preload("res://ocean_v3/rendering/ocean_clipmap_mesh_builder.gd")
const ClipmapConfigScript := preload("res://ocean_v3/rendering/ocean_clipmap_config.gd")

enum DebugMode {
	FULL_DISPLACEMENT,
	HEIGHT_ONLY,
	NORMALS,
	SLOPE,
	WIREFRAME,
}

enum CoastalDebugField {
	OFF,
	DEPTH,
	WAVELENGTH,
	PHASE_SPEED,
	GROUP_VELOCITY,
	SHOALING,
	PHASE_OFFSET,
	LOCAL_K,
	REACHABILITY,
}

@export var clipmap_config := ClipmapConfigScript.new()

var _surface_material := ShaderMaterial.new()
var _wireframe_material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _debug_mode: int = DebugMode.FULL_DISPLACEMENT
var _module_enabled := true
var _lod_debug := false
var _periodicity_debug := false
var _coastal_debug_field: int = CoastalDebugField.OFF
var _tracking_camera: Camera3D
var _triangle_count := 0


func configure(configs: Array[OpenOceanFFTConfig], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	assert(clipmap_config.is_valid())
	# 3B.2B: 4 cascadas de render: LONG_COASTAL, LONG_REMAINDER, MID, SHORT.
	assert(configs.size() == 4 and displacements.size() == 4 and normals.size() == 4)
	_surface_material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_wireframe_material.shader = load("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	_configure_materials(configs, displacements, normals)
	_rebuild_levels()
	_apply_debug_mode()


func _process(_delta: float) -> void:
	var camera := _tracking_camera if is_instance_valid(_tracking_camera) else get_viewport().get_camera_3d()
	if camera == null:
		return
	global_position = Vector3(camera.global_position.x, clipmap_config.sea_level_y, camera.global_position.z)
	var camera_xz := Vector2(camera.global_position.x, camera.global_position.z)
	_surface_material.set_shader_parameter(&"camera_world_xz", camera_xz)
	_wireframe_material.set_shader_parameter(&"camera_world_xz", camera_xz)


func set_tracking_camera(camera: Camera3D) -> void:
	_tracking_camera = camera


## 3B.2B: reaplica los rangos de fade (la demo ajusta long_fade para ver el
## warp sobre el banco local). No altera el campo FFT.
func apply_fade_ranges(config) -> void:
	for material in [_surface_material, _wireframe_material]:
		material.set_shader_parameter(&"short_fade_range_m", config.short_fade_range_m)
		material.set_shader_parameter(&"mid_fade_range_m", config.mid_fade_range_m)
		material.set_shader_parameter(&"long_fade_range_m", config.long_fade_range_m)


func set_band_debug(mode: int) -> void:
	var masks := [Vector3.ONE, Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)]
	var mask: Vector3 = masks[clampi(mode, 0, masks.size() - 1)]
	_surface_material.set_shader_parameter(&"band_mask", mask)
	_wireframe_material.set_shader_parameter(&"band_mask", mask)


func set_module_enabled(enabled: bool) -> void:
	_module_enabled = enabled
	visible = enabled
	_surface_material.set_shader_parameter(&"module_enabled", enabled)
	_wireframe_material.set_shader_parameter(&"module_enabled", enabled)


func cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % (DebugMode.WIREFRAME + 1)
	_apply_debug_mode()


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, 0, DebugMode.WIREFRAME)
	_apply_debug_mode()


func toggle_lod_debug() -> void:
	_lod_debug = not _lod_debug
	_surface_material.set_shader_parameter(&"clipmap_lod_debug", _lod_debug)
	_wireframe_material.set_shader_parameter(&"clipmap_lod_debug", _lod_debug)


func toggle_periodicity_debug() -> void:
	_periodicity_debug = not _periodicity_debug
	_surface_material.set_shader_parameter(&"periodicity_debug", _periodicity_debug)
	_wireframe_material.set_shader_parameter(&"periodicity_debug", _periodicity_debug)


func set_coastal_propagation(data, monochromatic_debug := false, monochromatic_amplitude_m := 0.35, transform_enabled := true, eikonal_phase_debug := false) -> void:
	## Sólo LONG consume esta transformación. MID/SHORT y sus H0 quedan intactos.
	var enabled: bool = data != null and data.is_valid()
	var textures: Dictionary = data.build_gpu_textures() if enabled else {}
	for material in [_surface_material, _wireframe_material]:
		# data_enabled permite MONO/Eikonal y sus probes; transform_enabled sólo
		# autoriza el warp visual de LONG (nunca para Eikonal 3B.1).
		material.set_shader_parameter(&"coastal_propagation_enabled", enabled)
		material.set_shader_parameter(&"coastal_transform_enabled", enabled and transform_enabled)
		material.set_shader_parameter(&"coastal_monochromatic_debug", monochromatic_debug and enabled)
		material.set_shader_parameter(&"coastal_eikonal_phase_debug", eikonal_phase_debug and monochromatic_debug and enabled)
		material.set_shader_parameter(&"coastal_monochromatic_amplitude_m", monochromatic_amplitude_m)
		if not enabled:
			continue
		material.set_shader_parameter(&"coastal_field_texture", textures["field"])
		material.set_shader_parameter(&"coastal_metrics_texture", textures["metrics"])
		material.set_shader_parameter(&"coastal_phase_texture", textures["phase"])
		material.set_shader_parameter(&"coastal_origin_xz", data.world_origin_xz)
		material.set_shader_parameter(&"coastal_extent_m", data.world_max_xz() - data.world_origin_xz)
		material.set_shader_parameter(&"coastal_k0_rad_m", data.k0_rad_m)
		material.set_shader_parameter(&"coastal_omega_rad_s", data.omega_ref_rad_s)
		material.set_shader_parameter(&"coastal_incoming_direction_xz", data.incoming_direction_xz)
	set_coastal_debug_field(_coastal_debug_field)


func set_coastal_warp(warp_data, enabled := true) -> void:
	## 3B.2B: pasa el CoastalWarpData al shader (textura deep_xz + detJ + valid).
	## El shader samplea LONG_COASTAL en deep_xz cuando el warp es válido y
	## blend suave en NEAR_CAUSTIC; fallback a world_xz en inválido/folded.
	var warp_enabled: bool = enabled and warp_data != null and warp_data.is_valid()
	var textures: Dictionary = warp_data.build_gpu_textures() if warp_enabled else {}
	for material in [_surface_material, _wireframe_material]:
		material.set_shader_parameter(&"coastal_warp_enabled", warp_enabled)
		if not warp_enabled:
			continue
		material.set_shader_parameter(&"coastal_warp_texture", textures["warp"])
		material.set_shader_parameter(&"coastal_warp_origin_xz", warp_data.world_origin_xz)
		material.set_shader_parameter(&"coastal_warp_extent_m", warp_data.world_max_xz() - warp_data.world_origin_xz)
		material.set_shader_parameter(&"coastal_warp_detj_safe", warp_data.detj_safe_threshold)


func set_coastal_time(simulation_time_s: float) -> void:
	_surface_material.set_shader_parameter(&"coastal_time_s", simulation_time_s)
	_wireframe_material.set_shader_parameter(&"coastal_time_s", simulation_time_s)


func set_coastal_debug_field(field: int) -> void:
	_coastal_debug_field = clampi(field, CoastalDebugField.OFF, CoastalDebugField.REACHABILITY)
	_surface_material.set_shader_parameter(&"coastal_debug_field", _coastal_debug_field)
	_wireframe_material.set_shader_parameter(&"coastal_debug_field", _coastal_debug_field)


func debug_mode_name() -> String:
	match _debug_mode:
		DebugMode.FULL_DISPLACEMENT: return "DX + HEIGHT + DZ"
		DebugMode.HEIGHT_ONLY: return "HEIGHT ONLY"
		DebugMode.NORMALS: return "NORMALS"
		DebugMode.SLOPE: return "SLOPE / GEOMETRY"
		DebugMode.WIREFRAME: return "WIREFRAME"
	return "UNKNOWN"


func lod_debug_name() -> String:
	return "ON" if _lod_debug else "OFF"


func periodicity_debug_name() -> String:
	return "ON" if _periodicity_debug else "OFF"


func triangle_count() -> int:
	return _triangle_count


func level_count() -> int:
	return _levels.size()


func final_half_extent_m() -> float:
	return clipmap_config.final_half_extent_m()


func _configure_materials(configs: Array[OpenOceanFFTConfig], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	# 3B.2B: índices de render -> LONG_COASTAL=0, LONG_REMAINDER=1, MID=2, SHORT=3.
	var ids := ["long_coastal", "long_remainder", "mid", "short"]
	for material in [_surface_material, _wireframe_material]:
		material.set_shader_parameter(&"module_enabled", _module_enabled)
		material.set_shader_parameter(&"short_fade_range_m", clipmap_config.short_fade_range_m)
		material.set_shader_parameter(&"mid_fade_range_m", clipmap_config.mid_fade_range_m)
		material.set_shader_parameter(&"long_fade_range_m", clipmap_config.long_fade_range_m)
		material.set_shader_parameter(&"clipmap_lod_debug", _lod_debug)
		material.set_shader_parameter(&"periodicity_debug", _periodicity_debug)
		material.set_shader_parameter(&"coastal_propagation_enabled", false)
		material.set_shader_parameter(&"coastal_transform_enabled", false)
		material.set_shader_parameter(&"coastal_monochromatic_debug", false)
		material.set_shader_parameter(&"coastal_eikonal_phase_debug", false)
		material.set_shader_parameter(&"coastal_debug_field", CoastalDebugField.OFF)
		material.set_shader_parameter(&"coastal_warp_enabled", false)
		for index in 4:
			material.set_shader_parameter("domain_%s_m" % ids[index], configs[index].domain_size_m)
			material.set_shader_parameter("displacement_%s" % ids[index], displacements[index])
	_surface_material.set_shader_parameter(&"normal_long_coastal", normals[0])
	_surface_material.set_shader_parameter(&"normal_long_remainder", normals[1])
	_surface_material.set_shader_parameter(&"normal_mid", normals[2])
	_surface_material.set_shader_parameter(&"normal_short", normals[3])


func _rebuild_levels() -> void:
	for level in _levels:
		level.queue_free()
	_levels.clear()
	_triangle_count = 0
	for level_index in clipmap_config.level_count:
		var geometry := MeshBuilder.build_level_geometry(clipmap_config, level_index)
		var error := MeshBuilder.validate_geometry(geometry)
		if not error.is_empty():
			push_error("Clipmap L%d inválido: %s" % [level_index, error])
			continue
		var level_mesh := MeshBuilder.create_mesh(geometry)
		var instance := MeshInstance3D.new()
		instance.name = "Level%d" % level_index
		instance.mesh = level_mesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = clipmap_config.extra_cull_margin_m
		instance.set_instance_shader_parameter(&"clipmap_level", float(level_index))
		add_child(instance)
		_levels.append(instance)
		_triangle_count += int(float(geometry.indices.size()) / 3.0)


func _apply_debug_mode() -> void:
	for level in _levels:
		level.material_override = _wireframe_material if _debug_mode == DebugMode.WIREFRAME else _surface_material
	_surface_material.set_shader_parameter(&"debug_mode", mini(_debug_mode, DebugMode.SLOPE))

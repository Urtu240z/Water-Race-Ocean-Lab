class_name OceanTestSurface
extends MeshInstance3D
## Malla finita de inspección. No es un clipmap ni un LOD de producción.

enum DebugMode {
	FULL_DISPLACEMENT,
	HEIGHT_ONLY,
	NORMALS,
	WIREFRAME,
}

var _surface_material := ShaderMaterial.new()
var _wireframe_material := ShaderMaterial.new()
var _debug_mode := DebugMode.FULL_DISPLACEMENT
var _module_enabled := true


func configure(config: Resource, displacement: Texture2DRD, normal: Texture2DRD) -> void:
	var plane = PlaneMesh.new()
	plane.size = Vector2(config.domain_size_m, config.domain_size_m)
	plane.subdivide_width = config.resolution - 1
	plane.subdivide_depth = config.resolution - 1
	mesh = plane

	_surface_material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_wireframe_material.shader = load("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	for material in [_surface_material, _wireframe_material]:
		material.set_shader_parameter(&"domain_size_m", config.domain_size_m)
		material.set_shader_parameter(&"displacement_map", displacement)
		material.set_shader_parameter(&"module_enabled", _module_enabled)
	_surface_material.set_shader_parameter(&"ocean_normal_map", normal)
	_apply_debug_mode()


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, DebugMode.FULL_DISPLACEMENT, DebugMode.WIREFRAME)
	_apply_debug_mode()


func cycle_debug_mode() -> void:
	set_debug_mode((_debug_mode + 1) % (DebugMode.WIREFRAME + 1))


func debug_mode_name() -> String:
	match _debug_mode:
		DebugMode.FULL_DISPLACEMENT:
			return "DX + HEIGHT + DZ"
		DebugMode.HEIGHT_ONLY:
			return "HEIGHT ONLY"
		DebugMode.NORMALS:
			return "NORMALS"
		DebugMode.WIREFRAME:
			return "WIREFRAME"
	return "UNKNOWN"


func set_module_enabled(enabled: bool) -> void:
	_module_enabled = enabled
	visible = enabled
	_surface_material.set_shader_parameter(&"module_enabled", enabled)
	_wireframe_material.set_shader_parameter(&"module_enabled", enabled)


func _apply_debug_mode() -> void:
	material_override = _wireframe_material if _debug_mode == DebugMode.WIREFRAME else _surface_material
	_surface_material.set_shader_parameter(&"debug_mode", mini(_debug_mode, DebugMode.NORMALS))

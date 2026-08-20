class_name OceanTestSurface
extends MeshInstance3D
## Malla finita de inspección multibanda. No es un clipmap ni un LOD de producción.

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


func configure(configs: Array[OpenOceanFFTConfig], displacements: Array[Texture2DRD], normals: Array[Texture2DRD]) -> void:
	assert(configs.size() == 3 and displacements.size() == 3 and normals.size() == 3)
	var plane := PlaneMesh.new()
	# 256 m permite inspeccionar la banda LONG sin anticipar el clipmap de Fase 1C.
	plane.size = Vector2(256.0, 256.0)
	plane.subdivide_width = 255
	plane.subdivide_depth = 255
	mesh = plane

	_surface_material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_wireframe_material.shader = load("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	var ids := ["long", "mid", "short"]
	for material in [_surface_material, _wireframe_material]:
		material.set_shader_parameter(&"module_enabled", _module_enabled)
		for index in 3:
			material.set_shader_parameter("domain_%s_m" % ids[index], configs[index].domain_size_m)
			material.set_shader_parameter("displacement_%s" % ids[index], displacements[index])
	_surface_material.set_shader_parameter(&"normal_long", normals[0])
	_surface_material.set_shader_parameter(&"normal_mid", normals[1])
	_surface_material.set_shader_parameter(&"normal_short", normals[2])
	_apply_debug_mode()


func set_band_debug(mode: int) -> void:
	# ALL, LONG, MID, SHORT se convierten en máscaras para el material.
	var masks := [Vector3.ONE, Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)]
	var mask: Vector3 = masks[clampi(mode, 0, masks.size() - 1)]
	_surface_material.set_shader_parameter(&"band_mask", mask)
	_wireframe_material.set_shader_parameter(&"band_mask", mask)


func cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % (DebugMode.WIREFRAME + 1)
	_apply_debug_mode()


func debug_mode_name() -> String:
	match _debug_mode:
		DebugMode.FULL_DISPLACEMENT: return "DX + HEIGHT + DZ"
		DebugMode.HEIGHT_ONLY: return "HEIGHT ONLY"
		DebugMode.NORMALS: return "NORMALS"
		DebugMode.WIREFRAME: return "WIREFRAME"
	return "UNKNOWN"


func set_module_enabled(enabled: bool) -> void:
	_module_enabled = enabled
	visible = enabled
	_surface_material.set_shader_parameter(&"module_enabled", enabled)
	_wireframe_material.set_shader_parameter(&"module_enabled", enabled)


func _apply_debug_mode() -> void:
	material_override = _wireframe_material if _debug_mode == DebugMode.WIREFRAME else _surface_material
	_surface_material.set_shader_parameter(&"debug_mode", mini(_debug_mode, DebugMode.NORMALS))

extends Node3D
## Prototipo AISLADO de breaker por cross-section (inspirado en Horizon Forbidden West).
## Una única ola local cuya silueta lateral está controlada por una curva
## paramétrica explícita (BreakerCrossSection). NO depende de PREBREAK, FFT,
## coastal, pool ni del shader de producción.

const CrossSection := preload("res://lab/breaking/breaker_cross_section.gd")

const U_SEGMENTS := 64
const V_SEGMENTS := 8
const WIDTH_M := 3.0

enum CameraMode { SIDE, THREE_QUARTER, CLOSE }
enum DebugMode { LIT, WIREFRAME, SILHOUETTE }

const _CAMERA_NAMES := ["SIDE", "3-QUARTER", "CLOSE"]
const _DEBUG_NAMES := ["LIT", "WIREFRAME", "SILHOUETTE"]

@onready var _breaker_mesh: MeshInstance3D = $BreakerMesh
@onready var _water_plane: MeshInstance3D = $WaterPlane
@onready var _status: Label = %Status
@onready var _side_camera: Camera3D = $SideCamera
@onready var _three_quarter_camera: Camera3D = $ThreeQuarterCamera
@onready var _close_camera: Camera3D = $CloseCamera

var _breaker_stage := 0.5
var _camera_mode: int = CameraMode.THREE_QUARTER
var _debug_mode: int = DebugMode.LIT
var _animating := false
var _auto_t := 0.0

var _mesh: ArrayMesh
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _indices := PackedInt32Array()

var _lit_material: StandardMaterial3D
var _silhouette_material: StandardMaterial3D
var _wireframe_material: ShaderMaterial


func _ready() -> void:
	get_window().title = "Breaker Cross-Section Prototype"
	_build_indices()
	_make_materials()
	_make_water_plane()
	_side_camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	_three_quarter_camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	_close_camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	_set_camera_mode(_camera_mode)
	_set_debug_mode(_debug_mode)
	_rebuild_geometry()
	_update_status()


func _process(delta: float) -> void:
	if not _animating:
		return
	_auto_t += delta
	var phase := fmod(_auto_t * 0.3, 1.0)
	_breaker_stage = 0.5 - 0.5 * cos(phase * TAU)  # 0 → 1 → 0 suave.
	_rebuild_geometry()
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_Q:
			_set_stage(_breaker_stage - 0.05)
		KEY_E:
			_set_stage(_breaker_stage + 0.05)
		KEY_R:
			_set_stage(0.0)
		KEY_P:
			_animating = not _animating
		KEY_C:
			_set_camera_mode((_camera_mode + 1) % (CameraMode.CLOSE + 1))
		KEY_W:
			_set_debug_mode((_debug_mode + 1) % (DebugMode.SILHOUETTE + 1))
	_update_status()


func _set_stage(value: float) -> void:
	_breaker_stage = clampf(value, 0.0, 1.0)
	_rebuild_geometry()
	_update_status()


func _set_camera_mode(mode: int) -> void:
	_camera_mode = clampi(mode, CameraMode.SIDE, CameraMode.CLOSE)
	if _camera_mode == CameraMode.SIDE:
		_side_camera.make_current()
	elif _camera_mode == CameraMode.THREE_QUARTER:
		_three_quarter_camera.make_current()
	else:
		_close_camera.make_current()


func _set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, DebugMode.LIT, DebugMode.SILHOUETTE)
	match _debug_mode:
		DebugMode.LIT:
			_breaker_mesh.material_override = _lit_material
		DebugMode.WIREFRAME:
			_breaker_mesh.material_override = _wireframe_material
		DebugMode.SILHOUETTE:
			_breaker_mesh.material_override = _silhouette_material


func _build_indices() -> void:
	_indices.clear()
	for j in V_SEGMENTS:
		for i in U_SEGMENTS:
			var a := j * (U_SEGMENTS + 1) + i
			var b := a + 1
			var c := a + (U_SEGMENTS + 1)
			var d := c + 1
			_indices.append_array(PackedInt32Array([a, b, c, b, d, c]))


func _rebuild_geometry() -> void:
	var count := (U_SEGMENTS + 1) * (V_SEGMENTS + 1)
	_vertices.resize(count)
	_normals.resize(count)
	var idx := 0
	for j in V_SEGMENTS + 1:
		var v := float(j) / float(V_SEGMENTS)
		for i in U_SEGMENTS + 1:
			var u := float(i) / float(U_SEGMENTS)
			var p: Vector2 = CrossSection.point(u, _breaker_stage)
			var n: Vector2 = CrossSection.normal(u, _breaker_stage)
			_vertices[idx] = Vector3(p.x, p.y, (v - 0.5) * WIDTH_M)
			_normals[idx] = Vector3(n.x, n.y, 0.0)
			idx += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_INDEX] = _indices
	if _mesh == null:
		_mesh = ArrayMesh.new()
		_breaker_mesh.mesh = _mesh
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _make_materials() -> void:
	_lit_material = StandardMaterial3D.new()
	_lit_material.albedo_color = Color(0.16, 0.34, 0.46)
	_lit_material.roughness = 0.35
	_lit_material.metallic = 0.0
	_lit_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_silhouette_material = StandardMaterial3D.new()
	_silhouette_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_silhouette_material.albedo_color = Color(0.82, 0.9, 1.0)
	_silhouette_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_wireframe_material = ShaderMaterial.new()
	_wireframe_material.shader = load("res://lab/breaking/breaker_wireframe.gdshader")


func _make_water_plane() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	_water_plane.mesh = plane
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.08, 0.20, 0.30)
	water.roughness = 0.4
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.albedo_color.a = 0.55
	_water_plane.material_override = water


func _update_status() -> void:
	_status.text = "BREAKER CROSS-SECTION PROTOTYPE\nstage: %.2f | camera: %s | debug: %s | auto-play: %s\n\nQ/E stage +- | R reset | P auto-play | C camera | W debug" % [_breaker_stage, _CAMERA_NAMES[_camera_mode], _DEBUG_NAMES[_debug_mode], "ON" if _animating else "OFF"]

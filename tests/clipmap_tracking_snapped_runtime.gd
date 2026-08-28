extends SceneTree
## Validación de tracking en el árbol 3D real; no inspecciona ni modifica shaders.

var _frame := 0
var _failures := 0
var _surface: OceanClipmapSurface
var _camera: Camera3D
var _original_camera_position := Vector3.ZERO


func _initialize() -> void:
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 5:
		if not _prepare_runtime_nodes():
			push_error("CLIPMAP_TRACKING_SNAPPED_RUNTIME: faltan surface o cámara")
			quit(1)
			return false
		_validate_modes()
		_surface.set_clipmap_tracking_debug_mode(0)
		_camera.global_position = _original_camera_position
	if _frame == 10:
		if _failures == 0:
			print("CLIPMAP_TRACKING_SNAPPED_RUNTIME: PASS")
			quit(0)
		else:
			push_error("CLIPMAP_TRACKING_SNAPPED_RUNTIME: %d fallos" % _failures)
			quit(1)
	return false


func _prepare_runtime_nodes() -> bool:
	var module := get_first_node_in_group(&"ocean_fft")
	var scene := current_scene
	if module == null or scene == null:
		return false
	_surface = module.get_node_or_null(^"OceanClipmapSurface") as OceanClipmapSurface
	_camera = scene.get_node_or_null(^"Cameras/FreeCamera") as Camera3D
	if _surface == null or _camera == null:
		return false
	_surface.set_tracking_camera(_camera)
	_original_camera_position = _camera.global_position
	return true


func _validate_modes() -> void:
	_camera.global_position = Vector3(123.30, 4.0, -45.30)
	_surface.set_clipmap_tracking_debug_mode(0)
	_surface._process(0.0)
	_check(is_equal_approx(_surface.global_position.x, 123.30) and is_equal_approx(_surface.global_position.z, -45.30), "CONTINUOUS sigue la cámara")

	_surface.set_clipmap_tracking_debug_mode(1)
	_surface._process(0.0)
	var frozen_position := _surface.global_position
	_camera.global_position = Vector3(127.0, 4.0, -49.0)
	_surface._process(0.0)
	_check(_surface.global_position == frozen_position, "FROZEN conserva el root")

	_surface.clipmap_tracking_snap_m = 0.25
	_surface.set_clipmap_tracking_debug_mode(2)
	_camera.global_position = Vector3(123.30, 4.0, -45.30)
	_surface._process(0.0)
	_check(_surface.global_position == Vector3(123.25, 0.0, -45.25), "SNAPPED cuantiza a 0.25 m")
	var snapped_position := _surface.global_position
	_camera.global_position = Vector3(123.36, 4.0, -45.36)
	_surface._process(0.0)
	_check(_surface.global_position == snapped_position, "SNAPPED no se mueve dentro de la celda")
	_camera.global_position = Vector3(123.38, 4.0, -45.38)
	_surface._process(0.0)
	_check(_surface.global_position == Vector3(123.50, 0.0, -45.50), "SNAPPED salta al cruzar la celda")
	var camera_world_xz = _surface.get_surface_material().get_shader_parameter(&"camera_world_xz")
	_check(camera_world_xz == Vector2(123.38, -45.38), "camera_world_xz conserva la cámara continua")

	_surface.clipmap_tracking_snap_m = 0.50
	_surface._process(0.0)
	_check(_surface.global_position == Vector3(123.50, 0.0, -45.50), "SNAPPED recalcula al cambiar a 0.50 m")
	_surface.clipmap_tracking_snap_m = 1.00
	_surface._process(0.0)
	_check(_surface.global_position == Vector3(123.0, 0.0, -45.0), "SNAPPED recalcula al cambiar a 1.00 m")
	_check(_surface.clipmap_tracking_debug_mode_name() == "SNAPPED (1.00 m)", "HUD expone modo y tamaño SNAPPED")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

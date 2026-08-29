extends SceneTree
## X2: valida el tracking per-level sobre el árbol 3D real.
## Comprueba cache estático, cells/origins/parity, cambios de modo y propiedades
## de instancia; no cambia shaders ni reconstruye escenas durante el test.

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
			push_error("CLIPMAP_PER_LEVEL_TRACKING_RUNTIME: faltan surface o cámara")
			quit(1)
			return false
		_validate_per_level_tracking()
		_validate_mode_switching()
		_surface.set_clipmap_tracking_debug_mode(0)
		_camera.global_position = _original_camera_position
	if _frame == 10:
		if _failures == 0:
			print("CLIPMAP_PER_LEVEL_TRACKING_RUNTIME: PASS")
			quit(0)
		else:
			push_error("CLIPMAP_PER_LEVEL_TRACKING_RUNTIME: %d fallos" % _failures)
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


func _validate_per_level_tracking() -> void:
	_check(_surface.level_count() == 10, "hay un nivel MeshInstance por cada LOD")
	_check(_surface._levels.size() == 10, "no se crean MeshInstance superpuestos por variante")
	_check(_surface._level_states[0].variant_meshes[0] != null and _surface._level_states[0].variant_meshes[1] == null and _surface._level_states[0].variant_meshes[2] == null and _surface._level_states[0].variant_meshes[3] == null, "L0 conserva una única mesh")
	var all_coarse_variants_built := true
	for level in range(1, _surface._level_states.size()):
		for variant_mesh in _surface._level_states[level].variant_meshes:
			all_coarse_variants_built = all_coarse_variants_built and variant_mesh != null
	_check(all_coarse_variants_built, "L1-L9 tienen las cuatro meshes preconstruidas")
	_check(_surface.clipmap_variant_cache_memory_bytes() == 22012560, "cache runtime de variantes coincide con X1")
	_check(_surface.triangle_count() == 256256, "triangle_count inicial usa baseline 00")

	_surface.set_debug_mode(4)
	_surface.toggle_lod_debug()
	_camera.global_position = Vector3(0.0, 4.0, 0.0)
	_surface.set_clipmap_tracking_debug_mode(3)
	_surface._process(0.0)
	var initial_snapshot: Array = _surface.clipmap_tracking_snapshot()
	_check(_surface.clipmap_tracking_debug_mode_name() == "PER-LEVEL", "HUD expone PER-LEVEL")
	_check(_snapshot_matches_camera(initial_snapshot, Vector2.ZERO), "cells, origins y parity usan floor absoluto")
	_check(_surface.get_surface_material().get_shader_parameter(&"camera_world_xz") == Vector2.ZERO, "camera_world_xz permanece continua")
	_check(_active_meshes_match_snapshot(initial_snapshot), "cada LOD selecciona la variante de su parity")

	var first_instance := _surface._levels[0]
	var first_material := first_instance.material_override
	var first_cull_margin := first_instance.extra_cull_margin
	var first_cast_shadow := first_instance.cast_shadow
	var first_visibility := first_instance.visible
	var first_lod_parameter = first_instance.get_instance_shader_parameter(&"clipmap_level")
	_camera.global_position = Vector3(0.11, 4.0, 0.11)
	_surface._process(0.0)
	_check(_snapshots_equal(initial_snapshot, _surface.clipmap_tracking_snapshot()), "LOD inmóvil dentro de sus cells")
	_check(first_instance.material_override == first_material and first_instance.extra_cull_margin == first_cull_margin and first_instance.cast_shadow == first_cast_shadow and first_instance.visible == first_visibility and first_instance.get_instance_shader_parameter(&"clipmap_level") == first_lod_parameter, "mesh swap conserva estado de instancia y debug")

	var previous_snapshot := initial_snapshot
	for camera_xz in [Vector2(0.38, 0.38), Vector2(0.38, 0.63), Vector2(0.63, 0.38), Vector2(100.0, 100.0), Vector2(-100.0, 100.0), Vector2(100.0, -100.0), Vector2(-100.0, -100.0), Vector2.ZERO]:
		_camera.global_position = Vector3(camera_xz.x, 4.0, camera_xz.y)
		_surface._process(0.0)
		var snapshot: Array = _surface.clipmap_tracking_snapshot()
		_check(_snapshot_matches_camera(snapshot, camera_xz), "trayectoria %s: floor, origin y parity exactos" % camera_xz)
		_check(_origin_deltas_are_lattice_multiples(previous_snapshot, snapshot), "trayectoria %s: delta por level es múltiplo de spacing" % camera_xz)
		_check(_active_meshes_match_snapshot(snapshot), "trayectoria %s: variant coincide con parity" % camera_xz)
		_check(_surface.triangle_count() == _active_triangle_count(snapshot), "trayectoria %s: triangle_count refleja variants activas" % camera_xz)
		previous_snapshot = snapshot
	_check(_snapshots_equal(initial_snapshot, _surface.clipmap_tracking_snapshot()), "ida y vuelta devuelve exactamente cells/origins/variants iniciales")
	_check(_surface.triangle_count() == 256256, "triangle_count vuelve al baseline en estado 00")


func _validate_mode_switching() -> void:
	_camera.global_position = Vector3(7.13, 4.0, -3.37)
	_surface.set_clipmap_tracking_debug_mode(3)
	_surface._process(0.0)
	var per_snapshot: Array = _surface.clipmap_tracking_snapshot()
	_surface.set_clipmap_tracking_debug_mode(1)
	_surface._process(0.0)
	_check(_legacy_children_restored(), "PER-LEVEL -> FROZEN restaura transforms y meshes 00")
	_surface.set_clipmap_tracking_debug_mode(3)
	_surface._process(0.0)
	_check(_snapshot_matches_camera(_surface.clipmap_tracking_snapshot(), Vector2(7.13, -3.37)), "FROZEN -> PER-LEVEL recalcula inmediatamente")
	_surface.set_clipmap_tracking_debug_mode(2)
	_surface._process(0.0)
	_check(_legacy_children_restored(), "PER-LEVEL -> SNAPPED restaura transforms y meshes 00")
	_surface.set_clipmap_tracking_debug_mode(3)
	_surface._process(0.0)
	_check(_active_meshes_match_snapshot(_surface.clipmap_tracking_snapshot()), "SNAPPED -> PER-LEVEL selecciona variant inmediatamente")
	_surface.set_clipmap_tracking_debug_mode(0)
	_surface._process(0.0)
	_check(_legacy_children_restored(), "PER-LEVEL -> CONTINUOUS restaura transforms y meshes 00")
	_check(_surface._levels[0].get_instance_shader_parameter(&"clipmap_level") == 0.0, "clipmap_level permanece intacto al cambiar de modo")
	_check(per_snapshot.size() == _surface.level_count(), "el cambio de modo no altera el número de instancias")


func _snapshot_matches_camera(snapshot: Array, camera_xz: Vector2) -> bool:
	if snapshot.size() != _surface.level_count():
		return false
	for level in snapshot.size():
		var spacing: float = _surface.clipmap_config.spacing_for_level(level)
		var cell := Vector2i(floori(camera_xz.x / spacing), floori(camera_xz.y / spacing))
		var expected_origin := Vector3(float(cell.x) * spacing, _surface.clipmap_config.sea_level_y, float(cell.y) * spacing)
		var state: Dictionary = snapshot[level]
		if state["cell"] != cell or not state["global_position"].is_equal_approx(expected_origin):
			return false
		if level == 0:
			if state["parity"] != Vector2i(-1, -1) or state["variant_index"] != 0:
				return false
		else:
			var fine_spacing: float = _surface.clipmap_config.spacing_for_level(level - 1)
			var fine_cell := Vector2i(floori(camera_xz.x / fine_spacing), floori(camera_xz.y / fine_spacing))
			var parity := fine_cell - cell * 2
			if parity.x < 0 or parity.x > 1 or parity.y < 0 or parity.y > 1:
				return false
			if state["parity"] != parity or state["variant_index"] != parity.x + parity.y * 2:
				return false
	return true


func _active_meshes_match_snapshot(snapshot: Array) -> bool:
	for level in snapshot.size():
		var state: Dictionary = snapshot[level]
		var runtime_state = _surface._level_states[level]
		if _surface._levels[level].mesh != runtime_state.variant_meshes[state["variant_index"]]:
			return false
	return true


func _active_triangle_count(snapshot: Array) -> int:
	var total := 0
	for level in snapshot.size():
		var state = _surface._level_states[level]
		total += state.variant_triangle_counts[snapshot[level]["variant_index"]]
	return total


func _origin_deltas_are_lattice_multiples(previous: Array, current: Array) -> bool:
	for level in current.size():
		var before: Vector3 = previous[level]["global_position"]
		var after: Vector3 = current[level]["global_position"]
		var spacing: float = _surface.clipmap_config.spacing_for_level(level)
		for delta in [after.x - before.x, after.z - before.z]:
			var lattice_delta: float = delta / spacing
			if not is_equal_approx(lattice_delta, roundi(lattice_delta)):
				return false
	return true


func _snapshots_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if a[index]["cell"] != b[index]["cell"] or a[index]["parity"] != b[index]["parity"] or a[index]["variant_index"] != b[index]["variant_index"] or not a[index]["global_position"].is_equal_approx(b[index]["global_position"]):
			return false
	return true


func _legacy_children_restored() -> bool:
	for level in _surface._level_states.size():
		var state = _surface._level_states[level]
		if state.instance.transform != state.baseline_transform or state.instance.mesh != state.variant_meshes[0] or state.current_variant_index != 0:
			return false
	return true


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

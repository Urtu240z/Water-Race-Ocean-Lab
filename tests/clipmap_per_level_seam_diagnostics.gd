extends SceneTree
## X2.1: diagnostica seams del runtime per-level sin modificar la topología.
## A audita las fronteras de las ArrayMesh activas en world space. B/C dejan
## preparados dos A/B visuales independientes para la inspección D3D12.

const TRACKING_MODE_PER_LEVEL := 3
const CAMERA_HEIGHT_M := 4.0
const TRANSITION_EPSILON_M := 0.001

var _frame := 0
var _failures := 0
var _surface: OceanClipmapSurface
var _camera: Camera3D
var _original_camera_position := Vector3.ZERO
var _boundary_local_cache: Dictionary = {}
var _link_order: Array[String] = []
var _cpu_max_errors: Dictionary = {}
var _float32_max_errors: Dictionary = {}
var _audit_sample_count := 0
var _temporal_sample_count := 0


func _initialize() -> void:
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 5:
		if not _prepare_runtime_nodes():
			push_error("CLIPMAP_PER_LEVEL_SEAM_DIAGNOSTICS: faltan surface o cámara")
			quit(1)
			return false
		_validate_x21()
	if _frame == 10:
		if _failures == 0:
			_print_matrix()
			print("CLIPMAP_PER_LEVEL_SEAM_DIAGNOSTICS: PASS")
			quit(0)
		else:
			push_error("CLIPMAP_PER_LEVEL_SEAM_DIAGNOSTICS: %d fallos" % _failures)
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
	for level in range(1, _surface.level_count()):
		_link_order.append("L%d-L%d" % [level - 1, level])
		_cpu_max_errors["L%d-L%d" % [level - 1, level]] = 0.0
		_float32_max_errors["L%d-L%d" % [level - 1, level]] = 0.0
	return true


func _validate_x21() -> void:
	_surface.set_debug_mode(0)
	_surface.set_clipmap_tracking_debug_mode(TRACKING_MODE_PER_LEVEL)
	_validate_diagnostic_modes()
	_validate_world_boundaries()
	_validate_temporal_parity()
	_camera.global_position = _original_camera_position
	_surface.set_clipmap_flat_geometry_debug(false)
	_surface.set_clipmap_displaced_unlit_debug(false)
	_surface.set_clipmap_tracking_debug_mode(0)
	_surface._process(0.0)


func _validate_diagnostic_modes() -> void:
	_surface.set_clipmap_flat_geometry_debug(true)
	_check(_surface.clipmap_diagnostic_mode_name() == "FLAT GEOMETRY", "diagnóstico FLAT GEOMETRY disponible")
	_check(_surface.get_surface_material().get_shader_parameter(&"clipmap_flat_geometry_debug") == true, "uniform FLAT activo")
	_surface.set_clipmap_flat_geometry_debug(false)
	_surface.set_clipmap_displaced_unlit_debug(true)
	_check(_surface.clipmap_diagnostic_mode_name() == "DISPLACED UNLIT", "diagnóstico DISPLACED UNLIT disponible")
	_check(_surface.get_surface_material().get_shader_parameter(&"clipmap_displaced_unlit_debug") == true, "uniform DISPLACED UNLIT activo")
	_surface.set_clipmap_displaced_unlit_debug(false)
	_check(_surface.clipmap_diagnostic_mode_name() == "OFF", "diagnósticos restaurados a OFF")


func _validate_world_boundaries() -> void:
	# Large absolute positions exercise the same floor/parity decisions as X2,
	# including negative cells and diagonal movement. The audit uses the active
	# mesh resource and the active MeshInstance3D transform at every sample.
	var positions := [
		Vector2.ZERO,
		Vector2(100.0, 0.0), Vector2(-100.0, 0.0), Vector2(0.0, 100.0), Vector2(0.0, -100.0),
		Vector2(100.0, 100.0), Vector2(-100.0, 100.0), Vector2(100.0, -100.0), Vector2(-100.0, -100.0),
		Vector2(1000.0, 1000.0), Vector2(-1000.0, 1000.0), Vector2(4000.0, -4000.0),
		Vector2(-8000.0, 8000.0), Vector2(8000.0, -8000.0),
	]
	for camera_xz in positions:
		_audit_sample(camera_xz, "large %s" % camera_xz)


func _validate_temporal_parity() -> void:
	# Probe both signs and both axes immediately before, at, and after every
	# per-level cell boundary. The snapshot is checked after each process callback,
	# so no partially applied logical state can pass the diagnostic.
	for level in range(1, _surface.level_count()):
		var spacing: float = _surface.clipmap_config.spacing_for_level(level)
		for sign in [-1.0, 1.0]:
			var boundary: float = spacing * sign
			for delta in [-TRANSITION_EPSILON_M, 0.0, TRANSITION_EPSILON_M]:
				_audit_sample(Vector2(boundary + delta, 0.0), "L%d X %+.3f" % [level, delta], true)
				_audit_sample(Vector2(0.0, boundary + delta), "L%d Z %+.3f" % [level, delta], true)


func _audit_sample(camera_xz: Vector2, label: String, temporal_probe := false) -> void:
	_camera.global_position = Vector3(camera_xz.x, CAMERA_HEIGHT_M, camera_xz.y)
	_surface._process(0.0)
	var snapshot: Array = _surface.clipmap_tracking_snapshot()
	_check(_snapshot_matches_camera(snapshot, camera_xz), "%s: parity/cells/origins coherentes" % label)
	_check(_active_meshes_match_snapshot(snapshot), "%s: mesh activa coincide con variante" % label)
	var all_links_closed := true
	for link_index in range(_link_order.size()):
		var fine_level := link_index
		var coarse_level := link_index + 1
		var result: Dictionary = _audit_link(fine_level, coarse_level)
		all_links_closed = all_links_closed and bool(result["closed"])
		var key: String = _link_order[link_index]
		_cpu_max_errors[key] = maxf(float(_cpu_max_errors[key]), float(result["cpu_max_error_m"]))
		_float32_max_errors[key] = maxf(float(_float32_max_errors[key]), float(result["float32_max_error_m"]))
	_check(all_links_closed, "%s: fronteras fine/coarse cerradas en world space" % label)
	_audit_sample_count += 1
	if temporal_probe:
		_temporal_sample_count += 1


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


func _audit_link(fine_level: int, coarse_level: int) -> Dictionary:
	var fine_state = _surface._level_states[fine_level]
	var coarse_state = _surface._level_states[coarse_level]
	var fine_spacing: float = _surface.clipmap_config.spacing_for_level(fine_level)
	var coarse_spacing: float = _surface.clipmap_config.spacing_for_level(coarse_level)
	var fine_half := _surface.clipmap_config.outer_width_for_level(fine_level) * 0.5
	var fine_local_bounds := Vector4(-fine_half, fine_half, -fine_half, fine_half)
	var parity: Vector2i = coarse_state.current_parity
	var coarse_fine_half := fine_half
	var offset := Vector2(float(parity.x) * fine_spacing, float(parity.y) * fine_spacing)
	var coarse_local_bounds := Vector4(
		-coarse_fine_half + offset.x, coarse_fine_half + offset.x,
		-coarse_fine_half + offset.y, coarse_fine_half + offset.y)
	var fine_local_points: Array = _boundary_points_for_mesh(fine_state.instance.mesh, fine_local_bounds)
	var coarse_local_points: Array = _boundary_points_for_mesh(coarse_state.instance.mesh, coarse_local_bounds)
	var closed := true
	var cpu_max_error := 0.0
	var float32_max_error := 0.0
	for side in 4:
		var fine_points: Array = _world_points(fine_state.instance, fine_local_points[side], false)
		var coarse_points: Array = _world_points(coarse_state.instance, coarse_local_points[side], false)
		var fine_points_f32: Array = _world_points(fine_state.instance, fine_local_points[side], true)
		var coarse_points_f32: Array = _world_points(coarse_state.instance, coarse_local_points[side], true)
		if fine_points.size() != coarse_points.size():
			closed = false
		for index in range(mini(fine_points.size(), coarse_points.size())):
			cpu_max_error = maxf(cpu_max_error, fine_points[index].distance_to(coarse_points[index]))
			float32_max_error = maxf(float32_max_error, fine_points_f32[index].distance_to(coarse_points_f32[index]))
	return {
		"closed": closed,
		"cpu_max_error_m": cpu_max_error,
		"float32_max_error_m": float32_max_error,
	}


func _boundary_points_for_mesh(mesh: ArrayMesh, bounds: Vector4) -> Array:
	var cache_key := "%s|%.6f|%.6f|%.6f|%.6f" % [mesh.get_instance_id(), bounds.x, bounds.y, bounds.z, bounds.w]
	if _boundary_local_cache.has(cache_key):
		return _boundary_local_cache[cache_key]
	var result: Array = [[], [], [], []]
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var edge_counts: Dictionary = {}
	for triangle_base in range(0, indices.size(), 3):
		_add_edge_count(edge_counts, indices[triangle_base], indices[triangle_base + 1])
		_add_edge_count(edge_counts, indices[triangle_base + 1], indices[triangle_base + 2])
		_add_edge_count(edge_counts, indices[triangle_base + 2], indices[triangle_base])
	for edge_key in edge_counts:
		if int(edge_counts[edge_key]) != 1:
			continue
		var a: Vector3 = vertices[edge_key.x]
		var b: Vector3 = vertices[edge_key.y]
		for side in 4:
			if _point_on_boundary_side(a, bounds, side) and _point_on_boundary_side(b, bounds, side):
				_append_unique_point(result[side], a)
				_append_unique_point(result[side], b)
	for side in 4:
		if side <= 1:
			result[side].sort_custom(Callable(self, "_sort_by_z"))
		else:
			result[side].sort_custom(Callable(self, "_sort_by_x"))
	_boundary_local_cache[cache_key] = result
	return result


func _add_edge_count(edge_counts: Dictionary, a: int, b: int) -> void:
	var edge := Vector2i(mini(a, b), maxi(a, b))
	edge_counts[edge] = int(edge_counts.get(edge, 0)) + 1


func _point_on_boundary_side(point: Vector3, bounds: Vector4, side: int) -> bool:
	var tolerance := 0.00001
	if side == 0:
		return absf(point.x - bounds.x) <= tolerance
	if side == 1:
		return absf(point.x - bounds.y) <= tolerance
	if side == 2:
		return absf(point.z - bounds.z) <= tolerance
	return absf(point.z - bounds.w) <= tolerance


func _append_unique_point(points: Array, point: Vector3) -> void:
	for existing in points:
		if existing == point:
			return
	points.append(point)


func _sort_by_x(a: Vector3, b: Vector3) -> bool:
	return a.x < b.x


func _sort_by_z(a: Vector3, b: Vector3) -> bool:
	return a.z < b.z


func _world_points(instance: MeshInstance3D, local_points: Array, float32_simulation: bool) -> Array:
	var points: Array = []
	for local_point in local_points:
		points.append(_model_point_f32(instance.global_transform, local_point) if float32_simulation else instance.global_transform * local_point)
	return points


func _model_point_f32(transform: Transform3D, point: Vector3) -> Vector3:
	var x := _f32_add(_f32_add(_f32_add(_f32_mul(transform.basis.x.x, point.x), _f32_mul(transform.basis.y.x, point.y)), _f32_mul(transform.basis.z.x, point.z)), transform.origin.x)
	var y := _f32_add(_f32_add(_f32_add(_f32_mul(transform.basis.x.y, point.x), _f32_mul(transform.basis.y.y, point.y)), _f32_mul(transform.basis.z.y, point.z)), transform.origin.y)
	var z := _f32_add(_f32_add(_f32_add(_f32_mul(transform.basis.x.z, point.x), _f32_mul(transform.basis.y.z, point.y)), _f32_mul(transform.basis.z.z, point.z)), transform.origin.z)
	return Vector3(x, y, z)


func _f32(value: float) -> float:
	var packed := PackedFloat32Array()
	packed.append(value)
	return float(packed[0])


func _f32_mul(a: float, b: float) -> float:
	return _f32(a * b)


func _f32_add(a: float, b: float) -> float:
	return _f32(a + b)


func _print_matrix() -> void:
	print("X2.1 SEAM DIAGNOSTIC MATRIX")
	print("A geometry/world-edge: PASS; samples=%d; links=%d" % [_audit_sample_count, _link_order.size()])
	for key in _link_order:
		print("A %s max_cpu_error_m=%.9f max_float32_error_m=%.9f" % [key, float(_cpu_max_errors[key]), float(_float32_max_errors[key])])
	print("B GPU raster seam: READY; use FLAT GEOMETRY with normal surface material")
	print("C displaced FFT seam: READY; use DISPLACED UNLIT with normal surface material")
	print("D temporal parity: PASS; before/at/after probes=%d" % _temporal_sample_count)
	print("E runtime smoke: PASS; active MeshInstances/transforms/variants remained coherent")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

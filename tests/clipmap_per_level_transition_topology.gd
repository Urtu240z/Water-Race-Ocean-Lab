extends SceneTree
## X1: prueba CPU determinista de origins, trims y cobertura fine/coarse.
## No carga escenas y no conecta ninguna variante al runtime.

const ClipmapConfigScript := preload("res://ocean_v3/rendering/ocean_clipmap_config.gd")
const MeshBuilder := preload("res://ocean_v3/rendering/ocean_clipmap_mesh_builder.gd")

const OWNER_COARSE := 0
const OWNER_TRANSITION := 1
const OWNER_SKIRT := 2
const OWNER_FINE := 2
const MM_PER_BASE_M := 1000
const BASE_SPACING_MM := 250

var _failures := 0


func _initialize() -> void:
	var config = ClipmapConfigScript.new()
	_check(config.is_valid(), "configuración válida")
	_test_parity(config)
	_test_variants(config)
	if _failures == 0:
		print("CLIPMAP_PER_LEVEL_TRANSITION_TOPOLOGY: PASS")
		quit(0)
	else:
		push_error("CLIPMAP_PER_LEVEL_TRANSITION_TOPOLOGY: %d fallos" % _failures)
		quit(1)


func _test_parity(config) -> void:
	var expected_states := {"0:0": true, "1:0": true, "0:1": true, "1:1": true}
	var samples: Array[int] = []
	for coordinate_mm in range(-100000, 100001, 37):
		samples.append(coordinate_mm)
	for coordinate_mm in [100, 900, 3700, -100, -900, -3700, 0, 25000, -25000]:
		samples.append(coordinate_mm)

	for level in range(1, config.level_count):
		var found := {}
		var coarse_spacing_mm := BASE_SPACING_MM * (1 << level)
		var fine_spacing_mm := coarse_spacing_mm / 2
		for x_mm in samples:
			for z_mm in [x_mm, -x_mm, 173, -173, 9999, -9999]:
				var coarse_cell_x := _floor_div(x_mm, coarse_spacing_mm)
				var coarse_cell_z := _floor_div(z_mm, coarse_spacing_mm)
				var fine_cell_x := _floor_div(x_mm, fine_spacing_mm)
				var fine_cell_z := _floor_div(z_mm, fine_spacing_mm)
				_check((coarse_cell_x * coarse_spacing_mm) % coarse_spacing_mm == 0 and
					(coarse_cell_z * coarse_spacing_mm) % coarse_spacing_mm == 0,
					"L%d: origin grueso divisible" % level)
				_check((fine_cell_x * fine_spacing_mm) % fine_spacing_mm == 0 and
					(fine_cell_z * fine_spacing_mm) % fine_spacing_mm == 0,
					"L%d: origin fino divisible" % level)
				var relative_x := fine_cell_x - coarse_cell_x * 2
				var relative_z := fine_cell_z - coarse_cell_z * 2
				_check(relative_x == 0 or relative_x == 1, "L%d: parity X en {0,1}" % level)
				_check(relative_z == 0 or relative_z == 1, "L%d: parity Z en {0,1}" % level)
				found["%d:%d" % [relative_x, relative_z]] = true
		for state in expected_states:
			_check(found.has(state), "L%d: aparece estado %s" % [level, state])
		print("INFO: L%d parity states=%s" % [level, ",".join(found.keys())])


func _test_variants(config) -> void:
	var total_variant_bytes := 0
	var total_skirt_triangles := 0
	var total_skirt_memory_bytes := 0
	# 00: all four fine boundaries coincide with coarse grid lines; the existing
	# stitches are sufficient. 10: only the left/right boundaries need trims;
	# 01: only bottom/top need trims; 11: all four sides need trims. In every
	# state the rectangle decomposition below must prove both no gap and no
	# overlap at the corners.
	for level in range(1, config.level_count):
		var baseline: Dictionary = MeshBuilder.build_level_geometry(config, level)
		var baseline_surface: Dictionary = MeshBuilder.build_level_geometry(config, level, false)
		var baseline_variant: Dictionary = MeshBuilder.build_level_geometry_variant(config, level, 0, 0)
		_check(_surface_prefix_matches(baseline, baseline_surface), "L%d: superficie horizontal idéntica sin skirt" % level)
		_check(_surface_prefix_matches(baseline_variant, baseline_surface), "L%d/00: superficie baseline idéntica sin skirt" % level)
		_check(int(baseline.skirt_triangle_count) == _expected_skirt_triangles(config, level), "L%d: skirt triangle count exacto" % level)
		_check(_validate_skirt_geometry(baseline, config, level), "L%d: skirt cerrado y no degenerado" % level)
		_check(is_equal_approx(baseline.outer_width_m, baseline_variant.outer_width_m), "L%d/00: outer extent idéntico" % level)
		_check(is_equal_approx(baseline.inner_width_m, baseline_variant.inner_width_m), "L%d/00: inner extent idéntico" % level)
		_check(int(baseline.surface_triangle_count) == int(baseline_variant.surface_triangle_count), "L%d/00: surface triangle count idéntico" % level)
		_check(int(baseline.skirt_triangle_count) == int(baseline_variant.skirt_triangle_count), "L%d/00: skirt triangle count idéntico" % level)
		_check(baseline.stitch_inner_positions == baseline_variant.stitch_inner_positions, "L%d/00: stitches surface idénticos" % level)

		for parity_x in 2:
			for parity_z in 2:
				var geometry: Dictionary = baseline_variant if parity_x == 0 and parity_z == 0 else MeshBuilder.build_level_geometry_variant(config, level, parity_x, parity_z)
				var error: String = MeshBuilder.validate_geometry(geometry)
				_check(error.is_empty(), "L%d/%d%d: índices y winding válidos (%s)" % [level, parity_x, parity_z, error])
				_check(_has_no_duplicate_triangles(geometry), "L%d/%d%d: no hay triángulos duplicados" % [level, parity_x, parity_z])
				_check(geometry.triangle_owners.size() == geometry.indices.size() / 3, "L%d/%d%d: owner por triángulo" % [level, parity_x, parity_z])
				_check(int(geometry.skirt_triangle_count) == _expected_skirt_triangles(config, level), "L%d/%d%d: skirt triangle count exacto" % [level, parity_x, parity_z])
				_check(_validate_skirt_geometry(geometry, config, level), "L%d/%d%d: skirt cerrado y no degenerado" % [level, parity_x, parity_z])
				var topology_ok := _validate_pair_topology(config, level, parity_x, parity_z, geometry)
				_check(topology_ok, "L%d/%d%d: edges y cobertura fine/coarse" % [level, parity_x, parity_z])
				var bytes: int = geometry.vertices.size() * 24 + geometry.indices.size() * 4
				total_variant_bytes += bytes
				total_skirt_triangles += int(geometry.skirt_triangle_count)
				total_skirt_memory_bytes += int(geometry.skirt_vertex_count) * 24 + int(geometry.skirt_triangle_count) * 3 * 4
				print("INFO: L%d/%d%d vertices=%d triangles=%d transition_triangles=%d bytes=%d" % [
					level, parity_x, parity_z, geometry.vertices.size(), geometry.indices.size() / 3,
					geometry.transition_triangle_count, bytes])
	print("INFO: L1-L9 x 4 variantes: memoria aproximada vertex+normal+index=%d bytes (%.2f MiB)" % [total_variant_bytes, float(total_variant_bytes) / 1048576.0])
	_check(total_skirt_triangles == 32768, "L1-L9 x 4 variantes: skirt triangles totales exactos")
	_check(total_skirt_memory_bytes == 786432, "L1-L9 x 4 variantes: memoria de skirts exacta")
	print("INFO: L1-L9 x 4 variantes: skirts=%d triangles, memoria adicional=%d bytes (%.2f MiB)" % [total_skirt_triangles, total_skirt_memory_bytes, float(total_skirt_memory_bytes) / 1048576.0])


func _validate_pair_topology(config, level: int, parity_x: int, parity_z: int, coarse_geometry: Dictionary) -> bool:
	var vertices: Array[Vector3] = []
	var indices: Array[int] = []
	var owners: Array[int] = []
	var vertex_lookup := {}
	var fine_geometry: Dictionary = MeshBuilder.build_level_geometry(config, 0)
	var fine_scale := float(1 << (level - 1))
	var fine_spacing: float = config.spacing_for_level(level - 1)
	var fine_offset := Vector2(float(parity_x) * fine_spacing, float(parity_z) * fine_spacing)
	_append_geometry(vertices, indices, owners, vertex_lookup, fine_geometry, fine_scale, fine_offset, OWNER_FINE)
	_append_geometry(vertices, indices, owners, vertex_lookup, coarse_geometry, 1.0, Vector2.ZERO, -1)

	var edges := {}
	var triangles := {}
	for triangle_base in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[triangle_base]]
		var b: Vector3 = vertices[indices[triangle_base + 1]]
		var c: Vector3 = vertices[indices[triangle_base + 2]]
		var area := (b - a).cross(c - a).y
		if area <= 0.00000001:
			return false
		var triangle_key := _sorted_key([_position_key(a), _position_key(b), _position_key(c)])
		if triangles.has(triangle_key):
			return false
		triangles[triangle_key] = true
		_add_edge(edges, a, b)
		_add_edge(edges, b, c)
		_add_edge(edges, c, a)

	var outer_half: float = config.outer_width_for_level(level) * 0.5
	for edge_key in edges:
		var count: int = edges[edge_key]
		if count > 2:
			return false
		if count == 1:
			var edge_points: Array = edge_key.split("|")
			if not (_position_on_outer(edge_points[0], outer_half) and _position_on_outer(edge_points[1], outer_half)):
				return false
		if count < 1:
			return false

	var coverage_ok := _validate_coverage(config, level, parity_x, parity_z, vertices, indices, owners)
	return coverage_ok


func _expected_skirt_triangles(config, level: int) -> int:
	return config.cells_per_side * 8 if level < config.level_count - 1 else 0


func _surface_prefix_matches(with_skirt: Dictionary, surface: Dictionary) -> bool:
	if int(with_skirt.surface_vertex_count) != surface.vertices.size():
		return false
	if int(with_skirt.surface_triangle_count) * 3 != surface.indices.size():
		return false
	for index in surface.vertices.size():
		if with_skirt.vertices[index] != surface.vertices[index] or with_skirt.normals[index] != surface.normals[index]:
			return false
	for index in surface.indices.size():
		if with_skirt.indices[index] != surface.indices[index]:
			return false
	return true


func _validate_skirt_geometry(geometry: Dictionary, config, level: int) -> bool:
	var vertices: PackedVector3Array = geometry.vertices
	var indices: PackedInt32Array = geometry.indices
	var owners: PackedInt32Array = geometry.triangle_owners
	var expected_triangles := _expected_skirt_triangles(config, level)
	if int(geometry.skirt_triangle_count) != expected_triangles:
		return false
	if expected_triangles == 0:
		return geometry.skirt_top_loop.is_empty() and int(geometry.skirt_vertex_count) == 0
	var loop: PackedVector3Array = geometry.skirt_top_loop
	var expected_loop_size: int = int(config.cells_per_side) * 4
	if loop.size() != expected_loop_size:
		return false
	var vertex_keys := {}
	for vertex in vertices:
		vertex_keys[_position_3d_key(vertex)] = true
	var loop_keys := {}
	for top_position in loop:
		var top_key := _position_key(top_position)
		if loop_keys.has(top_key):
			return false
		loop_keys[top_key] = true
		var bottom_key := _position_3d_key(Vector3(top_position.x, -float(geometry.skirt_depth_m), top_position.z))
		if not vertex_keys.has(bottom_key):
			return false
	var top_edges := {}
	for triangle_index in owners.size():
		if owners[triangle_index] != OWNER_SKIRT:
			continue
		var base := triangle_index * 3
		var a: Vector3 = vertices[indices[base]]
		var b: Vector3 = vertices[indices[base + 1]]
		var c: Vector3 = vertices[indices[base + 2]]
		if (b - a).cross(c - a).length() <= 0.00000001:
			return false
		var top_vertices: Array[Vector3] = []
		for vertex in [a, b, c]:
			if is_equal_approx(vertex.y, 0.0):
				top_vertices.append(vertex)
			elif not is_equal_approx(vertex.y, -float(geometry.skirt_depth_m)):
				return false
		if top_vertices.is_empty() or top_vertices.size() > 2:
			return false
		if top_vertices.size() == 2:
			var edge_key_a := _position_key(top_vertices[0])
			var edge_key_b := _position_key(top_vertices[1])
			var edge_key := "%s|%s" % [edge_key_a, edge_key_b] if edge_key_a < edge_key_b else "%s|%s" % [edge_key_b, edge_key_a]
			top_edges[edge_key] = int(top_edges.get(edge_key, 0)) + 1
	for index in loop.size():
		var next := (index + 1) % loop.size()
		var key_a := _position_key(loop[index])
		var key_b := _position_key(loop[next])
		var edge_key := "%s|%s" % [key_a, key_b] if key_a < key_b else "%s|%s" % [key_b, key_a]
		if int(top_edges.get(edge_key, 0)) != 1:
			return false
	return true


func _validate_coverage(config, level: int, parity_x: int, parity_z: int, vertices: Array[Vector3], indices: Array[int], owners: Array[int]) -> bool:
	var fine_spacing: float = config.spacing_for_level(level - 1)
	var coarse_spacing: float = config.spacing_for_level(level)
	var outer_half: float = config.outer_width_for_level(level) * 0.5
	var fine_half: float = config.outer_width_for_level(level - 1) * 0.5
	var fine_min := Vector2(-fine_half + parity_x * fine_spacing, -fine_half + parity_z * fine_spacing)
	var fine_max := fine_min + Vector2(fine_half * 2.0, fine_half * 2.0)
	var atomic_count: int = config.cells_per_side * 2
	var cell_area := fine_spacing * fine_spacing
	var total := PackedFloat32Array()
	var fine_owned := PackedFloat32Array()
	var coarse_owned := PackedFloat32Array()
	var transition_owned := PackedFloat32Array()
	total.resize(atomic_count * atomic_count)
	fine_owned.resize(total.size())
	coarse_owned.resize(total.size())
	transition_owned.resize(total.size())

	for triangle_base in range(0, indices.size(), 3):
		var triangle: Array[Vector2] = [
			Vector2(vertices[indices[triangle_base]].x, vertices[indices[triangle_base]].z),
			Vector2(vertices[indices[triangle_base + 1]].x, vertices[indices[triangle_base + 1]].z),
			Vector2(vertices[indices[triangle_base + 2]].x, vertices[indices[triangle_base + 2]].z),
		]
		var min_x := minf(triangle[0].x, minf(triangle[1].x, triangle[2].x))
		var max_x := maxf(triangle[0].x, maxf(triangle[1].x, triangle[2].x))
		var min_z := minf(triangle[0].y, minf(triangle[1].y, triangle[2].y))
		var max_z := maxf(triangle[0].y, maxf(triangle[1].y, triangle[2].y))
		var ix0 := clampi(floori((min_x + outer_half) / fine_spacing), 0, atomic_count - 1)
		var ix1 := clampi(ceili((max_x + outer_half) / fine_spacing), 1, atomic_count)
		var iz0 := clampi(floori((min_z + outer_half) / fine_spacing), 0, atomic_count - 1)
		var iz1 := clampi(ceili((max_z + outer_half) / fine_spacing), 1, atomic_count)
		for iz in range(iz0, iz1):
			for ix in range(ix0, ix1):
				var cell_min := Vector2(-outer_half + ix * fine_spacing, -outer_half + iz * fine_spacing)
				var cell_max := cell_min + Vector2(fine_spacing, fine_spacing)
				var clipped := _clip_triangle_to_rect(triangle, cell_min, cell_max)
				if clipped.size() < 3:
					continue
				var area := absf(_polygon_area(clipped))
				var slot: int = iz * atomic_count + ix
				total[slot] += area
				if owners[triangle_base / 3] == OWNER_FINE:
					fine_owned[slot] += area
				elif owners[triangle_base / 3] == OWNER_TRANSITION:
					transition_owned[slot] += area
				else:
					coarse_owned[slot] += area

	for iz in atomic_count:
		for ix in atomic_count:
			var slot: int = iz * atomic_count + ix
			var covered := total[slot]
			if absf(covered - cell_area) > 0.00001:
				return false
			var center := Vector2(-outer_half + (ix + 0.5) * fine_spacing, -outer_half + (iz + 0.5) * fine_spacing)
			var expected_fine := center.x >= fine_min.x and center.x < fine_max.x and center.y >= fine_min.y and center.y < fine_max.y
			var fine_area: float = fine_owned[slot]
			var non_fine_area: float = coarse_owned[slot] + transition_owned[slot]
			if expected_fine:
				if absf(fine_area - cell_area) > 0.00001 or non_fine_area > 0.00001:
					return false
			else:
				if fine_area > 0.00001 or absf(non_fine_area - cell_area) > 0.00001:
					return false
	return true


func _append_geometry(vertices: Array[Vector3], indices: Array[int], owners: Array[int], vertex_lookup: Dictionary,
		geometry: Dictionary, scale: float, offset: Vector2, owner_override: int) -> void:
	var source_vertices: PackedVector3Array = geometry.vertices
	var source_indices: PackedInt32Array = geometry.indices
	var source_owners: PackedInt32Array = geometry.triangle_owners if geometry.has("triangle_owners") else PackedInt32Array()
	for triangle_base in range(0, source_indices.size(), 3):
		if not source_owners.is_empty() and source_owners[triangle_base / 3] == OWNER_SKIRT:
			continue
		for local_index in 3:
			var source_position: Vector3 = source_vertices[source_indices[triangle_base + local_index]]
			var position := Vector3(source_position.x * scale + offset.x, 0.0, source_position.z * scale + offset.y)
			var key := _position_key(position)
			if not vertex_lookup.has(key):
				vertex_lookup[key] = vertices.size()
				vertices.append(position)
			indices.append(vertex_lookup[key])
		owners.append(owner_override if owner_override >= 0 else int(source_owners[triangle_base / 3]))


func _add_edge(edges: Dictionary, a: Vector3, b: Vector3) -> void:
	var key_a := _position_key(a)
	var key_b := _position_key(b)
	var edge_key := "%s|%s" % [key_a, key_b] if key_a < key_b else "%s|%s" % [key_b, key_a]
	edges[edge_key] = int(edges.get(edge_key, 0)) + 1


func _has_no_duplicate_triangles(geometry: Dictionary) -> bool:
	var vertices: PackedVector3Array = geometry.vertices
	var indices: PackedInt32Array = geometry.indices
	var owners: PackedInt32Array = geometry.triangle_owners if geometry.has("triangle_owners") else PackedInt32Array()
	var seen := {}
	for triangle_base in range(0, indices.size(), 3):
		if not owners.is_empty() and owners[triangle_base / 3] == OWNER_SKIRT:
			continue
		var key := _sorted_key([
			_position_key(vertices[indices[triangle_base]]),
			_position_key(vertices[indices[triangle_base + 1]]),
			_position_key(vertices[indices[triangle_base + 2]]),
		])
		if seen.has(key):
			return false
		seen[key] = true
	return true


func _position_on_outer(key: String, outer_half: float) -> bool:
	var parts := key.split(":")
	var x := float(int(parts[0])) / 1000.0
	var z := float(int(parts[1])) / 1000.0
	return is_equal_approx(absf(x), outer_half) or is_equal_approx(absf(z), outer_half)


func _position_key(position: Vector3) -> String:
	return "%d:%d" % [roundi(position.x * 1000.0), roundi(position.z * 1000.0)]


func _position_3d_key(position: Vector3) -> String:
	return "%d:%d:%d" % [roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0)]


func _sorted_key(values: Array) -> String:
	values.sort()
	return "|".join(values)


func _clip_triangle_to_rect(triangle: Array[Vector2], rect_min: Vector2, rect_max: Vector2) -> Array[Vector2]:
	var polygon: Array[Vector2] = triangle
	polygon = _clip_polygon(polygon, 0, rect_min.x, true)
	polygon = _clip_polygon(polygon, 0, rect_max.x, false)
	polygon = _clip_polygon(polygon, 1, rect_min.y, true)
	polygon = _clip_polygon(polygon, 1, rect_max.y, false)
	return polygon


func _clip_polygon(polygon: Array[Vector2], axis: int, bound: float, keep_greater: bool) -> Array[Vector2]:
	if polygon.is_empty():
		return []
	var result: Array[Vector2] = []
	var previous: Vector2 = polygon[polygon.size() - 1]
	var previous_inside := _inside_half_plane(previous, axis, bound, keep_greater)
	for current in polygon:
		var current_inside := _inside_half_plane(current, axis, bound, keep_greater)
		if current_inside != previous_inside:
			var denominator := (current[axis] - previous[axis])
			if absf(denominator) > 0.00000001:
				var t := (bound - previous[axis]) / denominator
				result.append(previous.lerp(current, t))
		if current_inside:
			result.append(current)
		previous = current
		previous_inside = current_inside
	return result


func _inside_half_plane(point: Vector2, axis: int, bound: float, keep_greater: bool) -> bool:
	return point[axis] >= bound - 0.00000001 if keep_greater else point[axis] <= bound + 0.00000001


func _polygon_area(polygon: Array[Vector2]) -> float:
	var area := 0.0
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		area += polygon[index].x * polygon[next].y - polygon[next].x * polygon[index].y
	return area * 0.5


func _floor_div(numerator: int, denominator: int) -> int:
	return floori(float(numerator) / float(denominator))


func _check(condition: bool, label: String) -> void:
	if condition:
		return
	else:
		_failures += 1
		push_error("FAIL: " + label)

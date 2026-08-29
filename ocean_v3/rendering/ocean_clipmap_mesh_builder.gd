class_name OceanClipmapMeshBuilder
extends RefCounted
## Genera L0 y los anillos con stitches 2:1; nunca se llama por frame.

const VARIANT_OWNER_COARSE := 0
const VARIANT_OWNER_TRANSITION := 1

static func build_level_geometry(config: Resource, level: int) -> Dictionary:
	assert(config.is_valid())
	assert(level >= 0 and level < config.level_count)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_indices := {}
	var stitch_inner_positions := PackedVector3Array()
	var half_cells := int(float(config.cells_per_side) * 0.5)
	var spacing: float = config.spacing_for_level(level)

	if level == 0:
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing)
	else:
		var inner_cells := int(float(half_cells) * 0.5)
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				if x_cell >= -inner_cells and x_cell < inner_cells and z_cell >= -inner_cells and z_cell < inner_cells:
					continue
				if z_cell == -inner_cells - 1 and x_cell >= -inner_cells and x_cell < inner_cells:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, stitch_inner_positions, x_cell, -inner_cells, -1, spacing)
				elif z_cell == inner_cells and x_cell >= -inner_cells and x_cell < inner_cells:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, stitch_inner_positions, x_cell, inner_cells, 1, spacing)
				elif x_cell == -inner_cells - 1 and z_cell >= -inner_cells and z_cell < inner_cells:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, stitch_inner_positions, -inner_cells, z_cell, -1, spacing)
				elif x_cell == inner_cells and z_cell >= -inner_cells and z_cell < inner_cells:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, stitch_inner_positions, inner_cells, z_cell, 1, spacing)
				else:
					_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing)

	return {
		"vertices": vertices,
		"normals": normals,
		"indices": indices,
		"stitch_inner_positions": stitch_inner_positions,
		"spacing_m": spacing,
		"outer_width_m": config.outer_width_for_level(level),
		"inner_width_m": config.inner_width_for_level(level),
	}


## X1: construye una variante offline para un origen fino desfasado media celda.
## El estado 00 delega en build_level_geometry() para conservar exactamente el
## baseline. Los otros estados recortan cada celda gruesa contra el cuadrado
## fino; no se asume que mover simplemente el hueco cierre la unión.
static func build_level_geometry_variant(config: Resource, level: int, parity_x: int, parity_z: int) -> Dictionary:
	assert(config.is_valid())
	assert(level > 0 and level < config.level_count)
	assert(parity_x == 0 or parity_x == 1)
	assert(parity_z == 0 or parity_z == 1)
	if parity_x == 0 and parity_z == 0:
		var baseline := build_level_geometry(config, level)
		baseline["parity_x"] = 0
		baseline["parity_z"] = 0
		baseline["fine_origin_offset_m"] = Vector2.ZERO
		baseline["triangle_owners"] = _baseline_triangle_owners(baseline, config, level)
		baseline["transition_triangle_count"] = _count_owner(baseline["triangle_owners"], VARIANT_OWNER_TRANSITION)
		return baseline

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var owners := PackedInt32Array()
	var vertex_indices := {}
	var half_cells := int(float(config.cells_per_side) * 0.5)
	var coarse_spacing: float = config.spacing_for_level(level)
	var fine_spacing := coarse_spacing * 0.5
	var fine_half_extent: float = config.outer_width_for_level(level - 1) * 0.5
	var fine_offset := Vector2(float(parity_x) * fine_spacing, float(parity_z) * fine_spacing)
	var fine_min := Vector2(-fine_half_extent, -fine_half_extent) + fine_offset
	var fine_max := Vector2(fine_half_extent, fine_half_extent) + fine_offset

	for z_cell in range(-half_cells, half_cells):
		for x_cell in range(-half_cells, half_cells):
			var x0 := float(x_cell) * coarse_spacing
			var x1 := float(x_cell + 1) * coarse_spacing
			var z0 := float(z_cell) * coarse_spacing
			var z1 := float(z_cell + 1) * coarse_spacing
			var rect_min := Vector2(x0, z0)
			var rect_max := Vector2(x1, z1)
			if not _rectangles_overlap(rect_min, rect_max, fine_min, fine_max):
				_add_variant_outer_cell(vertices, normals, indices, owners, vertex_indices,
					x0, x1, z0, z1, fine_min, fine_max, coarse_spacing, fine_spacing)
				continue
			if _rectangle_inside(rect_min, rect_max, fine_min, fine_max):
				continue
			_add_variant_outside_components(vertices, normals, indices, owners, vertex_indices,
				 x0, x1, z0, z1, fine_min, fine_max, coarse_spacing, fine_spacing)

	return {
		"vertices": vertices,
		"normals": normals,
		"indices": indices,
		"stitch_inner_positions": _variant_transition_positions(vertices, indices, owners),
		"triangle_owners": owners,
		"transition_triangle_count": _count_owner(owners, VARIANT_OWNER_TRANSITION),
		"spacing_m": coarse_spacing,
		"outer_width_m": config.outer_width_for_level(level),
		"inner_width_m": config.inner_width_for_level(level),
		"parity_x": parity_x,
		"parity_z": parity_z,
		"fine_origin_offset_m": fine_offset,
	}


static func _add_variant_outer_cell(vertices: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, owners: PackedInt32Array, vertex_indices: Dictionary,
		x0: float, x1: float, z0: float, z1: float, fine_min: Vector2, fine_max: Vector2,
		coarse_spacing: float, fine_spacing: float) -> void:
	# A boundary corner in a neighboring cell can split one edge of this full
	# exterior cell. Split only that edge: splitting the whole cell would create
	# a new T-junction on its opposite, unrelated edge.
	var vertical_overlap := minf(z1, fine_max.y) - maxf(z0, fine_min.y)
	if is_equal_approx(x1, fine_min.x) and vertical_overlap > 0.000001:
		_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
			x0, x1, z0, z1, 1, _fine_edge_points(z0, z1, fine_min.y, fine_max.y, fine_spacing), VARIANT_OWNER_COARSE)
		return
	if is_equal_approx(x0, fine_max.x) and vertical_overlap > 0.000001:
		_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
			x0, x1, z0, z1, 0, _fine_edge_points(z0, z1, fine_min.y, fine_max.y, fine_spacing), VARIANT_OWNER_COARSE)
		return
	var horizontal_overlap := minf(x1, fine_max.x) - maxf(x0, fine_min.x)
	if is_equal_approx(z1, fine_min.y) and horizontal_overlap > 0.000001:
		_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
			x0, x1, z0, z1, 2, _fine_edge_points(x0, x1, fine_min.x, fine_max.x, fine_spacing), VARIANT_OWNER_COARSE)
		return
	if is_equal_approx(z0, fine_max.y) and horizontal_overlap > 0.000001:
		_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
			x0, x1, z0, z1, 3, _fine_edge_points(x0, x1, fine_min.x, fine_max.x, fine_spacing), VARIANT_OWNER_COARSE)
		return
	# When a fine corner falls halfway through a coarse cell, its transition
	# endpoint also subdivides the immediately neighboring outer edge. Mirror
	# that endpoint here so the shared coarse edge has no T-junction.
	var bottom_corner_edge := float(floori(fine_min.y / coarse_spacing)) * coarse_spacing
	if is_equal_approx(z1, bottom_corner_edge) and z1 < fine_min.y:
		var bottom_corner_points := _fine_corner_edge_points(x0, x1, fine_min.x, fine_max.x)
		if bottom_corner_points.size() > 2:
			_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, z0, z1, 2, bottom_corner_points, VARIANT_OWNER_COARSE)
			return
	var top_corner_edge := float(ceili(fine_max.y / coarse_spacing)) * coarse_spacing
	if is_equal_approx(z0, top_corner_edge) and z0 > fine_max.y:
		var top_corner_points := _fine_corner_edge_points(x0, x1, fine_min.x, fine_max.x)
		if top_corner_points.size() > 2:
			_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, z0, z1, 3, top_corner_points, VARIANT_OWNER_COARSE)
			return
	var left_corner_edge := float(floori(fine_min.x / coarse_spacing)) * coarse_spacing
	if is_equal_approx(x1, left_corner_edge) and x1 < fine_min.x:
		var left_corner_points := _fine_corner_edge_points(z0, z1, fine_min.y, fine_max.y)
		if left_corner_points.size() > 2:
			_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, z0, z1, 1, left_corner_points, VARIANT_OWNER_COARSE)
			return
	var right_corner_edge := float(ceili(fine_max.x / coarse_spacing)) * coarse_spacing
	if is_equal_approx(x0, right_corner_edge) and x0 > fine_max.x:
		var right_corner_points := _fine_corner_edge_points(z0, z1, fine_min.y, fine_max.y)
		if right_corner_points.size() > 2:
			_add_variant_edge_split_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, z0, z1, 0, right_corner_points, VARIANT_OWNER_COARSE)
			return
	_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
		x0, x1, z0, z1, VARIANT_OWNER_COARSE, -1, coarse_spacing, fine_spacing)


static func _fine_edge_points(edge_min: float, edge_max: float, fine_min: float, fine_max: float, fine_spacing: float) -> Array[float]:
	var points: Array[float] = [edge_min, edge_max]
	var fine_steps := roundi((fine_max - fine_min) / fine_spacing)
	for step in range(-1, fine_steps + 2):
		var candidate := fine_min + float(step) * fine_spacing
		if candidate > edge_min + 0.000001 and candidate < edge_max - 0.000001 and candidate >= fine_min - 0.000001 and candidate <= fine_max + 0.000001:
			points.append(candidate)
	points.sort()
	return points


static func _fine_corner_edge_points(edge_min: float, edge_max: float, fine_min: float, fine_max: float) -> Array[float]:
	var points: Array[float] = [edge_min, edge_max]
	for candidate in [fine_min, fine_max]:
		if candidate > edge_min + 0.000001 and candidate < edge_max - 0.000001:
			points.append(candidate)
	points.sort()
	return points


static func _add_variant_edge_split_rect(vertices: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, owners: PackedInt32Array, vertex_indices: Dictionary,
		x0: float, x1: float, z0: float, z1: float, interface_side: int,
		points: Array[float], owner: int) -> void:
	if points.size() < 3:
		_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
			x0, x1, z0, z1, owner, -1, x1 - x0, z1 - z0)
		return
	var inner: Array[Vector3] = []
	var outer_start := Vector3.ZERO
	var outer_end := Vector3.ZERO
	if interface_side == 0:
		for point in points:
			inner.append(Vector3(x0, 0.0, point))
		outer_start = Vector3(x1, 0.0, z0)
		outer_end = Vector3(x1, 0.0, z1)
	elif interface_side == 1:
		for point in points:
			inner.append(Vector3(x1, 0.0, point))
		outer_start = Vector3(x0, 0.0, z0)
		outer_end = Vector3(x0, 0.0, z1)
	elif interface_side == 2:
		for point in points:
			inner.append(Vector3(point, 0.0, z1))
		outer_start = Vector3(x0, 0.0, z0)
		outer_end = Vector3(x1, 0.0, z0)
	else:
		for point in points:
			inner.append(Vector3(point, 0.0, z0))
		outer_start = Vector3(x0, 0.0, z1)
		outer_end = Vector3(x1, 0.0, z1)
	var outer_a := _vertex(vertices, normals, vertex_indices, outer_start)
	var outer_b := _vertex(vertices, normals, vertex_indices, outer_end)
	var inner_indices: Array[int] = []
	for point in inner:
		inner_indices.append(_vertex(vertices, normals, vertex_indices, point))
	_add_variant_triangle(vertices, indices, owners, inner_indices[0], outer_a, inner_indices[1], owner)
	for index in range(1, inner_indices.size() - 2):
		_add_variant_triangle(vertices, indices, owners, inner_indices[index], outer_a, inner_indices[index + 1], owner)
	_add_variant_triangle(vertices, indices, owners, inner_indices[inner_indices.size() - 2], outer_a, outer_b, owner)
	_add_variant_triangle(vertices, indices, owners, inner_indices[inner_indices.size() - 2], outer_b, inner_indices[inner_indices.size() - 1], owner)

static func _add_variant_outside_components(vertices: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, owners: PackedInt32Array, vertex_indices: Dictionary,
		x0: float, x1: float, z0: float, z1: float, fine_min: Vector2, fine_max: Vector2,
		coarse_spacing: float, fine_spacing: float) -> void:
	# R \ F is partitioned into left/right/bottom/top rectangles. This keeps
	# corner cells disjoint while allowing only the interface segment to use the
	# denser fine boundary; no global half-cell grid is introduced.
	if x0 < fine_min.x:
		var left_x1 := minf(x1, fine_min.x)
		if left_x1 > x0:
			_add_variant_side_component(vertices, normals, indices, owners, vertex_indices,
				x0, left_x1, z0, z1, fine_min.y, fine_max.y, 1, coarse_spacing, fine_spacing)
	if x1 > fine_max.x:
		var right_x0 := maxf(x0, fine_max.x)
		if x1 > right_x0:
			_add_variant_side_component(vertices, normals, indices, owners, vertex_indices,
				right_x0, x1, z0, z1, fine_min.y, fine_max.y, 0, coarse_spacing, fine_spacing)

	var middle_x0 := maxf(x0, fine_min.x)
	var middle_x1 := minf(x1, fine_max.x)
	if middle_x1 > middle_x0:
		if z0 < fine_min.y:
			var bottom_z1 := minf(z1, fine_min.y)
			if bottom_z1 > z0:
				_add_variant_side_component(vertices, normals, indices, owners, vertex_indices,
					middle_x0, middle_x1, z0, bottom_z1, fine_min.x, fine_max.x, 2,
					coarse_spacing, fine_spacing)
		if z1 > fine_max.y:
			var top_z0 := maxf(z0, fine_max.y)
			if z1 > top_z0:
				_add_variant_side_component(vertices, normals, indices, owners, vertex_indices,
					middle_x0, middle_x1, top_z0, z1, fine_min.x, fine_max.x, 3,
					coarse_spacing, fine_spacing)


static func _add_variant_side_component(vertices: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, owners: PackedInt32Array, vertex_indices: Dictionary,
		x0: float, x1: float, z0: float, z1: float, interface_min: float,
		interface_max: float, interface_side: int, coarse_spacing: float, fine_spacing: float) -> void:
	# interface_side: 0 left, 1 right, 2 top, 3 bottom. Split at the fine
	# square's corners so the transition edge is subdivided only where needed.
	if interface_side <= 1:
		var split_min := maxf(z0, interface_min)
		var split_max := minf(z1, interface_max)
		if split_min > z0:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, z0, split_min, VARIANT_OWNER_COARSE, -1, coarse_spacing, fine_spacing)
		if split_max > split_min:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, split_min, split_max, VARIANT_OWNER_TRANSITION, interface_side,
				coarse_spacing, fine_spacing)
		if z1 > split_max:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				x0, x1, split_max, z1, VARIANT_OWNER_COARSE, -1, coarse_spacing, fine_spacing)
	else:
		var split_min := maxf(x0, interface_min)
		var split_max := minf(x1, interface_max)
		if split_min > x0:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				x0, split_min, z0, z1, VARIANT_OWNER_COARSE, -1, coarse_spacing, fine_spacing)
		if split_max > split_min:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				split_min, split_max, z0, z1, VARIANT_OWNER_TRANSITION, interface_side,
				coarse_spacing, fine_spacing)
		if x1 > split_max:
			_add_variant_rect(vertices, normals, indices, owners, vertex_indices,
				split_max, x1, z0, z1, VARIANT_OWNER_COARSE, -1, coarse_spacing, fine_spacing)


static func _add_variant_rect(vertices: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, owners: PackedInt32Array, vertex_indices: Dictionary,
		x0: float, x1: float, z0: float, z1: float, owner: int, interface_side: int,
		coarse_spacing: float, fine_spacing: float) -> void:
	if x1 <= x0 or z1 <= z0:
		return
	if interface_side < 0:
		var a := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z0))
		var b := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z0))
		var c := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z1))
		var d := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z1))
		_add_variant_triangle(vertices, indices, owners, a, c, b, owner)
		_add_variant_triangle(vertices, indices, owners, a, d, c, owner)
		return

	var interface_length := (z1 - z0) if interface_side <= 1 else (x1 - x0)
	var segment_count := roundi(interface_length / fine_spacing)
	assert(segment_count >= 1 and segment_count <= 2)
	if segment_count == 1:
		var a1: int
		var b1: int
		var c1: int
		var d1: int
		if interface_side == 0:
			a1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z0))
			b1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z1))
			c1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z0))
			d1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z1))
		elif interface_side == 1:
			a1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z0))
			b1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z1))
			c1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z0))
			d1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z1))
		elif interface_side == 2:
			a1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z1))
			b1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z1))
			c1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z0))
			d1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z0))
		else:
			a1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z0))
			b1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z0))
			c1 = _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, z1))
			d1 = _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, z1))
		_add_variant_triangle(vertices, indices, owners, a1, c1, b1, owner)
		_add_variant_triangle(vertices, indices, owners, b1, c1, d1, owner)
		return

	# Two fine segments meet one coarse edge. This is the existing 2:1 stitch
	# pattern, generalized to any of the four oriented interface sides.
	var a := Vector3.ZERO
	var middle := Vector3.ZERO
	var b := Vector3.ZERO
	var c := Vector3.ZERO
	var d := Vector3.ZERO
	if interface_side == 0:
		a = Vector3(x0, 0.0, z0)
		middle = Vector3(x0, 0.0, (z0 + z1) * 0.5)
		b = Vector3(x0, 0.0, z1)
		c = Vector3(x1, 0.0, z0)
		d = Vector3(x1, 0.0, z1)
	elif interface_side == 1:
		a = Vector3(x1, 0.0, z0)
		middle = Vector3(x1, 0.0, (z0 + z1) * 0.5)
		b = Vector3(x1, 0.0, z1)
		c = Vector3(x0, 0.0, z0)
		d = Vector3(x0, 0.0, z1)
	elif interface_side == 2:
		a = Vector3(x0, 0.0, z1)
		middle = Vector3((x0 + x1) * 0.5, 0.0, z1)
		b = Vector3(x1, 0.0, z1)
		c = Vector3(x0, 0.0, z0)
		d = Vector3(x1, 0.0, z0)
	else:
		a = Vector3(x0, 0.0, z0)
		middle = Vector3((x0 + x1) * 0.5, 0.0, z0)
		b = Vector3(x1, 0.0, z0)
		c = Vector3(x0, 0.0, z1)
		d = Vector3(x1, 0.0, z1)
	var ai := _vertex(vertices, normals, vertex_indices, a)
	var mi := _vertex(vertices, normals, vertex_indices, middle)
	var bi := _vertex(vertices, normals, vertex_indices, b)
	var ci := _vertex(vertices, normals, vertex_indices, c)
	var di := _vertex(vertices, normals, vertex_indices, d)
	_add_variant_triangle(vertices, indices, owners, ai, ci, mi, owner)
	_add_variant_triangle(vertices, indices, owners, mi, ci, di, owner)
	_add_variant_triangle(vertices, indices, owners, mi, di, bi, owner)


static func _add_variant_triangle(vertices: PackedVector3Array, indices: PackedInt32Array,
		owners: PackedInt32Array, a: int, b: int, c: int, owner: int) -> void:
	_add_triangle(vertices, indices, a, b, c)
	owners.append(owner)


static func _rectangles_overlap(a_min: Vector2, a_max: Vector2, b_min: Vector2, b_max: Vector2) -> bool:
	return a_min.x < b_max.x and a_max.x > b_min.x and a_min.y < b_max.y and a_max.y > b_min.y


static func _rectangle_inside(rect_min: Vector2, rect_max: Vector2, square_min: Vector2, square_max: Vector2) -> bool:
	return rect_min.x >= square_min.x and rect_max.x <= square_max.x and rect_min.y >= square_min.y and rect_max.y <= square_max.y


static func _baseline_triangle_owners(geometry: Dictionary, config: Resource, level: int) -> PackedInt32Array:
	var owners := PackedInt32Array()
	var inner_half: float = config.inner_width_for_level(level) * 0.5
	var spacing: float = config.spacing_for_level(level)
	var vertices: PackedVector3Array = geometry.vertices
	var indices: PackedInt32Array = geometry.indices
	for triangle_base in range(0, indices.size(), 3):
		var centroid := (vertices[indices[triangle_base]] + vertices[indices[triangle_base + 1]] + vertices[indices[triangle_base + 2]]) / 3.0
		var horizontal: bool = absf(centroid.x) < inner_half and absf(centroid.z) >= inner_half and absf(centroid.z) < inner_half + spacing
		var vertical: bool = absf(centroid.z) < inner_half and absf(centroid.x) >= inner_half and absf(centroid.x) < inner_half + spacing
		owners.append(VARIANT_OWNER_TRANSITION if horizontal or vertical else VARIANT_OWNER_COARSE)
	return owners


static func _count_owner(owners: PackedInt32Array, owner: int) -> int:
	var count := 0
	for value in owners:
		if value == owner:
			count += 1
	return count


static func _variant_transition_positions(vertices: PackedVector3Array, indices: PackedInt32Array, owners: PackedInt32Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for triangle_base in range(0, owners.size()):
		if owners[triangle_base] != VARIANT_OWNER_TRANSITION:
			continue
		var index_base := triangle_base * 3
		result.append(vertices[indices[index_base]])
		result.append(vertices[indices[index_base + 1]])
		result.append(vertices[indices[index_base + 2]])
	return result


static func create_mesh(geometry: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = geometry.vertices
	arrays[Mesh.ARRAY_NORMAL] = geometry.normals
	arrays[Mesh.ARRAY_INDEX] = geometry.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func validate_geometry(geometry: Dictionary) -> String:
	var vertices: PackedVector3Array = geometry.vertices
	var indices: PackedInt32Array = geometry.indices
	if indices.size() % 3 != 0:
		return "El índice no forma triángulos completos."
	for index in indices:
		if index < 0 or index >= vertices.size():
			return "Índice fuera de rango."
	for triangle_base in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[triangle_base]]
		var b: Vector3 = vertices[indices[triangle_base + 1]]
		var c: Vector3 = vertices[indices[triangle_base + 2]]
		var signed_area: float = (b - a).cross(c - a).y
		if signed_area <= 0.00000001:
			return "Triángulo degenerado o winding invertido."
	return ""


static func outer_boundary_positions(config: Resource, level: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	var half_cells := int(float(config.cells_per_side) * 0.5)
	var spacing: float = config.spacing_for_level(level)
	for cell in range(-half_cells, half_cells + 1):
		result.append(Vector3(float(cell) * spacing, 0.0, -float(half_cells) * spacing))
		result.append(Vector3(float(cell) * spacing, 0.0, float(half_cells) * spacing))
		if cell > -half_cells and cell < half_cells:
			result.append(Vector3(-float(half_cells) * spacing, 0.0, float(cell) * spacing))
			result.append(Vector3(float(half_cells) * spacing, 0.0, float(cell) * spacing))
	return result


static func _add_regular_cell(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, x_cell: int, z_cell: int, spacing: float) -> void:
	var a := _vertex(vertices, normals, vertex_indices, Vector3(float(x_cell) * spacing, 0.0, float(z_cell) * spacing))
	var b := _vertex(vertices, normals, vertex_indices, Vector3(float(x_cell + 1) * spacing, 0.0, float(z_cell) * spacing))
	var c := _vertex(vertices, normals, vertex_indices, Vector3(float(x_cell + 1) * spacing, 0.0, float(z_cell + 1) * spacing))
	var d := _vertex(vertices, normals, vertex_indices, Vector3(float(x_cell) * spacing, 0.0, float(z_cell + 1) * spacing))
	_add_triangle(vertices, indices, a, c, b)
	_add_triangle(vertices, indices, a, d, c)


static func _add_horizontal_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, stitch_positions: PackedVector3Array, x_cell: int, inner_z_cell: int, outer_sign: int, spacing: float) -> void:
	var x0 := float(x_cell) * spacing
	var x1 := float(x_cell + 1) * spacing
	var inner_z := float(inner_z_cell) * spacing
	var outer_z := inner_z + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, inner_z))
	var middle := _vertex(vertices, normals, vertex_indices, Vector3((x0 + x1) * 0.5, 0.0, inner_z))
	var b := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, inner_z))
	var c := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, outer_z))
	var d := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, outer_z))
	stitch_positions.append(vertices[a])
	stitch_positions.append(vertices[middle])
	stitch_positions.append(vertices[b])
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_vertical_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, stitch_positions: PackedVector3Array, inner_x_cell: int, z_cell: int, outer_sign: int, spacing: float) -> void:
	var z0 := float(z_cell) * spacing
	var z1 := float(z_cell + 1) * spacing
	var inner_x := float(inner_x_cell) * spacing
	var outer_x := inner_x + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, z0))
	var middle := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, (z0 + z1) * 0.5))
	var b := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, z1))
	var c := _vertex(vertices, normals, vertex_indices, Vector3(outer_x, 0.0, z0))
	var d := _vertex(vertices, normals, vertex_indices, Vector3(outer_x, 0.0, z1))
	stitch_positions.append(vertices[a])
	stitch_positions.append(vertices[middle])
	stitch_positions.append(vertices[b])
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_stitch_triangles(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, middle: int, b: int, c: int, d: int) -> void:
	_add_triangle(vertices, indices, a, c, middle)
	_add_triangle(vertices, indices, middle, c, d)
	_add_triangle(vertices, indices, middle, d, b)


static func _vertex(vertices: PackedVector3Array, normals: PackedVector3Array, vertex_indices: Dictionary, position: Vector3) -> int:
	var key := "%d:%d" % [roundi(position.x * 1000.0), roundi(position.z * 1000.0)]
	if vertex_indices.has(key):
		return vertex_indices[key]
	var index := vertices.size()
	vertex_indices[key] = index
	vertices.append(position)
	normals.append(Vector3.UP)
	return index


static func _add_triangle(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	var signed_area: float = (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).y
	if signed_area > 0.0:
		indices.append_array(PackedInt32Array([a, b, c]))
	else:
		indices.append_array(PackedInt32Array([a, c, b]))

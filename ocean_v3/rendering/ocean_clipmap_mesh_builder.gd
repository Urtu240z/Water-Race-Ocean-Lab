class_name OceanClipmapMeshBuilder
extends RefCounted
## Genera L0 y los anillos con stitches 2:1; nunca se llama por frame.

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
	# The grid is deterministic in millimetres.  Vector2i preserves the former
	# key identity without allocating/formatting a String per lookup.
	var key := Vector2i(roundi(position.x * 1000.0), roundi(position.z * 1000.0))
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
		indices.append(a)
		indices.append(b)
		indices.append(c)
	else:
		indices.append(a)
		indices.append(c)
		indices.append(b)

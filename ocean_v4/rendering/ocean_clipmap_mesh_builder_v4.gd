class_name OceanClipmapMeshBuilderV4
extends RefCounted
## Static 2:1 stitched grids. Geometry is built once; displacement stays GPU-only.

static func build_level(config: OceanClipmapConfigV4, level: int) -> Dictionary:
	assert(config.is_valid())
	assert(level >= 0 and level < config.level_count)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_indices := {}
	var half_cells := int(float(config.cells_per_side) * 0.5)
	var spacing := config.spacing_for_level(level)
	var phase_offset_cells := config.grid_phase_offset_cells(level)

	if level == 0:
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing, phase_offset_cells)
	else:
		var inner_min := config.inner_cell_min()
		var inner_max := config.inner_cell_max()
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				if x_cell >= inner_min and x_cell < inner_max and z_cell >= inner_min and z_cell < inner_max:
					continue
				if z_cell == inner_min - 1 and x_cell >= inner_min and x_cell < inner_max:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, x_cell, inner_min, -1, spacing, phase_offset_cells)
				elif z_cell == inner_max and x_cell >= inner_min and x_cell < inner_max:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, x_cell, inner_max, 1, spacing, phase_offset_cells)
				elif x_cell == inner_min - 1 and z_cell >= inner_min and z_cell < inner_max:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, inner_min, z_cell, -1, spacing, phase_offset_cells)
				elif x_cell == inner_max and z_cell >= inner_min and z_cell < inner_max:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, inner_max, z_cell, 1, spacing, phase_offset_cells)
				else:
					_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing, phase_offset_cells)

	return {"vertices": vertices, "normals": normals, "indices": indices}


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
		return "Indices do not form whole triangles."
	for index in indices:
		if index < 0 or index >= vertices.size():
			return "Index outside vertex range."
	for triangle_base in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[triangle_base]]
		var b: Vector3 = vertices[indices[triangle_base + 1]]
		var c: Vector3 = vertices[indices[triangle_base + 2]]
		if (b - a).cross(c - a).y <= 0.00000001:
			return "Degenerate or inverted triangle."
	return ""


static func _add_regular_cell(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, x_cell: int, z_cell: int, spacing: float, phase: float) -> void:
	var a := _vertex(vertices, normals, vertex_indices, Vector3((float(x_cell) + phase) * spacing, 0.0, (float(z_cell) + phase) * spacing))
	var b := _vertex(vertices, normals, vertex_indices, Vector3((float(x_cell + 1) + phase) * spacing, 0.0, (float(z_cell) + phase) * spacing))
	var c := _vertex(vertices, normals, vertex_indices, Vector3((float(x_cell + 1) + phase) * spacing, 0.0, (float(z_cell + 1) + phase) * spacing))
	var d := _vertex(vertices, normals, vertex_indices, Vector3((float(x_cell) + phase) * spacing, 0.0, (float(z_cell + 1) + phase) * spacing))
	_add_triangle(vertices, indices, a, c, b)
	_add_triangle(vertices, indices, a, d, c)


static func _add_horizontal_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, x_cell: int, inner_z_cell: int, outer_sign: int, spacing: float, phase: float) -> void:
	var x0 := (float(x_cell) + phase) * spacing
	var x1 := (float(x_cell + 1) + phase) * spacing
	var inner_z := (float(inner_z_cell) + phase) * spacing
	var outer_z := inner_z + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, inner_z))
	var middle := _vertex(vertices, normals, vertex_indices, Vector3((x0 + x1) * 0.5, 0.0, inner_z))
	var b := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, inner_z))
	var c := _vertex(vertices, normals, vertex_indices, Vector3(x0, 0.0, outer_z))
	var d := _vertex(vertices, normals, vertex_indices, Vector3(x1, 0.0, outer_z))
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_vertical_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, vertex_indices: Dictionary, inner_x_cell: int, z_cell: int, outer_sign: int, spacing: float, phase: float) -> void:
	var z0 := (float(z_cell) + phase) * spacing
	var z1 := (float(z_cell + 1) + phase) * spacing
	var inner_x := (float(inner_x_cell) + phase) * spacing
	var outer_x := inner_x + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, z0))
	var middle := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, (z0 + z1) * 0.5))
	var b := _vertex(vertices, normals, vertex_indices, Vector3(inner_x, 0.0, z1))
	var c := _vertex(vertices, normals, vertex_indices, Vector3(outer_x, 0.0, z0))
	var d := _vertex(vertices, normals, vertex_indices, Vector3(outer_x, 0.0, z1))
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_stitch_triangles(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, middle: int, b: int, c: int, d: int) -> void:
	_add_triangle(vertices, indices, a, c, middle)
	_add_triangle(vertices, indices, middle, c, d)
	_add_triangle(vertices, indices, middle, d, b)


static func _vertex(vertices: PackedVector3Array, normals: PackedVector3Array, vertex_indices: Dictionary, position: Vector3) -> int:
	var key := Vector2i(roundi(position.x * 1000.0), roundi(position.z * 1000.0))
	if vertex_indices.has(key):
		return vertex_indices[key]
	var index := vertices.size()
	vertex_indices[key] = index
	vertices.append(position)
	normals.append(Vector3.UP)
	return index


static func _add_triangle(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).y > 0.0:
		indices.append_array([a, b, c])
	else:
		indices.append_array([a, c, b])

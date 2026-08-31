class_name OceanClipmapMeshBuilderV4
extends RefCounted
## Static stitched-grid builder. It has no ocean-state or presentation logic.

static func build_level(config: OceanClipmapConfigV4, level: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var seen := {}
	var half := config.cells_per_side / 2
	var spacing := config.spacing_for_level(level)
	var inner := half / 2
	for z in range(-half, half):
		for x in range(-half, half):
			if level > 0 and x >= -inner and x < inner and z >= -inner and z < inner:
				continue
			var a := _vertex(vertices, normals, seen, x, z, spacing)
			var b := _vertex(vertices, normals, seen, x + 1, z, spacing)
			var c := _vertex(vertices, normals, seen, x + 1, z + 1, spacing)
			var d := _vertex(vertices, normals, seen, x, z + 1, spacing)
			_add_triangle(vertices, indices, a, c, b)
			_add_triangle(vertices, indices, a, d, c)
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


static func _vertex(vertices: PackedVector3Array, normals: PackedVector3Array, seen: Dictionary, x: int, z: int, spacing: float) -> int:
	var key := Vector2i(x, z)
	if seen.has(key): return seen[key]
	var index := vertices.size()
	seen[key] = index
	vertices.append(Vector3(float(x) * spacing, 0.0, float(z) * spacing))
	normals.append(Vector3.UP)
	return index


static func _add_triangle(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).y > 0.0:
		indices.append_array([a, b, c])
	else:
		indices.append_array([a, c, b])

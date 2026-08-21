class_name BathymetryCaseFactory
extends RefCounted
## Geometría dev-time simple: las tres superficies alimentan el MISMO baker de
## mesh real que usaría un BathymetrySource importado desde Blender.

static func make_ramp_beach(center := Vector3(-32.0, 0.0, 0.0)) -> MeshInstance3D:
	return _grid_mesh(center, Vector2(-24.0, -16.0), Vector2(24.0, 16.0), 1.0,
		func(x: float, _z: float) -> float: return -8.0 + 0.34 * (x + 8.0))


static func make_submerged_bank(center := Vector3(32.0, 0.0, 0.0)) -> MeshInstance3D:
	return _grid_mesh(center, Vector2(-24.0, -20.0), Vector2(24.0, 20.0), 1.0,
		func(x: float, z: float) -> float:
			return -9.0 + 5.0 * exp(-(x * x / 90.0 + z * z / 55.0)))


static func make_simple_island(center := Vector3(0.0, 0.0, 42.0)) -> MeshInstance3D:
	return _grid_mesh(center, Vector2(-20.0, -20.0), Vector2(20.0, 20.0), 1.0,
		func(x: float, z: float) -> float:
			var radius := sqrt(x * x + z * z)
			return -8.0 + 11.0 * maxf(0.0, 1.0 - radius / 12.0))


static func _grid_mesh(center: Vector3, min_xz: Vector2, max_xz: Vector2, spacing: float, height_fn: Callable) -> MeshInstance3D:
	var nx := int(round((max_xz.x - min_xz.x) / spacing)) + 1
	var nz := int(round((max_xz.y - min_xz.y) / spacing)) + 1
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in nz - 1:
		for x in nx - 1:
			var p00 := _point(min_xz, spacing, x, z, height_fn)
			var p10 := _point(min_xz, spacing, x + 1, z, height_fn)
			var p01 := _point(min_xz, spacing, x, z + 1, height_fn)
			var p11 := _point(min_xz, spacing, x + 1, z + 1, height_fn)
			tool.add_vertex(p00); tool.add_vertex(p10); tool.add_vertex(p11)
			tool.add_vertex(p00); tool.add_vertex(p11); tool.add_vertex(p01)
	var instance := MeshInstance3D.new()
	instance.name = "BathymetrySource"
	instance.mesh = tool.commit()
	instance.position = center
	return instance


static func _point(min_xz: Vector2, spacing: float, x: int, z: int, height_fn: Callable) -> Vector3:
	var px := min_xz.x + float(x) * spacing
	var pz := min_xz.y + float(z) * spacing
	return Vector3(px, height_fn.call(px, pz), pz)

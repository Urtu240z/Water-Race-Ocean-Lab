@tool
class_name BathymetryBaker
extends Node
## Herramienta offline/dev-time. Rasteriza el MeshInstance3D de fondo a datos
## 2D; el runtime sólo consulta BathymetryData y nunca vuelve a tocar triángulos.

@export var source: MeshInstance3D
@export var sea_level_y := 0.0
@export_range(0.1, 32.0, 0.1, "suffix:m") var cell_size_m := 1.0
@export var bounds_min_xz := Vector2(-64.0, -64.0)
@export var bounds_max_xz := Vector2(64.0, 64.0)
@export var use_source_bounds := true
@export_file("*.tres") var output_path := ""


func bake():
	if source == null or source.mesh == null:
		push_error("BathymetryBaker: falta MeshInstance3D source con mesh.")
		return null
	var faces := _world_faces(source)
	if faces.is_empty():
		push_error("BathymetryBaker: el mesh source no tiene caras trianguladas.")
		return null
	var bounds := _bounds_from_faces(faces) if use_source_bounds else Rect2(bounds_min_xz, bounds_max_xz - bounds_min_xz)
	return bake_faces(faces, bounds.position, bounds.end)


func bake_to_resource():
	var data = bake()
	if data != null and not output_path.is_empty():
		var error := ResourceSaver.save(data, output_path)
		if error != OK:
			push_error("BathymetryBaker: no se pudo guardar %s (error %d)." % [output_path, error])
	return data


## Entrada de test/dev: triángulos world-space (cada tres Vector3). Es la misma
## rasterización usada por el MeshInstance3D, para que los tests no dependan de
## collision ni de raycasts de runtime.
func bake_faces(world_faces: PackedVector3Array, min_xz: Vector2, max_xz: Vector2):
	assert(cell_size_m > 0.0)
	assert(world_faces.size() % 3 == 0)
	var span := max_xz - min_xz
	var data = DataScript.new()
	data.world_origin_xz = min_xz
	data.cell_size_m = cell_size_m
	data.sea_level_y = sea_level_y
	data.width = maxi(2, int(ceil(span.x / cell_size_m)) + 1)
	data.height = maxi(2, int(ceil(span.y / cell_size_m)) + 1)
	var count := data.cell_count()
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	data.coast_metadata.resize(count)
	for z in data.height:
		for x in data.width:
			var world_xz := min_xz + Vector2(float(x), float(z)) * cell_size_m
			var seabed_y := _top_surface_y(world_faces, world_xz)
			var index = z * data.width + x
			# Sin geometría no se inventa profundidad: se representa como tierra/shore.
			var depth := 0.0 if is_nan(seabed_y) else sea_level_y - seabed_y
			data.depth_m[index] = depth
			data.land_water_mask[index] = 1 if depth > 0.0 else 0
			data.coast_metadata[index] = 0
	_compute_gradients(data)
	return data


func _world_faces(instance: MeshInstance3D) -> PackedVector3Array:
	var local_faces := instance.mesh.get_faces()
	var world_faces := PackedVector3Array()
	world_faces.resize(local_faces.size())
	# Un baker de editor normalmente está en árbol; los tests/tools también
	# pueden hornear un MeshInstance aún no añadido. Su transform local es world
	# en ese caso y evita depender de SceneTree para el formato de datos.
	var transform := instance.global_transform if instance.is_inside_tree() else instance.transform
	for index in local_faces.size():
		world_faces[index] = transform * local_faces[index]
	return world_faces


func _bounds_from_faces(faces: PackedVector3Array) -> Rect2:
	var min_xz := Vector2(INF, INF)
	var max_xz := Vector2(-INF, -INF)
	for vertex in faces:
		min_xz.x = minf(min_xz.x, vertex.x)
		min_xz.y = minf(min_xz.y, vertex.z)
		max_xz.x = maxf(max_xz.x, vertex.x)
		max_xz.y = maxf(max_xz.y, vertex.z)
	return Rect2(min_xz, max_xz - min_xz)


func _top_surface_y(faces: PackedVector3Array, point_xz: Vector2) -> float:
	var top_y := NAN
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var bary := _barycentric_xz(point_xz, a, b, c)
		if bary.x < -1.0e-7 or bary.y < -1.0e-7 or bary.z < -1.0e-7:
			continue
		var y := bary.x * a.y + bary.y * b.y + bary.z * c.y
		if is_nan(top_y) or y > top_y:
			top_y = y
	return top_y


func _barycentric_xz(p: Vector2, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := p - Vector2(a.x, a.z)
	var det := v0.x * v1.y - v1.x * v0.y
	if absf(det) <= 1.0e-12:
		return Vector3(-1.0, -1.0, -1.0) # triángulo vertical en XZ: sin área rasterizable.
	var inv_det := 1.0 / det
	var vb := (v2.x * v1.y - v1.x * v2.y) * inv_det
	var vc := (v0.x * v2.y - v2.x * v0.y) * inv_det
	return Vector3(1.0 - vb - vc, vb, vc)


func _compute_gradients(data) -> void:
	for z in data.height:
		for x in data.width:
			var index = z * data.width + x
			var gx := _finite_difference_x(data, x, z)
			var gz := _finite_difference_z(data, x, z)
			data.gradient_x[index] = gx
			data.gradient_z[index] = gz
			data.slope_magnitude[index] = sqrt(gx * gx + gz * gz)


func _finite_difference_x(data, x: int, z: int) -> float:
	if x == 0:
		return (data.depth_at_node(1, z) - data.depth_at_node(0, z)) / data.cell_size_m
	if x == data.width - 1:
		return (data.depth_at_node(x, z) - data.depth_at_node(x - 1, z)) / data.cell_size_m
	return (data.depth_at_node(x + 1, z) - data.depth_at_node(x - 1, z)) / (2.0 * data.cell_size_m)


func _finite_difference_z(data, x: int, z: int) -> float:
	if z == 0:
		return (data.depth_at_node(x, 1) - data.depth_at_node(x, 0)) / data.cell_size_m
	if z == data.height - 1:
		return (data.depth_at_node(x, z) - data.depth_at_node(x, z - 1)) / data.cell_size_m
	return (data.depth_at_node(x, z + 1) - data.depth_at_node(x, z - 1)) / (2.0 * data.cell_size_m)
const DataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

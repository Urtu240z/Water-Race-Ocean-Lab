@tool
class_name BathymetryBaker
extends Node
## Herramienta offline/dev-time. Rasteriza una o varias superficies a datos
## 2D; el runtime sólo consulta BathymetryData y nunca vuelve a tocar triángulos.

## Bathymetry samples represent the seabed/top surface, not near-vertical coast
## walls. Mesh winding is not part of this contract, hence the absolute value.
## Without this filter, a side face can win the XZ projection and create a false
## deep-water sample immediately beside the shoreline.
const MIN_SURFACE_HORIZONTALNESS := 0.7

@export var source_root: Node3D
@export var source: MeshInstance3D
@export var sea_level_y := 0.0
@export_range(0.1, 32.0, 0.1, "suffix:m") var cell_size_m := 1.0
@export var bounds_min_xz := Vector2(-64.0, -64.0)
@export var bounds_max_xz := Vector2(64.0, 64.0)
@export var use_source_bounds := true
@export_range(0.0, 10000.0, 1.0, "suffix:m") var bounds_padding_m := 64.0
@export var synthetic_depth_enabled := true
@export_range(0.0, 10.0, 0.01) var synthetic_slope := 0.20
@export_range(0.0, 10000.0, 0.1, "suffix:m") var synthetic_max_depth_m := 20.0
@export_range(0.0, 128.0, 0.5, "suffix:m") var optical_seabed_feather_m := 12.0
@export_file("*.tres") var output_path := ""

enum PreviewMode {
	DEPTH = 0,
	GRADIENT_SLOPE = 1,
	LAND_WATER = 2,
	SHORE_DISTANCE = 3,
	DEPTH_SOURCE = 4,
}

@export_category("Bathymetry Preview")
@export_tool_button("BAKE PREVIEW", "Play") var bake_preview_button = bake_preview
@export_tool_button("CLEAR PREVIEW", "Remove") var clear_preview_button = clear_preview
@export var preview_mode: PreviewMode = PreviewMode.LAND_WATER:
	set(value):
		preview_mode = value
		_update_preview_mode()

const PREVIEW_OWNER_META := "_bathymetry_preview_owner_id"
const PreviewScript := preload("res://ocean_v3/bathymetry/bathymetry_debug.gd")

var _preview: BathymetryDebug = null


func bake():
	var faces := _collect_world_faces()
	if faces.is_empty():
		push_error("BathymetryBaker: no hay caras válidas bajo source_root/source.")
		return null
	var bounds := _bounds_from_faces(faces) if use_source_bounds else Rect2(bounds_min_xz, bounds_max_xz - bounds_min_xz)
	if use_source_bounds:
		var padding := Vector2(bounds_padding_m, bounds_padding_m)
		bounds = Rect2(bounds.position - padding, bounds.size + 2.0 * padding)
	return bake_faces(faces, bounds.position, bounds.end)


func bake_to_resource():
	var data = bake()
	if data != null and not output_path.is_empty():
		var error := ResourceSaver.save(data, output_path)
		if error != OK:
			push_error("BathymetryBaker: no se pudo guardar %s (error %d)." % [output_path, error])
	return data


func bake_preview() -> void:
	if source_root == null and source == null:
		push_error("BathymetryBaker: asigna source_root o source antes de BAKE PREVIEW.")
		return
	clear_preview()
	var data = bake()
	if data == null:
		return
	var parent := _preview_parent()
	if parent == null:
		push_error("BathymetryBaker: no se encontró un parent válido para BathymetryPreview.")
		return
	var preview: BathymetryDebug = PreviewScript.new()
	preview.name = "%s_Preview" % name if not name.is_empty() else "BathymetryPreview"
	preview.set_meta(PREVIEW_OWNER_META, get_instance_id())
	parent.add_child(preview, false, Node.INTERNAL_MODE_FRONT)
	preview.owner = null
	preview.set_as_top_level(true)
	preview.global_transform = Transform3D.IDENTITY
	preview.mode = _debug_mode_for_preview()
	preview.data = data
	_preview = preview


func clear_preview() -> void:
	var preview := _find_owned_preview()
	_preview = null
	if preview == null or not is_instance_valid(preview):
		return
	if preview.get_meta(PREVIEW_OWNER_META, -1) != get_instance_id():
		return
	var parent := preview.get_parent()
	if parent != null:
		parent.remove_child(preview)
	preview.free()


func _exit_tree() -> void:
	clear_preview()


func _update_preview_mode() -> void:
	var preview := _find_owned_preview()
	if preview != null and is_instance_valid(preview):
		preview.mode = _debug_mode_for_preview()


func _debug_mode_for_preview() -> BathymetryDebug.Mode:
	match preview_mode:
		PreviewMode.DEPTH:
			return BathymetryDebug.Mode.DEPTH
		PreviewMode.GRADIENT_SLOPE:
			return BathymetryDebug.Mode.GRADIENT_SLOPE
		PreviewMode.LAND_WATER:
			return BathymetryDebug.Mode.LAND_WATER
		PreviewMode.SHORE_DISTANCE:
			return BathymetryDebug.Mode.SHORE_DISTANCE
		PreviewMode.DEPTH_SOURCE:
			return BathymetryDebug.Mode.DEPTH_SOURCE
	return BathymetryDebug.Mode.LAND_WATER


func _preview_parent() -> Node:
	if is_inside_tree():
		var edited_root := get_tree().edited_scene_root
		if edited_root != null:
			return edited_root
	return self


func _find_owned_preview() -> BathymetryDebug:
	if _preview != null and is_instance_valid(_preview):
		return _preview
	var parent := _preview_parent()
	if parent == null:
		return null
	for child in parent.get_children(true):
		if child is BathymetryDebug and child.get_meta(PREVIEW_OWNER_META, -1) == get_instance_id():
			return child as BathymetryDebug
	return null


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
	data.optical_seabed_feather_m = optical_seabed_feather_m
	data.width = maxi(2, int(ceil(span.x / cell_size_m)) + 1)
	data.height = maxi(2, int(ceil(span.y / cell_size_m)) + 1)
	var count: int = data.cell_count()
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	data.shore_signed_distance_m.resize(count)
	data.depth_source_mask.resize(count)
	data.real_seabed_coverage.resize(count)
	data.optical_seabed_confidence.resize(count)
	data.coast_metadata.resize(count)
	var top_surface_y := PackedFloat32Array()
	top_surface_y.resize(count)
	var has_surface := PackedByteArray()
	has_surface.resize(count)
	_rasterize_triangles_to_top_surface(world_faces, data, top_surface_y, has_surface)
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			if has_surface[index] == 0:
				# Un dominio con islas no necesita un seabed cerrado: el vacío es
				# agua abierta y se rellena después de conocer todas las costas.
				data.depth_m[index] = 0.0
				data.land_water_mask[index] = 1
				data.depth_source_mask[index] = 0
			elif top_surface_y[index] >= sea_level_y:
				# Conservamos la profundidad firmada histórica para tierra; la
				# máscara es la autoridad que consumen los sistemas costeros.
				data.depth_m[index] = sea_level_y - top_surface_y[index]
				data.land_water_mask[index] = 0
				data.depth_source_mask[index] = 0
			else:
				data.depth_m[index] = sea_level_y - top_surface_y[index]
				data.land_water_mask[index] = 1
				data.depth_source_mask[index] = 1
			data.coast_metadata[index] = 0
	_compute_real_seabed_coverage(data, has_surface)
	_compute_shore_signed_distance(data)
	_apply_synthetic_depth(data)
	_compute_gradients(data)
	return data


func _compute_real_seabed_coverage(data, has_surface: PackedByteArray) -> void:
	## Captura la cobertura geométrica antes de cualquier relleno sintético.
	## La erosión sólo reduce autoridad hacia el interior: nunca expande un hit.
	var count: int = data.cell_count()
	var no_hit_seeds := PackedByteArray()
	no_hit_seeds.resize(count)
	var no_hit_count := 0
	for index in count:
		var has_hit := has_surface[index] != 0
		data.real_seabed_coverage[index] = 255 if has_hit else 0
		if not has_hit:
			no_hit_seeds[index] = 1
			no_hit_count += 1
	if no_hit_count == 0:
		for index in count:
			data.optical_seabed_confidence[index] = 255 if data.real_seabed_coverage[index] != 0 else 0
		return
	var distance_squared := PackedFloat32Array()
	distance_squared.resize(count)
	var horizontal := PackedFloat32Array()
	horizontal.resize(count)
	for z in data.height:
		var row := []
		row.resize(data.width)
		for x in data.width:
			row[x] = 0.0 if no_hit_seeds[z * data.width + x] != 0 else 1.0e20
		var transformed: Array = _edt_1d(row, data.width)
		for x in data.width:
			horizontal[z * data.width + x] = transformed[x]
	for x in data.width:
		var column := []
		column.resize(data.height)
		for z in data.height:
			column[z] = horizontal[z * data.width + x]
		var transformed: Array = _edt_1d(column, data.height)
		for z in data.height:
			distance_squared[z * data.width + x] = maxf(float(transformed[z]), 0.0)
	var feather_m := maxf(optical_seabed_feather_m, 0.0)
	for index in count:
		if data.real_seabed_coverage[index] == 0:
			data.optical_seabed_confidence[index] = 0
		elif feather_m <= 0.0:
			data.optical_seabed_confidence[index] = 255
		else:
			var distance_m: float = sqrt(distance_squared[index]) * data.cell_size_m
			var confidence := clampf(distance_m / feather_m, 0.0, 1.0)
			data.optical_seabed_confidence[index] = clampi(int(round(confidence * 255.0)), 0, 255)


func _rasterize_triangles_to_top_surface(world_faces: PackedVector3Array, data, top_surface_y: PackedFloat32Array, has_surface: PackedByteArray) -> void:
	for face_index in range(0, world_faces.size(), 3):
		var a: Vector3 = world_faces[face_index]
		var b: Vector3 = world_faces[face_index + 1]
		var c: Vector3 = world_faces[face_index + 2]
		var face_cross: Vector3 = (b - a).cross(c - a)
		var face_length_squared: float = face_cross.length_squared()
		if face_length_squared <= 1.0e-12 or absf(face_cross.y) / sqrt(face_length_squared) < MIN_SURFACE_HORIZONTALNESS:
			continue
		var v0 := Vector2(b.x - a.x, b.z - a.z)
		var v1 := Vector2(c.x - a.x, c.z - a.z)
		var det := v0.x * v1.y - v1.x * v0.y
		if absf(det) <= 1.0e-12:
			# Vertical/degenerate XZ projections do not rasterize into the 2D field.
			continue
		var min_x := minf(a.x, minf(b.x, c.x))
		var max_x := maxf(a.x, maxf(b.x, c.x))
		var min_z := minf(a.z, minf(b.z, c.z))
		var max_z := maxf(a.z, maxf(b.z, c.z))
		var aabb_tolerance_m: float = maxf(max_x - min_x, max_z - min_z) * 1.0e-7 + data.cell_size_m * 1.0e-7
		var x_min := _grid_min_for_world(min_x - aabb_tolerance_m, data.world_origin_xz.x, data.cell_size_m, data.width)
		var x_max := _grid_max_for_world(max_x + aabb_tolerance_m, data.world_origin_xz.x, data.cell_size_m, data.width)
		var z_min := _grid_min_for_world(min_z - aabb_tolerance_m, data.world_origin_xz.y, data.cell_size_m, data.height)
		var z_max := _grid_max_for_world(max_z + aabb_tolerance_m, data.world_origin_xz.y, data.cell_size_m, data.height)
		if x_min > x_max or z_min > z_max:
			continue
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var point_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
				var bary := _barycentric_xz(point_xz, a, b, c)
				if bary.x < -1.0e-7 or bary.y < -1.0e-7 or bary.z < -1.0e-7:
					continue
				var index: int = z * data.width + x
				var y := bary.x * a.y + bary.y * b.y + bary.z * c.y
				if has_surface[index] == 0 or y > top_surface_y[index]:
					top_surface_y[index] = y
					has_surface[index] = 1


func _grid_min_for_world(world_value: float, origin_value: float, cell_size: float, grid_size: int) -> int:
	# The AABB is already expanded by the same order of tolerance used by the
	# exact barycentric test; this conversion only clamps it to grid nodes.
	var grid_value := (world_value - origin_value) / cell_size
	return clampi(int(ceil(grid_value - 1.0e-7)), 0, grid_size - 1)


func _grid_max_for_world(world_value: float, origin_value: float, cell_size: float, grid_size: int) -> int:
	var grid_value := (world_value - origin_value) / cell_size
	return clampi(int(floor(grid_value + 1.0e-7)), 0, grid_size - 1)


func _collect_world_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	if source_root != null:
		_append_node_faces(source_root, faces)
	elif source != null:
		_append_instance_faces(source, faces)
	return faces


func _append_node_faces(node: Node, faces: PackedVector3Array) -> void:
	if node is MeshInstance3D:
		_append_instance_faces(node as MeshInstance3D, faces)
	for child in node.get_children():
		_append_node_faces(child, faces)


func _append_instance_faces(instance: MeshInstance3D, faces: PackedVector3Array) -> void:
	if instance.mesh == null:
		return
	var local_faces := instance.mesh.get_faces()
	if local_faces.is_empty():
		return
	var transform := _world_transform(instance)
	for local_face in local_faces:
		faces.append(transform * local_face)


func _world_transform(instance: MeshInstance3D) -> Transform3D:
	if instance.is_inside_tree():
		return instance.global_transform
	var result := instance.transform
	var parent := instance.get_parent()
	while parent is Node3D:
		result = (parent as Node3D).transform * result
		parent = parent.get_parent()
	return result


func _world_faces(instance: MeshInstance3D) -> PackedVector3Array:
	# Compatibilidad interna con callers/tools antiguos; bake() usa el collector.
	var faces := PackedVector3Array()
	_append_instance_faces(instance, faces)
	return faces


func _compute_shore_signed_distance(data) -> void:
	var count: int = data.cell_count()
	var seeds := PackedByteArray()
	seeds.resize(count)
	var seed_count := 0
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var water: bool = data.land_water_mask[index] != 0
			var boundary := false
			for neighbor in [Vector2i(x - 1, z), Vector2i(x + 1, z), Vector2i(x, z - 1), Vector2i(x, z + 1)]:
				if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= data.width or neighbor.y >= data.height:
					continue
				if (data.land_water_mask[neighbor.y * data.width + neighbor.x] != 0) != water:
					boundary = true
					break
			if boundary:
				seeds[index] = 1
				seed_count += 1
	data.shore_signed_distance_m.fill(0.0)
	if seed_count == 0:
		return

	# Felzenszwalb/Huttenlocher separable squared Euclidean transform.
	var horizontal := PackedFloat32Array()
	horizontal.resize(count)
	for z in data.height:
		var row := []
		row.resize(data.width)
		for x in data.width:
			row[x] = 0.0 if seeds[z * data.width + x] != 0 else 1.0e20
		var transformed: Array = _edt_1d(row, data.width)
		for x in data.width:
			horizontal[z * data.width + x] = transformed[x]
	for x in data.width:
		var column := []
		column.resize(data.height)
		for z in data.height:
			column[z] = horizontal[z * data.width + x]
		var transformed: Array = _edt_1d(column, data.height)
		for z in data.height:
			var distance: float = sqrt(maxf(0.0, float(transformed[z]))) * data.cell_size_m
			data.shore_signed_distance_m[z * data.width + x] = distance if data.land_water_mask[z * data.width + x] != 0 else -distance


func _edt_1d(values: Array, length: int) -> Array:
	var result := []
	result.resize(length)
	var vertices := []
	vertices.resize(length)
	var boundaries := []
	boundaries.resize(length + 1)
	var k := 0
	vertices[0] = 0
	boundaries[0] = -INF
	boundaries[1] = INF
	for q in range(1, length):
		var intersection := _edt_intersection(values, vertices[k], q)
		while intersection <= boundaries[k]:
			k -= 1
			intersection = _edt_intersection(values, vertices[k], q)
		k += 1
		vertices[k] = q
		boundaries[k] = intersection
		boundaries[k + 1] = INF
	k = 0
	for q in length:
		while boundaries[k + 1] < q:
			k += 1
		var delta := float(q - vertices[k])
		result[q] = delta * delta + values[vertices[k]]
	return result


func _edt_intersection(values: Array, left: int, right: int) -> float:
	return ((values[right] + float(right * right)) - (values[left] + float(left * left))) / (2.0 * float(right - left))


func _apply_synthetic_depth(data) -> void:
	if not synthetic_depth_enabled:
		return
	for index in data.cell_count():
		if data.land_water_mask[index] == 0 or data.depth_source_mask[index] != 0:
			continue
		data.depth_m[index] = minf(synthetic_max_depth_m, maxf(0.0, data.shore_signed_distance_m[index] * synthetic_slope))


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

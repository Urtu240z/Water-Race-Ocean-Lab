extends SceneTree
## Validación de la extensión multi-mesh/islas de BathymetryBaker.

const BakerScript := preload("res://ocean_v3/bathymetry/bathymetry_baker.gd")
const DebugScript := preload("res://ocean_v3/bathymetry/bathymetry_debug.gd")

var _failures := 0


func _initialize() -> void:
	_validate_single_island_without_seabed()
	_validate_two_islands_channel()
	_validate_real_seabed_precedence()
	_validate_bruteforce_equivalence()
	_validate_preview_lifecycle()
	if _failures == 0:
		print("PHASE_3A_BATHYMETRY_COASTAL: PASS")
		quit(0)
	else:
		push_error("PHASE_3A_BATHYMETRY_COASTAL: %d fallos" % _failures)
		quit(1)


func _bake_root(root: Node3D):
	var baker = BakerScript.new()
	baker.source_root = root
	baker.sea_level_y = 0.0
	baker.cell_size_m = 1.0
	baker.bounds_padding_m = 4.0
	var data = baker.bake()
	root.free()
	baker.free()
	return data


func _validate_single_island_without_seabed() -> void:
	var root := Node3D.new()
	var island := _make_plane(Vector2(-3.0, -3.0), Vector2(3.0, 3.0), 3.0)
	root.add_child(island)
	var data = _bake_root(root)
	var land = data.sample_bathymetry(Vector2(0.0, 0.0))
	var water = data.sample_bathymetry(Vector2(0.0, 6.0))
	_check(data.world_origin_xz == Vector2(-7.0, -7.0) and data.world_max_xz() == Vector2(7.0, 7.0), "single island: source bounds include padding")
	_check(not land.is_water, "single island: surface above sea is LAND")
	_check(water.is_water and not water.depth_is_measured, "single island: empty space is synthetic WATER")
	_check(water.shore_signed_distance_m > 0.0 and water.depth_m > 0.0, "single island: shore distance drives synthetic depth")


func _validate_two_islands_channel() -> void:
	var root := Node3D.new()
	var island_a := Node3D.new()
	island_a.name = "IslandA"
	island_a.position = Vector3(-6.0, 0.0, 0.0)
	island_a.add_child(_make_plane(Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 2.0))
	var island_b := Node3D.new()
	island_b.name = "IslandB"
	island_b.position = Vector3(6.0, 0.0, 0.0)
	island_b.add_child(_make_plane(Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 2.0))
	root.add_child(island_a)
	root.add_child(island_b)
	var data = _bake_root(root)
	var channel = data.sample_bathymetry(Vector2(0.0, 0.0))
	var left_island = data.sample_bathymetry(Vector2(-6.0, 0.0))
	var right_island = data.sample_bathymetry(Vector2(6.0, 0.0))
	_check(not left_island.is_water and not right_island.is_water, "two islands: both meshes collected recursively")
	_check(channel.is_water and channel.shore_signed_distance_m > 0.0, "two islands: channel is WATER with global shore distance")
	_check(channel.depth_m > 0.0 and not channel.depth_is_measured, "two islands: channel uses synthetic depth")


func _validate_real_seabed_precedence() -> void:
	var root := Node3D.new()
	root.add_child(_make_plane(Vector2(-5.0, -5.0), Vector2(5.0, 5.0), -8.0))
	root.add_child(_make_plane(Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 2.0))
	var data = _bake_root(root)
	var measured = data.sample_bathymetry(Vector2(4.0, 0.0))
	var land = data.sample_bathymetry(Vector2(0.0, 0.0))
	_check(measured.is_water and measured.depth_is_measured and absf(measured.depth_m - 8.0) < 1.0e-5, "real seabed: measured depth wins over synthetic")
	_check(not land.is_water, "real seabed: island top remains LAND")


func _validate_bruteforce_equivalence() -> void:
	var baker = BakerScript.new()
	baker.cell_size_m = 1.0
	var faces := PackedVector3Array()
	_append_plane_faces(faces, Vector2(-4.0, -4.0), Vector2(4.0, 4.0), -8.0)
	_append_plane_faces(faces, Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 2.0)
	var data = baker.bake_faces(faces, Vector2(-5.0, -5.0), Vector2(5.0, 5.0))
	var equivalent := true
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var point: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
			var top_y: float = baker._top_surface_y(faces, point)
			var expected_depth: float
			var expected_water: bool
			var expected_measured: bool
			if is_nan(top_y):
				expected_water = true
				expected_measured = false
				expected_depth = minf(baker.synthetic_max_depth_m, maxf(0.0, data.shore_signed_distance_m[index] * baker.synthetic_slope))
			elif top_y >= baker.sea_level_y:
				expected_water = false
				expected_measured = false
				expected_depth = baker.sea_level_y - top_y
			else:
				expected_water = true
				expected_measured = true
				expected_depth = baker.sea_level_y - top_y
			if (data.land_water_mask[index] != 0) != expected_water or (data.depth_source_mask[index] != 0) != expected_measured or absf(data.depth_m[index] - expected_depth) > 1.0e-5:
				equivalent = false
	_check(equivalent, "equivalence: triangle-driven raster matches brute-force top surface")
	baker.free()


func _validate_preview_lifecycle() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var baker = BakerScript.new()
	baker.name = "PreviewLifecycleBaker"
	holder.add_child(baker)
	var source := _make_plane(Vector2(-2.0, -2.0), Vector2(2.0, 2.0), 2.0)
	baker.source = source
	baker.bounds_padding_m = 2.0
	baker.bake_preview()
	var preview = baker._find_owned_preview()
	_check(preview != null and preview.mode == DebugScript.Mode.LAND_WATER, "preview: bake creates default LAND_WATER")
	baker.preview_mode = 4
	_check(preview != null and preview.mode == DebugScript.Mode.DEPTH_SOURCE, "preview: mode changes without rebake")
	baker.bake_preview()
	var rebaked_preview = baker._find_owned_preview()
	_check(rebaked_preview != null and _count_owned_previews(baker) == 1, "preview: rebake replaces without duplicates")
	var user_debug = DebugScript.new()
	holder.add_child(user_debug)
	baker.clear_preview()
	_check(baker._find_owned_preview() == null and is_instance_valid(user_debug), "preview: clear removes only owned preview")
	source.free()
	holder.free()


func _count_owned_previews(baker) -> int:
	var count := 0
	var parent = baker._preview_parent()
	for child in parent.get_children(true):
		if child is DebugScript and child.get_meta("_bathymetry_preview_owner_id", -1) == baker.get_instance_id():
			count += 1
	return count


func _make_plane(min_xz: Vector2, max_xz: Vector2, y: float) -> MeshInstance3D:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p00 := Vector3(min_xz.x, y, min_xz.y)
	var p10 := Vector3(max_xz.x, y, min_xz.y)
	var p01 := Vector3(min_xz.x, y, max_xz.y)
	var p11 := Vector3(max_xz.x, y, max_xz.y)
	tool.add_vertex(p00); tool.add_vertex(p10); tool.add_vertex(p11)
	tool.add_vertex(p00); tool.add_vertex(p11); tool.add_vertex(p01)
	var instance := MeshInstance3D.new()
	instance.mesh = tool.commit()
	return instance


func _append_plane_faces(faces: PackedVector3Array, min_xz: Vector2, max_xz: Vector2, y: float) -> void:
	var p00 := Vector3(min_xz.x, y, min_xz.y)
	var p10 := Vector3(max_xz.x, y, min_xz.y)
	var p01 := Vector3(min_xz.x, y, max_xz.y)
	var p11 := Vector3(max_xz.x, y, max_xz.y)
	faces.append(p00); faces.append(p10); faces.append(p11)
	faces.append(p00); faces.append(p11); faces.append(p01)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

extends SceneTree
## Validación lifecycle del tooling editor CoastalEikonalPreviewBaker.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const PreviewBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_preview_baker.gd")
const DebugScript := preload("res://ocean_v3/coastal/coastal_eikonal_debug.gd")

var _failures := 0


class MockBathymetryBaker extends BathymetryBaker:
	var bake_calls := 0
	var payload: BathymetryData

	func bake():
		bake_calls += 1
		return payload


func _initialize() -> void:
	_validate_lifecycle()
	_validate_controlled_errors()
	if _failures == 0:
		print("PHASE_3B_COASTAL_PREVIEW: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_COASTAL_PREVIEW: %d fallos" % _failures)
		quit(1)


func _validate_lifecycle() -> void:
	var root := Node.new()
	root.name = "CoastalPreviewTestRoot"
	get_root().add_child(root)
	var mock := MockBathymetryBaker.new()
	mock.payload = _make_bathymetry()
	root.add_child(mock)
	var preview_baker = PreviewBakerScript.new()
	root.add_child(preview_baker)
	preview_baker.bathymetry_baker = mock
	preview_baker.preview_mode = PreviewBakerScript.PreviewMode.SHADOW_SCALE
	preview_baker.bake_coastal_preview()
	var first_debug = preview_baker._find_owned_preview()
	var first_data = preview_baker._coastal_data
	_check(mock.bake_calls == 1 and first_debug != null, "lifecycle: BAKE crea preview")
	_check(first_debug != null and first_debug.data == first_data and first_debug.mode == DebugScript.Mode.SHADOW_SCALE, "lifecycle: preview recibe CoastalPropagationData y modo")
	var data_before_mode_change = preview_baker._coastal_data
	preview_baker.preview_mode = PreviewBakerScript.PreviewMode.REACHED
	_check(mock.bake_calls == 1 and preview_baker._coastal_data == data_before_mode_change and preview_baker._find_owned_preview().mode == DebugScript.Mode.REACHED, "lifecycle: cambiar modo no rebakea")
	preview_baker.bake_coastal_preview()
	var second_debug = preview_baker._find_owned_preview()
	_check(mock.bake_calls == 2 and second_debug != null and second_debug != first_debug, "lifecycle: rebake reemplaza preview")
	_check(_owned_preview_count(root, preview_baker) == 1, "lifecycle: rebake deja un solo preview propio")
	preview_baker.clear_preview()
	_check(preview_baker._find_owned_preview() == null and _owned_preview_count(root, preview_baker) == 0, "lifecycle: CLEAR elimina sólo el preview propio")
	root.free()


func _validate_controlled_errors() -> void:
	var preview_baker = PreviewBakerScript.new()
	get_root().add_child(preview_baker)
	preview_baker.bake_coastal_preview()
	_check(preview_baker._find_owned_preview() == null, "errors: BathymetryBaker null no crea preview")
	var mock := MockBathymetryBaker.new()
	mock.payload = _make_bathymetry()
	preview_baker.bathymetry_baker = mock
	preview_baker.incoming_direction_xz = Vector2.ZERO
	preview_baker.bake_coastal_preview()
	_check(mock.bake_calls == 0, "errors: dirección cero no ejecuta bake")
	preview_baker.free()
	mock.free()


func _owned_preview_count(root: Node, owner: Node) -> int:
	var count := 0
	for child in root.get_children(true):
		if child is CoastalEikonalDebug and child.get_meta("_coastal_eikonal_preview_owner_id", -1) == owner.get_instance_id():
			count += 1
	return count


func _make_bathymetry() -> BathymetryData:
	var data: BathymetryData = BathymetryDataScript.new()
	data.width = 17
	data.height = 13
	data.cell_size_m = 1.0
	data.sea_level_y = 2.5
	var count := data.width * data.height
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var dx := float(x - 8)
			var dz := float(z - 6)
			var land := dx * dx + dz * dz < 3.0 * 3.0
			data.depth_m[index] = -1.0 if land else 18.0
			data.land_water_mask[index] = 0 if land else 1
	return data


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

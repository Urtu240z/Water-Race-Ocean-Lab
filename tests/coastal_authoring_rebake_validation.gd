extends SceneTree
## Validación same-process del publish canónico de CoastalBakeAuthoring.

const AuthoringScript := preload("res://ocean_v3/coastal/coastal_bake_authoring.gd")

const COAST_ID := "__codex_coastal_rebake_validation__"
const OUTPUT_DIR := "res://ocean_v3/baked/coastal/%s" % COAST_ID
const ASSET_PATH := OUTPUT_DIR + "/coastal_bake.tres"

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_cleanup_output()
	var source := _make_source()
	var authoring := _make_authoring(source)
	var asset_a: CoastalBakeAsset = authoring.bake_coastal_asset()
	_check(asset_a != null and asset_a.is_valid(), "A: bake y manifest válidos")
	_print_owners("A", asset_a)
	var disk_a := _read_bytes(ASSET_PATH)
	_check(not disk_a.is_empty(), "A: manifest existe en disco")
	_check(_manifest_is_external_and_compact(), "A: manifest usa tres ext_resource y no arrays embebidos")

	# Error antes de persistir: el publish A no debe cambiar.
	authoring.incoming_direction_xz = Vector2.ZERO
	var failed = authoring.bake_coastal_asset()
	_check(failed == null, "failure: dirección inválida aborta antes de publicar")
	_check(_read_bytes(ASSET_PATH) == disk_a, "failure: A permanece intacto en disco")
	authoring.incoming_direction_xz = Vector2.DOWN

	var asset_b: CoastalBakeAsset = authoring.bake_coastal_asset()
	_check(asset_b != null and asset_b.is_valid(), "B: rebake same coast_id válido")
	_check(asset_b != asset_a and asset_b.eikonal_incoming_direction_xz.is_equal_approx(Vector2.DOWN), "B: representación nueva sustituye al owner")
	var loaded_b := ResourceLoader.load(ASSET_PATH, "", ResourceLoader.CACHE_MODE_REUSE) as CoastalBakeAsset
	_print_owners("B", asset_b)
	_check(loaded_b == asset_b and loaded_b.is_valid(), "B: nueva carga REUSE devuelve la representación canónica")
	_check(loaded_b.bathymetry == asset_b.bathymetry and loaded_b.propagation == asset_b.propagation and loaded_b.warp == asset_b.warp, "B: manifest apunta a los children B")
	_check(asset_a.is_valid() and asset_a.eikonal_incoming_direction_xz.is_equal_approx(Vector2.RIGHT), "B: referencia viva A conserva sus datos")

	authoring.incoming_direction_xz = Vector2.LEFT
	var asset_c: CoastalBakeAsset = authoring.bake_coastal_asset()
	_check(asset_c != null and asset_c.is_valid(), "C: tercer rebake same coast_id válido")
	var loaded_c := ResourceLoader.load(ASSET_PATH, "", ResourceLoader.CACHE_MODE_REUSE) as CoastalBakeAsset
	_print_owners("C", asset_c)
	_check(loaded_c == asset_c and loaded_c.is_valid(), "C: nueva carga REUSE devuelve C")
	_check(loaded_c.bathymetry == asset_c.bathymetry and loaded_c.propagation == asset_c.propagation and loaded_c.warp == asset_c.warp, "C: manifest apunta a los children C")
	_check(asset_b.is_valid() and asset_b.eikonal_incoming_direction_xz.is_equal_approx(Vector2.DOWN), "C: referencia viva B conserva sus datos")
	_check(asset_c.eikonal_incoming_direction_xz.is_equal_approx(Vector2.LEFT), "C: datos publicados son los de C")
	_check(asset_a.resource_path.is_empty() and asset_b.resource_path.is_empty() and asset_c.resource_path == ASSET_PATH, "owners: take_over_path libera la ruta de A/B y deja C como owner")
	_check(_manifest_is_external_and_compact(), "C: manifest sigue usando ext_resource y tamaño compacto")
	if not Engine.is_editor_hint():
		await _validate_ocean_v3_load(asset_c)

	_cleanup_output()
	source.free()
	authoring.free()
	if failures == 0:
		print("COASTAL_AUTHORING_REBAKE: PASS")
		quit(0)
	else:
		push_error("COASTAL_AUTHORING_REBAKE: %d fallos" % failures)
		quit(1)


func _validate_ocean_v3_load(asset: CoastalBakeAsset) -> void:
	var ocean_scene := ResourceLoader.load("res://ocean_v3/ocean_v3.tscn", "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	_check(ocean_scene != null, "OceanV3: escena canónica carga")
	if ocean_scene == null:
		return
	var ocean := ocean_scene.instantiate()
	ocean.coastal_bake_asset = asset
	get_root().add_child(ocean)
	await process_frame
	await process_frame
	var module := ocean.get_node_or_null(^"OpenOceanFFT")
	_check(module != null, "OceanV3: flujo normal encuentra OpenOceanFFT")
	if module != null:
		_check(module.coastal_bathymetry_data == asset.bathymetry and module.coastal_propagation_enabled, "OceanV3: instala el manifest canónico")
	ocean.queue_free()
	await process_frame


func _make_authoring(source: MeshInstance3D) -> CoastalBakeAuthoring:
	var authoring: CoastalBakeAuthoring = AuthoringScript.new()
	authoring.coast_id = COAST_ID
	authoring.source = source
	authoring.sea_level_y = 0.0
	authoring.cell_size_m = 1.0
	authoring.use_source_bounds = false
	authoring.bounds_min_xz = Vector2(-4.0, -4.0)
	authoring.bounds_max_xz = Vector2(4.0, 4.0)
	authoring.synthetic_depth_enabled = false
	authoring.reference_wavelength_m = 8.0
	authoring.max_sweep_cycles = 4
	authoring.shadow_recovery_enabled = false
	authoring.shadow_smoothing_passes = 0
	authoring.direction_smoothing_passes = 0
	authoring.cut_locus_enabled = false
	authoring.phase_regularization_enabled = false
	authoring.max_backtrace_steps = 64
	return authoring


func _make_source() -> MeshInstance3D:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.add_vertex(Vector3(-2.0, -4.0, -2.0))
	tool.add_vertex(Vector3(2.0, -4.0, -2.0))
	tool.add_vertex(Vector3(2.0, -4.0, 2.0))
	tool.add_vertex(Vector3(-2.0, -4.0, -2.0))
	tool.add_vertex(Vector3(2.0, -4.0, 2.0))
	tool.add_vertex(Vector3(-2.0, -4.0, 2.0))
	var source := MeshInstance3D.new()
	source.mesh = tool.commit()
	return source


func _manifest_is_external_and_compact() -> bool:
	var text := FileAccess.get_file_as_string(ASSET_PATH)
	var ext_count := text.count("[ext_resource type=\"Resource\"")
	print("MANIFEST: bytes=", text.to_utf8_buffer().size(), " ext_resource=", ext_count)
	return ext_count == 3 and text.find("bathymetry.res") >= 0 and text.find("propagation.res") >= 0 and text.find("warp.res") >= 0 and text.find("PackedFloat32Array") < 0 and text.length() < 32768


func _print_owners(label: String, asset: CoastalBakeAsset) -> void:
	print("OWNER_", label, ": asset id=", asset.get_instance_id(), " path=", asset.resource_path,
		" bathymetry id=", asset.bathymetry.get_instance_id(), " path=", asset.bathymetry.resource_path,
		" propagation id=", asset.propagation.get_instance_id(), " path=", asset.propagation.resource_path,
		" warp id=", asset.warp.get_instance_id(), " path=", asset.warp.resource_path)


func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


func _cleanup_output() -> void:
	for filename in ["bathymetry.res", "propagation.res", "warp.res", "coastal_bake.tres"]:
		var path: String = OUTPUT_DIR + "/" + filename
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var directory := DirAccess.open(ProjectSettings.globalize_path(OUTPUT_DIR))
	if directory != null and directory.get_files().is_empty() and directory.get_directories().is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		failures += 1
		push_error("FAIL: " + label)

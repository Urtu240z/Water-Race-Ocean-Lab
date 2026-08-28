extends SceneTree
## Validación CPU de topología clipmap: no requiere rendering ni readback GPU.

const ClipmapConfigScript := preload("res://ocean_v3/rendering/ocean_clipmap_config.gd")
const MeshBuilder := preload("res://ocean_v3/rendering/ocean_clipmap_mesh_builder.gd")

var _failures := 0


func _initialize() -> void:
	var config = ClipmapConfigScript.new()
	_check(config.is_valid(), "configuración clipmap inicial válida")
	_check(config.final_half_extent_m() >= config.horizon_distance_m, "la extensión final cubre el horizonte configurado")

	var total_triangles := 0
	for level in config.level_count:
		var geometry := MeshBuilder.build_level_geometry(config, level)
		var validation_error: String = MeshBuilder.validate_geometry(geometry)
		_check(validation_error.is_empty(), "L%d: índices, áreas y winding válidos (%s)" % [level, validation_error])
		total_triangles += int(float(geometry.indices.size()) / 3.0)
		if level > 0:
			_check(is_equal_approx(config.spacing_for_level(level), config.spacing_for_level(level - 1) * 2.0), "L%d: spacing duplica" % level)
			_check(is_equal_approx(config.outer_width_for_level(level), config.outer_width_for_level(level - 1) * 2.0), "L%d: anchura duplica" % level)
			_check(is_equal_approx(config.inner_width_for_level(level), config.outer_width_for_level(level - 1)), "L%d: hueco coincide con nivel anterior" % level)
			_validate_stitch_positions(config, level, geometry)

	print("INFO: clipmap %d niveles, %d triángulos, semiextensión %.0f m" % [config.level_count, total_triangles, config.final_half_extent_m()])
	_check(total_triangles > 100000 and total_triangles < 1000000, "presupuesto geométrico de cientos de miles de triángulos")
	_validate_world_anchoring()
	_validate_module_api()

	if _failures == 0:
		print("PHASE_1C_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_1C_VALIDATION: %d fallos" % _failures)
		quit(1)


func _validate_stitch_positions(config: Resource, level: int, geometry: Dictionary) -> void:
	var stitch_positions: PackedVector3Array = geometry.stitch_inner_positions
	var stitch_lookup := {}
	for position in stitch_positions:
		stitch_lookup[_position_key(position)] = true
	var all_boundary_positions_match := true
	for fine_boundary_position in MeshBuilder.outer_boundary_positions(config, level - 1):
		if not stitch_lookup.has(_position_key(fine_boundary_position)):
			all_boundary_positions_match = false
			break
	_check(all_boundary_positions_match, "L%d: borde fino coincide con stitch" % level)
	var half_extent: float = config.inner_width_for_level(level) * 0.5
	var all_corners_match := true
	for corner in [Vector3(-half_extent, 0.0, -half_extent), Vector3(half_extent, 0.0, -half_extent), Vector3(-half_extent, 0.0, half_extent), Vector3(half_extent, 0.0, half_extent)]:
		if not stitch_lookup.has(_position_key(corner)):
			all_corners_match = false
	_check(all_corners_match, "L%d: esquinas stitch cerradas" % level)


func _validate_world_anchoring() -> void:
	var shader_file := FileAccess.open("res://ocean_v3/rendering/shaders/ocean_surface.gdshader", FileAccess.READ)
	var shader_source := shader_file.get_as_text() if shader_file != null else ""
	_check(shader_source.contains("MODEL_MATRIX * vec4(VERTEX, 1.0)"), "shader calcula UV desde posición mundial")
	_check(not shader_source.contains("VERTEX.xz / domain"), "shader no ancla UV a coordenadas locales")
	_check(shader_source.contains("uniform float lod_morph_ratio"), "shader expone lod_morph_ratio")
	_check(shader_source.contains("instance uniform float clipmap_next_spacing_m"), "shader recibe spacing del siguiente LOD")
	_check(shader_source.contains("instance uniform float clipmap_inner_extent_m"), "shader recibe extensión interior para stitching")
	_check(shader_source.contains("clipmap_origin_xz"), "morph usa el origen estable del clipmap")
	_check(shader_source.contains("clipmap_lod_morph_factor"), "shader calcula lod_alpha")
	_check(shader_source.contains("floor(clipmap_local_xz / coarse_spacing"), "coarse grid se cuantiza en clipmap-space")


func _validate_module_api() -> void:
	var module_file := FileAccess.open("res://ocean_v3/open_ocean_fft_module.gd", FileAccess.READ)
	var module_source := module_file.get_as_text() if module_file != null else ""
	_check(module_source.contains("func toggle_enabled"), "API ON/OFF preservada")
	_check(module_source.contains("func cycle_band_debug"), "API de bandas preservada")
	_check(module_source.contains("func cycle_debug_mode"), "API de superficie preservada")


func _position_key(position: Vector3) -> String:
	return "%d:%d" % [roundi(position.x * 1000.0), roundi(position.z * 1000.0)]


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

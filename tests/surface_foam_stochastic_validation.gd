extends SceneTree
## Source-contract validation for deterministic stochastic Surface Foam sampling.
## Run: Godot --headless --path . --script res://tests/surface_foam_stochastic_validation.gd

var _failures: Array[String] = []


func _init() -> void:
	var shader := _read("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var root := _read("res://ocean_v3/ocean_v3.gd")
	_validate_stochastic_shader(shader)
	_validate_root_controls(root)
	if _failures.is_empty():
		print("PASS: stochastic Surface Foam deperiodization")
		quit(0)
	for failure in _failures:
		push_error(failure)
	quit(1)


func _validate_stochastic_shader(shader: String) -> void:
	_check(shader.contains("surface_foam_stochastic_deperiodization_enabled = true"), "stochastic deperiodization defaults on")
	_check(shader.contains("surface_foam_stochastic_cell_size_m") and shader.contains("= 32.0"), "32 m stochastic cell default")
	_check(shader.contains("void surface_foam_stochastic_triangle"), "triangular lattice exists")
	_check(shader.contains("surface_foam_stochastic_hash12"), "deterministic mathematical hash exists")
	_check(shader.contains("void surface_foam_shared_direct_topologies"), "Surface Foam and Crest Filigree share one Direct-J topology pass")
	_check(shader.contains("float j0 = surface_foam_direct_j_at") and shader.contains("float j1 = surface_foam_direct_j_at") and shader.contains("float j2 = surface_foam_direct_j_at"), "three Direct-J samples are fetched once")
	_check(shader.contains("float surface_raw0 = max(0.0, surface_foam_whitecap - j0)") and shader.contains("float crest_raw0 = max(0.0, crest_filigree_whitecap - j0)"), "each consumer thresholds the same J sample independently")
	_check(shader.contains("surface_raw = surface_raw0 * weights.x + surface_raw1 * weights.y + surface_raw2 * weights.z;") and shader.contains("crest_raw = crest_raw0 * weights.x + crest_raw1 * weights.y + crest_raw2 * weights.z;"), "both raw topologies compose only after threshold")
	_check(shader.contains("float jacobian = surface_foam_direct_j_at(world_xz);") and shader.contains("crest_raw = max(0.0, crest_filigree_whitecap - jacobian);"), "periodic fallback shares one Direct-J sample")
	_check(shader.contains("crest_filigree_source = crest_filigree_source_from_macro(crest_filigree_macro);"), "Crest source uses the Crest whitecap topology")
	_check(shader.contains("vec2 field0 = textureLod") and shader.contains("vec2 field1 = textureLod") and shader.contains("vec2 field2 = textureLod"), "history envelope also samples stochastically")
	_check(not shader.contains("surface_foam_direct_warp_a") and not shader.contains("surface_foam_direct_sample_position_b") and not shader.contains("surface_foam_direct_selector"), "legacy A/B mechanism removed")
	var stochastic_section := shader.substr(shader.find("float surface_foam_stochastic_hash12"), shader.find("float surface_foam_macro_from_topology") - shader.find("float surface_foam_stochastic_hash12"))
	_check(not stochastic_section.contains("TIME"), "stochastic mapping has no temporal seed")


func _validate_root_controls(root: String) -> void:
	_check(root.contains("@export var surface_foam_stochastic_deperiodization_enabled: bool = true"), "root exposes stochastic toggle")
	_check(root.contains("@export_range(16.0, 96.0, 0.5) var surface_foam_stochastic_cell_size_m: float = 32.0"), "root exposes 16-96 m cell size")
	_check(root.contains("@export_range(0.0, 1.5, 0.01) var crest_filigree_whitecap: float = 0.0"), "root exposes independent Crest Filigree whitecap")
	_check(root.contains("set_shader_parameter(&\"crest_filigree_whitecap\", crest_filigree_whitecap)"), "Crest Filigree whitecap syncs live")
	_check(root.contains("@export_range(4.0, 32.0, 0.5) var surface_foam_source_domain_m: float = 8.0"), "source domain remains 8 m")


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append("Could not open %s" % path)
		return ""
	return file.get_as_text()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

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
	_check(shader.contains("float raw0 = surface_foam_direct_j_raw_at") and shader.contains("float raw1 = surface_foam_direct_j_raw_at") and shader.contains("float raw2 = surface_foam_direct_j_raw_at"), "three Direct-J samples threshold independently")
	_check(shader.contains("return raw0 * weights.x + raw1 * weights.y + raw2 * weights.z;"), "raw samples compose only after threshold")
	_check(shader.contains("vec2 field0 = textureLod") and shader.contains("vec2 field1 = textureLod") and shader.contains("vec2 field2 = textureLod"), "history envelope also samples stochastically")
	_check(shader.contains("? surface_foam_stochastic_direct_raw(world_xz)\n\t\t: surface_foam_direct_j_raw_at(world_xz);"), "toggle falls back to original periodic Direct-J")
	_check(not shader.contains("surface_foam_direct_warp_a") and not shader.contains("surface_foam_direct_sample_position_b") and not shader.contains("surface_foam_direct_selector"), "legacy A/B mechanism removed")
	var stochastic_section := shader.substr(shader.find("float surface_foam_stochastic_hash12"), shader.find("float surface_foam_macro_from_topology") - shader.find("float surface_foam_stochastic_hash12"))
	_check(not stochastic_section.contains("TIME"), "stochastic mapping has no temporal seed")


func _validate_root_controls(root: String) -> void:
	_check(root.contains("@export var surface_foam_stochastic_deperiodization_enabled: bool = true"), "root exposes stochastic toggle")
	_check(root.contains("@export_range(16.0, 96.0, 0.5) var surface_foam_stochastic_cell_size_m: float = 32.0"), "root exposes 16-96 m cell size")
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

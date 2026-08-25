extends SceneTree
## CPU/source-contract validation for Surface Foam visibility vs technical topology.
## Run: Godot --headless --path . --script res://tests/crest_filigree_topology_validation.gd

var _failures: Array[String] = []


func _init() -> void:
	_validate_solver_enable_policy()
	_validate_shader_contract()
	if _failures.is_empty():
		print("PASS: crest filigree topology decoupling")
		quit(0)
	for failure in _failures:
		push_error(failure)
	quit(1)


func _validate_solver_enable_policy() -> void:
	var surface_solver := SurfaceFoamSpectrumSolver.new()
	var history_solver := SurfaceFoamMidHistorySolver.new()
	for case_data in [
		["A", true, true, true],
		["B", false, true, true],
		["C", true, false, true],
		["D", false, false, false],
	]:
		var label: String = case_data[0]
		var surface_visible: bool = case_data[1]
		var filigree_visible: bool = case_data[2]
		var required: bool = case_data[3]
		var topology_required := surface_visible or filigree_visible
		_check(topology_required == required, "%s technical topology requirement" % label)
		surface_solver.set_settings(topology_required, 0.0, 1.0, 30.0)
		history_solver.set_settings(topology_required, 30.0, 0.16, 1.1, 0.10, 0.24)
		_check(surface_solver.get("_enabled") == required, "%s Surface Foam solver state" % label)
		_check(history_solver.get("_enabled") == required, "%s MID history solver state" % label)


func _validate_shader_contract() -> void:
	var shader := _read("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var module := _read("res://ocean_v3/open_ocean_fft_module.gd")
	var root := _read("res://ocean_v3/ocean_v3.gd")
	_check(shader.contains("if (foam_enabled && (surface_foam_enabled || crest_filigree_enabled))"), "shared topology evaluates for either consumer")
	_check(shader.contains("if (crest_filigree_enabled) {"), "filigree no longer requires Surface Foam visibility")
	_check(not shader.contains("crest_filigree_enabled && surface_foam_enabled"), "legacy filigree visibility gate removed")
	_check(not shader.contains("if (!surface_foam_enabled) {\n\t\treturn vec2(0.0);"), "technical history read is visibility-independent")
	_check(module.contains("var _surface_foam_topology_required := true"), "module stores explicit topology requirement")
	_check(module.contains("_surface_foam_topology_required, _surface_foam_whitecap"), "surface solver receives topology requirement")
	_check(module.contains("_surface_foam_topology_required,\n\t\t_surface_foam_update_hz"), "MID history receives topology requirement")
	_check(root.contains("surface_foam_enabled or crest_filigree_enabled"), "root synchronizes both visibility controls")


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures.append("Could not open %s" % path)
		return ""
	return file.get_as_text()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

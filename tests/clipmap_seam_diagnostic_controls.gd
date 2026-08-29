extends SceneTree
## X2.1B: valida la exposición runtime del diagnóstico de seams desde Lab Main.
## El test usa la misma ruta pública que la combinación Ctrl+L del laboratorio.

var _frame := 0
var _failures := 0
var _lab_main: Node
var _ocean_v3: Node
var _surface: Node
var _controls_label: Label
var _meshes_before: Array[Mesh] = []
var _transforms_before: Array[Transform3D] = []
var _clipmap_levels_before: Array[float] = []


func _initialize() -> void:
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 5:
		if not _prepare_runtime_nodes():
			push_error("CLIPMAP_SEAM_DIAGNOSTIC_CONTROLS: faltan nodos de Lab Main")
			quit(1)
			return false
		_validate_controls()
	if _frame == 10:
		if _failures == 0:
			print("CLIPMAP_SEAM_DIAGNOSTIC_CONTROLS: PASS")
			quit(0)
		else:
			push_error("CLIPMAP_SEAM_DIAGNOSTIC_CONTROLS: %d fallos" % _failures)
			quit(1)
	return false


func _prepare_runtime_nodes() -> bool:
	_lab_main = current_scene
	if _lab_main == null:
		return false
	_ocean_v3 = _lab_main.get_node_or_null(^"OceanV3Mount/OceanV3") as Node
	var fft_module := get_first_node_in_group(&"ocean_fft")
	_surface = fft_module.get_node_or_null(^"OceanClipmapSurface") as Node if fft_module != null else null
	_controls_label = _lab_main.get_node_or_null(^"BenchmarkHUD/Controls") as Label
	return _ocean_v3 != null and _surface != null and _controls_label != null


func _validate_controls() -> void:
	_surface.set_clipmap_flat_geometry_debug(false)
	_surface.set_clipmap_displaced_unlit_debug(false)
	_surface.set_clipmap_true_opaque_flat_debug(false)
	_surface.set_clipmap_tracking_debug_mode(3)
	_surface._process(0.0)
	var tracking_before: String = _ocean_v3.clipmap_tracking_debug_mode_name()
	var material: ShaderMaterial = _surface.call("get_surface_material") as ShaderMaterial
	var lod_before: bool = bool(material.get_shader_parameter(&"clipmap_lod_debug"))
	var levels_before: Array = _surface.get("_levels")
	for level in levels_before:
		var instance := level as MeshInstance3D
		_meshes_before.append(instance.mesh)
		_transforms_before.append(instance.global_transform)
		_clipmap_levels_before.append(float(instance.get_instance_shader_parameter(&"clipmap_level")))
	_check(levels_before.size() == 10, "PER_LEVEL_SNAPPED conserva una instancia por nivel")
	_check(_ocean_v3.clipmap_diagnostic_mode_name() == "OFF", "estado inicial OFF")

	_send_ctrl_l()
	_check_diagnostic("FLAT GEOMETRY", "Ctrl+L activa FLAT")
	_check(_controls_label.text.contains("Clipmap Seam Debug: FLAT GEOMETRY"), "HUD muestra FLAT GEOMETRY")

	_send_ctrl_l()
	_check_diagnostic("DISPLACED UNLIT", "Ctrl+L activa DISPLACED UNLIT")
	_check(_controls_label.text.contains("Clipmap Seam Debug: DISPLACED UNLIT"), "HUD muestra DISPLACED UNLIT")

	_send_ctrl_l()
	_check_diagnostic("TRUE OPAQUE FLAT", "Ctrl+L activa TRUE OPAQUE FLAT")
	_check(_controls_label.text.contains("Clipmap Seam Debug: TRUE OPAQUE FLAT"), "HUD muestra TRUE OPAQUE FLAT")
	_check_opaque_material_active()

	_send_ctrl_l()
	_check_diagnostic("OFF", "Ctrl+L devuelve a OFF")
	_check(_controls_label.text.contains("Clipmap Seam Debug: OFF"), "HUD muestra OFF")
	_check_opaque_material_restored(material)

	# Bare L remains the existing LOD control and does not alter seam mode.
	_send_key(KEY_L)
	_check(bool(material.get_shader_parameter(&"clipmap_lod_debug")) != lod_before, "L sin Ctrl conserva el control LOD")
	_check_diagnostic("OFF", "L sin Ctrl no cambia seam diagnostic")
	_send_key(KEY_L)
	_check(bool(material.get_shader_parameter(&"clipmap_lod_debug")) == lod_before, "L restaura el estado LOD original")
	_check(_ocean_v3.clipmap_tracking_debug_mode_name() == tracking_before, "PER_LEVEL_SNAPPED permanece activo")


func _send_ctrl_l() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_L
	event.pressed = true
	event.ctrl_pressed = true
	_lab_main.call("_unhandled_input", event)


func _send_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	_lab_main.call("_unhandled_input", event)


func _check_diagnostic(expected: String, label: String) -> void:
	var material: ShaderMaterial = _surface.call("get_surface_material") as ShaderMaterial
	var flat := bool(material.get_shader_parameter(&"clipmap_flat_geometry_debug"))
	var displaced := bool(material.get_shader_parameter(&"clipmap_displaced_unlit_debug"))
	_check(_ocean_v3.clipmap_diagnostic_mode_name() == expected, label + ": API root")
	_check(flat == (expected == "FLAT GEOMETRY"), label + ": sólo uniform FLAT")
	_check(displaced == (expected == "DISPLACED UNLIT"), label + ": sólo uniform DISPLACED")
	_check(not (flat and displaced), label + ": uniforms mutuamente excluyentes")
	_check(bool(_surface.get("_true_opaque_flat_debug")) == (expected == "TRUE OPAQUE FLAT"), label + ": estado TRUE OPAQUE coherente")


func _check_opaque_material_active() -> void:
	var levels: Array = _surface.get("_levels")
	_check(levels.size() == _meshes_before.size(), "TRUE OPAQUE no reconstruye niveles")
	var first_material: ShaderMaterial
	for index in levels.size():
		var level = levels[index]
		var instance := level as MeshInstance3D
		_check(instance.mesh == _meshes_before[index], "TRUE OPAQUE conserva meshes")
		_check(instance.global_transform == _transforms_before[index], "TRUE OPAQUE conserva transforms")
		_check(is_equal_approx(float(instance.get_instance_shader_parameter(&"clipmap_level")), _clipmap_levels_before[index]), "TRUE OPAQUE conserva clipmap_level")
		var material := instance.material_override as ShaderMaterial
		_check(material != null, "TRUE OPAQUE usa material override")
		if material == null:
			continue
		if first_material == null:
			first_material = material
		_check(material == first_material, "TRUE OPAQUE usa un material común")
		var shader := material.shader
		_check(shader != null and shader.resource_path.ends_with("ocean_clipmap_opaque_debug.gdshader"), "TRUE OPAQUE usa shader opaco dedicado")
		if shader == null:
			continue
		var code := shader.code
		_check(code.contains("shader_type spatial"), "shader opaco es spatial")
		_check(code.contains("unshaded") and code.contains("depth_draw_opaque"), "shader opaco es unshaded y opaque")
		_check(code.contains("ALBEDO") and not code.contains("ALPHA"), "shader opaco no escribe alpha")
		_check(not code.contains("screen_texture") and not code.contains("depth_texture"), "shader opaco no depende de screen/depth textures")


func _check_opaque_material_restored(production_material: ShaderMaterial) -> void:
	var levels: Array = _surface.get("_levels")
	for level in levels:
		var instance := level as MeshInstance3D
		_check(instance.material_override == production_material, "OFF restaura material de producción")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

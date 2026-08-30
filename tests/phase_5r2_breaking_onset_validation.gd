extends SceneTree
## STEP 2 contract validation. It exercises the bounded union mathematically and
## checks that the shader's OPEN_BREAK path remains independent from Coastal.

var _failures := 0


func _initialize() -> void:
	_validate_shader_contract()
	_validate_open_water_cases()
	_validate_depth_union()
	if _failures == 0:
		print("PHASE_5R2_BREAKING_ONSET: PASS")
		quit(0)
	else:
		push_error("PHASE_5R2_BREAKING_ONSET: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	var include_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc")
	var surface_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var clipmap_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/ocean_clipmap_surface.gd")
	var open_start := include_source.find("vec2 open_break_components_at")
	var open_end := include_source.find("float open_break_at", open_start)
	var open_body := include_source.substr(open_start, open_end - open_start)
	_check(open_start >= 0 and open_body.contains("long_height_at") and open_body.contains("mid_height_at"), "OPEN_BREAK usa estado FFT LONG + MID")
	_check(not open_body.contains("displacement_short") and not open_body.contains("short_height"), "SHORT no participa en OPEN_BREAK")
	_check(include_source.contains("if (!has_coastal_data(coast_uv, field_data)) return vec4(0.0);") and include_source.contains("float depth_break_at"), "DEPTH_BREAK es cero fuera de Coastal válido")
	_check(include_source.contains("vec3 breaking_onset_signals_at") and include_source.contains("open_break + depth_break - open_break * depth_break"), "BREAK_ONSET usa unión acotada")
	_check(surface_source.contains("breaking_debug_mode == 5") and surface_source.contains("breaking_debug_mode == 6") and surface_source.contains("breaking_debug_mode == 7"), "shader expone OPEN_BREAK, DEPTH_BREAK y BREAK_ONSET")
	_check(clipmap_source.contains("OPEN_BREAK") and clipmap_source.contains("BREAK_ONSET"), "API de debug del clipmap expone los nuevos modos")


func _validate_open_water_cases() -> void:
	var calm := _open_union(0.0, 0.0)
	var long_only := _open_union(0.82, 0.0)
	var mid_only := _open_union(0.0, 0.78)
	var reinforced := _open_union(0.55, 0.65)
	print("5R2 OPEN calm=%.3f long=%.3f mid=%.3f reinforced=%.3f" % [calm, long_only, mid_only, reinforced])
	_check(calm == 0.0, "crestas LONG/MID débiles permanecen estables")
	_check(long_only > 0.8, "LONG inestable puede producir OPEN_BREAK")
	_check(mid_only > 0.7, "MID inestable modifica materialmente OPEN_BREAK")
	_check(reinforced > maxf(0.55, 0.65) and reinforced <= 1.0, "LONG+MID se refuerzan sin superar 1")


func _validate_depth_union() -> void:
	var offshore_open := _onset(0.72, 0.0)
	var coastal_depth := _onset(0.0, 0.81)
	var both := _onset(0.72, 0.81)
	print("5R2 ONSET offshore=%.3f coastal=%.3f both=%.3f" % [offshore_open, coastal_depth, both])
	_check(offshore_open > 0.0, "Coastal desactivado no fuerza OPEN_BREAK a cero")
	_check(coastal_depth > 0.0, "DEPTH_BREAK puede activar onset independientemente")
	_check(both <= 1.0 and both > maxf(offshore_open, coastal_depth), "unión OPEN+DEPTH es monótona y acotada")


func _open_union(long_signal: float, mid_signal: float) -> float:
	return long_signal + mid_signal - long_signal * mid_signal


func _onset(open_break: float, depth_break: float) -> float:
	return _open_union(open_break, depth_break)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

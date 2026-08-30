extends SceneTree
## STEP 3 contract validation. The numeric cases exercise the deterministic
## parent-scale normalisation independently from GPU texture availability.

var _failures := 0


func _initialize() -> void:
	_validate_shader_contract()
	_validate_strength_cases()
	_validate_attribution_cases()
	if _failures == 0:
		print("PHASE_5R3_PARENT_STRENGTH: PASS")
		quit(0)
	else:
		push_error("PHASE_5R3_PARENT_STRENGTH: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	var include_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc")
	var surface_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var clipmap_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/ocean_clipmap_surface.gd")
	var descriptor_start := include_source.find("void parent_crest_descriptor_at")
	var descriptor_end := include_source.find("float break_strength_from_parent", descriptor_start)
	var descriptor_body := include_source.substr(descriptor_start, descriptor_end - descriptor_start)
	_check(descriptor_start >= 0 and descriptor_body.contains("long_height_at") and descriptor_body.contains("mid_height_at"), "descriptor usa geometría FFT LONG + MID")
	_check(descriptor_body.contains("effective_height_m = 2.0 * crest_scale_m") and descriptor_body.contains("effective_wavelength_m"), "descriptor expone escala, altura y longitud de onda físicas")
	_check(not descriptor_body.contains("displacement_short") and not descriptor_body.contains("depth_break_at"), "SHORT y profundidad no inventan el parent descriptor")
	_check(include_source.contains("return clamp(onset * parent_scale_capacity"), "BREAK_STRENGTH se gatea por onset")
	_check(surface_source.contains("breaking_debug_mode == 8") and surface_source.contains("breaking_debug_mode == 9") and surface_source.contains("band_attribution_debug"), "shader expone fuerza, altura y atribución")
	_check(clipmap_source.contains("BREAK_STRENGTH") and clipmap_source.contains("BAND_ATTRIBUTION"), "API de debug del clipmap expone Step 3")


func _validate_strength_cases() -> void:
	var small_high_onset := _break_strength(0.92, 0.20, 5.0, 0.20)
	var large_high_onset := _break_strength(0.92, 1.30, 40.0, 0.28)
	var stable_large := _break_strength(0.0, 1.80, 55.0, 0.30)
	print("5R3 strength small=%.3f large=%.3f stable=%.3f" % [small_high_onset, large_high_onset, stable_large])
	_check(small_high_onset < 0.20, "cresta pequeña con onset alto no obtiene fuerza grande")
	_check(large_high_onset > 0.70 and large_high_onset > small_high_onset, "cresta grande e inestable domina BREAK_STRENGTH")
	_check(is_zero_approx(stable_large), "ola grande estable conserva fuerza nula sin onset")


func _validate_attribution_cases() -> void:
	var long_only := _attribution(0.90, 0.00)
	var mid_only := _attribution(0.00, 0.65)
	var mixed := _attribution(0.80, 0.40)
	_check(long_only.x > 0.999 and long_only.y < 0.001, "caso LONG dominante mantiene atribución LONG")
	_check(mid_only.y > 0.999 and mid_only.x < 0.001, "caso MID dominante mantiene atribución MID")
	_check(mixed.x > mixed.y and is_equal_approx(mixed.x + mixed.y, 1.0), "mezcla LONG+MID es continua y normalizada")


func _break_strength(onset: float, height_m: float, wavelength_m: float, steepness: float) -> float:
	var height_capacity := smoothstep(0.10, 1.25, height_m)
	var wavelength_capacity := smoothstep(3.0, 32.0, wavelength_m)
	var steepness_capacity := smoothstep(0.08, 0.30, steepness)
	var parent_scale_capacity := sqrt(maxf(height_capacity * wavelength_capacity, 0.0))
	return clampf(onset * parent_scale_capacity * lerpf(0.60, 1.0, steepness_capacity), 0.0, 1.0)


func _attribution(long_support: float, mid_support: float) -> Vector2:
	var total := long_support + mid_support
	return Vector2(long_support, mid_support) / total if total > 0.0001 else Vector2(0.5, 0.5)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

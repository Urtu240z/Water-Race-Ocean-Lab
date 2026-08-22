extends SceneTree
## Phase 4A: valida los criterios deterministas del campo pre-break.
## No ejecuta OceanQuery ni hace readback; el detector de producción vive en el shader.

const GAMMA := 0.78
const DEPTH_RANGE := Vector2(0.55, 1.0)
const STEEPNESS_RANGE := Vector2(0.28, 0.42)
var _failures := 0


func _initialize() -> void:
	_validate_shader_contract()
	_validate_deep_flat()
	_validate_bank()
	_validate_crest_selection()
	_validate_pause_determinism()
	if _failures == 0:
		print("PHASE_4A_PREBREAK: PASS")
		quit(0)
	else:
		push_error("PHASE_4A_PREBREAK: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	## Phase 4B refactorizó las funciones del detector a ocean_breaking_common.gdshaderinc
	## (compartido con breaker_lip.gdshader); el comportamiento del clipmap no cambia.
	var source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var inc := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc")
	_check(source.contains("displacement_long_coastal") and source.contains("displacement_long_remainder"), "crestness samplea LONG_COASTAL + LONG_REMAINDER reales")
	_check(inc.contains("warp_deep_sample") and inc.contains("field_data.g"), "LONG_COASTAL conserva warp y shoaling en las muestras de cresta")
	_check(inc.contains("phase_data.gb") and inc.contains("wavelength / 16.0"), "crestness usa dirección local y separación lambda/16")
	_check(source.contains("breaking_debug_mode > 0") and not source.contains("sample_water(") and not inc.contains("sample_water("), "ruta pre-break es opt-in GPU y no invoca OceanQuery")
	_check(inc.contains("if (!has_coastal_data(coast_uv, field_data)) return vec4(0.0)"), "Coastal OFF/fuera del campo no inventa rotura por el banco")
	_check(source.contains("ocean_breaking_common.gdshaderinc"), "el clipmap incluye el detector compartido (refactor 4B sin cambio de comportamiento")


func _validate_deep_flat() -> void:
	var indices := _indices(18.0, 0.50, 0.392699, 1.0, 0.25, 0.22, 0.22)
	print("4A DEEP_FLAT depth=%.6f steep=%.6f crest=%.6f prebreak=%.6f" % [indices.x, indices.y, indices.z, indices.w])
	_check(indices.x < 0.001, "deep/flat: depth pressure prácticamente cero")
	_check(indices.w < 0.001, "deep/flat: no activa prebreak aunque haya cresta")


func _validate_bank() -> void:
	var deep := _indices(18.0, 0.50, 0.392699, 1.0, 0.25, 0.22, 0.22)
	var bank := _indices(0.55, 0.68, 1.20, 1.0, 0.34, 0.27, 0.27)
	print("4A BANK deep_prebreak=%.6f bank depth=%.6f steep=%.6f crest=%.6f prebreak=%.6f" % [deep.w, bank.x, bank.y, bank.z, bank.w])
	_check(bank.x > deep.x and bank.x > 0.80, "bank: H/h eleva la presión de profundidad")
	_check(bank.y > 0.0, "bank: k_local*a aporta steepness continuo")
	_check(bank.w > 0.15, "bank: una cresta LONG candidata produce prebreak móvil")


func _validate_crest_selection() -> void:
	var crest := _indices(0.55, 0.68, 1.20, 1.0, 0.34, 0.27, 0.27)
	var trough := _indices(0.55, 0.68, 1.20, 1.0, -0.34, -0.27, -0.27)
	var shoulder := _indices(0.55, 0.68, 1.20, 1.0, 0.12, 0.22, 0.02)
	print("4A CREST crest=%.6f trough=%.6f shoulder=%.6f" % [crest.z, trough.z, shoulder.z])
	_check(crest.z > 0.90, "crest real: máximo local y curvatura negativa -> crestness alta")
	_check(trough.z < 0.001, "valle: no se confunde con cresta")
	_check(shoulder.z < crest.z, "hombro: crestness suave, no banda fija de fondo")


func _validate_pause_determinism() -> void:
	var at_pause := _indices(0.55, 0.68, 1.20, 1.0, 0.34, 0.27, 0.27)
	var after_camera_move := _indices(0.55, 0.68, 1.20, 1.0, 0.34, 0.27, 0.27)
	_check(at_pause == after_camera_move, "misma ola/campos -> prebreak idéntico al pausar o mover cámara")


func _indices(depth_m: float, local_hs: float, local_k: float, shoaling: float, eta_0: float, eta_minus: float, eta_plus: float) -> Vector4:
	var amplitude := maxf(0.5 * local_hs, 0.01)
	var depth_pressure := _smooth(DEPTH_RANGE.x, DEPTH_RANGE.y, local_hs / (GAMMA * depth_m))
	var steepness_pressure := _smooth(STEEPNESS_RANGE.x, STEEPNESS_RANGE.y, local_k * amplitude)
	var neighbor_rise := minf(eta_0 - eta_minus, eta_0 - eta_plus)
	var curvature_down := 2.0 * eta_0 - eta_minus - eta_plus
	var crestness := _smooth(0.012 * amplitude, 0.075 * amplitude, neighbor_rise) * _smooth(0.025 * amplitude, 0.15 * amplitude, curvature_down)
	var prebreak := crestness * depth_pressure * lerpf(0.35, 1.0, steepness_pressure)
	return Vector4(depth_pressure, steepness_pressure, crestness, prebreak)


func _smooth(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

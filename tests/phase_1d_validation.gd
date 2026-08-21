extends SceneTree
## Validación de Fase 1D: sea states CALM/RACE/ROUGH, determinismo y
## separación con OceanQualitySettings. No realiza readback GPU.
##
## Cubre los puntos A–M de la especificación de Fase 1D. La parte CPU se
## ejecuta en _initialize; el cambio de preset en runtime (L) se comprueba
## sobre la escena real una vez instanciada.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QualityScript := preload("res://ocean_v3/core/ocean_quality_settings.gd")

const _BAND_IDS: Array[StringName] = [&"LONG", &"MID", &"SHORT"]
const _SEED := 20260820

var _failures := 0
var _frame := 0
var _runtime_checked := false


func _initialize() -> void:
	_validate_identity()
	_validate_band_parameters()
	_validate_combined_hs()
	_validate_determinism()
	_validate_distinct_states()
	_validate_quality_independence()
	_validate_module_source()
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3 and not _runtime_checked:
		_runtime_checked = true
		_validate_runtime_preset_switch()
		_finish()
	return false


# A. enum/identidad de los tres sea states.
func _validate_identity() -> void:
	_check(SeaStateScript.State.CALM == 0, "A: CALM es el estado 0")
	_check(SeaStateScript.State.RACE == 1, "A: RACE es el estado 1")
	_check(SeaStateScript.State.ROUGH == 2, "A: ROUGH es el estado 2")
	_check(SeaStateScript.is_valid_state(0) and SeaStateScript.is_valid_state(1) and SeaStateScript.is_valid_state(2), "A: los tres estados son válidos")
	_check(not SeaStateScript.is_valid_state(3) and not SeaStateScript.is_valid_state(-1), "A: los estados fuera de rango no son válidos")
	_check(SeaStateScript.state_name(0) == "CALM", "A: nombre CALM")
	_check(SeaStateScript.state_name(1) == "RACE", "A: nombre RACE")
	_check(SeaStateScript.state_name(2) == "ROUGH", "A: nombre ROUGH")


# B/C/I/J/K. Hs por banda y combinada.
func _validate_band_parameters() -> void:
	var expected := {
		SeaStateScript.State.CALM: [0.18, 0.12, 0.05],
		SeaStateScript.State.RACE: [0.50, 0.38, 0.15],
		SeaStateScript.State.ROUGH: [0.85, 0.65, 0.30],
	}
	for state in [SeaStateScript.State.CALM, SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var configs: Array[OpenOceanFFTConfig] = SeaStateScript.build_cascades(state)
		_check(configs.size() == 3, "B: %s produce tres cascadas" % state_name)
		var variance := 0.0
		for index in 3:
			var config := configs[index]
			_check(config.id == _BAND_IDS[index], "B: %s banda %s en orden" % [state_name, _BAND_IDS[index]])
			_check(is_equal_approx(config.target_hs_m, expected[state][index]), "B: %s/%s Hs %.2f m" % [state_name, _BAND_IDS[index], expected[state][index]])
			_check(config.is_valid(), "B: %s/%s configuración válida" % [state_name, _BAND_IDS[index]])
			variance += config.target_hs_m * config.target_hs_m
		_check(is_equal_approx(sqrt(variance), SeaStateScript.target_combined_hs_m(state)), "C: %s Hs combinada coherente" % state_name)


func _validate_combined_hs() -> void:
	var calm_hs := SeaStateScript.target_combined_hs_m(SeaStateScript.State.CALM)
	var race_hs := SeaStateScript.target_combined_hs_m(SeaStateScript.State.RACE)
	var rough_hs := SeaStateScript.target_combined_hs_m(SeaStateScript.State.ROUGH)
	_check(_within(calm_hs, 0.22, 0.005), "I: CALM total ≈ 0.22 m (%.3f)" % calm_hs)
	_check(_within(race_hs, 0.65, 0.005), "J: RACE total ≈ 0.65 m (%.3f)" % race_hs)
	_check(_within(rough_hs, 1.11, 0.005), "K: ROUGH total ≈ 1.11 m (%.3f)" % rough_hs)
	_check(race_hs >= 0.4 and race_hs <= 0.8, "J: RACE dentro del rango físico 0.4–0.8 m")


# D/E. Determinismo por seed y por estado.
func _validate_determinism() -> void:
	for state in [SeaStateScript.State.CALM, SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var first := _build_state_h0(state, _SEED)
		var repeated := _build_state_h0(state, _SEED)
		var other_seed := _build_state_h0(state, _SEED + 1)
		for index in 3:
			_check(first[index] == repeated[index], "D/E: %s/%s mismo estado+seed = mismo H0" % [state_name, _BAND_IDS[index]])
			_check(first[index] != other_seed[index], "D: %s/%s otra seed = otro H0" % [state_name, _BAND_IDS[index]])


# F. Estados distintos = configuración distinta.
func _validate_distinct_states() -> void:
	var calm := SeaStateScript.build_cascades(SeaStateScript.State.CALM)
	var race := SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	var rough := SeaStateScript.build_cascades(SeaStateScript.State.ROUGH)
	_check(_configs_differ(calm, race), "F: CALM y RACE difieren")
	_check(_configs_differ(race, rough), "F: RACE y ROUGH difieren")
	_check(_configs_differ(calm, rough), "F: CALM y ROUGH difieren")


# G/H. Separación con OceanQualitySettings.
func _validate_quality_independence() -> void:
	var quality := QualityScript.new()
	quality.set_profile(QualityScript.Profile.STANDARD)
	var profile_before: int = quality.active_profile
	SeaStateScript.build_cascades(SeaStateScript.State.CALM)
	SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	SeaStateScript.build_cascades(SeaStateScript.State.ROUGH)
	_check(quality.active_profile == profile_before, "G: construir sea states no altera OceanQualitySettings")

	var race_base := SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	quality.set_profile(QualityScript.Profile.DECK)
	var race_deck := SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	quality.set_profile(QualityScript.Profile.DEV_HIGH)
	var race_high := SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	_check(not _configs_differ(race_base, race_deck) and not _configs_differ(race_deck, race_high), "H: los perfiles de calidad no alteran los parámetros macro del sea state")
	quality.free()


# L/M (inspección de código). El cambio de preset no registra módulos nuevos y
# no hay readback por frame.
func _validate_module_source() -> void:
	var module_source := _read_file("res://ocean_v3/open_ocean_fft_module.gd")
	_check(module_source.count(".register_module(") == 1, "L: register_module sólo se llama en _ready")
	for forbidden in ["texture_get_data", "buffer_get_data", ".sync(", "submit("]:
		_check(forbidden not in module_source, "M: el módulo no usa %s" % forbidden)
	var solver_source := _read_file("res://ocean_v3/rendering/fft/gpu_stockham_fft.gd")
	for forbidden in ["texture_get_data", "buffer_get_data", ".sync(", "submit("]:
		_check(forbidden not in solver_source, "M: el worker FFT no usa %s" % forbidden)


# L (runtime). Cambiar de preset conserva un único módulo registrado.
func _validate_runtime_preset_switch() -> void:
	var registry := root.get_node_or_null("OceanModuleRegistry")
	if registry == null:
		_check(false, "L: autoload OceanModuleRegistry no disponible")
		return
	var module := get_first_node_in_group(&"ocean_fft")
	if module == null:
		_check(false, "L: el módulo open_ocean_fft se instancia en la escena")
		return
	var before: int = registry.active_module_count()
	_check(before == 1, "L: Ocean modules == 1 antes de cambiar preset")
	module.set_sea_state(SeaStateScript.State.CALM)
	module.set_sea_state(SeaStateScript.State.RACE)
	module.set_sea_state(SeaStateScript.State.ROUGH)
	var after: int = registry.active_module_count()
	_check(after == 1, "L: cambiar de preset no crea módulos (Ocean modules sigue == 1)")
	_check(module.configs.size() == 3, "L: el módulo conserva tres cascadas tras cambiar preset")
	_check(module.sea_state_name() == "ROUGH", "L: el módulo refleja el último preset aplicado")


func _build_state_h0(state: int, simulation_seed: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for config in SeaStateScript.build_cascades(state):
		result.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id)))
	return result


func _configs_differ(a: Array[OpenOceanFFTConfig], b: Array[OpenOceanFFTConfig]) -> bool:
	for index in 3:
		if a[index].target_hs_m != b[index].target_hs_m:
			return true
		if a[index].choppiness != b[index].choppiness:
			return true
		if a[index].directional_spread != b[index].directional_spread:
			return true
		if a[index].wind_speed_mps != b[index].wind_speed_mps:
			return true
		if a[index].wind_direction != b[index].wind_direction:
			return true
	return false


func _within(value: float, target: float, tolerance: float) -> bool:
	return absf(value - target) <= tolerance


func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _finish() -> void:
	if _failures == 0:
		print("PHASE_1D_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_1D_VALIDATION: %d fallos" % _failures)
		quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

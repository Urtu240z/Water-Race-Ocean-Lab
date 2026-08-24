class_name SeaStateConfig
extends RefCounted
## Estados físicos del mar abierto: CALM / RACE / ROUGH.
##
## Esta capa es independiente de los perfiles de calidad
## (OceanQualitySettings: DECK / STANDARD / DEV_HIGH). Un estado de mar define
## la identidad macroscópica de las olas (Hs, dirección, dispersión, viento,
## choppiness). El perfil de calidad sólo decide detalle/rendimiento.
##
## Fase 1D usa estos presets como estados estáticos de laboratorio: no hay
## transición temporal CALM->ROUGH, memoria oceánica ni crecimiento del viento.
## Cambiar de estado regenera H0 inmediatamente conservando seed y tiempo.

enum State {
	CALM,
	RACE,
	ROUGH,
}

const STATE_NAMES := {
	State.CALM: "CALM",
	State.RACE: "RACE",
	State.ROUGH: "ROUGH",
}

# Los parámetros invariantes (resolución, dominio, band-pass y amortiguación)
# no cambian entre estados: sólo cambian los parámetros macro físicos.
const _BAND_IDS: Array[StringName] = [&"LONG", &"MID", &"SHORT"]


static func is_valid_state(state: int) -> bool:
	return state == State.CALM or state == State.RACE or state == State.ROUGH


static func state_name(state: int) -> String:
	return STATE_NAMES.get(state, "UNKNOWN")


static func build_cascades(state: int) -> Array[OpenOceanFFTConfig]:
	assert(is_valid_state(state), "Estado de mar no válido: %d" % state)
	var entry: Dictionary = _state_table()[state]
	var wind_speed: float = entry["wind_speed_mps"]
	var bands: Array = entry["bands"]
	var cascades: Array[OpenOceanFFTConfig] = []
	for band_index in 3:
		var band: Dictionary = bands[band_index]
		var config := OpenOceanFFTConfig.new()
		_apply_invariant(config, band_index)
		config.wind_direction = (band["wind_direction"] as Vector2).normalized()
		config.wind_speed_mps = wind_speed
		config.directional_spread = band["directional_spread"]
		config.choppiness = band["choppiness"]
		config.target_hs_m = band["target_hs_m"]
		config.foam_enabled = band["foam_enabled"]
		config.foam_whitecap = band["foam_whitecap"]
		config.foam_amount = band["foam_amount"]
		config.foam_decay = band["foam_decay"]
		config.foam_cascade_weight = band["foam_cascade_weight"]
		cascades.append(config)
	return cascades


static func target_combined_hs_m(state: int) -> float:
	assert(is_valid_state(state))
	var variance := 0.0
	for config in build_cascades(state):
		variance += config.target_hs_m * config.target_hs_m
	return sqrt(variance)


static func _apply_invariant(config: OpenOceanFFTConfig, band_index: int) -> void:
	config.id = _BAND_IDS[band_index]
	config.resolution = 256
	config.gravity_mps2 = 9.81
	config.energy = 0.00016
	match band_index:
		0:
			config.domain_size_m = 512.0
			config.min_wavelength_m = 16.0
			config.max_wavelength_m = 128.0
			config.transition_width_m = 4.0
			config.short_wave_damping_m = 0.35
			# 5R.1B JONSWAP LONG: swell coherente, peak más corto (17-36m) para
			# subir la steepness de LONG sin aumentar Hs (crest más legible).
			config.fetch_length_m = 25000.0
			config.swell = 0.8
			config.detail = 1.0
			config.jonswap_spread = 0.05
		1:
			# 137 m: no múltiplo simple de 512 (137 = primo), rompe la
			# periodicidad combinada de las tres cascadas.
			config.domain_size_m = 137.0
			config.min_wavelength_m = 4.0
			config.max_wavelength_m = 20.0
			config.transition_width_m = 0.75
			config.short_wave_damping_m = 0.35
			# 5R.1 JONSWAP MID: algo más disperso, modula la crest line.
			config.fetch_length_m = 3000.0
			config.swell = 0.45
			config.detail = 1.0
			config.jonswap_spread = 0.35
		2:
			# 37 m: no múltiplo simple de 137 ni de 512.
			config.domain_size_m = 37.0
			config.min_wavelength_m = 0.5
			config.max_wavelength_m = 5.0
			config.transition_width_m = 0.15
			config.short_wave_damping_m = 0.20
			# 5R.1 JONSWAP SHORT: spread alto, piel, no silueta macro.
			config.fetch_length_m = 300.0
			config.swell = 0.15
			config.detail = 1.0
			config.jonswap_spread = 0.75


static func _state_table() -> Dictionary:
	return {
		State.CALM: {
			"wind_speed_mps": 6.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.10), "directional_spread": 8.0, "choppiness": 0.55, "target_hs_m": 0.20, "foam_enabled": true, "foam_whitecap": 0.70, "foam_amount": 0.04, "foam_decay": 7.00, "foam_cascade_weight": 1.0},
				{"wind_direction": Vector2(1.0, 0.18), "directional_spread": 6.0, "choppiness": 0.45, "target_hs_m": 0.09, "foam_enabled": true, "foam_whitecap": 0.74, "foam_amount": 0.008, "foam_decay": 7.00, "foam_cascade_weight": 0.35},
				{"wind_direction": Vector2(1.0, 0.25), "directional_spread": 4.0, "choppiness": 0.25, "target_hs_m": 0.03, "foam_enabled": false, "foam_whitecap": 0.78, "foam_amount": 0.0, "foam_decay": 7.00, "foam_cascade_weight": 0.0},
			],
		},
		State.RACE: {
			"wind_speed_mps": 12.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.15), "directional_spread": 7.0, "choppiness": 1.00, "target_hs_m": 0.59, "foam_enabled": true, "foam_whitecap": 0.52, "foam_amount": 0.80, "foam_decay": 5.50, "foam_cascade_weight": 1.0},
				{"wind_direction": Vector2(1.0, 0.30), "directional_spread": 5.0, "choppiness": 0.70, "target_hs_m": 0.25, "foam_enabled": true, "foam_whitecap": 0.56, "foam_amount": 0.16, "foam_decay": 5.50, "foam_cascade_weight": 0.35},
				{"wind_direction": Vector2(1.0, 0.45), "directional_spread": 4.0, "choppiness": 0.35, "target_hs_m": 0.05, "foam_enabled": false, "foam_whitecap": 0.64, "foam_amount": 0.0, "foam_decay": 5.50, "foam_cascade_weight": 0.0},
			],
		},
		State.ROUGH: {
			"wind_speed_mps": 18.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.10), "directional_spread": 5.0, "choppiness": 2.0, "target_hs_m": 2.50, "foam_enabled": true, "foam_whitecap": 0.42, "foam_amount": 1.60, "foam_decay": 4.50, "foam_cascade_weight": 1.0},
				{"wind_direction": Vector2(1.0, 0.38), "directional_spread": 3.5, "choppiness": 1.25, "target_hs_m": 0.60, "foam_enabled": true, "foam_whitecap": 0.48, "foam_amount": 0.42, "foam_decay": 4.50, "foam_cascade_weight": 0.35},
				{"wind_direction": Vector2(1.0, 0.62), "directional_spread": 3.0, "choppiness": 0.40, "target_hs_m": 0.12, "foam_enabled": false, "foam_whitecap": 0.58, "foam_amount": 0.0, "foam_decay": 4.50, "foam_cascade_weight": 0.0},
			],
		},
	}

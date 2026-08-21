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
		1:
			config.domain_size_m = 128.0
			config.min_wavelength_m = 4.0
			config.max_wavelength_m = 20.0
			config.transition_width_m = 0.75
			config.short_wave_damping_m = 0.35
		2:
			config.domain_size_m = 32.0
			config.min_wavelength_m = 0.5
			config.max_wavelength_m = 5.0
			config.transition_width_m = 0.15
			config.short_wave_damping_m = 0.20


static func _state_table() -> Dictionary:
	return {
		State.CALM: {
			"wind_speed_mps": 6.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.10), "directional_spread": 8.0, "choppiness": 0.45, "target_hs_m": 0.18},
				{"wind_direction": Vector2(1.0, 0.18), "directional_spread": 6.0, "choppiness": 0.55, "target_hs_m": 0.12},
				{"wind_direction": Vector2(1.0, 0.25), "directional_spread": 4.0, "choppiness": 0.45, "target_hs_m": 0.05},
			],
		},
		State.RACE: {
			"wind_speed_mps": 12.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.15), "directional_spread": 7.0, "choppiness": 0.75, "target_hs_m": 0.50},
				{"wind_direction": Vector2(1.0, 0.30), "directional_spread": 5.0, "choppiness": 1.00, "target_hs_m": 0.38},
				{"wind_direction": Vector2(1.0, 0.45), "directional_spread": 4.0, "choppiness": 0.90, "target_hs_m": 0.15},
			],
		},
		State.ROUGH: {
			"wind_speed_mps": 18.0,
			"bands": [
				{"wind_direction": Vector2(1.0, 0.10), "directional_spread": 5.0, "choppiness": 0.90, "target_hs_m": 0.85},
				{"wind_direction": Vector2(1.0, 0.38), "directional_spread": 3.5, "choppiness": 1.15, "target_hs_m": 0.65},
				{"wind_direction": Vector2(1.0, 0.62), "directional_spread": 3.0, "choppiness": 1.05, "target_hs_m": 0.30},
			],
		},
	}

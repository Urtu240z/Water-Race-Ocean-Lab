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

const _PRESET_PATHS := {
	State.CALM: "res://ocean_v3/presets/waves/calm.tres",
	State.RACE: "res://ocean_v3/presets/waves/race.tres",
	State.ROUGH: "res://ocean_v3/presets/waves/rough.tres",
}


static func is_valid_state(state: int) -> bool:
	return state == State.CALM or state == State.RACE or state == State.ROUGH


static func state_name(state: int) -> String:
	return STATE_NAMES.get(state, "UNKNOWN")


static func build_cascades(state: int) -> Array[OpenOceanFFTConfig]:
	assert(is_valid_state(state), "Estado de mar no válido: %d" % state)
	var preset := load(_PRESET_PATHS[state]) as OceanWavePreset
	assert(preset != null, "No se pudo cargar el preset base de %s." % state_name(state))
	return preset.build_cascades()


static func target_combined_hs_m(state: int) -> float:
	assert(is_valid_state(state))
	var variance := 0.0
	for config in build_cascades(state):
		variance += config.target_hs_m * config.target_hs_m
	return sqrt(variance)

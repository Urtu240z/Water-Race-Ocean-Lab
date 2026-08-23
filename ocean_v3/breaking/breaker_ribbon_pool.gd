class_name BreakerRibbonPool
extends Node3D
## Phase 4B — pool de geometría local de breaker (takeover geométrico).
##
## Cada slot es un ribetón (MeshInstance3D) reutilizable que comparte una malla
## plantilla y un ShaderMaterial único. El pool se configura sólo cuando cambian
## los datos horneados o el modelo de energía (eventos raros, nunca por frame).
##
## SIN readback GPU→CPU: los anchors se colocan una vez desde CoastalPropagationData
## (datos CPU horneados, no una lectura de GPU) y toda la detección/geometría del
## labio vive en breaker_lip.gdshader usando el campo PREBREAK de 4A. El pool
## sólo sincroniza por frame los uniforms compartidos desde el material del clipmap.
##
## Reglas de Phase 4B:
##   - Sólo LONG_COASTAL (con LONG_REMAINDER) origina el labio; MID/SHORT jamás
##     deciden el nacimiento (sólo integran visualmente la superficie base).
##   - Coastal OFF / fuera de batimetría / PREBREAK inválido => ningún breaker.
##   - Pausa/determinismo: sin estado temporal; el resultado es función de los
##     datos horneados + el reloj (vía texturas FFT), nunca del frame.

const LipShader := preload("res://ocean_v3/rendering/shaders/breaker_lip.gdshader")
## 4C-S1: LUT de cross-section horneada (ocean_v3 autocontenido; sin depender de lab/).
const LutTexture := preload("res://ocean_v3/breaking/data/breaker_cross_section_lut.res")

enum DebugMode { LIP, TAKEOVER, REGION, FORCE_LIP, OFF }

const DEBUG_NAMES := ["LIP", "TAKEOVER", "REGION", "FORCE_LIP", "OFF"]
const BREAKER_GAMMA := 0.78
const BREAKER_CREST_U := 0.545

## 4C-S4.2: detector de eventos de ola + breaker autónomo. OceanQuery ya NO
## trackea continuamente: sólo detecta candidatos y decide un spawn por ola.
const CREST_SAMPLE_OFFSETS: Array = [-0.45, -0.30, -0.15, 0.0, 0.15, 0.30, 0.45]
const CREST_SAMPLE_SPACING_LAMBDA := 0.15
const CREST_TRACK_EPSILON := 1.0e-4
## Detector: wrap shoreward -> siguiente ola offshore (identifica nueva ola).
const NEW_WAVE_WRAP_LAMBDA := 0.45
const SPAWN_S_START_LAMBDA := -0.28
const SPAWN_S_END_LAMBDA := -0.06
## break_score 0..1 (pesos juntos y fáciles de tunear).
const SCORE_PRESSURE_WEIGHT := 0.45
const SCORE_PROMINENCE_WEIGHT := 0.35
const SCORE_STEEPNESS_WEIGHT := 0.20
const SPAWN_PROB_SOFT_LO := 0.30
const SPAWN_PROB_SOFT_HI := 0.85
const SPAWN_STRENGTH_MIN := 0.70
## Lifecycle / cooldown.
const LIFECYCLE_DURATION_WAVE_FRACTION := 0.85
const LIFECYCLE_DURATION_MIN := 1.0
const LIFECYCLE_DURATION_MAX := 3.0
const SPAWN_INTERVAL_WAVE_FRACTION := 0.90
const SPAWN_INTERVAL_MIN := 2.0
const SPAWN_INTERVAL_MAX := 3.0
## Stage / alpha analíticos (derivados de life_t, no de crest_s).
const STAGE_LIFE_END := 0.82
const FADE_IN_END_LIFE := 0.12
const FADE_OUT_BEGIN_LIFE := 0.80

## Límite estricto de slots simultáneos; el pool reutiliza las mismas instancias.
@export_range(1, 16, 1) var max_breakers := 8
@export_range(8, 128, 1) var ribbon_u_segments := 96
@export_range(2, 12, 1) var ribbon_v_segments := 5
@export_range(2.0, 40.0, 0.5) var ribbon_width_m := 5.0
@export_range(0.6, 2.0, 0.05) var ribbon_length_lambda := 1.15
@export_range(0.2, 8.0, 0.1) var anchor_min_depth_m := 0.35
@export_range(0.1, 1.0, 0.05) var anchor_min_depth_pressure := 0.35
@export_range(0.5, 3.0, 0.1) var anchor_max_depth_pressure := 1.6
@export_range(4.0, 60.0, 0.5) var anchor_min_spacing_m := 9.0
@export var breaker_fade_range_m := Vector2(6.0, 200.0)

## Uniforms compartidos copiados cada frame desde el material del clipmap
## (fuente única de verdad; el shader del ribetón los declara con el mismo nombre).
const _UNIFORMS_TO_COPY: PackedStringArray = [
	&"module_enabled",
	&"coastal_propagation_enabled",
	&"coastal_transform_enabled",
	&"coastal_warp_enabled",
	&"coastal_monochromatic_debug",
	&"coastal_field_texture",
	&"coastal_metrics_texture",
	&"coastal_phase_texture",
	&"coastal_origin_xz",
	&"coastal_extent_m",
	&"coastal_incoming_direction_xz",
	&"coastal_warp_texture",
	&"coastal_warp_jacobian_texture",
	&"coastal_warp_origin_xz",
	&"coastal_warp_extent_m",
	&"coastal_warp_detj_safe",
	&"coastal_k0_rad_m",
	&"breaking_long_hs_m",
	&"breaking_coastal_energy_fraction",
	&"domain_long_coastal_m",
	&"domain_long_remainder_m",
	&"domain_mid_m",
	&"domain_short_m",
	&"displacement_long_coastal",
	&"displacement_long_remainder",
	&"displacement_mid",
	&"displacement_short",
	&"normal_long_coastal",
	&"normal_long_remainder",
	&"normal_mid",
	&"normal_short",
	&"short_fade_range_m",
	&"mid_fade_range_m",
	&"long_fade_range_m",
	&"band_mask",
	&"coastal_composition_debug",
	&"coastal_debug_gain",
	&"camera_world_xz",
]

var _propagation = null
var _warp = null
var _long_hs_m := 0.5
var _coastal_fraction := 0.5
var _sea_level_y := 0.0
var _surface_material: ShaderMaterial = null
var _material: ShaderMaterial = null
var _template_mesh: ArrayMesh = null
var _ribbons: Array[MeshInstance3D] = []
var _anchors: Array[Dictionary] = []
var _debug_mode: int = DebugMode.LIP
var _debug_slot := 0 # -1 => ALL; sólo filtra visibilidad en REGION/FORCE_LIP.
var _debug_stage := 1.0 # 4C-S1: stage manual de la cross-section LUT (0..1).
var _profile_forward_sign := -1.0 # 4C-S3: default FLIPPED (-1) = alineado con el avance real del FFT.
var _takeover_mask_enabled := false # 4C-S3: Y toggle del takeover mask debug.
var _last_fingerprint := ""
var _query_batch: Callable = Callable() # 4C-S4: sample_water_batch_at_time del módulo.
var _tracking: Array[Dictionary] = [] # 4C-S4: {crest_s, stage, valid, tracked_xz, h0, h3, h6} por slot.
var _last_track_time := 0.0 # 4C-S4: último render_time usado por el tracker (HUD).


# --- Réplicas CPU de los perfiles del shader (breaker_lip.gdshader / inc).
# Mismas fórmulas, para validación y HUD; el shader es la fuente de verdad. ---

static func lip_lift_profile(u: float) -> float:
	var rise := _smoothstep(0.40, BREAKER_CREST_U, u)
	var fall := 1.0 - _smoothstep(BREAKER_CREST_U, 0.68, u)
	return rise * fall


static func lip_advance_profile(u: float) -> float:
	var rise := _smoothstep(BREAKER_CREST_U, BREAKER_CREST_U + 0.08, u)
	var fall := 1.0 - _smoothstep(BREAKER_CREST_U + 0.08, BREAKER_CREST_U + 0.20, u)
	return rise * fall


static func edge_fade(u: float, v: float) -> float:
	var uf := _smoothstep(0.02, 0.12, u) * (1.0 - _smoothstep(0.88, 0.98, u))
	var vf := _smoothstep(0.04, 0.22, v) * (1.0 - _smoothstep(0.78, 0.96, v))
	return uf * vf


static func breaker_envelope(prebreak: float) -> float:
	return _smoothstep(0.05, 0.5, prebreak)


static func estimate_local_hs(long_hs_m: float, coastal_fraction: float, shoaling: float) -> float:
	var fraction := clampf(coastal_fraction, 0.0, 1.0)
	return long_hs_m * sqrt(maxf(0.0, (1.0 - fraction) + fraction * shoaling * shoaling))


static func estimate_depth_pressure(long_hs_m: float, coastal_fraction: float, shoaling: float, depth_m: float) -> float:
	var local_hs := estimate_local_hs(long_hs_m, coastal_fraction, shoaling)
	return local_hs / maxf(BREAKER_GAMMA * depth_m, 0.001)


# --- Configuración (eventos raros: rebuild coastal / cambio de sea state). ---

func configure(propagation, warp, long_hs_m: float, coastal_fraction: float, sea_level_y: float, surface_material: ShaderMaterial) -> void:
	## propagation: CoastalPropagationData válido; warp: CoastalWarpData (o null).
	## surface_material: material del clipmap del que se copian los uniforms.
	_propagation = propagation
	_warp = warp
	_sea_level_y = sea_level_y
	_surface_material = surface_material
	_ensure_material()
	set_energy_model(long_hs_m, coastal_fraction)
	_sync_uniforms()
	visible = true


func set_query_source(callable: Callable) -> void:
	## 4C-S4: Callable batch de OceanQuery (sample_water_batch_at_time del módulo).
	_query_batch = callable


func set_energy_model(long_hs_m: float, coastal_fraction: float) -> void:
	## Recoloca los anchors con el modelo de energía vigente (Hs + fracción del
	## split). Determinista: misma batimetría + mismo modelo => mismos anchors.
	_long_hs_m = maxf(long_hs_m, 0.0)
	_coastal_fraction = clampf(coastal_fraction, 0.0, 1.0)
	if _propagation != null and _propagation.is_valid():
		_anchors = _place_anchors()
	else:
		_anchors.clear()
	_rebuild_instances()


func disable() -> void:
	## Coastal OFF / sin batimetría / PREBREAK inválido: ningún breaker visible.
	_anchors.clear()
	_rebuild_instances()
	visible = false


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, DebugMode.LIP, DebugMode.OFF)
	if _material != null:
		_material.set_shader_parameter(&"breaker_debug_mode", _debug_mode)
	_apply_visibility()
	_sync_takeover_mask()


func cycle_debug_mode() -> void:
	set_debug_mode((_debug_mode + 1) % (DebugMode.OFF + 1))


func set_debug_slot(slot: int) -> void:
	## slot -1 => ALL. Sólo filtra visibilidad en REGION/FORCE_LIP; no recrea mesh.
	_debug_slot = slot
	_apply_visibility()
	_sync_takeover_mask()


func cycle_debug_slot() -> void:
	## 0 -> 1 -> ... -> (N-1) -> ALL -> 0, con N = slots activos.
	var count := _anchors.size()
	if count == 0:
		_debug_slot = -1
	elif _debug_slot < 0:
		_debug_slot = 0
	else:
		_debug_slot += 1
		if _debug_slot >= count:
			_debug_slot = -1
	_apply_visibility()
	_sync_takeover_mask()


func debug_slot_name() -> String:
	return "ALL" if _debug_slot < 0 else str(_debug_slot)


func set_debug_stage(value: float) -> void:
	## 4C-S1: actualiza SÓLO breaker_profile_debug_stage del material (sin rebuild).
	_debug_stage = clampf(value, 0.0, 1.0)
	if _material != null:
		_material.set_shader_parameter(&"breaker_profile_debug_stage", _debug_stage)
	_sync_takeover_mask()


func adjust_debug_stage(delta: float) -> void:
	set_debug_stage(_debug_stage + delta)


func debug_stage() -> float:
	return _debug_stage


func toggle_debug_profile_direction() -> void:
	## 4C-S2: espeja la cross-section longitudinalmente (sólo FORCE_LIP, debug).
	_profile_forward_sign = -_profile_forward_sign
	if _material != null:
		_material.set_shader_parameter(&"breaker_profile_forward_sign", _profile_forward_sign)
	_sync_takeover_mask()


func debug_profile_direction_name() -> String:
	return "FLIPPED" if _profile_forward_sign < 0.0 else "FORWARD"


func debug_profile_aligned() -> bool:
	## FLIPPED es el estado alineado con el avance real del FFT (convención
	## actual: las crestas LONG viajan en -direction_xz).
	return _profile_forward_sign < 0.0


func toggle_takeover_mask() -> void:
	## 4C-S3: activa/desactiva el takeover mask del ocean base (sólo FORCE_LIP).
	_takeover_mask_enabled = not _takeover_mask_enabled
	_sync_takeover_mask()


func takeover_mask_name() -> String:
	return "ON" if _takeover_mask_enabled else "OFF"


func breaker_debug_name() -> String:
	return DEBUG_NAMES[_debug_mode]


func anchor_count() -> int:
	return _anchors.size()


func anchor_snapshot() -> Array:
	## Datos deterministas por slot para validación/HUD (sin readback de GPU).
	var result: Array = []
	for anchor in _anchors:
		result.append({
			"xz": Vector2(anchor["xz"]),
			"direction": Vector2(anchor["direction"]),
			"depth_m": float(anchor["depth_m"]),
			"wavelength_m": float(anchor["wavelength_m"]),
			"pressure": float(anchor["pressure"]),
		})
	return result


func tracking_snapshot() -> Array:
	## 4C-S4.2: estado por slot (DETECT/ACTIVE/COOLDOWN) para el HUD.
	var result: Array = []
	var now := _last_track_time
	for index in _anchors.size():
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		var active: bool = bool(entry.get("active", false))
		var next_spawn: float = float(entry.get("next_spawn_time", 0.0))
		var state_name: String = "ACTIVE" if active else ("COOLDOWN" if now < next_spawn else "DETECT")
		result.append({
			"state": state_name,
			"wave": int(entry.get("wave_serial", 0)),
			"candidate_s": float(entry.get("candidate_s", 0.0)),
			"score": float(entry.get("score", 0.0)),
			"probability": float(entry.get("probability", 0.0)),
			"roll": float(entry.get("roll", 0.0)),
			"life_t": float(entry.get("life_t", 0.0)),
			"stage": float(entry.get("stage", 0.0)),
			"alpha": float(entry.get("alpha", 0.0)),
			"phase_speed": float(entry.get("phase_speed", 0.0)),
			"remaining": float(entry.get("remaining", 0.0)),
			"h0": float(entry.get("h0", 0.0)),
			"h3": float(entry.get("h3", 0.0)),
			"h6": float(entry.get("h6", 0.0)),
		})
	return result


func track_time() -> float:
	## 4C-S4: último render_time evaluado por el tracker (para verificar que avanza).
	return _last_track_time


func summary() -> Dictionary:
	return {
		"configured": _propagation != null and _propagation.is_valid(),
		"slots": _anchors.size(),
		"max_slots": max_breakers,
		"debug": breaker_debug_name(),
		"anchors": anchor_snapshot(),
	}


func _process(_delta: float) -> void:
	if _material == null or _surface_material == null:
		return
	_sync_uniforms()
	_update_tracking()


# --- Internos. ---

func _sync_uniforms() -> void:
	if _surface_material == null:
		return
	for uniform_name in _UNIFORMS_TO_COPY:
		var value: Variant = _surface_material.get_shader_parameter(uniform_name)
		if value != null:
			_material.set_shader_parameter(uniform_name, value)


func _update_tracking() -> void:
	## 4C-S4.2: detector de eventos de ola (batch única) + breaker autónomo por
	## slot. El detector sólo decide el spawn; una vez spawneado, el breaker
	## avanza por phase_speed y muere por su propio lifecycle (sin OceanQuery).
	if _anchors.is_empty() or _ribbons.size() != _anchors.size():
		return
	if not _query_batch.is_valid():
		_clear_tracking()
		return
	var render_time: float = SimulationClock.get_render_time()
	_last_track_time = render_time
	var positions: Array[Vector3] = []
	var base_index: Array[int] = []
	for anchor in _anchors:
		var travel_dir := -Vector2(anchor["direction"])
		var wavelength := float(anchor["wavelength_m"])
		base_index.append(positions.size())
		for offset in CREST_SAMPLE_OFFSETS:
			var xz: Vector2 = Vector2(anchor["xz"]) + travel_dir * (float(offset) * wavelength)
			positions.append(Vector3(xz.x, _sea_level_y, xz.y))
	var samples: Array = _query_batch.call(positions, render_time)
	if samples.size() != positions.size():
		_clear_tracking()
		return
	for index in _anchors.size():
		var anchor: Dictionary = _anchors[index]
		var base: int = base_index[index]
		var heights := PackedFloat32Array()
		var all_valid := true
		for k in CREST_SAMPLE_OFFSETS.size():
			var sample: OceanQuerySample = samples[base + k]
			if sample == null or not sample.valid or not is_finite(sample.height):
				all_valid = false
				break
			heights.append(sample.height)
		if not all_valid:
			_update_slot_invalid(index, Vector2(anchor["xz"]), render_time)
			continue
		_update_slot(index, anchor, heights, samples, base, render_time)
		if index < _tracking.size():
			_tracking[index]["h0"] = heights[0]
			_tracking[index]["h3"] = heights[3]
			_tracking[index]["h6"] = heights[6]


func _detect_candidate(heights: PackedFloat32Array, wavelength: float, samples: Array, base: int) -> Dictionary:
	## Detector de 7 muestras: prominencia + parábola. Devuelve candidate_s,
	## prominence, index y el sample del candidato (para normal/steepness).
	var best_index := 1
	var best_prominence := -INF
	for k in range(1, CREST_SAMPLE_OFFSETS.size() - 1):
		var prominence: float = heights[k] - 0.5 * (heights[k - 1] + heights[k + 1])
		if prominence > best_prominence:
			best_prominence = prominence
			best_index = k
	var denom: float = heights[best_index - 1] - 2.0 * heights[best_index] + heights[best_index + 1]
	var delta := 0.0
	if absf(denom) > CREST_TRACK_EPSILON:
		delta = 0.5 * (heights[best_index - 1] - heights[best_index + 1]) / denom
	delta = clampf(delta, -1.0, 1.0)
	var candidate_s: float = float(CREST_SAMPLE_OFFSETS[best_index]) * wavelength + delta * (CREST_SAMPLE_SPACING_LAMBDA * wavelength)
	return {"s": candidate_s, "prominence": best_prominence, "index": best_index, "sample": samples[base + best_index]}


func _update_slot(index: int, anchor: Dictionary, heights: PackedFloat32Array, samples: Array, base: int, render_time: float) -> void:
	var wavelength := float(anchor["wavelength_m"])
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	var candidate := _detect_candidate(heights, wavelength, samples, base)
	if bool(entry.get("active", false)):
		_update_active_breaker(index, entry, render_time)
	else:
		_run_detector(index, anchor, candidate, render_time)


func _update_active_breaker(index: int, entry: Dictionary, render_time: float) -> void:
	## Breaker autónomo: posición/stage/alpha derivados SOLO de spawn_time (nada
	## de OceanQuery). Fórmula absoluta -> pausa determinista y sin acumulación.
	var spawn_time: float = float(entry.get("spawn_time", render_time))
	var duration: float = maxf(float(entry.get("lifecycle_duration", 1.0)), 0.001)
	var age: float = maxf(0.0, render_time - spawn_time)
	var life_t: float = clampf(age / duration, 0.0, 1.0)
	if life_t >= 1.0:
		var state := _base_state(entry)
		state["active"] = false
		state["valid"] = 0.0
		state["stage"] = 0.0
		state["alpha"] = 0.0
		state["tracked_xz"] = Vector2(entry.get("spawn_xz", Vector2.ZERO))
		state["detector_initialized"] = false
		state["detector_prev_s"] = 0.0
		state["life_t"] = 1.0
		state["remaining"] = maxf(0.0, float(entry.get("next_spawn_time", render_time)) - render_time)
		_publish_slot(index, state)
		return
	var stage: float = _smoothstep(0.0, STAGE_LIFE_END, life_t)
	var fade_in: float = _smoothstep(0.0, FADE_IN_END_LIFE, life_t)
	var fade_out: float = 1.0 - _smoothstep(FADE_OUT_BEGIN_LIFE, 1.0, life_t)
	var alpha: float = fade_in * fade_out
	var phase_speed: float = maxf(float(entry.get("spawn_phase_speed", 0.1)), 0.1)
	var breaker_xz: Vector2 = Vector2(entry.get("spawn_xz", Vector2.ZERO)) + Vector2(entry.get("spawn_direction", Vector2.RIGHT)) * (phase_speed * age)
	var state := _base_state(entry)
	state["active"] = true
	state["valid"] = 1.0
	state["stage"] = stage
	state["alpha"] = alpha
	state["tracked_xz"] = breaker_xz
	state["life_t"] = life_t
	state["phase_speed"] = phase_speed
	state["remaining"] = 0.0
	_publish_slot(index, state)


func _run_detector(index: int, anchor: Dictionary, candidate: Dictionary, render_time: float) -> void:
	var wavelength := float(anchor["wavelength_m"])
	var travel_dir := -Vector2(anchor["direction"])
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	var detector_initialized: bool = bool(entry.get("detector_initialized", false))
	var detector_prev_s: float = float(entry.get("detector_prev_s", 0.0))
	var wave_serial: int = int(entry.get("wave_serial", 0))
	var last_decided: int = int(entry.get("last_decided_wave_serial", -1))
	var next_spawn_time: float = float(entry.get("next_spawn_time", 0.0))
	var candidate_s: float = float(candidate["s"])

	if not detector_initialized:
		var state := _base_state(entry)
		state["detector_initialized"] = true
		state["detector_prev_s"] = candidate_s
		state["active"] = false
		state["valid"] = 0.0
		state["tracked_xz"] = Vector2(anchor["xz"])
		state["candidate_s"] = candidate_s
		state["remaining"] = maxf(0.0, next_spawn_time - render_time)
		_publish_slot(index, state)
		return

	# Identificar nueva ola: wrap shoreward -> offshore.
	if candidate_s < detector_prev_s - NEW_WAVE_WRAP_LAMBDA * wavelength:
		wave_serial += 1
	var advancing: bool = candidate_s > detector_prev_s
	detector_prev_s = candidate_s

	var s_start := SPAWN_S_START_LAMBDA * wavelength
	var s_end := SPAWN_S_END_LAMBDA * wavelength
	var in_window: bool = candidate_s >= s_start and candidate_s <= s_end
	var cooldown_done: bool = render_time >= next_spawn_time

	var state := _base_state(entry)
	state["detector_initialized"] = true
	state["detector_prev_s"] = detector_prev_s
	state["wave_serial"] = wave_serial
	state["active"] = false
	state["valid"] = 0.0
	state["stage"] = 0.0
	state["alpha"] = 0.0
	state["tracked_xz"] = Vector2(anchor["xz"])
	state["candidate_s"] = candidate_s
	state["remaining"] = maxf(0.0, next_spawn_time - render_time)

	if in_window and advancing and wave_serial != last_decided and cooldown_done:
		state["last_decided_wave_serial"] = wave_serial
		var score: float = _break_score(anchor, candidate, travel_dir)
		var probability: float = _smoothstep(SPAWN_PROB_SOFT_LO, SPAWN_PROB_SOFT_HI, score)
		var roll: float = _deterministic_roll(index, wave_serial)
		state["score"] = score
		state["probability"] = probability
		state["roll"] = roll
		if roll < probability:
			_spawn_breaker(index, anchor, candidate_s, travel_dir, wavelength, score, render_time, state)
			return
	_publish_slot(index, state)


func _spawn_breaker(index: int, anchor: Dictionary, candidate_s: float, travel_dir: Vector2, wavelength: float, score: float, render_time: float, state: Dictionary) -> void:
	var phase_speed: float = maxf(float(anchor.get("phase_speed_mps", 0.1)), 0.1)
	var local_hs: float = estimate_local_hs(_long_hs_m, _coastal_fraction, float(anchor.get("shoaling", 1.0)))
	var strength: float = lerpf(SPAWN_STRENGTH_MIN, 1.0, score)
	var wave_period: float = wavelength / phase_speed
	var duration: float = clampf(LIFECYCLE_DURATION_WAVE_FRACTION * wave_period, LIFECYCLE_DURATION_MIN, LIFECYCLE_DURATION_MAX)
	var interval: float = clampf(SPAWN_INTERVAL_WAVE_FRACTION * wave_period, SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_MAX)
	state["active"] = true
	state["valid"] = 1.0
	state["spawn_time"] = render_time
	state["spawn_xz"] = Vector2(anchor["xz"]) + travel_dir * candidate_s
	state["spawn_direction"] = travel_dir
	state["spawn_wavelength"] = wavelength
	state["spawn_phase_speed"] = phase_speed
	state["spawn_local_hs"] = local_hs
	state["spawn_strength"] = strength
	state["lifecycle_duration"] = duration
	state["next_spawn_time"] = render_time + interval
	state["stage"] = 0.0
	state["alpha"] = 0.0
	state["tracked_xz"] = state["spawn_xz"]
	state["life_t"] = 0.0
	state["phase_speed"] = phase_speed
	state["remaining"] = 0.0
	_publish_slot(index, state)


func _break_score(anchor: Dictionary, candidate: Dictionary, travel_dir: Vector2) -> float:
	var pressure_score: float = _smoothstep(anchor_min_depth_pressure, minf(anchor_max_depth_pressure, 1.15), float(anchor["pressure"]))
	var local_hs: float = estimate_local_hs(_long_hs_m, _coastal_fraction, float(anchor.get("shoaling", 1.0)))
	var prominence_score: float = _smoothstep(0.04 * local_hs, 0.20 * local_hs, maxf(float(candidate["prominence"]), 0.0))
	var sample: OceanQuerySample = candidate["sample"]
	var ny: float = maxf(absf(sample.normal.y), 0.05)
	var slope_xz := -Vector2(sample.normal.x, sample.normal.z) / ny
	var slope_long: float = absf(slope_xz.dot(travel_dir))
	var steepness_score: float = _smoothstep(0.20, 0.75, slope_long)
	return clampf(SCORE_PRESSURE_WEIGHT * pressure_score + SCORE_PROMINENCE_WEIGHT * prominence_score + SCORE_STEEPNESS_WEIGHT * steepness_score, 0.0, 1.0)


func _deterministic_roll(slot: int, wave_serial: int) -> float:
	var seed: int = int(SimulationClock.simulation_seed) & 0x7FFFFFFF
	seed ^= ((slot + 1) * 0x9E3779B1) & 0x7FFFFFFF
	seed ^= ((wave_serial + 1) * 0x85EBCA6B) & 0x7FFFFFFF
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return rng.randf()


func _base_state(entry: Dictionary) -> Dictionary:
	## Conserva los campos de spawn/detector que deben persistir; resetea lo visual.
	return {
		"active": false,
		"valid": 0.0,
		"stage": 0.0,
		"alpha": 0.0,
		"tracked_xz": entry.get("tracked_xz", Vector2.ZERO),
		"spawn_time": float(entry.get("spawn_time", 0.0)),
		"spawn_xz": entry.get("spawn_xz", Vector2.ZERO),
		"spawn_direction": entry.get("spawn_direction", Vector2.RIGHT),
		"spawn_wavelength": float(entry.get("spawn_wavelength", 0.0)),
		"spawn_phase_speed": float(entry.get("spawn_phase_speed", 0.1)),
		"spawn_local_hs": float(entry.get("spawn_local_hs", 0.0)),
		"spawn_strength": float(entry.get("spawn_strength", 0.0)),
		"lifecycle_duration": float(entry.get("lifecycle_duration", 1.0)),
		"next_spawn_time": float(entry.get("next_spawn_time", 0.0)),
		"detector_initialized": bool(entry.get("detector_initialized", false)),
		"detector_prev_s": float(entry.get("detector_prev_s", 0.0)),
		"wave_serial": int(entry.get("wave_serial", 0)),
		"last_decided_wave_serial": int(entry.get("last_decided_wave_serial", -1)),
		"candidate_s": float(entry.get("candidate_s", 0.0)),
		"score": float(entry.get("score", 0.0)),
		"probability": float(entry.get("probability", 0.0)),
		"roll": float(entry.get("roll", 0.0)),
		"life_t": float(entry.get("life_t", 0.0)),
		"phase_speed": float(entry.get("phase_speed", 0.0)),
		"remaining": float(entry.get("remaining", 0.0)),
	}


func _publish_slot(index: int, state: Dictionary) -> void:
	if index >= _tracking.size():
		_tracking.resize(index + 1)
	_tracking[index] = state
	if index < _ribbons.size():
		var ribbon: MeshInstance3D = _ribbons[index]
		ribbon.set_instance_shader_parameter(&"tracked_crest_xz", Vector2(state.get("tracked_xz", Vector2.ZERO)))
		ribbon.set_instance_shader_parameter(&"breaker_lifecycle_stage", float(state.get("stage", 0.0)))
		ribbon.set_instance_shader_parameter(&"breaker_lifecycle_alpha", float(state.get("alpha", 0.0)))
		ribbon.set_instance_shader_parameter(&"breaker_tracking_valid", float(state.get("valid", 0.0)))
		ribbon.set_instance_shader_parameter(&"breaker_spawn_strength", float(state.get("spawn_strength", 0.0)))
		ribbon.set_instance_shader_parameter(&"breaker_spawn_hs_m", float(state.get("spawn_local_hs", 0.0)))


func _update_slot_invalid(index: int, anchor_xz: Vector2, render_time: float) -> void:
	## 4C-S4.2: muestras no válidas -> el breaker activo sigue su lifecycle
	## autónomo (no depende del detector); si no, permanece IDLE.
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	if bool(entry.get("active", false)):
		_update_active_breaker(index, entry, render_time)
		return
	var state := _base_state(entry)
	state["active"] = false
	state["valid"] = 0.0
	state["tracked_xz"] = anchor_xz
	state["remaining"] = maxf(0.0, float(entry.get("next_spawn_time", 0.0)) - render_time)
	_publish_slot(index, state)


func _clear_tracking() -> void:
	## 4C-S4.2: fallo global de batch -> reinicio duro (IDLE, sin spawn).
	_tracking.resize(_anchors.size())
	for index in _ribbons.size():
		var ribbon: MeshInstance3D = _ribbons[index]
		ribbon.set_instance_shader_parameter(&"tracked_crest_xz", Vector2.ZERO)
		ribbon.set_instance_shader_parameter(&"breaker_lifecycle_stage", 0.0)
		ribbon.set_instance_shader_parameter(&"breaker_lifecycle_alpha", 0.0)
		ribbon.set_instance_shader_parameter(&"breaker_tracking_valid", 0.0)
		ribbon.set_instance_shader_parameter(&"breaker_spawn_strength", 0.0)
		ribbon.set_instance_shader_parameter(&"breaker_spawn_hs_m", 0.0)
		if index < _tracking.size():
			_tracking[index] = _base_state({})


func _ensure_material() -> void:
	if _material != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = LipShader
	_material.set_shader_parameter(&"breaker_debug_mode", _debug_mode)
	_material.set_shader_parameter(&"sea_level_y", _sea_level_y)
	_material.set_shader_parameter(&"breaker_fade_range_m", breaker_fade_range_m)
	# 4C-S1: LUT de cross-section (una vez; sin regeneración runtime).
	_material.set_shader_parameter(&"breaker_profile_lut", LutTexture)
	_material.set_shader_parameter(&"breaker_profile_debug_stage", _debug_stage)
	_material.set_shader_parameter(&"breaker_profile_forward_sign", _profile_forward_sign)
	_template_mesh = _build_ribbon_mesh()


func _place_anchors() -> Array[Dictionary]:
	## Candidatos = celdas válidas/alcanzadas de la propagación cuya presión de
	## profundidad estimada cae en la zona de pre-break. Greedy con separación
	## mínima, cap en max_breakers. Todo desde datos horneados (CPU).
	var candidates: Array[Dictionary] = []
	var propagation = _propagation
	var width: int = propagation.width
	var height: int = propagation.height
	var depth_arr: PackedFloat32Array = propagation.depth_m
	var k_arr: PackedFloat32Array = propagation.local_k
	var wave_arr: PackedFloat32Array = propagation.wavelength_m
	var shoal_arr: PackedFloat32Array = propagation.shoaling_scale
	var phase_speed_arr: PackedFloat32Array = propagation.phase_speed_mps
	var valid_mask: PackedByteArray = propagation.valid_mask
	var reached: PackedByteArray = propagation.reached_mask
	var dir_x: PackedFloat32Array = propagation.local_direction_x
	var dir_z: PackedFloat32Array = propagation.local_direction_z
	var k0: float = propagation.k0_rad_m
	var min_valid: float = propagation.min_valid_depth_m
	for z in height:
		for x in width:
			var index: int = z * width + x
			if valid_mask[index] == 0 or reached[index] == 0:
				continue
			var depth := depth_arr[index]
			if depth < maxf(min_valid, anchor_min_depth_m):
				continue
			var pressure := estimate_depth_pressure(_long_hs_m, _coastal_fraction, shoal_arr[index], depth)
			if pressure < anchor_min_depth_pressure:
				continue
			if pressure > anchor_max_depth_pressure:
				continue # zona ya sobre-excitada (rompiente rota/tierra): sin slots.
			var direction := Vector2(dir_x[index], dir_z[index])
			if direction.length_squared() < 1.0e-8:
				continue
			direction = direction.normalized()
			candidates.append({
				"xz": propagation.world_origin_xz + Vector2(float(x), float(z)) * propagation.cell_size_m,
				"depth_m": depth,
				"pressure": pressure,
				"direction": direction,
				"wavelength_m": maxf(wave_arr[index], 0.5),
				"local_k": maxf(k_arr[index], k0),
				"shoaling": shoal_arr[index],
				"phase_speed_mps": phase_speed_arr[index],
			})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a["depth_m"] - b["depth_m"]) > 0.001:
			return a["depth_m"] < b["depth_m"]
		if absf(a["xz"].x - b["xz"].x) > 0.001:
			return a["xz"].x < b["xz"].x
		return a["xz"].y < b["xz"].y)
	var picked: Array[Dictionary] = []
	for candidate in candidates:
		if picked.size() >= max_breakers:
			break
		var too_close := false
		for anchor in picked:
			if (Vector2(anchor["xz"]) - Vector2(candidate["xz"])).length() < anchor_min_spacing_m:
				too_close = true
				break
		if too_close:
			continue
		picked.append(candidate)
	return picked


func _anchors_fingerprint() -> String:
	if _anchors.is_empty():
		return ""
	var parts := PackedStringArray()
	for anchor in _anchors:
		parts.append("%.2f:%.2f|%.4f:%.4f|%.2f" % [
			anchor["xz"].x, anchor["xz"].y, anchor["direction"].x, anchor["direction"].y, anchor["wavelength_m"],
		])
	return "\n".join(parts)


func _rebuild_instances() -> void:
	## Reutilización de pool: si la disposición no cambió, no se toca nada.
	var fingerprint := _anchors_fingerprint()
	if fingerprint == _last_fingerprint and _ribbons.size() == _anchors.size():
		return
	_last_fingerprint = fingerprint
	for ribbon in _ribbons:
		ribbon.queue_free()
	_ribbons.clear()
	for index in _anchors.size():
		var anchor: Dictionary = _anchors[index]
		var instance := MeshInstance3D.new()
		instance.name = "Ribbon%d" % index
		instance.mesh = _template_mesh
		instance.material_override = _material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = 4096.0
		instance.set_instance_shader_parameter(&"anchor_xz", Vector2(anchor["xz"]))
		instance.set_instance_shader_parameter(&"direction_xz", Vector2(anchor["direction"]))
		instance.set_instance_shader_parameter(&"ribbon_id", float(index))
		instance.set_instance_shader_parameter(&"ribbon_wavelength_m", float(anchor["wavelength_m"]) * ribbon_length_lambda)
		instance.set_instance_shader_parameter(&"ribbon_width_m", ribbon_width_m)
		# 4C-S4.2: breaker autónomo (fallback = anchor + stage 0 + sin spawn).
		instance.set_instance_shader_parameter(&"tracked_crest_xz", Vector2(anchor["xz"]))
		instance.set_instance_shader_parameter(&"breaker_lifecycle_stage", 0.0)
		instance.set_instance_shader_parameter(&"breaker_tracking_valid", 0.0)
		instance.set_instance_shader_parameter(&"breaker_lifecycle_alpha", 0.0)
		instance.set_instance_shader_parameter(&"breaker_spawn_strength", 0.0)
		instance.set_instance_shader_parameter(&"breaker_spawn_hs_m", 0.0)
		add_child(instance)
		_ribbons.append(instance)
	_tracking.resize(_anchors.size())
	_apply_visibility()
	_sync_takeover_mask()


func _sync_takeover_mask() -> void:
	## 4C-S3: sincroniza los uniforms debug del takeover mask en el material del
	## ocean base. Activo sólo en FORCE_LIP + slot individual. Eventos, no por frame.
	if _surface_material == null:
		return
	var active: bool = _takeover_mask_enabled and _debug_mode == DebugMode.FORCE_LIP and _debug_slot >= 0 and _debug_slot < _anchors.size()
	if not active:
		_surface_material.set_shader_parameter(&"breaker_takeover_debug_enabled", false)
		return
	var anchor: Dictionary = _anchors[_debug_slot]
	var profile_scale: float = 0.65
	if _material != null:
		var s: Variant = _material.get_shader_parameter(&"breaker_profile_length_scale")
		if s != null and float(s) > 0.0:
			profile_scale = float(s)
	_surface_material.set_shader_parameter(&"breaker_takeover_debug_enabled", true)
	_surface_material.set_shader_parameter(&"breaker_takeover_anchor_xz", Vector2(anchor["xz"]))
	_surface_material.set_shader_parameter(&"breaker_takeover_direction_xz", Vector2(anchor["direction"]))
	_surface_material.set_shader_parameter(&"breaker_takeover_length_m", float(anchor["wavelength_m"]) * ribbon_length_lambda * profile_scale)
	_surface_material.set_shader_parameter(&"breaker_takeover_width_m", ribbon_width_m)
	_surface_material.set_shader_parameter(&"breaker_takeover_stage", _debug_stage)
	_surface_material.set_shader_parameter(&"breaker_takeover_forward_sign", _profile_forward_sign)


func _apply_visibility() -> void:
	## Debug: en REGION/FORCE_LIP oculta los slots no seleccionados (sin recrear
	## meshes). Producción (LIP/TAKEOVER/OFF) deja todos visibles; OFF ya hace
	## alpha 0 en el shader.
	var filter_active: bool = _debug_mode == DebugMode.REGION or _debug_mode == DebugMode.FORCE_LIP
	for index in _ribbons.size():
		var ribbon: MeshInstance3D = _ribbons[index]
		ribbon.visible = not (filter_active and _debug_slot >= 0 and index != _debug_slot)


func _build_ribbon_mesh() -> ArrayMesh:
	## Malla plantilla unitaria (u,v en [0,1]); el shader la mapea al mundo con
	## los instance uniforms. Sin retessalación dinámica del océano base.
	var u_seg := ribbon_u_segments
	var v_seg := ribbon_v_segments
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for v in v_seg + 1:
		for u in u_seg + 1:
			var uf := float(u) / float(u_seg)
			var vf := float(v) / float(v_seg)
			vertices.append(Vector3(uf, 0.0, vf))
			normals.append(Vector3.UP)
			uvs.append(Vector2(uf, vf))
	for v in v_seg:
		for u in u_seg:
			var a := v * (u_seg + 1) + u
			var b := a + 1
			var c := a + (u_seg + 1)
			var d := c + 1
			indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / maxf(edge1 - edge0, 1.0e-6), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

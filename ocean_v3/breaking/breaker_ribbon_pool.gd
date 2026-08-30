class_name BreakerRibbonPool
extends Node3D
## Phase 4C-S5 — pool de producción PREBREAK -> breaker -> FFT takeover.
##
## Cada slot es un ribetón (MeshInstance3D) reutilizable que comparte una malla
## plantilla y un ShaderMaterial único. El pool se configura sólo cuando cambian
## los datos horneados o el modelo de energía (eventos raros, nunca por frame).
##
## SIN readback GPU→CPU: los anchors se colocan una vez desde CoastalPropagationData
## (datos CPU horneados, no una lectura de GPU). El campo PREBREAK/geometría del
## labio vive en breaker_lip.gdshader; el detector CPU usa el sampler coastal
## LONG especializado y el pool sólo sincroniza uniforms compartidos por frame.
##
## Reglas de Phase 4B:
##   - Sólo LONG_COASTAL (con LONG_REMAINDER) origina el labio; MID/SHORT jamás
##     deciden el nacimiento (sólo integran visualmente la superficie base).
##   - Coastal OFF / fuera de batimetría / PREBREAK inválido => ningún breaker.
##   - Pausa/determinismo: sin estado temporal; el resultado es función de los
##     datos horneados + el reloj (vía texturas FFT), nunca del frame.

const LipShader := preload("res://ocean_v3/rendering/shaders/breaker_lip.gdshader")
const SeaStateZoneMathScript := preload("res://ocean_v3/core/sea_state_zone_math.gd")
## 4C-S1: LUT de cross-section horneada (ocean_v3 autocontenido; sin depender de lab/).
const LutTexture := preload("res://ocean_v3/breaking/data/breaker_cross_section_lut.res")

enum DebugMode { LIP, TAKEOVER, REGION, FORCE_LIP, DETECTOR, OFF }

const DEBUG_NAMES := ["LIP", "TAKEOVER", "REGION", "FORCE_LIP", "DETECTOR", "OFF"]
const BREAKER_GAMMA := 0.78
const ANCHOR_PRESSURE_TARGET := 0.78
const TRAJECTORY_STEP_S := 0.125
const TRAJECTORY_MAX_STEPS := 24
## Corridor de onset: evaluación CPU, sólo al recolocar anchors/bake/sea-state.
## La escala se expresa en wavelengths para seguir el modelo de cada ola.
const CORRIDOR_SAMPLE_COUNT := 16
const CORRIDOR_OFFSHORE_LENGTH_LAMBDA := 0.75
const CORRIDOR_SHOREWARD_LENGTH_LAMBDA := 2.0
const CORRIDOR_TERMINAL_VERTICAL_WEIGHT := 0.05
const CORRIDOR_ONSET_PRESSURE := 0.56
const CORRIDOR_MAX_CANDIDATES := 64
const CORRIDOR_MIN_PATH_SAMPLES := 3
const CORRIDOR_MIN_SHALLOW_DISTANCE_FRACTION := 0.90
const CORRIDOR_SPAWN_VERTICAL_WEIGHT_MIN := 0.18
const CORRIDOR_PLUNGE_STAGE := 0.88

## 4C-S4.2: detector de eventos de ola + breaker autónomo. OceanQuery ya NO
## trackea continuamente: sólo detecta candidatos y decide un spawn por ola.
const CREST_SAMPLE_OFFSETS: Array = [-0.45, -0.30, -0.15, 0.0, 0.15, 0.30, 0.45]
const CREST_SAMPLE_SPACING_LAMBDA := 0.15
const CREST_TRACK_EPSILON := 1.0e-4
## Detector: wrap shoreward -> siguiente ola offshore (identifica nueva ola).
const NEW_WAVE_WRAP_LAMBDA := 0.45
const SPAWN_S_START_LAMBDA := -0.28
const SPAWN_S_END_LAMBDA := -0.06
## Crest refinement score 0..1. Physical breaking eligibility is evaluated
## separately from the corridor and is the authoritative spawn gate.
const SCORE_PRESSURE_WEIGHT := 0.45
const SCORE_PROMINENCE_WEIGHT := 0.35
const SCORE_STEEPNESS_WEIGHT := 0.20
const PHYSICAL_BREAKING_MARGINAL_THRESHOLD := 0.30
const PHYSICAL_BREAKING_GUARANTEED_THRESHOLD := 0.55
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
const TRANSITION_MAX_ANCHORS := 16
const TRANSITION_ANCHOR_MATCH_DISTANCE_FACTOR := 0.65
const TRANSITION_ANCHOR_MATCH_DIRECTION_DOT := 0.85

## Límite estricto de slots simultáneos; el pool reutiliza las mismas instancias.
@export_range(1, 8, 1) var max_breakers := 8
@export_range(8, 128, 1) var ribbon_u_segments := 96
@export_range(2, 12, 1) var ribbon_v_segments := 5
@export_range(2.0, 40.0, 0.5) var ribbon_width_m := 6.0
@export_range(0.6, 2.0, 0.05) var ribbon_length_lambda := 1.55
@export_range(0.2, 8.0, 0.1) var anchor_min_depth_m := 0.35
@export_range(0.1, 1.0, 0.05) var anchor_min_depth_pressure := 0.35
@export_range(0.5, 3.0, 0.1) var anchor_max_depth_pressure := 1.35
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
	&"breaking_mid_hs_m",
	&"breaking_coastal_energy_fraction",
	&"breaking_long_min_wavelength_m",
	&"breaking_long_max_wavelength_m",
	&"breaking_mid_min_wavelength_m",
	&"breaking_mid_max_wavelength_m",
	&"breaking_long_direction_xz",
	&"breaking_mid_direction_xz",
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
	&"sea_state_zone_count",
	&"sea_state_zone_data0",
	&"sea_state_zone_data1",
	&"sea_state_zone_data2",
	&"sea_state_zone_data3",
	&"coastal_composition_debug",
	&"coastal_debug_gain",
	&"camera_world_xz",
	&"shore_stabilization_enabled",
	&"shore_vertical_depth_range_m",
	&"shore_horizontal_depth_range_m",
	&"coastal_min_valid_depth_m",
	&"coastal_cell_size_m",
	&"short_geometry_strength",
	&"short_vertex_normal_strength",
	&"ocean_crest_sharpen_strength",
	&"ocean_crest_sharpen_threshold",
	&"ocean_crest_sharpen_max_gain",
	&"ocean_crest_sharpen_long_weight",
	&"ocean_crest_sharpen_mid_weight",
]

var _propagation = null
var _warp = null
var _long_hs_m := 0.5
var _coastal_fraction := 0.5
var _sea_level_y := 0.0
var _sea_state_zone_descriptors: Array[Dictionary] = []
var _surface_material: ShaderMaterial = null
var _material: ShaderMaterial = null
var _template_mesh: ArrayMesh = null
var _ribbons: Array[MeshInstance3D] = []
var _anchors: Array[Dictionary] = []
var _debug_mode: int = DebugMode.LIP
var _debug_slot := 0 # -1 => ALL; sólo filtra visibilidad en REGION/FORCE_LIP.
var _debug_stage := 1.0 # 4C-S1: stage manual de la cross-section LUT (0..1).
var _profile_forward_sign := 1.0 # u+ de la LUT sigue el viaje físico de la cresta.
var _takeover_mask_enabled := false # 4C-S3: Y toggle del takeover mask debug.
var _last_fingerprint := ""
var _query_batch: Callable = Callable() # Legacy/tests: batch completa del módulo.
var _breaker_height_batch: Callable = Callable() # Specialized DETECT/ACTIVE height-only batch.
var _breaker_slope_batch: Callable = Callable() # Specialized candidate slope batch.
var _tracking: Array[Dictionary] = [] # 4C-S4: {crest_s, stage, valid, tracked_xz, h0, h3, h6} por slot.
var _last_track_time := 0.0 # 4C-S4: último render_time usado por el tracker (HUD).
var _detector_debug_instance: MeshInstance3D = null
var _detector_debug_mesh: ImmediateMesh = null
var _detector_debug_material: StandardMaterial3D = null
var _last_force_spawn_result := "never_requested"

## 5R.1F: scheduler del detector. El breaker ACTIVE es autónomo (nunca consulta
## OceanQuery); COOLDOWN tampoco consulta; sólo los slots DETECT se consultan en
## ticks de 20 Hz con round robin de DETECTOR_SLOTS_PER_TICK por tick.
const DETECTOR_INTERVAL := 0.05
const DETECTOR_SLOTS_PER_TICK := 2

var _next_detector_time := 0.0
var _detector_cursor := 0
var _detector_tick := 0
var _detector_queried_slots_last_tick := 0
var _detector_queried_points_last_tick := 0
var _structural_energy_update_pending := false
var _wave_transition_active := false
var _wave_transition_alpha := 0.0
var _active_tracking_queries_last_tick := 0
var _active_tracking_points_last_tick := 0
var _detector_slope_queries_last_tick := 0
var _detector_slope_points_last_tick := 0
var _detector_query_elapsed_ms_last_tick := 0.0
var _skip_next_structural_energy_update := false
var _diagnostic_visible := true
var _corridor_evaluation_count := 0
var _corridor_evaluation_usec := 0

# PERF-P0: counters are opt-in and deliberately separate from the normal
# scheduler.  When disabled, the hot path pays only the enclosing boolean
# checks; snapshots are created only when a diagnostic runner requests one.
var _performance_diagnostics_enabled := false
var _performance_diagnostic_frames := 0
var _performance_diagnostic_active_frames := 0
var _performance_diagnostic_idle_frames := 0
var _performance_diagnostic_active_slot_visits := 0
var _performance_diagnostic_cooldown_slot_visits := 0
var _performance_diagnostic_active_breaker_updates := 0
var _performance_diagnostic_predicted_breaker_calls := 0
var _performance_diagnostic_trajectory_steps := 0
var _performance_diagnostic_velocity_calls := 0
var _performance_diagnostic_velocity_propagation_samples := 0
var _performance_diagnostic_host_propagation_samples := 0
var _performance_diagnostic_detector_ticks := 0
var _performance_diagnostic_detector_slots := 0
var _performance_diagnostic_detector_height_points := 0
var _performance_diagnostic_detector_slope_points := 0


# --- Réplicas CPU de edge_fade/envelope para validación y HUD. ---
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
	_ensure_detector_debug_visual()
	set_energy_model(long_hs_m, coastal_fraction)
	_sync_uniforms()
	visible = _diagnostic_visible


func set_query_source(callable: Callable) -> void:
	## Legacy/test hook: Callable batch completa de OceanQuery.
	_query_batch = callable


func set_breaker_query_sources(height_callable: Callable, slope_callable: Callable) -> void:
	## Specialized path: DETECT/ACTIVE no usa la hot path general de OceanQuery.
	_breaker_height_batch = height_callable
	_breaker_slope_batch = slope_callable


func _call_breaker_heights(positions: Array[Vector3], render_time: float) -> Array:
	if _breaker_height_batch.is_valid():
		return _breaker_height_batch.call(positions, render_time)
	if _query_batch.is_valid():
		return _query_batch.call(positions, render_time)
	return []


func _call_breaker_slopes(positions: Array[Vector3], render_time: float) -> Array:
	if _breaker_slope_batch.is_valid():
		return _breaker_slope_batch.call(positions, render_time)
	return []


func set_sea_state_zones(descriptors: Array[Dictionary]) -> void:
	var copied: Array[Dictionary] = []
	for descriptor in descriptors:
		copied.append(descriptor.duplicate())
	_sea_state_zone_descriptors = copied
	for anchor in _anchors:
		anchor["zone_breaking_activity"] = _local_breaking_activity(Vector2(anchor.get("xz", Vector2.ZERO)))


func _local_breaking_activity(point: Vector2) -> float:
	var long_amplitude := 1.0
	var choppiness := 1.0
	for descriptor in _sea_state_zone_descriptors:
		var zone_weight := SeaStateZoneMathScript.weight_and_gradient(
			point,
			Vector2(descriptor.get("center", Vector2.ZERO)),
			Vector2(descriptor.get("axis", Vector2.RIGHT)),
			Vector2(descriptor.get("half_extents", Vector2.ZERO)),
			float(descriptor.get("feather", 0.0))
		).x
		zone_weight *= clampf(float(descriptor.get("strength", 1.0)), 0.0, 1.0)
		if zone_weight <= 0.0:
			continue
		var target: Vector4 = descriptor.get("target", Vector4.ONE)
		long_amplitude = lerpf(long_amplitude, target.x, zone_weight)
		choppiness = lerpf(choppiness, target.w, zone_weight)
	return clampf(long_amplitude * (0.5 + 0.5 * choppiness), 0.0, 1.0)


func set_diagnostic_visible(value: bool) -> void:
	## Instrumentación del Lab: sólo oculta el Node3D; no altera pool ni scheduler.
	_diagnostic_visible = value
	visible = _diagnostic_visible and _propagation != null and _propagation.is_valid()


func diagnostic_visible() -> bool:
	return _diagnostic_visible


func set_energy_model(long_hs_m: float, coastal_fraction: float) -> void:
	## Recoloca los anchors con el modelo de energía vigente (Hs + fracción del
	## split). Si hay breakers ACTIVE, difiere la operación destructiva hasta que
	## terminen; nunca reinicia su lifecycle por un cambio de sea state.
	set_runtime_energy_model(long_hs_m, coastal_fraction)
	if _skip_next_structural_energy_update:
		_skip_next_structural_energy_update = false
		return
	if _has_active_breakers():
		_structural_energy_update_pending = true
		return
	_apply_structural_energy_model()


func set_runtime_energy_model(long_hs_m: float, coastal_fraction: float) -> void:
	## Ruta de transición por frame: sólo alimenta energía para detección/spawns
	## futuros. No recoloca anchors, resetea scheduler ni recrea ribbons.
	_long_hs_m = maxf(long_hs_m, 0.0)
	_coastal_fraction = clampf(coastal_fraction, 0.0, 1.0)


func begin_wave_transition(target_long_hs_m: float, target_coastal_fraction: float) -> void:
	## Construye una vez el superset CURRENT + TARGET sin tocar slots ACTIVE.
	if _propagation == null or not _propagation.is_valid():
		return
	var target_anchors := _place_anchors_for_energy(target_long_hs_m, target_coastal_fraction)
	var merged: Array[Dictionary] = []
	for source_anchor in _anchors:
		var anchor := source_anchor.duplicate()
		anchor["current_eligibility"] = _anchor_runtime_eligibility(anchor)
		anchor["target_eligibility"] = _anchor_eligibility_for_energy(anchor, target_long_hs_m, target_coastal_fraction)
		anchor["retire_when_idle"] = false
		merged.append(anchor)
	for target_anchor in target_anchors:
		var match := _find_matching_anchor(merged, target_anchor)
		if match >= 0:
			merged[match]["target_eligibility"] = float(target_anchor.get("target_eligibility", 1.0))
			continue
		if merged.size() >= min(TRANSITION_MAX_ANCHORS, max_breakers * 2):
			break
		var target_only := target_anchor.duplicate()
		target_only["current_eligibility"] = 0.0
		target_only["target_eligibility"] = float(target_anchor.get("target_eligibility", 1.0))
		target_only["retire_when_idle"] = false
		merged.append(target_only)
	_wave_transition_active = true
	_wave_transition_alpha = 0.0
	_structural_energy_update_pending = false
	_install_transition_anchors(merged)


func set_wave_transition_alpha(alpha: float, effective_long_hs_m: float, effective_coastal_fraction: float) -> void:
	if not _wave_transition_active:
		return
	_wave_transition_alpha = clampf(alpha, 0.0, 1.0)
	set_runtime_energy_model(effective_long_hs_m, effective_coastal_fraction)


func complete_wave_transition() -> void:
	## Promueve TARGET sin reconstruir. Los anchors CURRENT exclusivos sobreviven
	## sólo hasta que su slot ACTIVE termine naturalmente.
	if not _wave_transition_active:
		return
	_wave_transition_alpha = 1.0
	_wave_transition_active = false
	for anchor in _anchors:
		anchor["current_eligibility"] = float(anchor.get("target_eligibility", 0.0))
		anchor["retire_when_idle"] = float(anchor.get("target_eligibility", 0.0)) <= 0.0001
	_structural_energy_update_pending = false
	_skip_next_structural_energy_update = true
	_prune_retired_transition_anchors()


func _apply_structural_energy_model() -> void:
	if _propagation != null and _propagation.is_valid():
		_anchors = _place_anchors()
	else:
		_anchors.clear()
	_reset_scheduler()
	_rebuild_instances()
	_structural_energy_update_pending = false


func _has_active_breakers() -> bool:
	for entry in _tracking:
		if bool(entry.get("active", false)):
			return true
	return false


func disable() -> void:
	## Coastal OFF / sin batimetría / PREBREAK inválido: ningún breaker visible.
	_anchors.clear()
	_reset_scheduler()
	_rebuild_instances()
	visible = false
	if _detector_debug_instance != null:
		_detector_debug_instance.visible = false
	if _surface_material != null:
		_surface_material.set_shader_parameter(&"breaker_takeover_count", 0)


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, DebugMode.LIP, DebugMode.OFF)
	if _material != null:
		_material.set_shader_parameter(&"breaker_debug_mode", _debug_mode)
	_apply_visibility()
	_sync_takeover_mask()
	_update_detector_debug_visual()


func cycle_debug_mode() -> void:
	set_debug_mode((_debug_mode + 1) % (DebugMode.OFF + 1))


func set_debug_slot(slot: int) -> void:
	## slot -1 => ALL. Sólo filtra visibilidad en REGION/FORCE_LIP; no recrea mesh.
	_debug_slot = slot
	_apply_visibility()
	_sync_takeover_mask()
	_update_detector_debug_visual()


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
	return "REVERSED_DEBUG" if _profile_forward_sign < 0.0 else "FORWARD"


func debug_profile_aligned() -> bool:
	## La orientación canónica es FORWARD: u+ de la LUT y direction_xz
	## apuntan hacia donde viaja físicamente la cresta.
	return _profile_forward_sign > 0.0


func toggle_takeover_mask() -> void:
	## Debug FORCE_LIP independiente del takeover ACTIVE de producción.
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
			"corridor_start_xz": Vector2(anchor.get("corridor_start_xz", anchor["xz"])),
			"corridor_end_xz": Vector2(anchor.get("corridor_end_xz", anchor["xz"])),
			"corridor_length_m": float(anchor.get("corridor_length_m", 0.0)),
			"available_corridor_length_m": float(anchor.get("available_corridor_length_m", 0.0)),
			"required_development_distance_m": float(anchor.get("required_development_distance_m", 0.0)),
			"lifecycle_distance_m": float(anchor.get("lifecycle_distance_m", 0.0)),
			"depth_start_m": float(anchor.get("depth_start_m", 0.0)),
			"depth_end_m": float(anchor.get("depth_end_m", 0.0)),
			"pressure_start": float(anchor.get("pressure_start", 0.0)),
			"pressure_end": float(anchor.get("pressure_end", 0.0)),
			"spawn_depth_m": float(anchor.get("spawn_depth_m", anchor["depth_m"])),
			"spawn_pressure": float(anchor.get("spawn_pressure", anchor["pressure"])),
			"spawn_shore_vertical_weight": float(anchor.get("spawn_shore_vertical_weight", 1.0)),
			"spawn_shore_horizontal_weight": float(anchor.get("spawn_shore_horizontal_weight", 1.0)),
			"surf_corridor_eligible": bool(anchor.get("surf_corridor_eligible", false)),
			"corridor_reason": str(anchor.get("corridor_reason", "legacy")),
			"direction_source": "render_direction" if _propagation != null and _propagation.has_render_direction() else "local_direction",
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
		var life_t := float(entry.get("life_t", 0.0))
		var stage := float(entry.get("stage", 0.0))
		var lifecycle_phase := "DETECT"
		if active:
			lifecycle_phase = "SPAWN" if life_t < 0.05 else ("GROW" if stage < 0.35 else ("LIP" if stage < 0.68 else ("PLUNGE" if stage < 0.88 else "FADE")))
		result.append({
			"state": state_name,
			"wave": int(entry.get("wave_serial", 0)),
			"last_decided_wave_serial": int(entry.get("last_decided_wave_serial", -1)),
			"best_wave_serial": int(entry.get("best_wave_serial", -1)),
			"best_score": float(entry.get("best_score", 0.0)),
			"best_candidate_s": float(entry.get("best_candidate_s", 0.0)),
			"best_in_window": bool(entry.get("best_in_window", false)),
			"best_pressure": float(entry.get("best_pressure", 0.0)),
			"best_prominence": float(entry.get("best_prominence", 0.0)),
			"best_steepness": float(entry.get("best_steepness", 0.0)),
			"best_crest_confidence": float(entry.get("best_crest_confidence", 0.0)),
			"best_physical_breaking_strength": float(entry.get("best_physical_breaking_strength", 0.0)),
			"candidate_s": float(entry.get("candidate_s", 0.0)),
			"candidate_s_lambda": float(entry.get("candidate_s_lambda", 0.0)),
			"previous_s": float(entry.get("detector_prev_s", 0.0)),
			"previous_s_lambda": float(entry.get("previous_s_lambda", 0.0)),
			"advancing": bool(entry.get("advancing", false)),
			"in_window": bool(entry.get("in_window", false)),
			"cooldown_done": bool(entry.get("cooldown_done", true)),
			"query_valid": bool(entry.get("query_valid", false)),
			"candidate_valid": bool(entry.get("candidate_valid", false)),
			"stencil_valid_count": int(entry.get("stencil_valid_count", 0)),
			"stencil_valid_start": int(entry.get("stencil_valid_start", -1)),
			"stencil_valid_end": int(entry.get("stencil_valid_end", -1)),
			"invalid_sample_indices": str(entry.get("invalid_sample_indices", "")),
			"spawn_window_start_s": float(entry.get("spawn_window_start_s", 0.0)),
			"spawn_window_end_s": float(entry.get("spawn_window_end_s", 0.0)),
			"pressure": float(entry.get("pressure", 0.0)),
			"pressure_score": float(entry.get("pressure_score", 0.0)),
			"pressure_contribution": float(entry.get("pressure_contribution", 0.0)),
			"prominence": float(entry.get("prominence", 0.0)),
			"prominence_score": float(entry.get("prominence_score", 0.0)),
			"prominence_contribution": float(entry.get("prominence_contribution", 0.0)),
			"local_hs": float(entry.get("local_hs", 0.0)),
			"slope_long": float(entry.get("slope_long", 0.0)),
			"steepness_score": float(entry.get("steepness_score", 0.0)),
			"steepness_contribution": float(entry.get("steepness_contribution", 0.0)),
			"raw_score": float(entry.get("raw_score", 0.0)),
			"anchor_eligibility": float(entry.get("anchor_eligibility", 0.0)),
			"zone_activity": float(entry.get("zone_activity", 0.0)),
			"final_score": float(entry.get("final_score", entry.get("score", 0.0))),
			"physical_breaking_strength": float(entry.get("physical_breaking_strength", 0.0)),
			"crest_confidence": float(entry.get("crest_confidence", 0.0)),
			"detector_gate_reason": str(entry.get("detector_gate_reason", "pending")),
			"score": float(entry.get("score", 0.0)),
			"probability": float(entry.get("probability", 0.0)),
			"roll": float(entry.get("roll", 0.0)),
			"life_t": float(entry.get("life_t", 0.0)),
			"stage": float(entry.get("stage", 0.0)),
			"lifecycle_phase": lifecycle_phase,
			"alpha": float(entry.get("alpha", 0.0)),
			"phase_speed": float(entry.get("phase_speed", 0.0)),
			"remaining": float(entry.get("remaining", 0.0)),
			"h0": float(entry.get("h0", 0.0)),
			"h3": float(entry.get("h3", 0.0)),
			"h6": float(entry.get("h6", 0.0)),
			"current_depth_m": float(entry.get("current_depth_m", 0.0)),
			"current_pressure": float(entry.get("current_pressure", 0.0)),
			"spawn_depth_m": float(entry.get("spawn_depth_m", 0.0)),
			"spawn_pressure": float(entry.get("spawn_pressure", 0.0)),
			"spawn_shore_vertical_weight": float(entry.get("spawn_shore_vertical_weight", 1.0)),
			"spawn_shore_horizontal_weight": float(entry.get("spawn_shore_horizontal_weight", 1.0)),
			"shore_vertical_weight": float(entry.get("shore_vertical_weight", 1.0)),
			"shore_horizontal_weight": float(entry.get("shore_horizontal_weight", 1.0)),
			"distance_travelled_m": float(entry.get("distance_travelled_m", 0.0)),
			"distance_remaining_in_corridor_m": float(entry.get("distance_remaining_in_corridor_m", entry.get("remaining", 0.0))),
			"corridor_start_xz": Vector2(entry.get("corridor_start_xz", Vector2.ZERO)),
			"corridor_end_xz": Vector2(entry.get("corridor_end_xz", Vector2.ZERO)),
			"corridor_length_m": float(entry.get("corridor_length_m", 0.0)),
			"required_development_distance_m": float(entry.get("required_development_distance_m", 0.0)),
			"lifecycle_distance_m": float(entry.get("lifecycle_distance_m", 0.0)),
			"surf_corridor_eligible": bool(entry.get("surf_corridor_eligible", false)),
			"corridor_reason": str(entry.get("corridor_reason", "legacy")),
			"direction_dot": Vector2(entry.get("spawn_direction", Vector2.RIGHT)).normalized().dot(Vector2(_anchors[index].get("direction", Vector2.RIGHT)).normalized()),
		})
	return result


func track_time() -> float:
	## 4C-S4: último render_time evaluado por el tracker (para verificar que avanza).
	return _last_track_time


func set_performance_diagnostics_enabled(enabled: bool) -> void:
	## PERF-P0: profiling-only counters.  This never changes pool scheduling,
	## queries, lifecycle, or visual state.
	_performance_diagnostics_enabled = enabled
	_reset_performance_diagnostics()


func performance_diagnostics_enabled() -> bool:
	return _performance_diagnostics_enabled


func reset_performance_diagnostics() -> void:
	_reset_performance_diagnostics()


func performance_diagnostics_snapshot() -> Dictionary:
	## Allocation is intentionally pull-based: normal runtime never builds this
	## Dictionary.  Totals can be differenced by a benchmark between frames.
	return {
		"enabled": _performance_diagnostics_enabled,
		"frames": _performance_diagnostic_frames,
		"active_frames": _performance_diagnostic_active_frames,
		"idle_frames": _performance_diagnostic_idle_frames,
		"active_slot_visits": _performance_diagnostic_active_slot_visits,
		"cooldown_slot_visits": _performance_diagnostic_cooldown_slot_visits,
		"active_breaker_updates": _performance_diagnostic_active_breaker_updates,
		"predicted_breaker_calls": _performance_diagnostic_predicted_breaker_calls,
		"trajectory_steps": _performance_diagnostic_trajectory_steps,
		"velocity_calls": _performance_diagnostic_velocity_calls,
		"velocity_propagation_samples": _performance_diagnostic_velocity_propagation_samples,
		"host_propagation_samples": _performance_diagnostic_host_propagation_samples,
		"coastal_propagation_samples": _performance_diagnostic_velocity_propagation_samples + _performance_diagnostic_host_propagation_samples,
		"detector_ticks": _performance_diagnostic_detector_ticks,
		"detector_slots": _performance_diagnostic_detector_slots,
		"detector_height_points": _performance_diagnostic_detector_height_points,
		"detector_slope_points": _performance_diagnostic_detector_slope_points,
	}


func _reset_performance_diagnostics() -> void:
	_performance_diagnostic_frames = 0
	_performance_diagnostic_active_frames = 0
	_performance_diagnostic_idle_frames = 0
	_performance_diagnostic_active_slot_visits = 0
	_performance_diagnostic_cooldown_slot_visits = 0
	_performance_diagnostic_active_breaker_updates = 0
	_performance_diagnostic_predicted_breaker_calls = 0
	_performance_diagnostic_trajectory_steps = 0
	_performance_diagnostic_velocity_calls = 0
	_performance_diagnostic_velocity_propagation_samples = 0
	_performance_diagnostic_host_propagation_samples = 0
	_performance_diagnostic_detector_ticks = 0
	_performance_diagnostic_detector_slots = 0
	_performance_diagnostic_detector_height_points = 0
	_performance_diagnostic_detector_slope_points = 0


func _record_performance_diagnostic_frame() -> void:
	_performance_diagnostic_frames += 1
	if _has_active_breakers():
		_performance_diagnostic_active_frames += 1
	else:
		_performance_diagnostic_idle_frames += 1


func summary() -> Dictionary:
	var active_count := 0
	for entry in _tracking:
		if bool(entry.get("active", false)):
			active_count += 1
	return {
		"configured": _propagation != null and _propagation.is_valid(),
		"slots": _anchors.size(),
		"max_slots": max_breakers,
		"debug": breaker_debug_name(),
		"debug_slot": _debug_slot,
		"anchors": anchor_snapshot(),
		# 5R.1F: métricas del scheduler (sin queries adicionales).
		"detector_hz": int(round(1.0 / DETECTOR_INTERVAL)),
		"detector_tick": _detector_tick,
		"queried_slots_last_tick": _detector_queried_slots_last_tick,
		"queried_points_last_tick": _detector_queried_points_last_tick,
		"transition_active": _wave_transition_active,
		"transition_alpha": _wave_transition_alpha,
		"transition_anchor_count": _anchors.size(),
		"active_breaker_count": active_count,
		"active_tracking_queries_last_tick": _active_tracking_queries_last_tick,
		"active_tracking_points_last_tick": _active_tracking_points_last_tick,
		"detector_slope_queries_last_tick": _detector_slope_queries_last_tick,
		"detector_slope_points_last_tick": _detector_slope_points_last_tick,
		"slope_queries_last_tick": _detector_slope_queries_last_tick,
		"slope_points_last_tick": _detector_slope_points_last_tick,
		"detector_query_elapsed_ms_last_tick": _detector_query_elapsed_ms_last_tick,
		"corridor_evaluation_count": _corridor_evaluation_count,
		"corridor_evaluation_ms": float(_corridor_evaluation_usec) * 0.001,
		"breaker_height_source_valid": _breaker_height_batch.is_valid() or _query_batch.is_valid(),
		"breaker_slope_source_valid": _breaker_slope_batch.is_valid(),
		"force_spawn_last_result": _last_force_spawn_result,
	}


func force_spawn_selected_slot() -> bool:
	## Diagnóstico explícito: salta sólo score/probability/roll. Conserva la
	## muestra candidate real, posición, dirección, wavelength y cooldown.
	if _debug_slot < 0 or _debug_slot >= _anchors.size():
		_last_force_spawn_result = "NO_SLOT_SELECTED"
		return false
	var index := _debug_slot
	var anchor: Dictionary = _anchors[index]
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	if bool(entry.get("active", false)):
		_last_force_spawn_result = "SLOT_ALREADY_ACTIVE"
		return false
	var render_time := _last_track_time
	if render_time < float(entry.get("next_spawn_time", 0.0)):
		_last_force_spawn_result = "COOLDOWN"
		return false
	if not bool(entry.get("detector_initialized", false)):
		_last_force_spawn_result = "NO_REAL_CANDIDATE_YET"
		return false
	var wavelength := float(anchor["wavelength_m"])
	var candidate_s := float(entry.get("candidate_s", 0.0))
	var travel_dir := Vector2(anchor["direction"]).normalized()
	var score := clampf(float(entry.get("final_score", entry.get("score", 0.0))), 0.0, 1.0)
	var state := _base_state(entry)
	for key in entry.keys():
		state[key] = entry[key]
	state["detector_gate_reason"] = "FORCE_SPAWN"
	state["last_decided_wave_serial"] = int(entry.get("wave_serial", 0))
	_spawn_breaker(index, anchor, candidate_s, travel_dir, wavelength, score, render_time, state)
	_last_force_spawn_result = "SPAWNED_SLOT_%d" % index
	return true


func _process(_delta: float) -> void:
	if _material == null or _surface_material == null:
		return
	_update_detector_debug_visual()
	# SimulationClock is the sole temporal authority. Camera movement while
	# paused may change visibility/fade uniforms, but never breaker world state.
	var clock = get_node_or_null("/root/SimulationClock")
	if clock != null and clock.is_paused():
		_sync_production_takeover()
		return
	_sync_uniforms()
	_update_tracking()
	if _performance_diagnostics_enabled:
		_record_performance_diagnostic_frame()
	_sync_production_takeover()
	_prune_retired_transition_anchors()
	if _structural_energy_update_pending and not _has_active_breakers():
		_apply_structural_energy_model()


func _ensure_detector_debug_visual() -> void:
	if _detector_debug_instance != null:
		return
	_detector_debug_mesh = ImmediateMesh.new()
	_detector_debug_material = StandardMaterial3D.new()
	_detector_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_detector_debug_material.vertex_color_use_as_albedo = true
	_detector_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_detector_debug_material.no_depth_test = true
	_detector_debug_material.render_priority = 127
	_detector_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_detector_debug_instance = MeshInstance3D.new()
	_detector_debug_instance.name = "DetectorDebugOverlay"
	_detector_debug_instance.mesh = _detector_debug_mesh
	_detector_debug_instance.material_override = _detector_debug_material
	_detector_debug_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_detector_debug_instance.top_level = true
	_detector_debug_instance.visible = false
	add_child(_detector_debug_instance)


func _update_detector_debug_visual() -> void:
	if _detector_debug_instance == null or _detector_debug_mesh == null:
		return
	var detector_enabled := _debug_mode == DebugMode.DETECTOR and _diagnostic_visible and visible and not _anchors.is_empty()
	var has_active_marker := false
	if _debug_mode != DebugMode.OFF and _diagnostic_visible and visible and not _anchors.is_empty():
		for index in _anchors.size():
			if _debug_slot >= 0 and index != _debug_slot:
				continue
			if index < _tracking.size() and bool(_tracking[index].get("active", false)):
				has_active_marker = true
				break
	var active_marker_enabled := has_active_marker
	var enabled := detector_enabled or active_marker_enabled
	_detector_debug_instance.visible = enabled
	if not enabled:
		return
	_detector_debug_mesh.clear_surfaces()
	_detector_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _detector_debug_material)
	for index in _anchors.size():
		if _debug_slot >= 0 and index != _debug_slot:
			continue
		var anchor: Dictionary = _anchors[index]
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		var origin := Vector2(anchor.get("xz", Vector2.ZERO))
		var direction := Vector2(anchor.get("direction", Vector2.RIGHT)).normalized()
		var side := direction.orthogonal()
		var wavelength := maxf(float(anchor.get("wavelength_m", 1.0)), 0.001)
		var y := _sea_level_y + 0.18
		if detector_enabled:
			# Dirección física y línea longitudinal de muestreo.
			_add_debug_line(origin - direction * wavelength * 0.50, origin + direction * wavelength * 0.50, y, Color(0.20, 0.55, 1.0, 0.95))
			_add_debug_line(origin, origin + direction * wavelength * 0.22, y + 0.01, Color(0.35, 0.75, 1.0, 1.0))
			_add_debug_line(origin + direction * wavelength * 0.22, origin + direction * wavelength * 0.16 + side * wavelength * 0.06, y + 0.01, Color(0.35, 0.75, 1.0, 1.0))
			_add_debug_line(origin + direction * wavelength * 0.22, origin + direction * wavelength * 0.16 - side * wavelength * 0.06, y + 0.01, Color(0.35, 0.75, 1.0, 1.0))
			# Anchor marker.
			_add_debug_line(origin - side * 0.55, origin + side * 0.55, y + 0.02, Color.WHITE)
			_add_debug_line(origin - direction * 0.55, origin + direction * 0.55, y + 0.02, Color.WHITE)
			# Spawn window: las constantes permanecen visibles en metros reales.
			var window_start := SPAWN_S_START_LAMBDA * wavelength
			var window_end := SPAWN_S_END_LAMBDA * wavelength
			var window_a := origin + direction * window_start
			var window_b := origin + direction * window_end
			_add_debug_line(window_a - side * 0.80, window_a + side * 0.80, y + 0.03, Color(1.0, 0.82, 0.10, 1.0))
			_add_debug_line(window_b - side * 0.80, window_b + side * 0.80, y + 0.03, Color(1.0, 0.82, 0.10, 1.0))
			_add_debug_line(window_a, window_b, y + 0.03, Color(1.0, 0.82, 0.10, 0.85))
			# Candidate: verde sólo si la muestra está en ventana y avanzando.
			var candidate_s := float(entry.get("candidate_s", 0.0))
			var candidate := origin + direction * candidate_s
			var candidate_color := Color(0.15, 1.0, 0.25, 1.0) if bool(entry.get("in_window", false)) and bool(entry.get("advancing", false)) else Color(1.0, 0.12, 0.10, 1.0)
			_add_debug_line(candidate - side * 1.0, candidate + side * 1.0, y + 0.05, candidate_color)
			_add_debug_line(candidate - direction * 1.0, candidate + direction * 1.0, y + 0.05, candidate_color)
		if active_marker_enabled and bool(entry.get("active", false)):
			# Baliza magenta sobre el agua: tracked y spawn quedan distinguibles.
			var tracked := Vector2(entry.get("tracked_xz", origin))
			var spawn := Vector2(entry.get("spawn_xz", origin))
			_add_debug_vertical(tracked, y - 0.15, y + 4.0, Color(1.0, 0.10, 0.80, 1.0))
			_add_debug_line(tracked - side * 1.2, tracked + side * 1.2, y + 0.08, Color(1.0, 0.10, 0.80, 1.0))
			_add_debug_line(tracked - direction * 1.2, tracked + direction * 1.2, y + 0.08, Color(1.0, 0.10, 0.80, 1.0))
			_add_debug_line(spawn - side * 0.85, spawn + side * 0.85, y + 0.10, Color(0.10, 1.0, 1.0, 1.0))
			_add_debug_line(spawn - direction * 0.85, spawn + direction * 0.85, y + 0.10, Color(0.10, 1.0, 1.0, 1.0))
			_add_debug_line(tracked, tracked + direction * 3.0, y + 0.10, Color(1.0, 0.35, 0.90, 0.95))
			if _debug_mode == DebugMode.REGION:
				var half_length := maxf(float(entry.get("spawn_wavelength", wavelength)) * ribbon_length_lambda * 0.325, 0.5)
				var half_width := maxf(ribbon_width_m * 0.5, 0.5)
				var a := tracked - direction * half_length - side * half_width
				var b := tracked + direction * half_length - side * half_width
				var c := tracked + direction * half_length + side * half_width
				var d := tracked - direction * half_length + side * half_width
				_add_debug_line(a, b, y + 0.11, Color(1.0, 0.45, 0.10, 0.95))
				_add_debug_line(b, c, y + 0.11, Color(1.0, 0.45, 0.10, 0.95))
				_add_debug_line(c, d, y + 0.11, Color(1.0, 0.45, 0.10, 0.95))
				_add_debug_line(d, a, y + 0.11, Color(1.0, 0.45, 0.10, 0.95))
	_detector_debug_mesh.surface_set_color(Color.WHITE)
	_detector_debug_mesh.surface_end()


func _add_debug_line(a: Vector2, b: Vector2, y: float, color: Color) -> void:
	_detector_debug_mesh.surface_set_color(color)
	_detector_debug_mesh.surface_add_vertex(Vector3(a.x, y, a.y))
	_detector_debug_mesh.surface_set_color(color)
	_detector_debug_mesh.surface_add_vertex(Vector3(b.x, y, b.y))


func _add_debug_vertical(point: Vector2, y0: float, y1: float, color: Color) -> void:
	_detector_debug_mesh.surface_set_color(color)
	_detector_debug_mesh.surface_add_vertex(Vector3(point.x, y0, point.y))
	_detector_debug_mesh.surface_set_color(color)
	_detector_debug_mesh.surface_add_vertex(Vector3(point.x, y1, point.y))


# --- Internos. ---

func _sync_uniforms() -> void:
	if _surface_material == null:
		return
	for uniform_name in _UNIFORMS_TO_COPY:
		var value: Variant = _surface_material.get_shader_parameter(uniform_name)
		if value != null:
			_material.set_shader_parameter(uniform_name, value)


func _update_tracking() -> void:
	## 5R.1F/S5: scheduling por estados:
	##  - ACTIVE: lifecycle y trayectoria RK2 desde CoastalPropagationData; no query.
	##  - COOLDOWN: si render_time < next_spawn_time NO se consulta; sólo se
	##    mantiene/publica el countdown.
	##  - DETECT: sólo se consulta en ticks de DETECTOR_INTERVAL (20 Hz), con
	##    round robin de DETECTOR_SLOTS_PER_TICK slots por tick y UNA llamada
	##    batch por tick. Sin catch-up de ticks perdidos.
	if _anchors.is_empty() or _ribbons.size() != _anchors.size():
		return
	var clock = get_node_or_null("/root/SimulationClock")
	var render_time: float = clock.get_render_time() if clock != null else 0.0
	_last_track_time = render_time
	_update_active_slots(render_time)
	_update_cooldown_slots(render_time)
	if not _breaker_height_batch.is_valid() and not _query_batch.is_valid():
		# ACTIVE already advanced above; DETECT simply waits for its source.
		return
	# A spectrum transition is a pending endpoint operation for breaker queries.
	# Keep existing ribbons procedural and defer both crest re-sampling and DETECT
	# until the new endpoint is installed; never put the 30 ms Reduced LONG path
	# on the frame scheduler during a transition.
	if _wave_transition_active:
		return
	if render_time < _next_detector_time:
		return
	_run_detector_tick(render_time)
	_next_detector_time = render_time + DETECTOR_INTERVAL


func _update_active_slots(render_time: float) -> void:
	## 5R.1F: todos los slots ACTIVE avanzan su lifecycle autónomo cada frame.
	for index in _anchors.size():
		if _performance_diagnostics_enabled:
			_performance_diagnostic_active_slot_visits += 1
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		if bool(entry.get("active", false)):
			if _performance_diagnostics_enabled:
				_performance_diagnostic_active_breaker_updates += 1
			_update_active_breaker(index, entry, render_time)


func _update_cooldown_slots(render_time: float) -> void:
	## 5R.1F: slots en COOLDOWN (active=false y render_time < next_spawn_time) no
	## consultan OceanQuery; sólo se refresca/publica el countdown para el HUD.
	for index in _anchors.size():
		if _performance_diagnostics_enabled:
			_performance_diagnostic_cooldown_slot_visits += 1
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		if bool(entry.get("active", false)):
			continue
		var next_spawn: float = float(entry.get("next_spawn_time", 0.0))
		if render_time >= next_spawn:
			continue # DETECT: lo gestiona el detector tick.
		var state := _base_state(entry)
		state["active"] = false
		state["valid"] = 0.0
		state["stage"] = 0.0
		state["alpha"] = 0.0
		state["remaining"] = maxf(0.0, next_spawn - render_time)
		_publish_slot(index, state)


func _reset_scheduler() -> void:
	## 5R.1F: reinicio determinista del scheduler en rebuild/reset.
	_next_detector_time = 0.0
	_detector_cursor = 0
	_detector_tick = 0
	_detector_queried_slots_last_tick = 0
	_detector_queried_points_last_tick = 0
	_detector_slope_queries_last_tick = 0
	_detector_slope_points_last_tick = 0
	_detector_query_elapsed_ms_last_tick = 0.0


func _run_detector_tick(render_time: float) -> void:
	## 5R.1F: un tick de detector. Selecciona como máximo DETECTOR_SLOTS_PER_TICK
	## slots DETECT recorriendo circularmente desde _detector_cursor (ignora
	## ACTIVE y COOLDOWN) y consulta TODOS en UNA única batch.
	_detector_tick += 1
	if _performance_diagnostics_enabled:
		_performance_diagnostic_detector_ticks += 1
	_detector_slope_queries_last_tick = 0
	_detector_slope_points_last_tick = 0
	_detector_query_elapsed_ms_last_tick = 0.0
	var total_anchors := _anchors.size()
	if total_anchors == 0:
		_detector_queried_slots_last_tick = 0
		_detector_queried_points_last_tick = 0
		return
	var selected: Array[int] = []
	var inspected := 0
	var cursor := _detector_cursor
	while selected.size() < DETECTOR_SLOTS_PER_TICK and inspected < total_anchors:
		var index: int = cursor % total_anchors
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		var active: bool = bool(entry.get("active", false))
		var next_spawn: float = float(entry.get("next_spawn_time", 0.0))
		if not active and render_time >= next_spawn:
			selected.append(index)
		inspected += 1
		cursor += 1
	_detector_cursor = cursor % total_anchors
	if selected.is_empty():
		_detector_queried_slots_last_tick = 0
		_detector_queried_points_last_tick = 0
		return
	var positions: Array[Vector3] = []
	var base_index: Array[int] = []
	for index in selected:
		var anchor: Dictionary = _anchors[index]
		var travel_dir := Vector2(anchor["direction"]).normalized()
		var wavelength := float(anchor["wavelength_m"])
		base_index.append(positions.size())
		for offset in CREST_SAMPLE_OFFSETS:
			var xz: Vector2 = Vector2(anchor["xz"]) + travel_dir * (float(offset) * wavelength)
			positions.append(Vector3(xz.x, _sea_level_y, xz.y))
	if _performance_diagnostics_enabled:
		_performance_diagnostic_detector_slots += selected.size()
		_performance_diagnostic_detector_height_points += positions.size()
	var query_start_usec := Time.get_ticks_usec()
	var samples: Array = _call_breaker_heights(positions, render_time)
	_detector_query_elapsed_ms_last_tick = float(Time.get_ticks_usec() - query_start_usec) * 0.001
	if samples.size() != positions.size():
		_clear_tracking()
		return
	_detector_queried_slots_last_tick = selected.size()
	_detector_queried_points_last_tick = positions.size()
	for sel in selected.size():
		var index: int = selected[sel]
		var anchor: Dictionary = _anchors[index]
		var base: int = base_index[sel]
		var heights := PackedFloat32Array()
		var valid_flags := PackedByteArray()
		var invalid_indices := PackedStringArray()
		for k in CREST_SAMPLE_OFFSETS.size():
			var sample: OceanQuerySample = samples[base + k]
			var valid := sample != null and sample.valid and is_finite(sample.height)
			valid_flags.append(1 if valid else 0)
			heights.append(sample.height if valid else 0.0)
			if not valid:
				invalid_indices.append(str(k))
		var candidate_probe := _find_valid_crest_run(valid_flags)
		if candidate_probe.is_empty():
			_update_slot_invalid(index, Vector2(anchor["xz"]), render_time, "INVALID_QUERY_SAMPLE", ",".join(invalid_indices))
			continue
		_update_slot(index, anchor, heights, valid_flags, samples, base, render_time)
		if index < _tracking.size():
			_tracking[index]["h0"] = heights[0]
			_tracking[index]["h3"] = heights[3]
			_tracking[index]["h6"] = heights[6]


func _find_valid_crest_run(valid_flags: PackedByteArray) -> Dictionary:
	## Un stencil parcial es seguro sólo en un run contiguo con centro+vecinos:
	## no se interpola ni se cruza un punto inválido/LAND.
	var best_start := -1
	var best_end := -1
	var run_start := -1
	for index in valid_flags.size() + 1:
		var is_valid := index < valid_flags.size() and valid_flags[index] != 0
		if is_valid and run_start < 0:
			run_start = index
		if (not is_valid or index == valid_flags.size()) and run_start >= 0:
			var run_end := index - 1
			if run_end - run_start + 1 >= CORRIDOR_MIN_PATH_SAMPLES and (best_start < 0 or run_end - run_start > best_end - best_start):
				best_start = run_start
				best_end = run_end
			run_start = -1
	if best_start < 0:
		return {}
	return {"start": best_start, "end": best_end, "count": best_end - best_start + 1}


func _detect_candidate(heights: PackedFloat32Array, valid_flags: PackedByteArray, wavelength: float, samples: Array, base: int) -> Dictionary:
	## Detector de stencil contiguo: prominencia + parábola. Devuelve
	## candidate_s, prominence, índice y el sample del candidato.
	var run := _find_valid_crest_run(valid_flags)
	if run.is_empty():
		return {"valid": false, "reason": "INVALID_QUERY_SAMPLE"}
	var best_index := int(run["start"]) + 1
	var best_prominence := -INF
	for k in range(int(run["start"]) + 1, int(run["end"])):
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
	return {"valid": true, "s": candidate_s, "prominence": best_prominence, "index": best_index, "sample": samples[base + best_index], "valid_count": int(run["count"]), "valid_start": int(run["start"]), "valid_end": int(run["end"])}


func _update_slot(index: int, anchor: Dictionary, heights: PackedFloat32Array, valid_flags: PackedByteArray, samples: Array, base: int, render_time: float) -> void:
	var wavelength := float(anchor["wavelength_m"])
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	var candidate := _detect_candidate(heights, valid_flags, wavelength, samples, base)
	if not bool(candidate.get("valid", false)):
		_update_slot_invalid(index, Vector2(anchor["xz"]), render_time, str(candidate.get("reason", "INVALID_QUERY_SAMPLE")))
		return
	if _breaker_slope_batch.is_valid() and not bool(entry.get("active", false)):
		var travel_dir := Vector2(anchor["direction"]).normalized()
		var candidate_xz := Vector2(anchor["xz"]) + travel_dir * float(candidate["s"])
		var slope_start_usec := Time.get_ticks_usec()
		if _performance_diagnostics_enabled:
			_performance_diagnostic_detector_slope_points += 1
		var slope_samples := _call_breaker_slopes([Vector3(candidate_xz.x, _sea_level_y, candidate_xz.y)], render_time)
		_detector_query_elapsed_ms_last_tick += float(Time.get_ticks_usec() - slope_start_usec) * 0.001
		if slope_samples.size() == 1 and slope_samples[0] != null:
			candidate["sample"] = slope_samples[0]
			_detector_slope_queries_last_tick += 1
			_detector_slope_points_last_tick += 1
	if bool(entry.get("active", false)):
		_update_active_breaker(index, entry, render_time)
	else:
		_run_detector(index, anchor, candidate, render_time)


func _update_active_breaker(index: int, entry: Dictionary, render_time: float) -> void:
	## Lifecycle autónomo; durante transición sólo suma la corrección de cresta ya
	## obtenida por la batch limitada, sin alterar spawn_time ni stage.
	var spawn_time: float = float(entry.get("spawn_time", render_time))
	var duration: float = maxf(float(entry.get("lifecycle_duration", 1.0)), 0.001)
	var age: float = maxf(0.0, render_time - spawn_time)
	var life_t: float = clampf(age / duration, 0.0, 1.0)
	if life_t >= 1.0:
		var finished_state := _base_state(entry)
		finished_state["active"] = false
		finished_state["valid"] = 0.0
		finished_state["stage"] = 0.0
		finished_state["alpha"] = 0.0
		finished_state["tracked_xz"] = Vector2(entry.get("spawn_xz", Vector2.ZERO))
		finished_state["detector_initialized"] = false
		finished_state["detector_prev_s"] = 0.0
		finished_state["life_t"] = 1.0
		finished_state["remaining"] = maxf(0.0, float(entry.get("next_spawn_time", render_time)) - render_time)
		_publish_slot(index, finished_state)
		return
	var stage: float = _smoothstep(0.0, STAGE_LIFE_END, life_t)
	var fade_in: float = _smoothstep(0.0, FADE_IN_END_LIFE, life_t)
	var fade_out: float = 1.0 - _smoothstep(FADE_OUT_BEGIN_LIFE, 1.0, life_t)
	var alpha: float = fade_in * fade_out
	var phase_speed: float = maxf(float(entry.get("spawn_phase_speed", 0.1)), 0.1)
	var breaker_xz := _predicted_breaker_xz(entry, render_time) + Vector2(entry.get("crest_correction_xz", Vector2.ZERO))
	var host_sample := _sample_propagation(breaker_xz)
	alpha *= _local_breaking_activity(breaker_xz)
	var active_state := _base_state(entry)
	active_state["active"] = true
	active_state["valid"] = 1.0
	active_state["stage"] = stage
	active_state["alpha"] = alpha
	active_state["tracked_xz"] = breaker_xz
	active_state["life_t"] = life_t
	active_state["phase_speed"] = phase_speed
	active_state["current_depth_m"] = float(host_sample.get("depth_m", 0.0))
	active_state["current_pressure"] = estimate_depth_pressure(_long_hs_m, _coastal_fraction, float(host_sample.get("shoaling", 1.0)), maxf(float(host_sample.get("depth_m", 0.0)), 0.001))
	active_state["shore_vertical_weight"] = _shore_weight(float(host_sample.get("depth_m", 0.0)), true)
	active_state["shore_horizontal_weight"] = _shore_weight(float(host_sample.get("depth_m", 0.0)), false)
	active_state["distance_travelled_m"] = Vector2(entry.get("spawn_xz", Vector2.ZERO)).distance_to(breaker_xz)
	active_state["distance_remaining_in_corridor_m"] = Vector2(entry.get("corridor_end_xz", breaker_xz)).distance_to(breaker_xz) if bool(entry.get("surf_corridor_eligible", false)) else 0.0
	active_state["remaining"] = active_state["distance_remaining_in_corridor_m"]
	_publish_slot(index, active_state)


func _predicted_breaker_xz(entry: Dictionary, render_time: float) -> Vector2:
	if _performance_diagnostics_enabled:
		_performance_diagnostic_predicted_breaker_calls += 1
	var spawn_time: float = float(entry.get("spawn_time", render_time))
	var age: float = maxf(0.0, render_time - spawn_time)
	var phase_speed: float = maxf(float(entry.get("spawn_phase_speed", 0.1)), 0.1)
	var predicted_position: Vector2 = Vector2(entry.get("spawn_xz", Vector2.ZERO))
	if _propagation == null or not _propagation.is_valid() or age <= 0.0:
		return predicted_position + Vector2(entry.get("spawn_direction", Vector2.RIGHT)).normalized() * (phase_speed * age)
	# Fixed-step midpoint integration makes the result independent of render FPS.
	var steps := clampi(int(ceil(age / TRAJECTORY_STEP_S)), 1, TRAJECTORY_MAX_STEPS)
	if _performance_diagnostics_enabled:
		_performance_diagnostic_trajectory_steps += steps
	var dt := age / float(steps)
	for _step in steps:
		var velocity_0 := _sample_velocity(predicted_position, entry)
		var midpoint := predicted_position + Vector2(velocity_0["direction"]) * float(velocity_0["speed"]) * dt * 0.5
		var velocity_mid := _sample_velocity(midpoint, entry)
		predicted_position += Vector2(velocity_mid["direction"]) * float(velocity_mid["speed"]) * dt
	return predicted_position


func _sample_velocity(world_xz: Vector2, entry: Dictionary) -> Dictionary:
	if _performance_diagnostics_enabled:
		_performance_diagnostic_velocity_calls += 1
	var fallback_direction := Vector2(entry.get("spawn_direction", Vector2.RIGHT)).normalized()
	var fallback_speed := maxf(float(entry.get("spawn_phase_speed", 0.1)), 0.1)
	if _propagation == null or not _propagation.is_valid():
		return {"direction": fallback_direction, "speed": fallback_speed}
	if _performance_diagnostics_enabled:
		_performance_diagnostic_velocity_propagation_samples += 1
	var sample = _propagation.sample_propagation(world_xz)
	if sample == null or not sample.valid or not sample.in_bounds:
		return {"direction": fallback_direction, "speed": fallback_speed}
	var direction: Vector2 = Vector2(sample.render_direction_xz).normalized()
	if direction.length_squared() < 0.5:
		direction = fallback_direction
	return {"direction": direction, "speed": maxf(float(sample.phase_speed_mps), 0.1)}


func _sample_propagation(world_xz: Vector2) -> Dictionary:
	if _propagation == null or not _propagation.is_valid():
		return {"valid": false, "in_bounds": false, "depth_m": 0.0, "shoaling": 1.0, "direction": Vector2.RIGHT}
	if _performance_diagnostics_enabled:
		_performance_diagnostic_host_propagation_samples += 1
	var sample = _propagation.sample_propagation(world_xz)
	if sample == null:
		return {"valid": false, "in_bounds": false, "depth_m": 0.0, "shoaling": 1.0, "direction": Vector2.RIGHT}
	var direction := Vector2(sample.render_direction_xz).normalized() if _propagation.has_render_direction() else Vector2(sample.local_direction_xz).normalized()
	if direction.length_squared() < 0.5:
		direction = Vector2.RIGHT
	return {
		"valid": bool(sample.valid),
		"in_bounds": bool(sample.in_bounds),
		"depth_m": float(sample.depth_m),
		"shoaling": float(sample.shoaling_scale),
		"local_k": float(sample.local_k),
		"wavelength_m": float(sample.wavelength_m),
		"phase_speed_mps": float(sample.phase_speed_mps),
		"direction": direction,
	}


func _shore_weight(depth_m: float, vertical: bool) -> float:
	var depth := maxf(depth_m, 0.0)
	var presence := _smoothstep(0.0, maxf(0.25, 0.001), depth)
	var depth_range := Vector2(0.25, 6.0) if vertical else Vector2(0.75, 12.0)
	return presence * _smoothstep(minf(depth_range.x, depth_range.y), maxf(depth_range.x, depth_range.y), depth)


func _run_detector(index: int, anchor: Dictionary, candidate: Dictionary, render_time: float) -> void:
	var wavelength := float(anchor["wavelength_m"])
	var travel_dir := Vector2(anchor["direction"]).normalized()
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	var detector_initialized: bool = bool(entry.get("detector_initialized", false))
	var detector_prev_s: float = float(entry.get("detector_prev_s", 0.0))
	var wave_serial: int = int(entry.get("wave_serial", 0))
	var last_decided: int = int(entry.get("last_decided_wave_serial", -1))
	var next_spawn_time: float = float(entry.get("next_spawn_time", 0.0))
	var candidate_s: float = float(candidate["s"])
	var score_details := _break_score_details(anchor, candidate, travel_dir)
	var s_start := SPAWN_S_START_LAMBDA * wavelength
	var s_end := SPAWN_S_END_LAMBDA * wavelength

	if not detector_initialized:
		var initial_state := _base_state(entry)
		initial_state["detector_initialized"] = true
		initial_state["detector_prev_s"] = candidate_s
		initial_state["active"] = false
		initial_state["valid"] = 0.0
		initial_state["tracked_xz"] = Vector2(anchor["xz"])
		initial_state["candidate_s"] = candidate_s
		initial_state["remaining"] = maxf(0.0, next_spawn_time - render_time)
		_apply_anchor_diagnostics(initial_state, anchor)
		initial_state["stencil_valid_count"] = int(candidate.get("valid_count", 0))
		initial_state["stencil_valid_start"] = int(candidate.get("valid_start", -1))
		initial_state["stencil_valid_end"] = int(candidate.get("valid_end", -1))
		_apply_detector_diagnostics(initial_state, score_details, candidate_s, candidate_s, false, candidate_s >= s_start and candidate_s <= s_end, render_time >= next_spawn_time, wave_serial, "INITIALIZED", wavelength)
		initial_state["best_wave_serial"] = wave_serial
		initial_state["best_score"] = float(score_details["final_score"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_candidate_s"] = candidate_s if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_pressure"] = float(score_details["pressure"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_prominence"] = float(score_details["prominence"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_steepness"] = float(score_details["slope_long"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_crest_confidence"] = float(score_details["crest_confidence"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		initial_state["best_physical_breaking_strength"] = float(score_details["physical_breaking_strength"]) if candidate_s >= s_start and candidate_s <= s_end else 0.0
		_publish_slot(index, initial_state)
		return

	# Identificar nueva ola: wrap shoreward -> offshore.
	if candidate_s < detector_prev_s - NEW_WAVE_WRAP_LAMBDA * wavelength:
		wave_serial += 1
	var new_wave := wave_serial != int(entry.get("wave_serial", 0))
	var advancing: bool = candidate_s > detector_prev_s
	detector_prev_s = candidate_s

	var in_window: bool = candidate_s >= s_start and candidate_s <= s_end
	var cooldown_done: bool = render_time >= next_spawn_time

	var candidate_state := _base_state(entry)
	candidate_state["detector_initialized"] = true
	candidate_state["detector_prev_s"] = detector_prev_s
	candidate_state["wave_serial"] = wave_serial
	candidate_state["active"] = false
	candidate_state["valid"] = 0.0
	candidate_state["stage"] = 0.0
	candidate_state["alpha"] = 0.0
	candidate_state["tracked_xz"] = Vector2(anchor["xz"])
	candidate_state["candidate_s"] = candidate_s
	candidate_state["remaining"] = maxf(0.0, next_spawn_time - render_time)
	_apply_anchor_diagnostics(candidate_state, anchor)
	candidate_state["stencil_valid_count"] = int(candidate.get("valid_count", 0))
	candidate_state["stencil_valid_start"] = int(candidate.get("valid_start", -1))
	candidate_state["stencil_valid_end"] = int(candidate.get("valid_end", -1))
	if new_wave or int(entry.get("best_wave_serial", -1)) != wave_serial:
		candidate_state["best_wave_serial"] = wave_serial
		candidate_state["best_score"] = 0.0
		candidate_state["best_candidate_s"] = 0.0
		candidate_state["best_pressure"] = 0.0
		candidate_state["best_prominence"] = 0.0
		candidate_state["best_steepness"] = 0.0
		candidate_state["best_crest_confidence"] = 0.0
		candidate_state["best_physical_breaking_strength"] = 0.0
	if in_window and advancing and (not bool(candidate_state.get("best_in_window", false)) or float(score_details["final_score"]) > float(candidate_state.get("best_score", 0.0))):
		candidate_state["best_score"] = float(score_details["final_score"])
		candidate_state["best_candidate_s"] = candidate_s
		candidate_state["best_pressure"] = float(score_details["pressure"])
		candidate_state["best_prominence"] = float(score_details["prominence"])
		candidate_state["best_steepness"] = float(score_details["slope_long"])
		candidate_state["best_crest_confidence"] = float(score_details["crest_confidence"])
		candidate_state["best_physical_breaking_strength"] = float(score_details["physical_breaking_strength"])
	var best_score := float(candidate_state.get("best_score", 0.0))
	var best_candidate_s := float(candidate_state.get("best_candidate_s", 0.0))
	var best_physical_strength := float(candidate_state.get("best_physical_breaking_strength", 0.0))
	var best_crest_confidence := float(candidate_state.get("best_crest_confidence", 0.0))
	var best_in_window := best_candidate_s >= s_start and best_candidate_s <= s_end
	var marginal_signal := clampf(0.70 * best_physical_strength + 0.30 * best_crest_confidence, 0.0, 1.0)
	var probability: float = _smoothstep(PHYSICAL_BREAKING_MARGINAL_THRESHOLD, PHYSICAL_BREAKING_GUARANTEED_THRESHOLD, marginal_signal) if best_physical_strength >= PHYSICAL_BREAKING_MARGINAL_THRESHOLD else 0.0
	var roll: float = _deterministic_roll(index, wave_serial)
	_apply_detector_diagnostics(candidate_state, score_details, candidate_s, detector_prev_s, advancing, in_window, cooldown_done, wave_serial, "PENDING", wavelength)
	candidate_state["probability"] = probability
	candidate_state["roll"] = roll
	candidate_state["best_in_window"] = best_in_window
	candidate_state["best_score"] = best_score
	candidate_state["best_candidate_s"] = best_candidate_s
	candidate_state["best_physical_breaking_strength"] = best_physical_strength

	var passed_spawn_window := candidate_s > s_end and best_in_window
	var guaranteed := best_physical_strength >= PHYSICAL_BREAKING_GUARANTEED_THRESHOLD
	var corridor_eligible := bool(anchor.get("surf_corridor_eligible", false))
	if corridor_eligible and best_in_window and advancing and wave_serial != last_decided and cooldown_done and (passed_spawn_window or guaranteed):
		candidate_state["last_decided_wave_serial"] = wave_serial
		candidate_state["detector_gate_reason"] = "PHYSICAL_BREAK_GUARANTEED" if guaranteed else ("MARGINAL_ROLL" if best_physical_strength >= PHYSICAL_BREAKING_MARGINAL_THRESHOLD else "WEAK_REJECT")
		if guaranteed or roll < probability:
			candidate_state["detector_gate_reason"] = "SPAWNED"
			_spawn_breaker(index, anchor, best_candidate_s, travel_dir, wavelength, best_score, render_time, candidate_state)
			return
	else:
		if not corridor_eligible:
			candidate_state["detector_gate_reason"] = "NO_SURF_CORRIDOR"
		elif not advancing:
			candidate_state["detector_gate_reason"] = "WAITING_CREST"
		elif not best_in_window and candidate_s <= s_end:
			candidate_state["detector_gate_reason"] = "OUTSIDE_WINDOW"
		elif not best_in_window:
			candidate_state["detector_gate_reason"] = "WAITING_CREST"
		elif not passed_spawn_window and not guaranteed:
			candidate_state["detector_gate_reason"] = "WAITING_CREST"
		elif wave_serial == last_decided:
			candidate_state["detector_gate_reason"] = "WAVE_ALREADY_DECIDED"
		elif not cooldown_done:
			candidate_state["detector_gate_reason"] = "COOLDOWN"
	_publish_slot(index, candidate_state)


func _apply_detector_diagnostics(state: Dictionary, score_details: Dictionary, candidate_s: float, previous_s: float, advancing: bool, in_window: bool, cooldown_done: bool, wave_serial: int, reason: String, wavelength: float) -> void:
	state["candidate_s"] = candidate_s
	state["candidate_s_lambda"] = candidate_s / maxf(wavelength, 0.001)
	state["previous_s"] = previous_s
	state["previous_s_lambda"] = previous_s / maxf(wavelength, 0.001)
	state["advancing"] = advancing
	state["in_window"] = in_window
	state["cooldown_done"] = cooldown_done
	state["query_valid"] = true
	state["candidate_valid"] = true
	state["spawn_window_start_s"] = SPAWN_S_START_LAMBDA * wavelength
	state["spawn_window_end_s"] = SPAWN_S_END_LAMBDA * wavelength
	state["wave_serial"] = wave_serial
	state["pressure"] = float(score_details.get("pressure", 0.0))
	state["pressure_score"] = float(score_details.get("pressure_score", 0.0))
	state["pressure_contribution"] = float(score_details.get("pressure_contribution", 0.0))
	state["prominence"] = float(score_details.get("prominence", 0.0))
	state["prominence_score"] = float(score_details.get("prominence_score", 0.0))
	state["prominence_contribution"] = float(score_details.get("prominence_contribution", 0.0))
	state["local_hs"] = float(score_details.get("local_hs", 0.0))
	state["slope_long"] = float(score_details.get("slope_long", 0.0))
	state["steepness_score"] = float(score_details.get("steepness_score", 0.0))
	state["steepness_contribution"] = float(score_details.get("steepness_contribution", 0.0))
	state["raw_score"] = float(score_details.get("raw_score", 0.0))
	state["anchor_eligibility"] = float(score_details.get("anchor_eligibility", 0.0))
	state["zone_activity"] = float(score_details.get("zone_activity", 0.0))
	state["final_score"] = float(score_details.get("final_score", 0.0))
	state["score"] = state["final_score"]
	state["physical_breaking_strength"] = float(score_details.get("physical_breaking_strength", 0.0))
	state["crest_confidence"] = float(score_details.get("crest_confidence", 0.0))
	state["detector_gate_reason"] = reason


func _apply_anchor_diagnostics(state: Dictionary, anchor: Dictionary) -> void:
	for key in [
		"corridor_start_xz", "corridor_end_xz", "corridor_length_m", "available_corridor_length_m",
		"required_development_distance_m", "lifecycle_distance_m", "depth_start_m", "depth_end_m",
		"pressure_start", "pressure_end", "spawn_depth_m", "spawn_pressure",
		"spawn_shore_vertical_weight", "spawn_shore_horizontal_weight", "surf_corridor_eligible", "corridor_reason",
	]:
		if anchor.has(key):
			state[key] = anchor[key]


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
	var spawn_sample := _sample_propagation(Vector2(state["spawn_xz"]))
	if bool(spawn_sample.get("valid", false)):
		state["spawn_depth_m"] = float(spawn_sample.get("depth_m", 0.0))
		state["spawn_pressure"] = estimate_depth_pressure(_long_hs_m, _coastal_fraction, float(spawn_sample.get("shoaling", 1.0)), maxf(float(spawn_sample.get("depth_m", 0.0)), 0.001))
		state["spawn_shore_vertical_weight"] = _shore_weight(float(spawn_sample.get("depth_m", 0.0)), true)
		state["spawn_shore_horizontal_weight"] = _shore_weight(float(spawn_sample.get("depth_m", 0.0)), false)
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
	return float(_break_score_details(anchor, candidate, travel_dir).get("final_score", 0.0))


func _break_score_details(anchor: Dictionary, candidate: Dictionary, travel_dir: Vector2) -> Dictionary:
	var pressure := float(anchor.get("spawn_pressure", estimate_depth_pressure(_long_hs_m, _coastal_fraction, float(anchor.get("shoaling", 1.0)), float(anchor.get("depth_m", 1.0)))))
	var pressure_score: float = _smoothstep(anchor_min_depth_pressure, minf(anchor_max_depth_pressure, 1.15), pressure)
	var local_hs: float = estimate_local_hs(_long_hs_m, _coastal_fraction, float(anchor.get("shoaling", 1.0)))
	var prominence: float = maxf(float(candidate.get("prominence", 0.0)), 0.0)
	var prominence_score: float = _smoothstep(0.04 * local_hs, 0.20 * local_hs, prominence)
	var sample = candidate.get("sample")
	var slope_long := 0.0
	if sample != null:
		var ny: float = maxf(absf(sample.normal.y), 0.05)
		var slope_xz := -Vector2(sample.normal.x, sample.normal.z) / ny
		slope_long = absf(slope_xz.dot(travel_dir))
	var steepness_score: float = _smoothstep(0.20, 0.75, slope_long)
	var raw_score := clampf(SCORE_PRESSURE_WEIGHT * pressure_score + SCORE_PROMINENCE_WEIGHT * prominence_score + SCORE_STEEPNESS_WEIGHT * steepness_score, 0.0, 1.0)
	var eligibility := _anchor_runtime_eligibility_details(anchor)
	var physical_strength := _physical_breaking_strength(anchor)
	# Confidence refines candidate selection only; it is never a physical gate.
	var crest_confidence := clampf(0.50 + 0.35 * prominence_score + 0.15 * steepness_score, 0.0, 1.0)
	return {
		"pressure": pressure,
		"pressure_score": pressure_score,
		"pressure_contribution": SCORE_PRESSURE_WEIGHT * pressure_score,
		"local_hs": local_hs,
		"prominence": prominence,
		"prominence_score": prominence_score,
		"prominence_contribution": SCORE_PROMINENCE_WEIGHT * prominence_score,
		"slope_long": slope_long,
		"steepness_score": steepness_score,
		"steepness_contribution": SCORE_STEEPNESS_WEIGHT * steepness_score,
		"raw_score": raw_score,
		"anchor_eligibility": eligibility["anchor_eligibility"],
		"zone_activity": eligibility["zone_activity"],
		"final_score": raw_score * eligibility["anchor_eligibility"] * eligibility["zone_activity"],
		"physical_breaking_strength": physical_strength,
		"crest_confidence": crest_confidence,
	}


func _physical_breaking_strength(anchor: Dictionary) -> float:
	## Autoridad de que la ola rompe: corridor + pressure + desarrollo. No usa
	## prominence ni specialized slope, que sólo refinan dónde está la cresta.
	if not bool(anchor.get("surf_corridor_eligible", false)):
		return 0.0
	var spawn_pressure := float(anchor.get("spawn_pressure", 0.0))
	var pressure_start := float(anchor.get("pressure_start", 0.0))
	var pressure_end := float(anchor.get("pressure_end", 0.0))
	var pressure_at_break := maxf(maxf(spawn_pressure, pressure_start), pressure_end)
	var pressure_progression := _smoothstep(CORRIDOR_ONSET_PRESSURE, anchor_max_depth_pressure, pressure_at_break)
	var spawn_pressure_fit := _smoothstep(anchor_min_depth_pressure, ANCHOR_PRESSURE_TARGET, spawn_pressure)
	var required := maxf(float(anchor.get("required_development_distance_m", 0.0)), 0.001)
	var available := maxf(float(anchor.get("available_corridor_length_m", 0.0)), 0.0)
	var development_ratio := available / required
	var development_strength := _smoothstep(CORRIDOR_MIN_SHALLOW_DISTANCE_FRACTION, 1.50, development_ratio)
	return clampf(0.45 * pressure_progression + 0.20 * spawn_pressure_fit + 0.35 * development_strength, 0.0, 1.0)


func _deterministic_roll(slot: int, wave_serial: int) -> float:
	var clock = get_node_or_null("/root/SimulationClock")
	var rng_seed: int = int(clock.simulation_seed if clock != null else 20260820) & 0x7FFFFFFF
	rng_seed ^= ((slot + 1) * 0x9E3779B1) & 0x7FFFFFFF
	rng_seed ^= ((wave_serial + 1) * 0x85EBCA6B) & 0x7FFFFFFF
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
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
		"spawn_depth_m": float(entry.get("spawn_depth_m", 0.0)),
		"spawn_pressure": float(entry.get("spawn_pressure", 0.0)),
		"spawn_shore_vertical_weight": float(entry.get("spawn_shore_vertical_weight", 1.0)),
		"spawn_shore_horizontal_weight": float(entry.get("spawn_shore_horizontal_weight", 1.0)),
		"lifecycle_duration": float(entry.get("lifecycle_duration", 1.0)),
		"next_spawn_time": float(entry.get("next_spawn_time", 0.0)),
		"detector_initialized": bool(entry.get("detector_initialized", false)),
		"detector_prev_s": float(entry.get("detector_prev_s", 0.0)),
		"wave_serial": int(entry.get("wave_serial", 0)),
		"last_decided_wave_serial": int(entry.get("last_decided_wave_serial", -1)),
		"best_wave_serial": int(entry.get("best_wave_serial", -1)),
		"best_score": float(entry.get("best_score", 0.0)),
		"best_candidate_s": float(entry.get("best_candidate_s", 0.0)),
		"best_in_window": bool(entry.get("best_in_window", false)),
		"best_pressure": float(entry.get("best_pressure", 0.0)),
		"best_prominence": float(entry.get("best_prominence", 0.0)),
		"best_steepness": float(entry.get("best_steepness", 0.0)),
		"best_crest_confidence": float(entry.get("best_crest_confidence", 0.0)),
		"best_physical_breaking_strength": float(entry.get("best_physical_breaking_strength", 0.0)),
		"candidate_s": float(entry.get("candidate_s", 0.0)),
		"candidate_s_lambda": float(entry.get("candidate_s_lambda", 0.0)),
		"previous_s": float(entry.get("previous_s", entry.get("detector_prev_s", 0.0))),
		"previous_s_lambda": float(entry.get("previous_s_lambda", 0.0)),
		"advancing": bool(entry.get("advancing", false)),
		"in_window": bool(entry.get("in_window", false)),
		"cooldown_done": bool(entry.get("cooldown_done", true)),
		"query_valid": bool(entry.get("query_valid", false)),
		"candidate_valid": bool(entry.get("candidate_valid", false)),
		"stencil_valid_count": int(entry.get("stencil_valid_count", 0)),
		"stencil_valid_start": int(entry.get("stencil_valid_start", -1)),
		"stencil_valid_end": int(entry.get("stencil_valid_end", -1)),
		"invalid_sample_indices": str(entry.get("invalid_sample_indices", "")),
		"spawn_window_start_s": float(entry.get("spawn_window_start_s", 0.0)),
		"spawn_window_end_s": float(entry.get("spawn_window_end_s", 0.0)),
		"pressure": float(entry.get("pressure", 0.0)),
		"pressure_score": float(entry.get("pressure_score", 0.0)),
		"pressure_contribution": float(entry.get("pressure_contribution", 0.0)),
		"prominence": float(entry.get("prominence", 0.0)),
		"prominence_score": float(entry.get("prominence_score", 0.0)),
		"prominence_contribution": float(entry.get("prominence_contribution", 0.0)),
		"local_hs": float(entry.get("local_hs", 0.0)),
		"slope_long": float(entry.get("slope_long", 0.0)),
		"steepness_score": float(entry.get("steepness_score", 0.0)),
		"steepness_contribution": float(entry.get("steepness_contribution", 0.0)),
		"raw_score": float(entry.get("raw_score", 0.0)),
		"anchor_eligibility": float(entry.get("anchor_eligibility", 0.0)),
		"zone_activity": float(entry.get("zone_activity", 0.0)),
		"final_score": float(entry.get("final_score", entry.get("score", 0.0))),
		"physical_breaking_strength": float(entry.get("physical_breaking_strength", 0.0)),
		"crest_confidence": float(entry.get("crest_confidence", 0.0)),
		"detector_gate_reason": str(entry.get("detector_gate_reason", "pending")),
		"score": float(entry.get("score", 0.0)),
		"probability": float(entry.get("probability", 0.0)),
		"roll": float(entry.get("roll", 0.0)),
		"life_t": float(entry.get("life_t", 0.0)),
		"phase_speed": float(entry.get("phase_speed", 0.0)),
		"current_depth_m": float(entry.get("current_depth_m", entry.get("depth_m", 0.0))),
		"current_pressure": float(entry.get("current_pressure", entry.get("pressure", 0.0))),
		"shore_vertical_weight": float(entry.get("shore_vertical_weight", 1.0)),
		"shore_horizontal_weight": float(entry.get("shore_horizontal_weight", 1.0)),
		"distance_travelled_m": float(entry.get("distance_travelled_m", 0.0)),
		"distance_remaining_in_corridor_m": float(entry.get("distance_remaining_in_corridor_m", entry.get("remaining", 0.0))),
		"remaining": float(entry.get("remaining", 0.0)),
		"crest_correction_xz": entry.get("crest_correction_xz", Vector2.ZERO),
		"crest_miss_ticks": int(entry.get("crest_miss_ticks", 0)),
		"host_crest_fade_start": float(entry.get("host_crest_fade_start", -1.0)),
		"corridor_start_xz": entry.get("corridor_start_xz", Vector2.ZERO),
		"corridor_end_xz": entry.get("corridor_end_xz", Vector2.ZERO),
		"corridor_length_m": float(entry.get("corridor_length_m", 0.0)),
		"available_corridor_length_m": float(entry.get("available_corridor_length_m", 0.0)),
		"required_development_distance_m": float(entry.get("required_development_distance_m", 0.0)),
		"lifecycle_distance_m": float(entry.get("lifecycle_distance_m", 0.0)),
		"depth_start_m": float(entry.get("depth_start_m", 0.0)),
		"depth_end_m": float(entry.get("depth_end_m", 0.0)),
		"pressure_start": float(entry.get("pressure_start", 0.0)),
		"pressure_end": float(entry.get("pressure_end", 0.0)),
		"surf_corridor_eligible": bool(entry.get("surf_corridor_eligible", false)),
		"corridor_reason": str(entry.get("corridor_reason", "legacy")),
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
		ribbon.set_instance_shader_parameter(&"breaker_spawn_strength", float(state.get("spawn_strength", 0.0)))
		ribbon.set_instance_shader_parameter(&"breaker_spawn_hs_m", float(state.get("spawn_local_hs", 0.0)))


func _update_slot_invalid(index: int, anchor_xz: Vector2, render_time: float, reason: String = "INVALID_QUERY_SAMPLE", invalid_indices: String = "unknown") -> void:
	## 4C-S4.2: muestras no válidas -> el breaker activo sigue su lifecycle
	## autónomo (no depende del detector); si no, permanece IDLE.
	var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
	if bool(entry.get("active", false)):
		_update_active_breaker(index, entry, render_time)
		return
	var state := _base_state(entry)
	state["active"] = false
	state["valid"] = 0.0
	state["query_valid"] = false
	state["candidate_valid"] = false
	state["detector_gate_reason"] = reason
	state["invalid_sample_indices"] = invalid_indices
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
	return _place_anchors_for_energy(_long_hs_m, _coastal_fraction)


func _place_anchors_for_energy(long_hs_m: float, coastal_fraction: float) -> Array[Dictionary]:
	## Candidatos = celdas válidas/alcanzadas de la propagación cuya presión de
	## profundidad estimada cae en la zona de pre-break. Antes de elegirlos se
	## valida el corredor costero y se retrocede desde el punto de plunge para
	## colocar el spawn al inicio físico del desarrollo. Todo desde CPU baked.
	_corridor_evaluation_count = 0
	_corridor_evaluation_usec = 0
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
	var dir_x: PackedFloat32Array = propagation.render_direction_x if propagation.has_render_direction() else propagation.local_direction_x
	var dir_z: PackedFloat32Array = propagation.render_direction_z if propagation.has_render_direction() else propagation.local_direction_z
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
			var pressure := estimate_depth_pressure(long_hs_m, coastal_fraction, shoal_arr[index], depth)
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
				"pressure_fit": 1.0 - clampf(absf(pressure - ANCHOR_PRESSURE_TARGET) / maxf(anchor_max_depth_pressure - anchor_min_depth_pressure, 0.001), 0.0, 1.0),
				"direction": direction,
				"wavelength_m": maxf(wave_arr[index], 0.5),
				"local_k": maxf(k_arr[index], k0),
				"shoaling": shoal_arr[index],
				"phase_speed_mps": phase_speed_arr[index],
				"zone_breaking_activity": _local_breaking_activity(propagation.world_origin_xz + Vector2(float(x), float(z)) * propagation.cell_size_m),
				"current_eligibility": _anchor_eligibility_for_pressure(pressure),
				"target_eligibility": _anchor_eligibility_for_pressure(pressure),
				"retire_when_idle": false,
			})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a["pressure_fit"] - b["pressure_fit"]) > 0.001:
			return a["pressure_fit"] > b["pressure_fit"]
		if absf(a["pressure"] - b["pressure"]) > 0.001:
			return a["pressure"] < b["pressure"]
		if absf(a["xz"].x - b["xz"].x) > 0.001:
			return a["xz"].x < b["xz"].x
		return a["xz"].y < b["xz"].y)
	var picked: Array[Dictionary] = []
	var corridor_candidates := 0
	for candidate in candidates:
		if corridor_candidates >= CORRIDOR_MAX_CANDIDATES:
			break
		corridor_candidates += 1
		var prepared := _prepare_anchor_from_corridor(candidate, long_hs_m, coastal_fraction)
		if prepared.is_empty():
			continue
		if picked.size() >= max_breakers:
			break
		var too_close := false
		for anchor in picked:
			if (Vector2(anchor["xz"]) - Vector2(prepared["xz"])).length() < anchor_min_spacing_m:
				too_close = true
				break
		if too_close:
			continue
		picked.append(prepared)
	return picked


func _prepare_anchor_from_corridor(candidate: Dictionary, long_hs_m: float, coastal_fraction: float) -> Dictionary:
	var corridor := _evaluate_breaking_corridor(candidate, long_hs_m, coastal_fraction)
	if not bool(corridor.get("surf_corridor_eligible", false)):
		return {}
	var spawn_xz: Vector2 = Vector2(corridor.get("spawn_xz", candidate["xz"]))
	var spawn := _sample_propagation(spawn_xz)
	if not bool(spawn.get("valid", false)) or not bool(spawn.get("in_bounds", false)):
		return {}
	var prepared := candidate.duplicate()
	prepared["xz"] = spawn_xz
	prepared["depth_m"] = float(spawn.get("depth_m", candidate.get("depth_m", 0.0)))
	prepared["shoaling"] = float(spawn.get("shoaling", candidate.get("shoaling", 1.0)))
	prepared["wavelength_m"] = maxf(float(spawn.get("wavelength_m", candidate.get("wavelength_m", 0.5))), 0.5)
	prepared["phase_speed_mps"] = maxf(float(spawn.get("phase_speed_mps", candidate.get("phase_speed_mps", 0.1))), 0.1)
	prepared["local_k"] = maxf(float(spawn.get("local_k", candidate.get("local_k", 0.0))), 0.0)
	prepared["direction"] = Vector2(spawn.get("direction", candidate.get("direction", Vector2.RIGHT))).normalized()
	prepared["pressure"] = float(corridor.get("spawn_pressure", candidate.get("pressure", 0.0)))
	prepared["pressure_fit"] = 1.0 - clampf(absf(prepared["pressure"] - ANCHOR_PRESSURE_TARGET) / maxf(anchor_max_depth_pressure - anchor_min_depth_pressure, 0.001), 0.0, 1.0)
	prepared["zone_breaking_activity"] = _local_breaking_activity(spawn_xz)
	prepared["current_eligibility"] = _anchor_eligibility_for_pressure(float(prepared["pressure"]))
	prepared["target_eligibility"] = prepared["current_eligibility"]
	for key in corridor.keys():
		prepared[key] = corridor[key]
	prepared["spawn_depth_m"] = float(corridor.get("spawn_depth_m", prepared["depth_m"]))
	prepared["spawn_pressure"] = float(corridor.get("spawn_pressure", prepared["pressure"]))
	prepared["spawn_shore_vertical_weight"] = float(corridor.get("spawn_shore_vertical_weight", 1.0))
	prepared["spawn_shore_horizontal_weight"] = float(corridor.get("spawn_shore_horizontal_weight", 1.0))
	prepared["retire_when_idle"] = false
	return prepared


func _evaluate_breaking_corridor(candidate: Dictionary, long_hs_m: float, coastal_fraction: float) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	_corridor_evaluation_count += 1
	var base_xz: Vector2 = Vector2(candidate["xz"])
	var fallback_direction := Vector2(candidate.get("direction", Vector2.RIGHT)).normalized()
	var wavelength := maxf(float(candidate.get("wavelength_m", 0.5)), 0.5)
	var phase_speed := maxf(float(candidate.get("phase_speed_mps", 0.1)), 0.1)
	var corridor_direction := _infer_shoreward_direction(base_xz, fallback_direction, wavelength)
	var offshore_distance := CORRIDOR_OFFSHORE_LENGTH_LAMBDA * wavelength
	var shoreward_distance := CORRIDOR_SHOREWARD_LENGTH_LAMBDA * wavelength
	var sample_spacing := (offshore_distance + shoreward_distance) / float(CORRIDOR_SAMPLE_COUNT - 1)
	var start_xz := _advance_render_path(base_xz, corridor_direction, -offshore_distance)
	var path: Array[Dictionary] = []
	var current_xz := start_xz
	var previous_direction := corridor_direction
	for sample_index in CORRIDOR_SAMPLE_COUNT:
		if sample_index > 0:
			current_xz = _advance_render_path(current_xz, previous_direction, sample_spacing)
		var sample := _sample_propagation(current_xz)
		var point := {
			"xz": current_xz,
			"valid": bool(sample.get("valid", false)) and bool(sample.get("in_bounds", false)),
			"depth_m": float(sample.get("depth_m", 0.0)),
			"shoaling": float(sample.get("shoaling", 1.0)),
			"direction": Vector2(sample.get("direction", previous_direction)).normalized(),
			"wavelength_m": float(sample.get("wavelength_m", wavelength)),
			"phase_speed_mps": float(sample.get("phase_speed_mps", phase_speed)),
		}
		point["pressure"] = estimate_depth_pressure(long_hs_m, coastal_fraction, point["shoaling"], maxf(point["depth_m"], 0.001)) if point["valid"] else 0.0
		point["shore_vertical_weight"] = _shore_weight(point["depth_m"], true) if point["valid"] else 0.0
		point["shore_horizontal_weight"] = _shore_weight(point["depth_m"], false) if point["valid"] else 0.0
		path.append(point)
		if point["valid"]:
			if point["direction"].length_squared() > 0.5:
				previous_direction = point["direction"] if point["direction"].dot(corridor_direction) >= 0.0 else -point["direction"]
	var onset_index := -1
	var plunge_index := -1
	for index in path.size():
		var point: Dictionary = path[index]
		if not bool(point["valid"]):
			continue
		if onset_index < 0 and float(point["pressure"]) >= CORRIDOR_ONSET_PRESSURE:
			onset_index = index
		if onset_index >= 0 and float(point["pressure"]) >= ANCHOR_PRESSURE_TARGET:
			plunge_index = index
			break
	if onset_index < 0 or plunge_index < 0:
		_corridor_evaluation_usec += Time.get_ticks_usec() - started_usec
		return {"surf_corridor_eligible": false, "corridor_reason": "NO_BREAK_PRESSURE_RAMP"}
	var terminal_index := -1
	for index in range(plunge_index, path.size()):
		var point: Dictionary = path[index]
		if not bool(point["valid"]):
			terminal_index = index
			break
		if float(point["pressure"]) >= anchor_max_depth_pressure or float(point["shore_vertical_weight"]) <= CORRIDOR_TERMINAL_VERTICAL_WEIGHT:
			terminal_index = index
			break
	if terminal_index <= onset_index:
		_corridor_evaluation_usec += Time.get_ticks_usec() - started_usec
		return {"surf_corridor_eligible": false, "corridor_reason": "NO_SHALLOW_DEVELOPMENT"}
	var onset_point: Dictionary = path[onset_index]
	var terminal_point: Dictionary = path[terminal_index]
	var available_length := Vector2(onset_point["xz"]).distance_to(Vector2(terminal_point["xz"]))
	var wave_period := wavelength / phase_speed
	var lifecycle_distance := phase_speed * clampf(LIFECYCLE_DURATION_WAVE_FRACTION * wave_period, LIFECYCLE_DURATION_MIN, LIFECYCLE_DURATION_MAX)
	var plunge_life := _life_for_stage(CORRIDOR_PLUNGE_STAGE)
	var required_distance := maxf(lifecycle_distance * plunge_life, wavelength * 0.55)
	if available_length < required_distance * CORRIDOR_MIN_SHALLOW_DISTANCE_FRACTION:
		_corridor_evaluation_usec += Time.get_ticks_usec() - started_usec
		return {"surf_corridor_eligible": false, "corridor_reason": "NO_SHALLOW_DEVELOPMENT"}
	var plunge_point: Dictionary = path[plunge_index]
	var spawn_xz := _advance_render_path(Vector2(plunge_point["xz"]), corridor_direction, -required_distance)
	var spawn := _sample_propagation(spawn_xz)
	var spawn_valid := bool(spawn.get("valid", false)) and bool(spawn.get("in_bounds", false))
	var spawn_depth := float(spawn.get("depth_m", 0.0))
	var spawn_shoaling := float(spawn.get("shoaling", 1.0))
	var spawn_pressure := estimate_depth_pressure(long_hs_m, coastal_fraction, spawn_shoaling, maxf(spawn_depth, 0.001)) if spawn_valid else 0.0
	var spawn_vertical := _shore_weight(spawn_depth, true) if spawn_valid else 0.0
	var spawn_horizontal := _shore_weight(spawn_depth, false) if spawn_valid else 0.0
	if not spawn_valid or spawn_pressure < anchor_min_depth_pressure or spawn_vertical < CORRIDOR_SPAWN_VERTICAL_WEIGHT_MIN:
		_corridor_evaluation_usec += Time.get_ticks_usec() - started_usec
		return {"surf_corridor_eligible": false, "corridor_reason": "SPAWN_NOT_PREBREAK"}
	_corridor_evaluation_usec += Time.get_ticks_usec() - started_usec
	return {
		"surf_corridor_eligible": true,
		"corridor_reason": "SURF_CORRIDOR",
		"corridor_start_xz": onset_point["xz"],
		"corridor_end_xz": terminal_point["xz"],
		"corridor_length_m": available_length,
		"available_corridor_length_m": available_length,
		"depth_start_m": float(onset_point["depth_m"]),
		"depth_end_m": float(terminal_point["depth_m"]),
		"pressure_start": float(onset_point["pressure"]),
		"pressure_end": float(terminal_point["pressure"]),
		"break_point_xz": plunge_point["xz"],
		"spawn_xz": spawn_xz,
		"spawn_depth_m": spawn_depth,
		"spawn_pressure": spawn_pressure,
		"spawn_shore_vertical_weight": spawn_vertical,
		"spawn_shore_horizontal_weight": spawn_horizontal,
		"required_development_distance_m": required_distance,
		"lifecycle_distance_m": lifecycle_distance,
		"plunge_life_fraction": plunge_life,
		"corridor_sample_count": CORRIDOR_SAMPLE_COUNT,
		"corridor_direction": corridor_direction,
	}


func _life_for_stage(target_stage: float) -> float:
	var low := 0.0
	var high := 1.0
	for _iteration in 12:
		var midpoint := (low + high) * 0.5
		if _smoothstep(0.0, STAGE_LIFE_END, midpoint) < target_stage:
			low = midpoint
		else:
			high = midpoint
	return (low + high) * 0.5


func _advance_render_path(origin: Vector2, fallback_direction: Vector2, distance_m: float) -> Vector2:
	var direction := fallback_direction.normalized()
	if _propagation != null and _propagation.is_valid():
		var start_sample := _sample_propagation(origin)
		var sampled_direction := Vector2(start_sample.get("direction", direction)).normalized()
		if bool(start_sample.get("valid", false)) and sampled_direction.length_squared() > 0.5:
			direction = sampled_direction if sampled_direction.dot(direction) >= 0.0 else -sampled_direction
	var midpoint := origin + direction * distance_m * 0.5
	if _propagation != null and _propagation.is_valid():
		var midpoint_sample := _sample_propagation(midpoint)
		var midpoint_direction := Vector2(midpoint_sample.get("direction", direction)).normalized()
		if bool(midpoint_sample.get("valid", false)) and midpoint_direction.length_squared() > 0.5:
			direction = midpoint_direction if midpoint_direction.dot(direction) >= 0.0 else -midpoint_direction
	return origin + direction * distance_m


func _infer_shoreward_direction(origin: Vector2, render_direction: Vector2, wavelength: float) -> Vector2:
	## La convención render_direction sigue siendo la única trayectoria. En
	## assets/mocks donde apunta offshore, el signo se determina por el gradiente
	## de depth para no confundir una rampa invertida con una costa plana.
	var direction := render_direction.normalized()
	if _propagation == null or not _propagation.is_valid():
		return direction
	var probe_distance := maxf(wavelength * 0.35, _propagation.cell_size_m * 2.0)
	var forward := _sample_propagation(origin + direction * probe_distance)
	var backward := _sample_propagation(origin - direction * probe_distance)
	if not bool(forward.get("valid", false)) or not bool(backward.get("valid", false)):
		return direction
	var depth_delta := float(forward.get("depth_m", 0.0)) - float(backward.get("depth_m", 0.0))
	if absf(depth_delta) <= maxf(_propagation.cell_size_m * 0.25, 0.05):
		return direction
	return -direction if depth_delta > 0.0 else direction


func _anchor_eligibility_for_pressure(pressure: float) -> float:
	var enter := _smoothstep(anchor_min_depth_pressure, anchor_min_depth_pressure + 0.10, pressure)
	var exit := 1.0 - _smoothstep(anchor_max_depth_pressure - 0.18, anchor_max_depth_pressure, pressure)
	return clampf(enter * exit, 0.0, 1.0)


func _anchor_eligibility_for_energy(anchor: Dictionary, long_hs_m: float, coastal_fraction: float) -> float:
	var pressure := estimate_depth_pressure(long_hs_m, coastal_fraction, float(anchor.get("shoaling", 1.0)), float(anchor.get("depth_m", 1.0)))
	return _anchor_eligibility_for_pressure(pressure)


func _anchor_runtime_eligibility(anchor: Dictionary) -> float:
	var details := _anchor_runtime_eligibility_details(anchor)
	return details["anchor_eligibility"] * details["zone_activity"]


func _anchor_runtime_eligibility_details(anchor: Dictionary) -> Dictionary:
	var current: float = float(anchor.get("current_eligibility", 1.0))
	var zone_activity: float = float(anchor.get("zone_breaking_activity", 1.0))
	var anchor_eligibility := current
	if not _wave_transition_active:
		return {"anchor_eligibility": anchor_eligibility, "zone_activity": zone_activity}
	anchor_eligibility = lerpf(current, float(anchor.get("target_eligibility", current)), _wave_transition_alpha)
	return {"anchor_eligibility": anchor_eligibility, "zone_activity": zone_activity}


func _find_matching_anchor(anchors: Array[Dictionary], candidate: Dictionary) -> int:
	var max_distance := maxf(2.0, anchor_min_spacing_m * TRANSITION_ANCHOR_MATCH_DISTANCE_FACTOR)
	var candidate_xz: Vector2 = Vector2(candidate["xz"])
	var candidate_direction: Vector2 = Vector2(candidate["direction"])
	for index in anchors.size():
		var anchor: Dictionary = anchors[index]
		if (Vector2(anchor["xz"]) - candidate_xz).length() > max_distance:
			continue
		if Vector2(anchor["direction"]).dot(candidate_direction) < TRANSITION_ANCHOR_MATCH_DIRECTION_DOT:
			continue
		return index
	return -1


func _install_transition_anchors(merged: Array[Dictionary]) -> void:
	## Reutiliza cada MeshInstance y tracking existente por identidad espacial.
	var old_anchors: Array[Dictionary] = _anchors
	var old_ribbons: Array[MeshInstance3D] = _ribbons
	var old_tracking: Array[Dictionary] = _tracking
	var next_ribbons: Array[MeshInstance3D] = []
	var next_tracking: Array[Dictionary] = []
	var used: Array[bool] = []
	used.resize(old_anchors.size())
	for index in used.size():
		used[index] = false
	for index in merged.size():
		var anchor: Dictionary = merged[index]
		var match := _find_matching_anchor(old_anchors, anchor)
		if match >= 0 and not used[match] and match < old_ribbons.size():
			used[match] = true
			next_ribbons.append(old_ribbons[match])
			next_tracking.append(old_tracking[match] if match < old_tracking.size() else _base_state({}))
		else:
			var instance := _create_ribbon_instance(index, anchor)
			next_ribbons.append(instance)
			var idle_state := _base_state({})
			idle_state["tracked_xz"] = Vector2(anchor["xz"])
			next_tracking.append(idle_state)
	_anchors = merged
	_ribbons = next_ribbons
	_tracking = next_tracking
	_last_fingerprint = _anchors_fingerprint()
	for index in _ribbons.size():
		_configure_ribbon_instance(_ribbons[index], index, _anchors[index])
		_publish_slot(index, _tracking[index])
	_apply_visibility()
	_sync_takeover_mask()


func _prune_retired_transition_anchors() -> void:
	for index in range(_anchors.size() - 1, -1, -1):
		if not bool(_anchors[index].get("retire_when_idle", false)):
			continue
		var entry: Dictionary = _tracking[index] if index < _tracking.size() else {}
		if bool(entry.get("active", false)):
			continue
		if index < _ribbons.size():
			_ribbons[index].queue_free()
			_ribbons.remove_at(index)
		_anchors.remove_at(index)
		if index < _tracking.size():
			_tracking.remove_at(index)
	if _ribbons.size() == _anchors.size():
		for index in _ribbons.size():
			_configure_ribbon_instance(_ribbons[index], index, _anchors[index])
	_last_fingerprint = _anchors_fingerprint()


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
		_ribbons.append(_create_ribbon_instance(index, anchor))
	_tracking.resize(_anchors.size())
	_apply_visibility()
	_sync_takeover_mask()


func _create_ribbon_instance(index: int, anchor: Dictionary) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = _template_mesh
	instance.material_override = _material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.extra_cull_margin = 4096.0
	_configure_ribbon_instance(instance, index, anchor)
	instance.set_instance_shader_parameter(&"tracked_crest_xz", Vector2(anchor["xz"]))
	instance.set_instance_shader_parameter(&"breaker_lifecycle_stage", 0.0)
	instance.set_instance_shader_parameter(&"breaker_lifecycle_alpha", 0.0)
	instance.set_instance_shader_parameter(&"breaker_spawn_strength", 0.0)
	instance.set_instance_shader_parameter(&"breaker_spawn_hs_m", 0.0)
	add_child(instance)
	return instance


func _configure_ribbon_instance(instance: MeshInstance3D, index: int, anchor: Dictionary) -> void:
	instance.name = "Ribbon%d" % index
	instance.set_instance_shader_parameter(&"anchor_xz", Vector2(anchor["xz"]))
	instance.set_instance_shader_parameter(&"direction_xz", Vector2(anchor["direction"]))
	instance.set_instance_shader_parameter(&"ribbon_id", float(index))
	instance.set_instance_shader_parameter(&"ribbon_wavelength_m", float(anchor["wavelength_m"]) * ribbon_length_lambda)
	instance.set_instance_shader_parameter(&"ribbon_width_m", ribbon_width_m)


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
	var profile_scale := _profile_length_scale()
	_surface_material.set_shader_parameter(&"breaker_takeover_debug_enabled", true)
	_surface_material.set_shader_parameter(&"breaker_takeover_anchor_xz", Vector2(anchor["xz"]))
	_surface_material.set_shader_parameter(&"breaker_takeover_direction_xz", Vector2(anchor["direction"]))
	_surface_material.set_shader_parameter(&"breaker_takeover_length_m", float(anchor["wavelength_m"]) * ribbon_length_lambda * profile_scale)
	_surface_material.set_shader_parameter(&"breaker_takeover_width_m", ribbon_width_m)
	_surface_material.set_shader_parameter(&"breaker_takeover_stage", _debug_stage)
	_surface_material.set_shader_parameter(&"breaker_takeover_forward_sign", _profile_forward_sign)


func _sync_production_takeover() -> void:
	## S5: cada ACTIVE publica su propia máscara. No es el debug FORCE_LIP y no
	## comparte anchor/dirección entre slots. Fixed arrays evitan texturas nuevas.
	if _surface_material == null:
		return
	var centers := PackedVector4Array()
	var states := PackedVector4Array()
	centers.resize(8)
	states.resize(8)
	var active_count := 0
	var profile_scale := _profile_length_scale()
	for index in mini(_tracking.size(), 8):
		var entry: Dictionary = _tracking[index]
		if not bool(entry.get("active", false)):
			continue
		var direction: Vector2 = Vector2(entry.get("spawn_direction", Vector2.RIGHT)).normalized()
		var tracked: Vector2 = Vector2(entry.get("tracked_xz", Vector2.ZERO))
		centers[active_count] = Vector4(tracked.x, tracked.y, direction.x, direction.y)
		states[active_count] = Vector4(
			maxf(float(entry.get("spawn_wavelength", 1.0)) * ribbon_length_lambda * profile_scale, 0.1),
			maxf(ribbon_width_m, 0.1),
			clampf(float(entry.get("stage", 0.0)), 0.0, 1.0),
			clampf(float(entry.get("alpha", 0.0)), 0.0, 1.0))
		active_count += 1
	_surface_material.set_shader_parameter(&"breaker_takeover_count", active_count)
	_surface_material.set_shader_parameter(&"breaker_takeover_data0", centers)
	_surface_material.set_shader_parameter(&"breaker_takeover_data1", states)


func _profile_length_scale() -> float:
	if _material != null:
		var value: Variant = _material.get_shader_parameter(&"breaker_profile_length_scale")
		if value != null and float(value) > 0.0:
			return float(value)
	return 0.82


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

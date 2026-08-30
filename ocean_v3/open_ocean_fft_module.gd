class_name OpenOceanFFTModule
extends Node3D
## Orquesta LONG/MID/SHORT como detalles internos del Ãºnico mÃ³dulo open_ocean_fft.

const MODULE_ID := &"open_ocean_fft"
const FFTConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SurfaceFoamConfigScript := preload("res://ocean_v3/core/surface_foam_reference_config.gd")
const SurfaceFoamSpectrumScript := preload("res://ocean_v3/core/surface_foam_reference_spectrum.gd")
const SurfaceFoamSolverScript := preload("res://ocean_v3/rendering/fft/surface_foam_spectrum_solver.gd")
const SurfaceFoamMidHistorySolverScript := preload("res://ocean_v3/rendering/fft/surface_foam_mid_history_solver.gd")
const SolverScript := preload("res://ocean_v3/rendering/fft/gpu_stockham_fft.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const SeaStateZoneMathScript := preload("res://ocean_v3/core/sea_state_zone_math.gd")
const QueryReferenceScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const QuerySampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")
const CoastalBakerScript := preload("res://ocean_v3/coastal/coastal_propagation_baker.gd")
const CoastalEikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")
const BreakerPoolScript := preload("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
const DEFAULT_FOAM_RESOLUTION := 1024


class _WaveTransitionPreparationTask:
	## Datos puros para Thread: no toca SceneTree, Nodes ni recursos de render.
	const Spectrum := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
	const QueryReduced := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
	var serial := 0
	var simulation_seed := 0
	var target_configs: Array[OpenOceanFFTConfig] = []
	var duration_s := 0.0
	var coastal_split_inner_deg := 20.0
	var coastal_split_outer_deg := 35.0
	var query_budgets: Array[int] = []
	var query_mode := 0
	var query_coastal_active := false
	var query_coastal_inner_deg := 20.0
	var query_coastal_outer_deg := 35.0
	var retarget := false
	var current_configs: Array[OpenOceanFFTConfig] = []
	var current_h0_datas: Array[PackedByteArray] = []
	var current_render_h0_datas: Array[PackedByteArray] = []
	var previous_target_h0_datas: Array[PackedByteArray] = []
	var previous_target_render_h0_datas: Array[PackedByteArray] = []
	var previous_target_configs: Array[OpenOceanFFTConfig] = []
	var current_energy_metrics: Dictionary = {}
	var previous_target_energy_metrics: Dictionary = {}
	var transition_alpha := 0.0

	func run() -> Dictionary:
		var result := _build_target_payload()
		result["serial"] = serial
		result["simulation_seed"] = simulation_seed
		result["retarget"] = retarget
		if retarget:
			var effective_configs := _interpolated_configs(current_configs, previous_target_configs, transition_alpha)
			var effective_h0 := _mix_h0_datas(current_h0_datas, previous_target_h0_datas, transition_alpha)
			var effective_render_h0 := _mix_h0_datas(current_render_h0_datas, previous_target_render_h0_datas, transition_alpha)
			result["current_configs"] = effective_configs
			result["current_h0_datas"] = effective_h0
			result["current_render_h0_datas"] = effective_render_h0
			result["current_energy_metrics"] = _interpolated_energy_metrics(current_energy_metrics, previous_target_energy_metrics, transition_alpha)
			result["current_query_payload"] = QueryReduced.prepare_spectrum_transition_target(
				effective_configs, effective_h0, query_budgets, query_mode,
				query_coastal_active, query_coastal_inner_deg, query_coastal_outer_deg
			)
		return result

	func _build_target_payload() -> Dictionary:
		var target_h0_datas := _build_h0_datas(target_configs, simulation_seed)
		var target_split := Spectrum.split_h0_rgba32f(
			target_configs[0], target_h0_datas[0], coastal_split_inner_deg, coastal_split_outer_deg
		)
		var target_render_h0_datas: Array[PackedByteArray] = [
			target_split["coastal"] as PackedByteArray,
			target_split["remainder"] as PackedByteArray,
			target_h0_datas[1],
			target_h0_datas[2],
		]
		return {
			"target_configs": target_configs,
			"target_h0_datas": target_h0_datas,
			"target_render_h0_datas": target_render_h0_datas,
			"target_energy_metrics": target_split["coastal_energy_metrics"],
			"target_query_payload": QueryReduced.prepare_spectrum_transition_target(
				target_configs, target_h0_datas, query_budgets, query_mode,
				query_coastal_active, query_coastal_inner_deg, query_coastal_outer_deg
			),
			"duration_s": duration_s,
		}

	func _build_h0_datas(source_configs: Array[OpenOceanFFTConfig], seed_value: int) -> Array[PackedByteArray]:
		var result: Array[PackedByteArray] = []
		for config in source_configs:
			result.append(Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed_value, config.id)))
		return result

	func _interpolated_configs(source: Array[OpenOceanFFTConfig], target: Array[OpenOceanFFTConfig], alpha: float) -> Array[OpenOceanFFTConfig]:
		var result: Array[OpenOceanFFTConfig] = []
		for index in source.size():
			var current := source[index]
			var endpoint := target[index]
			var blended := current.duplicate() as OpenOceanFFTConfig
			blended.choppiness = lerpf(current.choppiness, endpoint.choppiness, alpha)
			blended.target_hs_m = lerpf(current.target_hs_m, endpoint.target_hs_m, alpha)
			var direction := current.wind_direction.normalized().lerp(endpoint.wind_direction.normalized(), alpha)
			blended.wind_direction = direction.normalized() if direction.length_squared() > 1.0e-8 else Vector2.RIGHT
			blended.foam_whitecap = lerpf(current.foam_whitecap, endpoint.foam_whitecap, alpha)
			blended.foam_amount = lerpf(current.foam_amount, endpoint.foam_amount, alpha)
			blended.foam_decay = lerpf(current.foam_decay, endpoint.foam_decay, alpha)
			blended.foam_cascade_weight = lerpf(current.foam_cascade_weight if current.foam_enabled else 0.0, endpoint.foam_cascade_weight if endpoint.foam_enabled else 0.0, alpha)
			blended.foam_enabled = current.foam_enabled or endpoint.foam_enabled
			result.append(blended)
		return result

	func _mix_h0_datas(a_datas: Array[PackedByteArray], b_datas: Array[PackedByteArray], alpha: float) -> Array[PackedByteArray]:
		var result: Array[PackedByteArray] = []
		for index in a_datas.size():
			var a := a_datas[index].to_float32_array()
			var b := b_datas[index].to_float32_array()
			var mixed := PackedFloat32Array()
			mixed.resize(a.size())
			for component in a.size():
				mixed[component] = lerpf(a[component], b[component], alpha)
			result.append(mixed.to_byte_array())
		return result

	func _interpolated_energy_metrics(current: Dictionary, target: Dictionary, alpha: float) -> Dictionary:
		var result := current.duplicate()
		for key in target:
			if current.has(key) and current[key] is float and target[key] is float:
				result[key] = lerpf(float(current[key]), float(target[key]), alpha)
		return result


enum BandDebug {
	ALL,
	LONG,
	MID,
	SHORT,
}

@export var enabled_on_start := true
@export var enable_reference_query_debug := false
@export var query_native_enabled := true
# Presupuestos por banda (pares canÃ³nicos) elegidos por calibraciÃ³n 2B:
# mÃ­nimo total que cumple los objetivos de precisiÃ³n en el dataset de calibraciÃ³n.
@export var reduced_long_pairs := 1024
@export var reduced_mid_pairs := 1024
@export var reduced_short_pairs := 1024
# 3B: input horneado de 3A; sólo modula la representación visual LONG.
@export var coastal_bathymetry_data: Resource
@export var coastal_propagation_enabled := false
@export var coastal_incoming_direction_xz := Vector2.RIGHT
@export_range(4.0, 128.0, 0.5) var coastal_reference_wavelength_m := 16.0
@export_range(0.05, 4.0, 0.05) var coastal_min_valid_depth_m := 0.25
@export var coastal_monochromatic_debug := false
@export_range(0.01, 2.0, 0.01) var coastal_monochromatic_amplitude_m := 0.35
# 3B.1: instrumento MONO/Eikonal histórico. No gobierna el solver final.
@export var coastal_eikonal_refraction_debug := false
# Solver semántico del camino Coastal final. Se mantiene separado del flag de
# diagnóstico para que el warp de producción no dependa de una opción "debug".
@export var coastal_eikonal_enabled := true
# 3B.2B: split direccional de LONG (COASTAL / REMAINDER).
# Máscara angular suave: plena 1 hasta inner_deg, falloff hasta 0 en outer_deg.
@export_range(0.0, 60.0, 1.0) var coastal_split_inner_deg := 20.0
@export_range(20.0, 90.0, 1.0) var coastal_split_outer_deg := 35.0
@export var coastal_warp_enabled := true
# Phase 4B: pool de geometría local de breaker. ON por defecto; la visibilidad
# real depende del campo PREBREAK (Coastal OFF / sin batimetría => sin breakers).
@export var breaker_enabled := true
# Technical foam-field resolution, deliberately independent from FFT resolution.
# Changing it recreates only the RG16F foam ping-pong images; H0 and the FFT stay intact.
@export var foam_resolution_auto := true:
	set(value):
		foam_resolution_auto = value
		if is_inside_tree() and not _cascades.is_empty():
			_rebuild_foam_resolution()

@export_enum("AUTO:0", "256:256", "512:512", "1024:1024") var foam_resolution: int = 0:
	set(value):
		foam_resolution = _validated_foam_resolution(value)
		if is_inside_tree() and not _cascades.is_empty():
			_rebuild_foam_resolution()

@onready var surface: Node3D = $OceanClipmapSurface

var configs: Array[OpenOceanFFTConfig] = []
var dispatches_per_update := 0

var _cascades: Array[Dictionary] = []
var _query_reduced: RefCounted = null
var _query_native: RefCounted = null
var _query_golden: RefCounted = null
var _sea_state_zone_descriptors: Array[Dictionary] = []
var _current_h0_datas: Array[PackedByteArray] = []
var _current_render_h0_datas: Array[PackedByteArray] = []
var _wave_transition_active := false
var _wave_transition_alpha := 0.0
var _wave_transition_elapsed_s := 0.0
var _wave_transition_duration_s := 0.0
var _wave_transition_target_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_target_h0_datas: Array[PackedByteArray] = []
var _wave_transition_target_render_h0_datas: Array[PackedByteArray] = []
var _wave_transition_target_energy_metrics: Dictionary = {}
var _wave_transition_cancelled := false
var _wave_transition_preparing := false
var _wave_transition_progress_frozen := false
var _wave_transition_prepare_serial := 0
var _wave_transition_prepare_thread: Thread = null
var _wave_transition_prepare_task: _WaveTransitionPreparationTask = null
var _wave_transition_queued_target_configs: Array[OpenOceanFFTConfig] = []
var _wave_transition_queued_duration_s := 0.0
var _enabled := true
var _textures_published := false
var _dispatch_requested := true
var _band_debug: int = BandDebug.ALL
var _sea_state: int = SeaStateScript.State.RACE
var _sea_state_initialized := false
var _coastal_propagation = null
var _coastal_warp = null
var _coastal_runtime_enabled := true
var _coastal_performance_enabled := true
var _coastal_energy_metrics: Dictionary = {}
var _breaker_pool: BreakerRibbonPool = null
var _breaking_coastal_fraction := 0.0
var _spectrum_model: int = OpenOceanFFTConfig.SpectrumModel.JONSWAP_HASSELMANN
var _ocean_shape_debug := false # 5R.1: vista neutra de forma (silueta/crest/valle).
var _ocean_crest_sharpen_debug := false # 5R1C: vista de zonas de crest sharpening.
var _ocean_normal_fragment := false # 5R2: normal shading FRAGMENT (true) vs VERTEX (false).
# 5R1D: autoridad única de los parámetros de crest sharpening (render + query).
var _crest_sharpen := {
	"strength": 1.0,
	"threshold": 0.15,
	"max_gain": 0.30,
	"long_weight": 1.0,
	"mid_weight": 0.5,
}
var _foam_residual_decay_multiplier := 1.0
var _foam_deposit_strength := 0.72
var _foam_advection_enabled := true
var _foam_advection_strength := 1.0
var _crest_foam_update_hz := 60.0
var _crest_foam_compute_enabled := true
var _surface_foam_enabled := true
var _surface_foam_topology_required := true
var _surface_foam_mid_history_required := true
var _surface_foam_whitecap := 0.0
var _surface_foam_crest_whitecap := 0.0
var _surface_foam_amount := 8.573
var _surface_foam_birth_attack_s := 0.16
var _surface_foam_lifetime_s := 1.10
var _surface_foam_birth_selectivity := 0.28
var _surface_foam_evolution_speed := 0.35
var _surface_foam_mid_fold_start := 0.10
var _surface_foam_mid_fold_end := 0.24
# Dedicated technical spectrum: never enters configs/_cascades, queries or Hs.
var _surface_foam_fft_resolution := 512
var _surface_foam_field_resolution := 1024
var _surface_foam_topology_resolution := 1024
var _surface_foam_update_hz := 30.0
var _surface_foam_source_domain_m := 8.0
var _surface_foam_field_domain_m := 88.0
var _surface_foam_depth_m := 20.0
var _surface_foam_wind_speed_mps := 10.0
var _surface_foam_wind_direction_deg := 110.0
var _surface_foam_fetch_m := 6000.0
var _surface_foam_swell := 0.779
# JONSWAP semantics: 0 = full Hasselmann directionality, 1 = isotropic.
var _surface_foam_directional_spread := 0.0
var _surface_foam_detail := 1.0
var _surface_foam_config: Resource = null
var _surface_foam_solver = null
var _surface_foam_texture := Texture2DRD.new()
var _surface_foam_jacobian_texture := Texture2DRD.new()
var _surface_foam_topology_texture := Texture2DRD.new()
var _surface_foam_mid_fold_history_texture := Texture2DRD.new()
var _surface_foam_mid_history_solver = null
var _performance_spectral_enabled := true
var _performance_crest_foam_solver_enabled := true
var _performance_surface_foam_solver_enabled := true
var _performance_mid_fold_history_enabled := true
var _performance_surface_foam_render_enabled := true
var _performance_prebreak_enabled := true
var _performance_breakers_enabled := true


## Métricas honestas del split LONG: potencia H0, varianzas y covarianza.
func coastal_energy_metrics() -> Dictionary:
	return _coastal_energy_metrics.duplicate()


func coastal_long_reference_direction() -> Vector2:
	## Dirección del sector LONG que se dividió en COASTAL/REMAINDER.
	if not configs.is_empty() and configs[0] != null:
		var direction: Vector2 = configs[0].wind_direction.normalized()
		if direction.length_squared() > 1.0e-8:
			return direction
	return Vector2.RIGHT


func coastal_warp_direction() -> Vector2:
	if _coastal_propagation != null:
		return _coastal_propagation.incoming_direction_xz.normalized()
	return coastal_long_reference_direction()


func coastal_render_memory_diagnostics() -> Dictionary:
	var propagation_bytes: int = int(_coastal_propagation.approximate_gpu_memory_bytes()) if _coastal_propagation != null else 0
	var warp_bytes: int = int(_coastal_warp.approximate_warp_gpu_memory_bytes()) if _coastal_warp != null else 0
	var jacobian_bytes: int = int(_coastal_warp.approximate_jacobian_gpu_memory_bytes()) if _coastal_warp != null else 0
	return {
		"fft_gpu_bytes": gpu_memory_bytes(),
		"propagation_gpu_bytes": propagation_bytes,
		"warp_gpu_bytes": warp_bytes,
		"jacobian_gpu_bytes": jacobian_bytes,
		"fft_dispatches_per_update": dispatches_per_update,
	}


func _ready() -> void:
	var startup_started_usec := Time.get_ticks_usec()
	add_to_group(&"ocean_fft")
	_sea_state = SeaStateScript.State.RACE
	_sea_state_initialized = true
	configs = SeaStateScript.build_cascades(_sea_state)
	_apply_spectrum_model()
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		if not config.is_valid():
			push_error("ConfiguraciÃ³n FFT invÃ¡lida para %s." % config.id)
			return
		h0_datas.append(_build_h0(config, SimulationClock.simulation_seed))
	var h0_built_usec := Time.get_ticks_usec()
	# 3B.2B: LONG se divide en LONG_COASTAL + LONG_REMAINDER (misma física del
	# config LONG, H0 diferentes por máscara direccional). La query física sigue
	# usando el LONG original (configs[0]); sólo el render usa la 4.ª cascada.
	var long_config: OpenOceanFFTConfig = configs[0]
	var split: Dictionary = SpectrumScript.split_h0_rgba32f(long_config, h0_datas[0], coastal_split_inner_deg, coastal_split_outer_deg)
	_coastal_energy_metrics = split["coastal_energy_metrics"]
	_current_h0_datas = h0_datas
	var render_h0: Array[PackedByteArray] = [
		split["coastal"] as PackedByteArray,
		split["remainder"] as PackedByteArray,
		h0_datas[1],
		h0_datas[2],
	]
	var h0_split_usec := Time.get_ticks_usec()
	_current_render_h0_datas = render_h0
	_cascades.append(_make_cascade(long_config, split["coastal"], "Ocean2B.LONG_COASTAL"))
	_cascades.append(_make_cascade(long_config, split["remainder"], "Ocean2B.LONG_REMAINDER"))
	for index in [1, 2]:
		_cascades.append(_make_cascade(configs[index], h0_datas[index], "Ocean2B.%s" % configs[index].id))
	_initialize_surface_foam_solver()
	var gpu_submission_usec := Time.get_ticks_usec()

	_enabled = enabled_on_start
	dispatches_per_update = 0
	for cascade in _cascades:
		dispatches_per_update += cascade["config"].compute_pass_count()
	for index in _cascades.size():
		RenderingServer.call_on_render_thread(_cascades[index].solver.set_crest_foam_schedule.bind(
			_crest_foam_update_hz,
			float(index) * 0.25
		))
	# La referencia CPU recibe EXACTAMENTE los mismos bytes de H0 que la GPU.
	# Backend de producciÃ³n: REDUCED (GDScript), siempre disponible.
	_query_reduced = QueryReducedScript.new()
	_query_reduced.set_spectrum(configs, h0_datas)
	_query_reduced.set_sea_level(surface.clipmap_config.sea_level_y)
	_query_reduced.set_budget(reduced_long_pairs, reduced_mid_pairs, reduced_short_pairs)
	var query_ready_usec := Time.get_ticks_usec()
	# Backend NATIVE (GDExtension) si estÃ¡ disponible; si no, fallback GDScript.
	if query_native_enabled:
		_query_native = _try_create_native_backend()
		if _query_native != null:
			_query_reduced.configure_native_backend(_query_native)
			print("OceanQuery: backend nativo activo (OceanQueryNative).")
	# Golden Reference: sÃ³lo cuando se pide explÃ­citamente para debug/test.
	if enable_reference_query_debug:
		_query_golden = QueryReferenceScript.new()
		_query_golden.set_spectrum(configs, h0_datas)
		_query_golden.set_sea_level(surface.clipmap_config.sea_level_y)
	_apply_crest_sharpen_config()
	surface.configure(_render_configs(), _textures_for(&"displacement"), _textures_for(&"normal"), _textures_for(&"foam"), _surface_foam_texture, _surface_foam_field_domain_m)
	var surface_ready_usec := Time.get_ticks_usec()
	surface.set_surface_foam_jacobian(_surface_foam_jacobian_texture, _surface_foam_source_domain_m)
	surface.set_surface_foam_topology(_surface_foam_topology_texture, _surface_foam_source_domain_m)
	surface.set_surface_foam_mid_fold_history(_surface_foam_mid_fold_history_texture)
	# Phase 4B: pool de breakers como hijo del módulo; se configura cuando hay
	# coastal/warp válidos (rebuild_coastal_propagation). Antes de eso queda
	# inactivo y no renderiza nada.
	_breaker_pool = BreakerPoolScript.new()
	_breaker_pool.name = &"BreakerRibbonPool"
	add_child(_breaker_pool)
	_update_breaking_energy_model()
	# Runtime no hornea Coastal. OceanV3 carga un CoastalBakeAsset opcional
	# después de que este módulo haya terminado de crear su superficie.
	_breaker_pool.disable()
	surface.set_module_enabled(_enabled)
	surface.set_band_debug(_band_debug)
	OceanModuleRegistry.register_module(MODULE_ID, _enabled)
	OceanModuleRegistry.module_state_changed.connect(_on_module_state_changed)
	SimulationClock.seed_changed.connect(_on_seed_changed)
	SimulationClock.reset_completed.connect(_on_reset_completed)
	print("OCEAN STARTUP fft: h0=%d ms split=%d ms gpu_submit=%d ms query=%d ms surface=%d ms total=%d ms" % [
		(h0_built_usec - startup_started_usec) / 1000,
		(h0_split_usec - h0_built_usec) / 1000,
		(gpu_submission_usec - h0_split_usec) / 1000,
		(query_ready_usec - gpu_submission_usec) / 1000,
		(surface_ready_usec - query_ready_usec) / 1000,
		(Time.get_ticks_usec() - startup_started_usec) / 1000,
	])


func _make_cascade(config: OpenOceanFFTConfig, h0_data: PackedByteArray, resource_prefix: String) -> Dictionary:
	var cascade_index := _cascades.size()
	var displacement := Texture2DRD.new()
	var normal := Texture2DRD.new()
	var foam := Texture2DRD.new()
	var solver := SolverScript.new()
	RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0_data, resource_prefix, _crest_foam_resolution_for_cascade(cascade_index)))
	return {
		"config": config,
		"solver": solver,
		"displacement": displacement,
		"normal": normal,
		"foam": foam,
	}


## Configs de RENDER: LONG_COASTAL, LONG_REMAINDER, MID, SHORT (4 cascadas).
func _render_configs() -> Array[OpenOceanFFTConfig]:
	var result: Array[OpenOceanFFTConfig] = []
	for cascade in _cascades:
		result.append(cascade["config"])
	return result


func render_cascade_count() -> int:
	return _cascades.size()


func _exit_tree() -> void:
	if OceanModuleRegistry.module_state_changed.is_connected(_on_module_state_changed):
		OceanModuleRegistry.module_state_changed.disconnect(_on_module_state_changed)
	OceanModuleRegistry.unregister_module(MODULE_ID)
	_query_reduced = null
	_query_native = null
	_query_golden = null
	for cascade in _cascades:
		cascade.displacement.texture_rd_rid = RID()
		cascade.normal.texture_rd_rid = RID()
		cascade.foam.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(cascade.solver.free_resources)
	_cascades.clear()
	_surface_foam_texture.texture_rd_rid = RID()
	_surface_foam_jacobian_texture.texture_rd_rid = RID()
	_surface_foam_topology_texture.texture_rd_rid = RID()
	_surface_foam_mid_fold_history_texture.texture_rd_rid = RID()
	if _surface_foam_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_solver.free_resources)
	if _surface_foam_mid_history_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.free_resources)
	_surface_foam_solver = null
	_surface_foam_mid_history_solver = null
	_surface_foam_config = null


func _process(delta: float) -> void:
	_publish_ready_textures()
	surface.set_coastal_time(SimulationClock.get_render_time())
	_poll_wave_transition_preparation()
	if not _enabled:
		return
	if _wave_transition_active and not _wave_transition_progress_frozen and not SimulationClock.is_paused():
		_advance_wave_transition(delta)
	if _performance_spectral_enabled:
		for cascade in _cascades:
			var is_visible_band: bool = _band_debug == BandDebug.ALL or _band_index(cascade.config.id) == _band_debug
			# BandDebug may hide a cascade visually, but its temporal crest-foam field
			# must continue evolving while H0 CURRENT/TARGET are being blended.
			if not is_visible_band and not _wave_transition_active:
				continue
			if cascade.solver.ready and (not SimulationClock.is_paused() or _dispatch_requested):
				# The solver receives the actual frame delta and converts per-second foam
				# rates into exponential attack/release and decay. No fixed-FPS assumption.
				RenderingServer.call_on_render_thread(cascade.solver.dispatch.bind(SimulationClock.get_render_time(), delta, _wave_transition_alpha))
	if _performance_spectral_enabled and _performance_surface_foam_solver_enabled and _surface_foam_solver != null and _surface_foam_solver.ready and (not SimulationClock.is_paused() or _dispatch_requested):
		# Independent fixed-rate scheduler: the material keeps its last completed
		# field while this J-only FFT advances in small pass batches.
		RenderingServer.call_on_render_thread(_surface_foam_solver.advance.bind(delta))
	if _performance_spectral_enabled and _performance_mid_fold_history_enabled and _surface_foam_mid_history_solver != null and _surface_foam_mid_history_solver.ready and (not SimulationClock.is_paused() or _dispatch_requested):
		RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.advance.bind(delta))
	_dispatch_requested = false


func toggle_enabled() -> void:
	OceanModuleRegistry.set_module_enabled(MODULE_ID, not _enabled)


func set_performance_profile(profile: Dictionary) -> void:
	## Runtime gates for PERF-2A. Resources stay resident; toggles only skip work
	## or switch shader inputs to deterministic neutral paths.
	_performance_spectral_enabled = bool(profile.get("spectral", true))
	_performance_crest_foam_solver_enabled = bool(profile.get("crest_foam_solver", true))
	_performance_surface_foam_solver_enabled = bool(profile.get("surface_foam_solver", true))
	_performance_mid_fold_history_enabled = bool(profile.get("mid_fold_history", true))
	_performance_surface_foam_render_enabled = bool(profile.get("surface_foam_render", true))
	_performance_prebreak_enabled = bool(profile.get("prebreak", true))
	_performance_breakers_enabled = bool(profile.get("breakers", true))
	_coastal_performance_enabled = bool(profile.get("coastal", true))
	_dispatch_requested = true
	set_crest_foam_compute_enabled(_crest_foam_compute_enabled)
	surface.set_performance_profile(
		_performance_spectral_enabled,
		_coastal_performance_enabled,
		_performance_spectral_enabled and _performance_crest_foam_solver_enabled and _crest_foam_compute_enabled,
		_performance_surface_foam_solver_enabled,
		_performance_surface_foam_render_enabled,
		_performance_prebreak_enabled,
		_performance_breakers_enabled
	)
	if _surface_foam_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_solver.set_settings.bind(
			_surface_foam_enabled and _performance_spectral_enabled and _performance_surface_foam_solver_enabled,
			_surface_foam_whitecap,
			_surface_foam_amount,
			_surface_foam_update_hz,
			_surface_foam_birth_attack_s,
			_surface_foam_lifetime_s,
			_surface_foam_birth_selectivity,
			_surface_foam_evolution_speed,
			_surface_foam_crest_whitecap
		))
	if _surface_foam_mid_history_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.set_settings.bind(
			_surface_foam_mid_history_required and _performance_spectral_enabled and _performance_mid_fold_history_enabled,
			_surface_foam_update_hz,
			_surface_foam_birth_attack_s,
			_surface_foam_lifetime_s,
			_surface_foam_mid_fold_start,
			_surface_foam_mid_fold_end
		))
	_configure_breaker_pool()


func performance_profile() -> Dictionary:
	return {
		"spectral": _performance_spectral_enabled,
		"coastal": _coastal_performance_enabled,
		"crest_foam_solver": _performance_crest_foam_solver_enabled,
		"surface_foam_solver": _performance_surface_foam_solver_enabled,
		"mid_fold_history": _performance_mid_fold_history_enabled,
		"surface_foam_render": _performance_surface_foam_render_enabled,
		"prebreak": _performance_prebreak_enabled,
		"breakers": _performance_breakers_enabled,
	}


func set_sea_state(state: int) -> void:
	if not SeaStateScript.is_valid_state(state):
		push_warning("Estado de mar no vÃ¡lido: %s" % state)
		return
	_sea_state = state
	_sea_state_initialized = true
	# Legacy states now resolve through the same base .tres resources as the
	# editable root authoring layer. Surface Foam stays intentionally untouched.
	set_wave_spectrum_settings(SeaStateScript.build_cascades(state))


func set_wave_spectrum_settings(wave_configs: Array[OpenOceanFFTConfig]) -> void:
	## Public owner API for the three physical source configs. OceanV3 never
	## reaches into _cascades: this method preserves the shared LONG split and
	## synchronizes GPU H0, REDUCED and optional Golden query H0 in one route.
	if wave_configs.size() != 3:
		push_error("Wave spectrum requires exactly LONG, MID and SHORT configs.")
		return
	for config in wave_configs:
		if config == null or not config.is_valid():
			push_error("Invalid wave spectrum config.")
			return
	_invalidate_wave_transition_preparation()
	_reset_wave_transition_state()
	configs = wave_configs
	_apply_spectrum_model()
	if _cascades.is_empty():
		return
	# 3B.2B: las dos primeras cascadas de render (COASTAL/REMAINDER) comparten el
	# config LONG; MID/SHORT usan configs[1]/configs[2].
	for index in _cascades.size():
		var cascade: Dictionary = _cascades[index]
		var config := configs[0] if index < 2 else configs[index - 1]
		cascade["config"] = config
		RenderingServer.call_on_render_thread(cascade["solver"].update_config.bind(config))
	dispatches_per_update = 0
	for cascade in _cascades:
		dispatches_per_update += cascade["config"].compute_pass_count()
	_rebuild_h0_all(SimulationClock.simulation_seed)


func transition_to_wave_spectrum_settings(target_configs: Array[OpenOceanFFTConfig], duration_seconds: float) -> bool:
	if target_configs.size() != 3:
		push_error("Wave transition requires exactly LONG, MID and SHORT configs.")
		return false
	for config in target_configs:
		if config == null or not config.is_valid():
			push_error("Wave transition received an invalid config.")
			return false
	var prepared_target_configs := _duplicate_wave_configs(target_configs)
	for config in prepared_target_configs:
		config.spectrum_model = _spectrum_model
	if duration_seconds <= 0.0 or _cascades.is_empty():
		set_wave_spectrum_settings(prepared_target_configs)
		return true
	if not _transition_topology_is_compatible(prepared_target_configs):
		push_warning("Wave transition topology differs; applying target immediately.")
		set_wave_spectrum_settings(prepared_target_configs)
		return true
	if _wave_transition_preparing:
		_wave_transition_queued_target_configs = prepared_target_configs
		_wave_transition_queued_duration_s = duration_seconds
		if _wave_transition_active:
			_wave_transition_progress_frozen = true
		return true
	_start_wave_transition_preparation(prepared_target_configs, duration_seconds)
	return true


func wave_transition_state() -> Dictionary:
	return {
		"active": _wave_transition_active,
		"preparing": _wave_transition_preparing,
		"alpha": _wave_transition_alpha,
		"duration_s": _wave_transition_duration_s,
		"elapsed_s": _wave_transition_elapsed_s,
		"target_configs": _wave_transition_target_configs,
		"cancelled": _wave_transition_cancelled,
	}


func _start_wave_transition_preparation(target_configs: Array[OpenOceanFFTConfig], duration_seconds: float) -> void:
	if _wave_transition_preparing:
		return
	var task := _WaveTransitionPreparationTask.new()
	_wave_transition_prepare_serial += 1
	task.serial = _wave_transition_prepare_serial
	task.simulation_seed = SimulationClock.simulation_seed
	task.target_configs = target_configs
	task.duration_s = maxf(duration_seconds, 0.001)
	task.coastal_split_inner_deg = coastal_split_inner_deg
	task.coastal_split_outer_deg = coastal_split_outer_deg
	if _query_reduced != null:
		var query_settings: Dictionary = _query_reduced.spectrum_transition_preparation_settings()
		task.query_budgets = query_settings["budgets"]
		task.query_mode = int(query_settings["mode"])
		task.query_coastal_active = bool(query_settings["coastal_active"])
		task.query_coastal_inner_deg = float(query_settings["coastal_inner_deg"])
		task.query_coastal_outer_deg = float(query_settings["coastal_outer_deg"])
	if _wave_transition_active:
		# Mantiene el mar animado con el alpha actual mientras se materializa el
		# CURRENT efectivo en CPU; no se crean cascadas FFT adicionales.
		_wave_transition_progress_frozen = true
		task.retarget = true
		task.current_configs = _duplicate_wave_configs(configs)
		task.previous_target_configs = _duplicate_wave_configs(_wave_transition_target_configs)
		task.current_h0_datas = _current_h0_datas
		task.current_render_h0_datas = _current_render_h0_datas
		task.previous_target_h0_datas = _wave_transition_target_h0_datas
		task.previous_target_render_h0_datas = _wave_transition_target_render_h0_datas
		task.current_energy_metrics = _coastal_energy_metrics.duplicate()
		task.previous_target_energy_metrics = _wave_transition_target_energy_metrics.duplicate()
		task.transition_alpha = _wave_transition_alpha
	_wave_transition_prepare_task = task
	_wave_transition_prepare_thread = Thread.new()
	var start_error := _wave_transition_prepare_thread.start(task.run)
	if start_error != OK:
		push_error("Could not start wave transition preparation thread.")
		_wave_transition_prepare_thread = null
		_wave_transition_prepare_task = null
		_wave_transition_progress_frozen = false
		return
	_wave_transition_preparing = true


func _poll_wave_transition_preparation() -> void:
	if not _wave_transition_preparing or _wave_transition_prepare_thread == null:
		return
	if _wave_transition_prepare_thread.is_alive():
		return
	# wait_to_finish sólo se llama cuando is_alive() ya es false: nunca bloquea
	# el frame loop esperando cálculo de H0/Query.
	var payload = _wave_transition_prepare_thread.wait_to_finish()
	_wave_transition_prepare_thread = null
	_wave_transition_prepare_task = null
	_wave_transition_preparing = false
	var queued_configs := _wave_transition_queued_target_configs
	var queued_duration := _wave_transition_queued_duration_s
	_wave_transition_queued_target_configs = []
	_wave_transition_queued_duration_s = 0.0
	if not queued_configs.is_empty():
		_start_wave_transition_preparation(queued_configs, queued_duration)
		return
	if not (payload is Dictionary) or int(payload.get("serial", -1)) != _wave_transition_prepare_serial:
		return
	if int(payload.get("simulation_seed", SimulationClock.simulation_seed)) != SimulationClock.simulation_seed:
		return
	_install_prepared_wave_transition(payload)


func _install_prepared_wave_transition(payload: Dictionary) -> void:
	var retarget := bool(payload.get("retarget", false))
	if retarget:
		var effective_configs: Array[OpenOceanFFTConfig] = payload["current_configs"]
		var effective_h0: Array[PackedByteArray] = payload["current_h0_datas"]
		var effective_render_h0: Array[PackedByteArray] = payload["current_render_h0_datas"]
		configs = effective_configs
		_current_h0_datas = effective_h0
		_current_render_h0_datas = effective_render_h0
		_coastal_energy_metrics = payload["current_energy_metrics"]
		for index in _cascades.size():
			var current_config := configs[0] if index < 2 else configs[index - 1]
			_cascades[index]["config"] = current_config
			RenderingServer.call_on_render_thread(_cascades[index].solver.replace_current_h0.bind(effective_render_h0[index], current_config))
		if _query_reduced != null and not _query_reduced.install_prepared_spectrum(payload["current_query_payload"]):
			push_error("Could not install prepared OceanQuery current endpoint.")
			return

	_wave_transition_target_configs = payload["target_configs"]
	_wave_transition_target_h0_datas = payload["target_h0_datas"]
	_wave_transition_target_render_h0_datas = payload["target_render_h0_datas"]
	_wave_transition_target_energy_metrics = payload["target_energy_metrics"]
	_wave_transition_duration_s = float(payload["duration_s"])
	_wave_transition_elapsed_s = 0.0
	_wave_transition_alpha = 0.0
	_wave_transition_active = true
	_wave_transition_progress_frozen = false
	_wave_transition_cancelled = false
	if _query_reduced != null and not _query_reduced.begin_prepared_spectrum_transition(payload["target_query_payload"], 0.0):
		push_error("Could not install prepared OceanQuery target endpoint.")
		_wave_transition_active = false
		return
	for index in _cascades.size():
		var target_config := _wave_transition_target_configs[0] if index < 2 else _wave_transition_target_configs[index - 1]
		RenderingServer.call_on_render_thread(_cascades[index].solver.begin_h0_transition.bind(
			_wave_transition_target_render_h0_datas[index], target_config
		))
	if _breaker_pool != null and not _wave_transition_target_configs.is_empty():
		_breaker_pool.begin_wave_transition(
			_wave_transition_target_configs[0].target_hs_m,
			_coastal_fraction_from_metrics(_wave_transition_target_energy_metrics)
		)
	_apply_transition_effective_state()
	_dispatch_requested = true


func _duplicate_wave_configs(source: Array[OpenOceanFFTConfig]) -> Array[OpenOceanFFTConfig]:
	var result: Array[OpenOceanFFTConfig] = []
	for config in source:
		result.append(config.duplicate() as OpenOceanFFTConfig)
	return result


func _invalidate_wave_transition_preparation() -> void:
	_wave_transition_prepare_serial += 1
	_wave_transition_queued_target_configs = []
	_wave_transition_queued_duration_s = 0.0


func sea_state_name() -> String:
	return SeaStateScript.state_name(_sea_state)


## --- A/B de espectro: PHILLIPS <-> JONSWAP_HASSELMANN. ---
## Regenera H0 conservando seed, tiempo, cámara, sea state y coastal; target_hs_m
## sigue siendo la autoridad de amplitud en ambos modelos.

func cycle_spectrum_model() -> void:
	_spectrum_model = 1 - _spectrum_model
	_apply_spectrum_model()
	_rebuild_h0_all(SimulationClock.simulation_seed)


func set_spectrum_model(model: int) -> void:
	_spectrum_model = clampi(model, OpenOceanFFTConfig.SpectrumModel.PHILLIPS, OpenOceanFFTConfig.SpectrumModel.JONSWAP_HASSELMANN)
	_apply_spectrum_model()
	_rebuild_h0_all(SimulationClock.simulation_seed)


func spectrum_model_name() -> String:
	return "JONSWAP_HASSELMANN" if _spectrum_model == OpenOceanFFTConfig.SpectrumModel.JONSWAP_HASSELMANN else "PHILLIPS"


func spectrum_band_diagnostics() -> Array:
	## 5R1B: target/measured Hs + lambda_peak por banda (JONSWAP), sin readback GPU.
	var result: Array = []
	for config in configs:
		var u := maxf(config.wind_speed_mps, 0.1)
		var fetch := maxf(config.fetch_length_m, 1.0)
		var g := config.gravity_mps2
		var omega_p := 22.0 * pow(g * g / (u * fetch), 1.0 / 3.0)
		var k_p := omega_p * omega_p / g
		result.append({
			"id": String(config.id),
			"target_hs_m": config.target_hs_m,
			"measured_hs_m": config.measured_hs_m,
			"lambda_peak_m": TAU / k_p,
		})
	return result


func toggle_ocean_shape_debug() -> void:
	## 5R1B: vista neutra de forma (C en el lab). No altera simulación.
	_ocean_shape_debug = not _ocean_shape_debug
	surface.get_surface_material().set_shader_parameter(&"ocean_shape_debug", _ocean_shape_debug)


func ocean_shape_debug_name() -> String:
	return "ON" if _ocean_shape_debug else "OFF"


func toggle_ocean_crest_sharpen_debug() -> void:
	## 5R1C: vista de zonas de crest sharpening. No altera simulación.
	_ocean_crest_sharpen_debug = not _ocean_crest_sharpen_debug
	surface.get_surface_material().set_shader_parameter(&"ocean_crest_sharpen_debug", _ocean_crest_sharpen_debug)


func ocean_crest_sharpen_debug_name() -> String:
	return "ON" if _ocean_crest_sharpen_debug else "OFF"


func toggle_ocean_normal_fragment() -> void:
	## 5R2: A/B normal shading FRAGMENT vs VERTEX. No altera geometría.
	_ocean_normal_fragment = not _ocean_normal_fragment
	# Keep the base material and any active per-LOD debug material in lockstep.
	surface.set_surface_shader_parameter(&"ocean_normal_fragment", _ocean_normal_fragment)


func ocean_normal_fragment_name() -> String:
	return "FRAGMENT" if _ocean_normal_fragment else "VERTEX"


func _crest_sharpen_config() -> Dictionary:
	## 5R1D: configuración compartida render/query (world-space, sin camera LOD).
	var dir: Vector2 = coastal_incoming_direction_xz.normalized()
	if dir.length_squared() < 0.5:
		dir = Vector2.RIGHT
	# eps coincide con el shader en open ocean: swell_lambda = TAU/k0 ≈ 16 m.
	var k0 := 0.392699
	var eps := maxf((TAU / k0) * 0.12, 1.5)
	var hs: float = _effective_long_hs_m()
	return {
		"strength": _crest_sharpen["strength"],
		"threshold": _crest_sharpen["threshold"],
		"max_gain": _crest_sharpen["max_gain"],
		"long_weight": _crest_sharpen["long_weight"],
		"mid_weight": _crest_sharpen["mid_weight"],
		"direction_x": dir.x,
		"direction_z": dir.y,
		"eps": eps,
		"local_hs": hs,
	}


func _apply_crest_sharpen_config() -> void:
	## 5R1D: empuja la MISMA configuración a shader, REDUCED, NATIVE y GOLDEN.
	var mat: ShaderMaterial = surface.get_surface_material()
	mat.set_shader_parameter(&"ocean_crest_sharpen_strength", _crest_sharpen["strength"])
	mat.set_shader_parameter(&"ocean_crest_sharpen_threshold", _crest_sharpen["threshold"])
	mat.set_shader_parameter(&"ocean_crest_sharpen_max_gain", _crest_sharpen["max_gain"])
	mat.set_shader_parameter(&"ocean_crest_sharpen_long_weight", _crest_sharpen["long_weight"])
	mat.set_shader_parameter(&"ocean_crest_sharpen_mid_weight", _crest_sharpen["mid_weight"])
	var cfg := _crest_sharpen_config()
	if _query_reduced != null:
		_query_reduced.set_crest_sharpen(cfg)
	if _query_native != null and _query_native.has_method(&"set_crest_sharpen"):
		_query_native.set_crest_sharpen(cfg)
	if _query_golden != null:
		_query_golden.set_crest_sharpen(cfg)


func _validate_long_split(config: OpenOceanFFTConfig) -> Dictionary:
	## 5R1B: comprueba numéricamente que LONG_COASTAL + LONG_REMAINDER = LONG.
	var full := SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SimulationClock.simulation_seed, config.id))
	var split := SpectrumScript.build_h0_split_rgba32f(config, SpectrumScript.derive_cascade_seed(SimulationClock.simulation_seed, config.id), coastal_split_inner_deg, coastal_split_outer_deg)
	var full_f := full.to_float32_array()
	var coastal_f := (split["coastal"] as PackedByteArray).to_float32_array()
	var remainder_f := (split["remainder"] as PackedByteArray).to_float32_array()
	var max_err := 0.0
	var sum_sq := 0.0
	var count := 0
	for index in full_f.size():
		var recon := coastal_f[index] + remainder_f[index]
		var err := absf(recon - full_f[index])
		max_err = maxf(max_err, err)
		sum_sq += err * err
		count += 1
	return {"max_err": max_err, "rms_err": sqrt(sum_sq / float(max(count, 1)))}


func _apply_spectrum_model() -> void:
	for config in configs:
		config.spectrum_model = _spectrum_model


## --- OceanQuery (Fase 2C, backend NATIVE si disponible, fallback REDUCED) ---
## La query fÃ­sica evalÃºa SIEMPRE las tres bandas del sea state activo. El band
## debug (B), los fades visuales y los perfiles de calidad NO alteran la query.
## No hay readback GPU->CPU. Golden Reference sÃ³lo en debug/test.

func sample_water(world_position: Vector3, simulation_time: float):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_full():
		return _native_to_sample(_query_native.sample_world(world_position.x, world_position.z, simulation_time))
	if _query_reduced != null:
		return _query_reduced.sample_water(world_position, simulation_time)
	return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)


func sample_water_physics_time(world_position: Vector3):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_full():
		_query_native.ensure_prepared(SimulationClock.simulation_time)
		return _native_to_sample(_query_native.sample_prepared(world_position.x, world_position.z))
	if _query_reduced != null:
		_query_reduced.ensure_prepared(SimulationClock.simulation_time)
		return _query_reduced.sample_water_prepared(world_position)
	return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)


func sample_water_batch_physics_time(positions: Array[Vector3]) -> Array:
	if not _enabled:
		var flat_result: Array = []
		var flat = QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
		flat_result.resize(positions.size())
		for index in positions.size():
			flat_result[index] = flat
		return flat_result
	if _native_query_can_sample_full():
		_query_native.ensure_prepared(SimulationClock.simulation_time)
		var packed := PackedVector3Array()
		packed.resize(positions.size())
		for index in positions.size():
			packed[index] = positions[index]
		var out = _query_native.sample_batch_prepared(packed)
		var result: Array = []
		result.resize(positions.size())
		for index in positions.size():
			result[index] = _native_to_sample(out, index)
		return result
	if _query_reduced != null:
		_query_reduced.ensure_prepared(SimulationClock.simulation_time)
		return _query_reduced.sample_water_batch_prepared(positions)
	return []


func sample_water_batch_at_time(positions: Array[Vector3], simulation_time: float) -> Array:
	## 4C-S4: batch de tracking visual de crestas. Igual que la batch física pero
	## con un tiempo explícito (render time), para que el tracker sea determinista
	## y coincida exactamente con lo que se ve en pantalla (pausa incluida).
	if not _enabled:
		var flat_result: Array = []
		var flat = QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
		flat_result.resize(positions.size())
		for index in positions.size():
			flat_result[index] = flat
		return flat_result
	if _native_query_can_sample_full():
		_query_native.ensure_prepared(simulation_time)
		var packed := PackedVector3Array()
		packed.resize(positions.size())
		for index in positions.size():
			packed[index] = positions[index]
		var out = _query_native.sample_batch_prepared(packed)
		var result: Array = []
		result.resize(positions.size())
		for index in positions.size():
			result[index] = _native_to_sample(out, index)
		return result
	if _query_reduced != null:
		_query_reduced.prepare_time(simulation_time)
		return _query_reduced.sample_water_batch_prepared(positions)
	return []


func sample_coastal_breaker_heights_batch_at_time(positions: Array[Vector3], simulation_time: float) -> Array:
	## Breaker DETECT/ACTIVE: consulta especializada LONG_COASTAL, sin Newton,
	## sin MID/SHORT, sin Jacobiano ni velocidad. El XZ recibido es q directo,
	## igual que el dominio donde el renderer aplica CoastalWarp.
	if not _enabled or _query_reduced == null:
		return _breaker_invalid_results(positions.size())
	if _native_query_can_sample_breaker():
		return _sample_native_breaker_batch(positions, simulation_time, false)
	_query_reduced.prepare_breaker_time(simulation_time)
	return _query_reduced.sample_coastal_breaker_heights_prepared(positions)


func sample_coastal_breaker_slopes_batch_at_time(positions: Array[Vector3], simulation_time: float) -> Array:
	## Breaker break_score: misma consulta especializada, pero calcula slope sólo
	## para los candidatos ya seleccionados (no para las siete muestras del perfil).
	if not _enabled or _query_reduced == null:
		return _breaker_invalid_results(positions.size())
	if _native_query_can_sample_breaker():
		return _sample_native_breaker_batch(positions, simulation_time, true)
	_query_reduced.prepare_breaker_time(simulation_time)
	return _query_reduced.sample_coastal_breaker_slopes_prepared(positions)


func _sample_native_breaker_batch(positions: Array[Vector3], simulation_time: float, include_slope: bool) -> Array:
	_query_native.prepare_breaker_time(simulation_time)
	var packed := PackedVector3Array()
	packed.resize(positions.size())
	for index in positions.size():
		packed[index] = positions[index]
	var out: PackedFloat64Array = _query_native.sample_coastal_breaker_batch_prepared(packed, include_slope)
	var result: Array = []
	result.resize(positions.size())
	for index in positions.size():
		result[index] = _native_to_sample(out, index)
	return _apply_breaker_zone_postprocess(result, positions, include_slope)


func _breaker_invalid_results(count: int) -> Array:
	var result: Array = []
	result.resize(count)
	for index in count:
		result[index] = QuerySampleScript.invalid()
	return result


func prepare_query_time(simulation_time: float) -> void:
	if _native_query_can_sample_full():
		_query_native.ensure_prepared(simulation_time)
	if _query_reduced != null:
		_query_reduced.prepare_time(simulation_time)
	if _query_golden != null:
		_query_golden.prepare_time(simulation_time)


func sample_water_prepared(world_position: Vector3):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_full():
		return _native_to_sample(_query_native.sample_prepared(world_position.x, world_position.z))
	if _query_reduced != null:
		return _query_reduced.sample_water_prepared(world_position)
	return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)


func sample_water_open_reference(world_position: Vector3, simulation_time: float):
	## Instrumento de Lab 3B.3; la producción usa sample_water().
	if _query_reduced != null:
		return _query_reduced.sample_water_open_reference(world_position, simulation_time)
	return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)


func has_golden_reference() -> bool:
	return _query_golden != null


func prepare_golden_time(simulation_time: float) -> void:
	if _query_golden != null:
		_query_golden.prepare_time(simulation_time)


func sample_water_golden_prepared(world_position: Vector3):
	if _query_golden == null:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	return _query_golden.sample_prepared(world_position)


func query_backend_name() -> String:
	if _native_query_can_sample_full():
		return "NATIVE"
	return "REDUCED_GDSCRIPT"


func query_backend_reason() -> String:
	if _native_query_can_sample_full():
		return "NATIVE"
	if _wave_transition_active:
		return "WAVE_TRANSITION"
	if not _sea_state_zone_descriptors.is_empty():
		return "SEA_STATE_ZONE_FULL_QUERY"
	if _query_native == null:
		return "NATIVE_INSTANCE_MISSING"
	if _query_reduced != null and _query_reduced.coastal_enabled() and not _query_native.has_method(&"set_coastal_runtime"):
		return "NATIVE_METHOD_MISSING:set_coastal_runtime"
	return "NATIVE_FULL_GATE_FALSE"


func breaker_query_backend_name() -> String:
	if _native_query_can_sample_breaker():
		return "NATIVE+ZONE_POSTPROCESS" if not _sea_state_zone_descriptors.is_empty() else "NATIVE"
	return "REDUCED_GDSCRIPT"


func breaker_query_backend_reason() -> String:
	if not _enabled:
		return "MODULE_DISABLED"
	if _query_native == null:
		return "NATIVE_INSTANCE_MISSING"
	if not _query_native.has_method(&"prepare_breaker_time"):
		return "NATIVE_METHOD_MISSING:prepare_breaker_time"
	if not _query_native.has_method(&"sample_coastal_breaker_batch_prepared"):
		return "NATIVE_METHOD_MISSING:sample_coastal_breaker_batch_prepared"
	if _query_reduced == null or not _query_reduced.coastal_enabled():
		return "COASTAL_RUNTIME_MISSING"
	if not _query_native.has_method(&"set_coastal_runtime"):
		return "NATIVE_METHOD_MISSING:set_coastal_runtime"
	if _wave_transition_active:
		return "WAVE_TRANSITION_PENDING_NATIVE_ENDPOINT"
	if not _sea_state_zone_descriptors.is_empty():
		return "NATIVE+ZONE_POSTPROCESS"
	return "NATIVE"


func set_sea_state_zones(descriptors: Array[Dictionary]) -> void:
	# Breaker queries remain Native; zones are a cheap LONG amplitude/gradient
	# postprocess in GDScript. The full physical query keeps its stricter gate.
	_sea_state_zone_descriptors = descriptors.duplicate()
	if _query_reduced != null:
		_query_reduced.set_sea_state_zones(_sea_state_zone_descriptors)
	if _breaker_pool != null:
		_breaker_pool.set_sea_state_zones(_sea_state_zone_descriptors)


func _native_query_can_sample_full() -> bool:
	# The full physical query currently receives one compact H0 set. During a
	# global transition or spatial zone evaluation REDUCED preserves exact dual
	# endpoint/zone semantics.
	if _wave_transition_active:
		return false
	if not _sea_state_zone_descriptors.is_empty():
		return false
	## Durante un hot reload con una DLL anterior, coastal conserva corrección
	## GDScript en vez de declarar falsamente paridad native. Tras rebuild la
	## DLL expone el método y vuelve a NATIVE+AVX2 sin cambiar API pública.
	if _query_native == null:
		return false
	if _query_reduced == null or not _query_reduced.coastal_enabled():
		return true
	return _query_native.has_method(&"set_coastal_runtime")


func _native_query_can_sample_breaker() -> bool:
	# Breaker detection has its own Native capability gate. It is LONG-only,
	# height/slope-only and must not inherit the full OceanQuery restrictions.
	if not _enabled or _wave_transition_active or _query_native == null or _query_reduced == null:
		return false
	if not _query_native.has_method(&"prepare_breaker_time"):
		return false
	if not _query_native.has_method(&"sample_coastal_breaker_batch_prepared"):
		return false
	if not _query_reduced.coastal_enabled():
		return false
	return _query_native.has_method(&"set_coastal_runtime")


func _apply_breaker_zone_postprocess(samples: Array, positions: Array[Vector3], include_slope: bool) -> Array:
	if _sea_state_zone_descriptors.is_empty():
		return samples
	var sea_level: float = surface.clipmap_config.sea_level_y
	for index in samples.size():
		var sample = samples[index]
		if sample == null or not sample.valid:
			continue
		var zone_state := _breaker_zone_long_state(Vector2(positions[index].x, positions[index].z))
		var base_h: float = sample.height - sea_level
		sample.height = sea_level + base_h * zone_state.x
		if include_slope:
			var base_dhx := 0.0
			var base_dhz := 0.0
			if absf(sample.normal.y) > 1.0e-6:
				base_dhx = -sample.normal.x / sample.normal.y
				base_dhz = -sample.normal.z / sample.normal.y
			var dhx: float = zone_state.x * base_dhx + base_h * zone_state.y
			var dhz: float = zone_state.x * base_dhz + base_h * zone_state.z
			var normal := Vector3(-dhx, 1.0, -dhz)
			sample.normal = normal.normalized() if normal.length_squared() > 1.0e-8 else Vector3.UP
	return samples


func _breaker_zone_long_state(point: Vector2) -> Vector3:
	var long_amplitude := 1.0
	var grad_x := 0.0
	var grad_z := 0.0
	for descriptor in _sea_state_zone_descriptors:
		var sdf_weight := SeaStateZoneMathScript.weight_and_gradient(
			point,
			Vector2(descriptor.get("center", Vector2.ZERO)),
			Vector2(descriptor.get("axis", Vector2.RIGHT)),
			Vector2(descriptor.get("half_extents", Vector2.ZERO)),
			float(descriptor.get("feather", 0.0))
		)
		var blend_weight := clampf(sdf_weight.x * clampf(float(descriptor.get("strength", 1.0)), 0.0, 1.0), 0.0, 1.0)
		if blend_weight <= 0.0:
			continue
		var strength := clampf(float(descriptor.get("strength", 1.0)), 0.0, 1.0)
		var grad_weight_x := sdf_weight.y * strength
		var grad_weight_z := sdf_weight.z * strength
		var target: Vector4 = descriptor.get("target", Vector4.ONE)
		var old_long := long_amplitude
		long_amplitude = lerpf(old_long, target.x, blend_weight)
		grad_x = grad_x * (1.0 - blend_weight) + (target.x - old_long) * grad_weight_x
		grad_z = grad_z * (1.0 - blend_weight) + (target.x - old_long) * grad_weight_z
	return Vector3(long_amplitude, grad_x, grad_z)


func _try_create_native_backend():
	## Godot registra la GDExtension al arrancar si el descriptor activo y la
	## DLL existen. Aquí sólo se consulta ClassDB: si la clase no está
	## registrada, fallback GDScript completamente silencioso.
	if not query_native_enabled:
		return null
	if ClassDB.class_exists(&"OceanQueryNative"):
		return ClassDB.instantiate(&"OceanQueryNative")
	return null


func _native_to_sample(out: PackedFloat64Array, batch_index := -1) -> OceanQuerySample:
	## Decodifica el contrato plano nativo (stride 15, ver ocean_query_native.h).
	var base := 0 if batch_index < 0 else batch_index * 15
	var sample := QuerySampleScript.new()
	sample.valid = out[base + 0] > 0.5
	sample.height = out[base + 1]
	sample.displacement = Vector3(out[base + 2], out[base + 3], out[base + 4])
	sample.normal = Vector3(out[base + 5], out[base + 6], out[base + 7])
	sample.surface_velocity = Vector3(out[base + 8], out[base + 9], out[base + 10])
	sample.jacobian_det = out[base + 11]
	sample.foldover_risk = out[base + 12] > 0.5
	sample.query_residual_m = out[base + 13]
	sample.query_iterations = int(out[base + 14])
	return sample


func cycle_debug_mode() -> void:
	# V recorre displacement/height/normals/slope/wireframe.
	surface.cycle_debug_mode()


func cycle_band_debug() -> void:
	_band_debug = (_band_debug + 1) % (BandDebug.SHORT + 1)
	surface.set_band_debug(_band_debug)
	_dispatch_requested = true


## Temporary runtime diagnosis. This path only updates the existing band_mask;
## it does not change FFT dispatch, cascade visibility, or clipmap LOD state.
func set_band_enabled(long_enabled: bool, mid_enabled: bool, short_enabled: bool) -> void:
	var clipmap_surface := surface as OceanClipmapSurface
	if clipmap_surface != null:
		clipmap_surface.set_band_enabled(long_enabled, mid_enabled, short_enabled)


func toggle_band_enabled(band_index: int) -> void:
	var clipmap_surface := surface as OceanClipmapSurface
	if clipmap_surface == null or band_index < 0 or band_index > 2:
		return
	var states := [
		clipmap_surface.is_band_enabled(0),
		clipmap_surface.is_band_enabled(1),
		clipmap_surface.is_band_enabled(2),
	]
	states[band_index] = not states[band_index]
	clipmap_surface.set_band_enabled(states[0], states[1], states[2])


func toggle_clipmap_lod_debug() -> void:
	surface.toggle_lod_debug()


func toggle_periodicity_debug() -> void:
	surface.toggle_periodicity_debug()


func rebuild_coastal_propagation() -> bool:
	## Operación explícita/development-time; nunca se ejecuta por query ni frame.
	_coastal_propagation = null
	_coastal_warp = null
	if _query_reduced != null:
		_query_reduced.clear_coastal()
	surface.set_coastal_warp(null)
	surface.set_real_seabed_coverage(coastal_bathymetry_data)
	# El mono de diagnóstico necesita k0/omega aun con la transformación OFF:
	# así C compara la misma onda profunda contra la onda costeña. En uso normal
	# (ambos flags false) conserva el camino abierto y no hornea nada.
	if not coastal_propagation_enabled and not coastal_monochromatic_debug:
		surface.set_coastal_propagation(null)
		_configure_breaker_pool()
		return false
	if coastal_bathymetry_data == null or not coastal_bathymetry_data.is_valid():
		push_warning("3B coastal: BathymetryData no asignado o inválido; LONG queda abierto.")
		surface.set_coastal_propagation(null)
		_configure_breaker_pool()
		return false
	if coastal_eikonal_enabled:
		var eikonal_baker := CoastalEikonalBakerScript.new()
		eikonal_baker.bathymetry_data = coastal_bathymetry_data
		eikonal_baker.incoming_direction_xz = coastal_incoming_direction_xz
		eikonal_baker.reference_wavelength_m = coastal_reference_wavelength_m
		eikonal_baker.min_valid_depth_m = coastal_min_valid_depth_m
		_coastal_propagation = eikonal_baker.bake()
	else:
		var straight_baker := CoastalBakerScript.new()
		straight_baker.bathymetry_data = coastal_bathymetry_data
		straight_baker.incoming_direction_xz = coastal_incoming_direction_xz
		straight_baker.reference_wavelength_m = coastal_reference_wavelength_m
		straight_baker.min_valid_depth_m = coastal_min_valid_depth_m
		_coastal_propagation = straight_baker.bake()
	if _coastal_propagation == null:
		surface.set_coastal_propagation(null)
		_configure_breaker_pool()
		return false
	# 3B.2B: construir el warp world->deep a partir del campo Eikonal. El eikonal
	# ES la base del warp (propagation_kind==1); el transform visual del FFT se
	# autoriza cuando hay warp activo, o en el camino straight 3B (sin eikonal).
	# Con eikonal debug SIN warp (3B.1), el transform queda OFF (solo MONO).
	var fft_transform_enabled := coastal_propagation_enabled and (not coastal_eikonal_enabled or coastal_warp_enabled)
	if coastal_propagation_enabled and coastal_warp_enabled and _coastal_propagation.propagation_kind == 1:
		var warp_baker := WarpBakerScript.new()
		warp_baker.propagation = _coastal_propagation
		warp_baker.backtrace_step_cells = 0.5
		_coastal_warp = warp_baker.bake()
		surface.set_coastal_warp(_coastal_warp, _coastal_warp != null)
		# 3B.3: la query física configura la misma superficie paramétrica que el
		# renderer. El sampler se evalúa sobre q durante Newton, nunca sobre world.
		if _coastal_warp != null and _query_reduced != null:
			_query_reduced.configure_coastal(_coastal_warp, _coastal_propagation,
				coastal_split_inner_deg, coastal_split_outer_deg, coastal_long_reference_direction())
	# El campo 2D no se aplica al FFT: sólo el shader mono consume phi(x,z).
	surface.set_coastal_propagation(_coastal_propagation, coastal_monochromatic_debug, coastal_monochromatic_amplitude_m, fft_transform_enabled, coastal_eikonal_refraction_debug and coastal_propagation_enabled)
	surface.set_coastal_runtime_enabled(_coastal_runtime_enabled)
	_configure_breaker_pool()
	return coastal_propagation_enabled


func set_coastal_bake_asset(asset: CoastalBakeAsset, runtime_enabled := true) -> bool:
	## Publicada sólo para el root OceanV3: carga Resources ya horneados y nunca
	## instancia BathymetryBaker, CoastalEikonalBaker ni CoastalWarpBaker.
	_coastal_propagation = null
	_coastal_warp = null
	if _query_reduced != null:
		_query_reduced.clear_coastal()
	surface.set_coastal_warp(null)
	surface.set_coastal_propagation(null)
	surface.set_real_seabed_coverage(null)
	_coastal_runtime_enabled = runtime_enabled
	if asset == null:
		_coastal_runtime_enabled = false
		coastal_bathymetry_data = null
		coastal_propagation_enabled = false
		_configure_breaker_pool()
		return false
	if not asset.is_valid():
		push_warning("Ocean V3 CoastalBakeAsset inválido o incompatible; Coastal OFF, continúa open-ocean.")
		_coastal_runtime_enabled = false
		coastal_bathymetry_data = null
		coastal_propagation_enabled = false
		_configure_breaker_pool()
		return false
	coastal_bathymetry_data = asset.bathymetry
	_coastal_propagation = asset.propagation
	_coastal_warp = asset.warp
	coastal_propagation_enabled = true
	coastal_incoming_direction_xz = asset.propagation.incoming_direction_xz
	coastal_reference_wavelength_m = asset.eikonal_reference_wavelength_m
	coastal_min_valid_depth_m = asset.eikonal_min_valid_depth_m
	coastal_eikonal_enabled = asset.propagation.propagation_kind == 1
	coastal_warp_enabled = asset.warp.is_valid()
	surface.set_real_seabed_coverage(coastal_bathymetry_data)
	if _coastal_warp != null and _coastal_warp.is_valid() and _query_reduced != null:
		_query_reduced.configure_coastal(_coastal_warp, _coastal_propagation,
			coastal_split_inner_deg, coastal_split_outer_deg, coastal_long_reference_direction())
	surface.set_coastal_warp(_coastal_warp, coastal_warp_enabled)
	surface.set_coastal_propagation(_coastal_propagation, coastal_monochromatic_debug,
		coastal_monochromatic_amplitude_m, coastal_warp_enabled,
		coastal_eikonal_refraction_debug)
	surface.set_coastal_runtime_enabled(_coastal_runtime_enabled)
	_configure_breaker_pool()
	return true


func set_coastal_runtime_enabled(enabled: bool) -> void:
	## A/B visual inmediato sobre el bake residente; no llama a rebuild.
	_coastal_runtime_enabled = enabled
	surface.set_coastal_runtime_enabled(enabled)
	if enabled:
		_configure_breaker_pool()
	elif _breaker_pool != null:
		_breaker_pool.disable()


func coastal_runtime_enabled() -> bool:
	return _coastal_runtime_enabled


func cycle_coastal_composition_debug() -> void:
	surface.cycle_coastal_composition_debug()


func coastal_composition_debug_name() -> String:
	return surface.coastal_composition_debug_name()


func _configure_breaker_pool() -> void:
	## Phase 4B: activa el pool sólo con Coastal ON + propagación válida; en
	## cualquier otro caso (Coastal OFF, sin batimetría, PREBREAK inválido) no
	## hay ningún breaker. Nunca se ejecuta por frame.
	if _breaker_pool == null:
		return
	var coastal_ok: bool = _performance_spectral_enabled and _coastal_performance_enabled \
		and _coastal_runtime_enabled and coastal_propagation_enabled \
		and _coastal_propagation != null and _coastal_propagation.is_valid()
	if not _performance_breakers_enabled or not breaker_enabled or not coastal_ok:
		_breaker_pool.disable()
		return
	_breaker_pool.configure(
		_coastal_propagation,
		_coastal_warp,
		configs[0].target_hs_m,
		_breaking_coastal_fraction,
		surface.clipmap_config.sea_level_y,
		surface.get_surface_material(),
	)
	_breaker_pool.set_sea_state_zones(_sea_state_zone_descriptors)
	# Specialized breaker path: el detector no entra en la hot path general de OceanQuery.
	_breaker_pool.set_breaker_query_sources(
		Callable(self, &"sample_coastal_breaker_heights_batch_at_time"),
		Callable(self, &"sample_coastal_breaker_slopes_batch_at_time")
	)


func set_breakers_enabled(enabled: bool) -> void:
	breaker_enabled = enabled
	_configure_breaker_pool()


func toggle_breaker_ribbons_diagnostic_visibility() -> void:
	if _breaker_pool != null:
		_breaker_pool.set_diagnostic_visible(not _breaker_pool.diagnostic_visible())


func breaker_ribbons_diagnostic_visible() -> bool:
	return _breaker_pool != null and _breaker_pool.diagnostic_visible()


func set_breaker_debug(mode: int) -> void:
	if _breaker_pool != null:
		_breaker_pool.set_debug_mode(mode)


func cycle_breaker_debug() -> void:
	if _breaker_pool != null:
		_breaker_pool.cycle_debug_mode()


func force_spawn_selected_breaker() -> bool:
	if _breaker_pool == null:
		return false
	return _breaker_pool.force_spawn_selected_slot()


func breaker_debug_name() -> String:
	if _breaker_pool == null:
		return "UNAVAILABLE"
	return _breaker_pool.breaker_debug_name()


func set_breaker_debug_slot(slot: int) -> void:
	if _breaker_pool != null:
		_breaker_pool.set_debug_slot(slot)


func cycle_breaker_debug_slot() -> void:
	if _breaker_pool != null:
		_breaker_pool.cycle_debug_slot()


func breaker_debug_slot_name() -> String:
	if _breaker_pool == null:
		return "ALL"
	return _breaker_pool.debug_slot_name()


func set_breaker_debug_stage(value: float) -> void:
	if _breaker_pool != null:
		_breaker_pool.set_debug_stage(value)


func adjust_breaker_debug_stage(delta: float) -> void:
	if _breaker_pool != null:
		_breaker_pool.adjust_debug_stage(delta)


func breaker_debug_stage() -> float:
	if _breaker_pool == null:
		return 1.0
	return _breaker_pool.debug_stage()


func toggle_breaker_profile_direction() -> void:
	if _breaker_pool != null:
		_breaker_pool.toggle_debug_profile_direction()


func breaker_profile_direction_name() -> String:
	if _breaker_pool == null:
		return "FORWARD"
	return _breaker_pool.debug_profile_direction_name()


func breaker_profile_aligned() -> bool:
	if _breaker_pool == null:
		return true
	return _breaker_pool.debug_profile_aligned()


func toggle_breaker_takeover_mask() -> void:
	if _breaker_pool != null:
		_breaker_pool.toggle_takeover_mask()


func breaker_takeover_mask_name() -> String:
	if _breaker_pool == null:
		return "OFF"
	return _breaker_pool.takeover_mask_name()


func breaker_pool_summary() -> Dictionary:
	if _breaker_pool == null:
		return {}
	var result: Dictionary = _breaker_pool.summary()
	result["breaker_enabled"] = breaker_enabled
	result["coastal_runtime_enabled"] = _coastal_runtime_enabled
	result["coastal_propagation_enabled"] = coastal_propagation_enabled
	result["breaker_query_backend"] = breaker_query_backend_name()
	result["breaker_query_backend_reason"] = breaker_query_backend_reason()
	return result


func set_breaker_performance_diagnostics_enabled(enabled: bool) -> void:
	if _breaker_pool != null:
		_breaker_pool.set_performance_diagnostics_enabled(enabled)


func set_breaker_performance_diagnostics_timing_enabled(enabled: bool) -> void:
	if _breaker_pool != null:
		_breaker_pool.set_performance_diagnostics_timing_enabled(enabled)


func reset_breaker_performance_diagnostics() -> void:
	if _breaker_pool != null:
		_breaker_pool.reset_performance_diagnostics()


func breaker_performance_diagnostics_snapshot() -> Dictionary:
	if _breaker_pool == null:
		return {}
	return _breaker_pool.performance_diagnostics_snapshot()


func configure_breaker_performance_checkpoint_active_breakers(active_count: int, age_s: float) -> Dictionary:
	if _breaker_pool == null:
		return {"configured": false, "reason": "POOL_UNAVAILABLE", "requested_active": active_count}
	return _breaker_pool.configure_performance_checkpoint_active_breakers(active_count, age_s)


func breaker_tracking_snapshot() -> Array:
	## 4C-S4: crest_s/stage por slot para el HUD (función pura del render time).
	if _breaker_pool == null:
		return []
	return _breaker_pool.tracking_snapshot()


func breaker_track_time() -> float:
	## 4C-S4: último render_time evaluado por el tracker (HUD).
	if _breaker_pool == null:
		return 0.0
	return _breaker_pool.track_time()


func coastal_propagation_data():
	return _coastal_propagation


func coastal_warp_data():
	return _coastal_warp


func set_coastal_render_diagnostics(composition_mode: int, warp_effect_mode: int,
		forced_warp_enabled: bool, forced_warp_offset_xz: Vector2, debug_gain: float,
		delta_heatmap_enabled: bool) -> void:
	## Diagnóstico visual 3B.2B; delega al renderer sin tocar H0 ni dispatches.
	surface.set_coastal_render_diagnostics(composition_mode, warp_effect_mode,
		forced_warp_enabled, forced_warp_offset_xz, debug_gain, delta_heatmap_enabled)


func coastal_fft_diagnostics() -> Dictionary:
	## Estado de las dos cascadas LONG del renderer. No lee datos de GPU.
	if _cascades.size() < 2:
		return {"ready": false, "reason": "cascadas LONG no inicializadas"}
	var coastal: Dictionary = _cascade_fft_diagnostic(_cascades[0])
	var remainder: Dictionary = _cascade_fft_diagnostic(_cascades[1])
	return {
		"ready": coastal["solver_ready"] and remainder["solver_ready"],
		"long_coastal": coastal,
		"long_remainder": remainder,
		"distinct_solver_displacement_rid": coastal["solver_displacement_rid"] != remainder["solver_displacement_rid"],
		"distinct_solver_normal_rid": coastal["solver_normal_rid"] != remainder["solver_normal_rid"],
		"distinct_published_displacement_rid": coastal["published_displacement_rid"] != remainder["published_displacement_rid"],
		"distinct_published_normal_rid": coastal["published_normal_rid"] != remainder["published_normal_rid"],
	}


func _cascade_fft_diagnostic(cascade: Dictionary) -> Dictionary:
	var solver_state: Dictionary = cascade["solver"].diagnostic_state()
	var displacement_rid: RID = cascade["displacement"].texture_rd_rid
	var normal_rid: RID = cascade["normal"].texture_rd_rid
	return {
		"id": cascade["config"].id,
		"solver_ready": solver_state["ready"],
		"h0_rid": solver_state["h0_rid"],
		"h0_upload_bytes": solver_state["h0_upload_bytes"],
		"solver_displacement_rid": solver_state["displacement_rid"],
		"solver_normal_rid": solver_state["normal_rid"],
		"published_displacement_rid": displacement_rid.get_id() if displacement_rid.is_valid() else -1,
		"published_normal_rid": normal_rid.get_id() if normal_rid.is_valid() else -1,
	}


func set_coastal_debug_field(field: int) -> void:
	surface.set_coastal_debug_field(field)


func set_breaking_debug(mode: int) -> void:
	## Phase 4A: debug GPU opt-in; no modifica FFT, propagation ni OceanQuery.
	surface.set_breaking_debug(mode)


func breaking_debug_name() -> String:
	return surface.breaking_debug_name()


func _update_breaking_energy_model() -> void:
	if configs.is_empty():
		return
	# STEP 2: OPEN_BREAK must receive the live LONG/MID band contract even when
	# Coastal is unavailable. This is a uniform update only, not a detector run.
	var effective_hs := _effective_long_hs_m()
	surface.set_breaking_open_model(
		effective_hs,
		_effective_band_hs_m(2),
		_effective_band_wavelength_m(0, false), _effective_band_wavelength_m(0, true),
		_effective_band_wavelength_m(2, false), _effective_band_wavelength_m(2, true),
		_effective_band_direction(0), _effective_band_direction(2)
	)
	if _coastal_energy_metrics.is_empty():
		return
	var metrics := _interpolated_energy_metrics(_coastal_energy_metrics, _wave_transition_target_energy_metrics, _wave_transition_alpha) if _wave_transition_active else _coastal_energy_metrics
	var total_variance: float = float(metrics.get("total_reconstructed_variance", 0.0))
	var coastal_variance: float = float(metrics.get("reconstructed_spatial_variance_coastal", 0.0))
	# Las dos partes del split pueden estar correlacionadas; para la proxy de
	# energía local de 4A usamos la fracción positiva de varianza propia, acotada.
	_breaking_coastal_fraction = clampf(coastal_variance / maxf(total_variance, 1.0e-8), 0.0, 1.0)
	surface.set_breaking_energy_model(effective_hs, _breaking_coastal_fraction)
	# 4B: el pool recoloca sus anchors con el mismo modelo de energía (Hs + fracción).
	if _breaker_pool != null:
		if _wave_transition_active:
			_breaker_pool.set_wave_transition_alpha(_wave_transition_alpha, effective_hs, _breaking_coastal_fraction)
		else:
			_breaker_pool.set_energy_model(effective_hs, _breaking_coastal_fraction)


func _coastal_fraction_from_metrics(metrics: Dictionary) -> float:
	var total_variance: float = float(metrics.get("total_reconstructed_variance", 0.0))
	var coastal_variance: float = float(metrics.get("reconstructed_spatial_variance_coastal", 0.0))
	return clampf(coastal_variance / maxf(total_variance, 1.0e-8), 0.0, 1.0)


func _effective_long_hs_m() -> float:
	if configs.is_empty():
		return 0.5
	if _wave_transition_active and not _wave_transition_target_configs.is_empty():
		return lerpf(configs[0].target_hs_m, _wave_transition_target_configs[0].target_hs_m, _wave_transition_alpha)
	return configs[0].target_hs_m


func _effective_band_hs_m(index: int) -> float:
	if index < 0 or index >= configs.size():
		return 0.0
	if _wave_transition_active and index < _wave_transition_target_configs.size():
		return lerpf(configs[index].target_hs_m, _wave_transition_target_configs[index].target_hs_m, _wave_transition_alpha)
	return configs[index].target_hs_m


func _effective_band_wavelength_m(index: int, maximum: bool) -> float:
	if index < 0 or index >= configs.size():
		return 1.0
	var value: float = configs[index].max_wavelength_m if maximum else configs[index].min_wavelength_m
	if _wave_transition_active and index < _wave_transition_target_configs.size():
		var target: float = _wave_transition_target_configs[index].max_wavelength_m if maximum else _wave_transition_target_configs[index].min_wavelength_m
		value = lerpf(value, target, _wave_transition_alpha)
	return maxf(value, 0.05)


func _effective_band_direction(index: int) -> Vector2:
	if index < 0 or index >= configs.size():
		return Vector2.RIGHT
	var direction: Vector2 = configs[index].wind_direction
	if _wave_transition_active and index < _wave_transition_target_configs.size():
		direction = direction.lerp(_wave_transition_target_configs[index].wind_direction, _wave_transition_alpha)
	return direction.normalized() if direction.length_squared() > 1.0e-8 else Vector2.RIGHT


func is_fft_enabled() -> bool:
	return _enabled


func debug_mode_name() -> String:
	return surface.debug_mode_name()


func band_debug_name() -> String:
	return BandDebug.keys()[_band_debug]


func clipmap_lod_debug_name() -> String:
	return surface.lod_debug_name()


func periodicity_debug_name() -> String:
	return surface.periodicity_debug_name()


func clipmap_level_count() -> int:
	return surface.level_count()


func clipmap_near_spacing_m() -> float:
	return surface.clipmap_config.base_spacing_m


func clipmap_extent_m() -> float:
	return surface.final_half_extent_m()


func clipmap_triangle_count() -> int:
	return surface.triangle_count()


func gpu_memory_bytes() -> int:
	var total := 0
	for cascade in _cascades:
		total += cascade["config"].approximate_gpu_bytes()
		var solver_state: Dictionary = cascade["solver"].diagnostic_state()
		total += int(solver_state.get("foam_gpu_bytes", 0))
		total += int(solver_state.get("surface_foam_gpu_bytes", 0))
		total += int(solver_state.get("previous_displacement_gpu_bytes", 0))
	if _surface_foam_solver != null and _surface_foam_config != null:
		var surface_foam_state: Dictionary = _surface_foam_solver.diagnostic_state()
		total += int(surface_foam_state.get("gpu_bytes", 0))
	return total


func combined_hs_m() -> float:
	if _wave_transition_active:
		return lerpf(_combined_hs_for(configs), _combined_hs_for(_wave_transition_target_configs), _wave_transition_alpha)
	return _combined_hs_for(configs)


func _combined_hs_for(source_configs: Array[OpenOceanFFTConfig]) -> float:
	var variance := 0.0
	for config in source_configs:
		variance += config.measured_hs_m * config.measured_hs_m
	return sqrt(variance)


func _build_h0(config: Resource, simulation_seed: int) -> PackedByteArray:
	return SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id))


func _make_surface_foam_config() -> SurfaceFoamReferenceConfig:
	var config := SurfaceFoamConfigScript.new()
	config.resolution = _surface_foam_fft_resolution
	config.domain_size_m = _surface_foam_source_domain_m
	config.field_domain_m = _surface_foam_field_domain_m
	config.depth_m = _surface_foam_depth_m
	var direction := deg_to_rad(_surface_foam_wind_direction_deg)
	config.wind_direction = Vector2(cos(direction), sin(direction))
	config.wind_speed_mps = _surface_foam_wind_speed_mps
	config.fetch_length_m = _surface_foam_fetch_m
	config.swell = _surface_foam_swell
	config.detail = _surface_foam_detail
	# 0 is the narrow/full Hasselmann directional distribution; 1 is flat.
	config.directional_spread = _surface_foam_directional_spread
	return config


func _apply_surface_foam_wind_preset(state: int) -> void:
	var presets := [6.0, 10.0, 20.0]
	_surface_foam_wind_speed_mps = presets[clampi(state, 0, presets.size() - 1)]
	if _surface_foam_config != null:
		_surface_foam_config.wind_speed_mps = _surface_foam_wind_speed_mps
	var ocean_root := get_parent()
	if ocean_root != null and ocean_root.has_method(&"_set_surface_foam_wind_speed_from_sea_state"):
		ocean_root.call(&"_set_surface_foam_wind_speed_from_sea_state", _surface_foam_wind_speed_mps)


func _initialize_surface_foam_solver() -> void:
	_surface_foam_config = _make_surface_foam_config()
	if not _surface_foam_config.is_valid():
		push_error("Configuración FFT de Surface Foam inválida.")
		return
	_surface_foam_solver = SurfaceFoamSolverScript.new()
	var h0_data := SurfaceFoamSpectrumScript.build_h0_rgba32f(_surface_foam_config as SurfaceFoamReferenceConfig, SimulationClock.simulation_seed)
	# This H0 is TMA/JONSWAP reference-compatible and deliberately has no Hs
	# normalization, band-pass, or physical-ocean amplitude coupling.
	RenderingServer.call_on_render_thread(_surface_foam_solver.initialize.bind(
		_surface_foam_config, h0_data, "Ocean2B.SurfaceFoam", _surface_foam_field_resolution, _surface_foam_topology_resolution
	))
	RenderingServer.call_on_render_thread(_surface_foam_solver.set_settings.bind(
		_surface_foam_topology_required, _surface_foam_whitecap, _surface_foam_amount,
		_surface_foam_update_hz,
		_surface_foam_birth_attack_s,
		_surface_foam_lifetime_s,
		_surface_foam_birth_selectivity,
		_surface_foam_evolution_speed,
		_surface_foam_crest_whitecap
	))


func _initialize_surface_foam_mid_history() -> void:
	if _surface_foam_mid_history_solver != null or _cascades.size() <= 2:
		return
	var mid_solver = _cascades[2].solver
	if mid_solver == null or not mid_solver.ready:
		return
	_surface_foam_mid_history_solver = SurfaceFoamMidHistorySolverScript.new()
	RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.initialize.bind(
		mid_solver.displacement_rid,
		_cascades[2].config.resolution
	))
	RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.set_settings.bind(
		_surface_foam_mid_history_required and _performance_spectral_enabled and _performance_mid_fold_history_enabled,
		_surface_foam_update_hz,
		_surface_foam_birth_attack_s,
		_surface_foam_lifetime_s,
		_surface_foam_mid_fold_start,
		_surface_foam_mid_fold_end
	))


func _rebuild_surface_foam_solver() -> void:
	_surface_foam_texture.texture_rd_rid = RID()
	_surface_foam_jacobian_texture.texture_rd_rid = RID()
	# Detach every published RD texture before the solver releases its RIDs.
	# Leaving topology attached makes Texture2DRD retain a view of a texture
	# that free_resources() has already destroyed; the next publication then
	# attempts to free that stale view.
	_surface_foam_topology_texture.texture_rd_rid = RID()
	if _surface_foam_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_solver.free_resources)
	_surface_foam_solver = null
	_initialize_surface_foam_solver()
	surface.set_surface_foam_spectrum(_surface_foam_texture, _surface_foam_field_domain_m)
	surface.set_surface_foam_jacobian(_surface_foam_jacobian_texture, _surface_foam_source_domain_m)
	surface.set_surface_foam_topology(_surface_foam_topology_texture, _surface_foam_source_domain_m)
	_dispatch_requested = true


func _rebuild_surface_foam_h0(simulation_seed: int) -> void:
	if _surface_foam_solver == null or _surface_foam_config == null:
		return
	RenderingServer.call_on_render_thread(_surface_foam_solver.upload_h0.bind(
		SurfaceFoamSpectrumScript.build_h0_rgba32f(_surface_foam_config as SurfaceFoamReferenceConfig, simulation_seed)
	))


func _textures_for(key: StringName) -> Array[Texture2DRD]:
	var textures: Array[Texture2DRD] = []
	for cascade in _cascades:
		textures.append(cascade[key])
	return textures


func _publish_ready_textures() -> void:
	for cascade in _cascades:
		if not cascade.solver.ready:
			return
		if not _textures_published:
			cascade.displacement.texture_rd_rid = cascade.solver.displacement_rid
			cascade.normal.texture_rd_rid = cascade.solver.normal_rid
		cascade.foam.texture_rd_rid = cascade.solver.foam_rid
	if _surface_foam_solver != null and _surface_foam_solver.ready:
		_surface_foam_texture.texture_rd_rid = _surface_foam_solver.surface_foam_rid
		_surface_foam_jacobian_texture.texture_rd_rid = _surface_foam_solver.jacobian_rid
		_surface_foam_topology_texture.texture_rd_rid = _surface_foam_solver.topology_rid
	_initialize_surface_foam_mid_history()
	if _surface_foam_mid_history_solver != null and _surface_foam_mid_history_solver.ready:
		_surface_foam_mid_fold_history_texture.texture_rd_rid = _surface_foam_mid_history_solver.history_rid
	_textures_published = true


func set_foam_transport_settings(residual_decay_multiplier: float, deposit_strength: float, advection_enabled: bool, advection_strength: float) -> void:
	_foam_residual_decay_multiplier = maxf(residual_decay_multiplier, 0.0)
	_foam_deposit_strength = clampf(deposit_strength, 0.0, 2.0)
	_foam_advection_enabled = advection_enabled
	_foam_advection_strength = clampf(advection_strength, 0.0, 2.0)
	for index in _cascades.size():
		var cascade: Dictionary = _cascades[index]
		RenderingServer.call_on_render_thread(cascade.solver.set_foam_transport_settings.bind(
			_foam_residual_decay_multiplier,
			_foam_deposit_strength,
			_foam_advection_enabled,
			_foam_advection_strength
		))
		RenderingServer.call_on_render_thread(cascade.solver.set_crest_foam_schedule.bind(
			_crest_foam_update_hz,
			float(index) * 0.25
		))


func set_crest_foam_update_hz(update_hz: float) -> void:
	_crest_foam_update_hz = clampf(update_hz, 30.0, 60.0)
	for index in _cascades.size():
		RenderingServer.call_on_render_thread(_cascades[index].solver.set_crest_foam_schedule.bind(
			_crest_foam_update_hz,
			float(index) * 0.25
		))


func set_crest_foam_compute_enabled(enabled: bool) -> void:
	_crest_foam_compute_enabled = enabled
	for cascade in _cascades:
		RenderingServer.call_on_render_thread(cascade.solver.set_crest_foam_compute_enabled.bind(
			enabled and _performance_spectral_enabled and _performance_crest_foam_solver_enabled
		))


func foam_render_diagnostics() -> Dictionary:
	var cascades_state: Array[Dictionary] = []
	for cascade in _cascades:
		var state: Dictionary = cascade.solver.diagnostic_state()
		# Preserve the solver's dispatch-derived crest transition state verbatim for
		# the Lab HUD; this remains CPU-side instrumentation only.
		state["id"] = cascade.config.id
		state["resolution"] = state.get("foam_resolution", 0)
		state["updates_total"] = state.get("crest_updates_total", 0)
		state["updates_per_second"] = state.get("crest_updates_per_second", 0.0)
		state["snapshots"] = state.get("crest_snapshot_count", 0)
		cascades_state.append(state)
	var surface_state: Dictionary = _surface_foam_solver.diagnostic_state() if _surface_foam_solver != null else {}
	return {
		"crest": cascades_state,
		"surface": surface_state,
		"surface_topology_required": _surface_foam_topology_required,
		"surface_mid_history_required": _surface_foam_mid_history_required,
		"surface_fft_resolution": _surface_foam_fft_resolution,
		"surface_field_resolution": _surface_foam_field_resolution,
	}


func set_surface_foam_settings(enabled: bool, whitecap: float, amount: float, update_hz: float,
		birth_attack_s: float = 0.16, lifetime_s: float = 1.10, birth_selectivity: float = 0.28,
		evolution_speed: float = 0.35, mid_fold_start: float = 0.10, mid_fold_end: float = 0.24,
		topology_required: bool = true, crest_whitecap: float = 0.0) -> void:
	_surface_foam_enabled = enabled
	_surface_foam_topology_required = topology_required
	# Crest Filigree consumes direct-J topology plus the Surface Foam temporal
	# envelope, but never the MID fold visibility limiter.
	_surface_foam_mid_history_required = enabled
	_surface_foam_whitecap = clampf(whitecap, 0.0, 1.5)
	_surface_foam_crest_whitecap = clampf(crest_whitecap, 0.0, 1.5)
	_surface_foam_amount = clampf(amount, 0.0, 10.0)
	_surface_foam_update_hz = clampf(update_hz, 30.0, 60.0)
	_surface_foam_birth_attack_s = clampf(birth_attack_s, 0.02, 1.0)
	_surface_foam_lifetime_s = clampf(lifetime_s, 0.1, 5.0)
	_surface_foam_birth_selectivity = clampf(birth_selectivity, 0.0, 1.0)
	_surface_foam_evolution_speed = clampf(evolution_speed, 0.0, 1.5)
	_surface_foam_mid_fold_start = clampf(mid_fold_start, 0.0, 1.0)
	_surface_foam_mid_fold_end = maxf(mid_fold_end, _surface_foam_mid_fold_start + 0.01)
	if _surface_foam_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_solver.set_settings.bind(
			_surface_foam_topology_required and _performance_spectral_enabled and _performance_surface_foam_solver_enabled,
			_surface_foam_whitecap,
			_surface_foam_amount,
			_surface_foam_update_hz,
			birth_attack_s,
			lifetime_s,
			birth_selectivity,
			evolution_speed,
			_surface_foam_crest_whitecap
		))
	if _surface_foam_mid_history_solver != null:
		RenderingServer.call_on_render_thread(_surface_foam_mid_history_solver.set_settings.bind(
			_surface_foam_mid_history_required and _performance_spectral_enabled and _performance_mid_fold_history_enabled,
			_surface_foam_update_hz,
			_surface_foam_birth_attack_s,
			_surface_foam_lifetime_s,
			_surface_foam_mid_fold_start,
			_surface_foam_mid_fold_end
		))


func set_surface_foam_spectrum_settings(resolution: int, field_resolution: int, topology_resolution: int, source_domain_m: float, field_domain_m: float, depth_m: float,
		wind_speed_mps: float, wind_direction_deg: float, fetch_m: float, swell: float,
		directional_spread: float, detail: float) -> void:
	var effective_wind_speed := maxf(wind_speed_mps, 0.1)
	var next_resolution := 256 if resolution <= 256 else 512 if resolution <= 512 else 1024
	var next_field_resolution := 256 if field_resolution <= 256 else 512 if field_resolution <= 512 else 1024
	var next_topology_resolution := 512 if topology_resolution <= 512 else 1024
	var next_source_domain := clampf(source_domain_m, 4.0, 32.0)
	var next_field_domain := maxf(field_domain_m, 8.0)
	var changed := next_resolution != _surface_foam_fft_resolution \
		or next_field_resolution != _surface_foam_field_resolution \
		or next_topology_resolution != _surface_foam_topology_resolution \
		or not is_equal_approx(next_source_domain, _surface_foam_source_domain_m) \
		or not is_equal_approx(next_field_domain, _surface_foam_field_domain_m) \
		or not is_equal_approx(depth_m, _surface_foam_depth_m) \
		or not is_equal_approx(effective_wind_speed, _surface_foam_wind_speed_mps) \
		or not is_equal_approx(wind_direction_deg, _surface_foam_wind_direction_deg) \
		or not is_equal_approx(fetch_m, _surface_foam_fetch_m) \
		or not is_equal_approx(swell, _surface_foam_swell) \
		or not is_equal_approx(directional_spread, _surface_foam_directional_spread) \
		or not is_equal_approx(detail, _surface_foam_detail)
	if not changed:
		return
	_surface_foam_fft_resolution = next_resolution
	_surface_foam_field_resolution = next_field_resolution
	_surface_foam_topology_resolution = next_topology_resolution
	_surface_foam_source_domain_m = next_source_domain
	_surface_foam_field_domain_m = next_field_domain
	_surface_foam_depth_m = maxf(depth_m, 0.1)
	_surface_foam_wind_speed_mps = effective_wind_speed
	_surface_foam_wind_direction_deg = wind_direction_deg
	_surface_foam_fetch_m = maxf(fetch_m, 1.0)
	_surface_foam_swell = clampf(swell, 0.0, 1.0)
	_surface_foam_directional_spread = clampf(directional_spread, 0.0, 1.0)
	_surface_foam_detail = clampf(detail, 0.0, 1.0)
	_rebuild_surface_foam_solver()


func _rebuild_foam_resolution() -> void:
	# GPU-only resource rebuild: no H0 upload, spectrum rebuild or CPU readback.
	_textures_published = false
	for index in _cascades.size():
		RenderingServer.call_on_render_thread(_cascades[index].solver.set_foam_resolution.bind(_crest_foam_resolution_for_cascade(index)))


func _crest_foam_resolution_for_cascade(index: int) -> int:
	if not foam_resolution_auto:
		return _validated_foam_resolution(foam_resolution)
	# Production policy: LONG_COASTAL/LONG_REMAINDER 1024, MID 512, SHORT 256.
	return 1024 if index < 2 else 512 if index == 2 else 256


func _validated_foam_resolution(value: int) -> int:
	if value <= 0:
		return 0
	if value <= 256:
		return 256
	if value <= 512:
		return 512
	return 1024


func _band_index(cascade_id: StringName) -> int:
	match cascade_id:
		&"LONG": return BandDebug.LONG
		&"LONG_COASTAL", &"LONG_REMAINDER": return BandDebug.LONG
		&"MID": return BandDebug.MID
		&"SHORT": return BandDebug.SHORT
	return BandDebug.ALL


func _on_module_state_changed(module_id: StringName, enabled: bool) -> void:
	if module_id != MODULE_ID:
		return
	_enabled = enabled
	surface.set_module_enabled(enabled)
	_dispatch_requested = enabled


func _on_seed_changed(simulation_seed: int) -> void:
	_invalidate_wave_transition_preparation()
	_rebuild_h0_all(simulation_seed)
	_rebuild_surface_foam_h0(simulation_seed)


func _on_reset_completed(_seed: int) -> void:
	_dispatch_requested = true


func _rebuild_h0_all(simulation_seed: int) -> void:
	## Regenera H0 UNA VEZ por cascada y alimenta con los MISMOS bytes a la GPU
	## (upload_h0), al backend REDUCED y a la Golden (sÃ³lo debug/test).
	## 3B.2B: las dos primeras cascadas de RENDER (LONG_COASTAL / LONG_REMAINDER)
	## comparten el config LONG; la query sigue usando el LONG original (configs).
	if _wave_transition_preparing:
		_invalidate_wave_transition_preparation()
	if _wave_transition_active:
		# A seed reset defines a new deterministic physical state; do not retain
		# endpoint H0 generated from the previous seed.
		_reset_wave_transition_state()
		_wave_transition_cancelled = true
	var h0_datas: Array[PackedByteArray] = _build_h0_datas(configs, simulation_seed)
	var long_config: OpenOceanFFTConfig = configs[0]
	var split: Dictionary = SpectrumScript.split_h0_rgba32f(long_config, h0_datas[0], coastal_split_inner_deg, coastal_split_outer_deg)
	_coastal_energy_metrics = split["coastal_energy_metrics"]
	_update_breaking_energy_model()
	var render_h0: Array[PackedByteArray] = [
		split["coastal"] as PackedByteArray,
		split["remainder"] as PackedByteArray,
		h0_datas[1],
		h0_datas[2],
	]
	_current_h0_datas = h0_datas
	_current_render_h0_datas = render_h0
	for index in _cascades.size():
		RenderingServer.call_on_render_thread(_cascades[index]["solver"].upload_h0.bind(render_h0[index]))
	if _query_reduced != null:
		_query_reduced.set_spectrum(configs, h0_datas)
	if _query_golden != null:
		_query_golden.set_spectrum(configs, h0_datas)
	_dispatch_requested = true


func _build_h0_datas(source_configs: Array[OpenOceanFFTConfig], simulation_seed: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for config in source_configs:
		result.append(_build_h0(config, simulation_seed))
	return result


func _advance_wave_transition(delta: float) -> void:
	_wave_transition_elapsed_s = minf(_wave_transition_elapsed_s + maxf(delta, 0.0), _wave_transition_duration_s)
	var t := clampf(_wave_transition_elapsed_s / maxf(_wave_transition_duration_s, 0.001), 0.0, 1.0)
	_wave_transition_alpha = t * t * (3.0 - 2.0 * t)
	if _query_reduced != null:
		_query_reduced.set_spectrum_transition_alpha(_wave_transition_alpha)
	_apply_transition_effective_state()
	if t >= 1.0:
		_complete_wave_transition()


func _apply_transition_effective_state() -> void:
	_update_breaking_energy_model()
	_apply_crest_sharpen_config()


func _complete_wave_transition() -> void:
	for cascade in _cascades:
		RenderingServer.call_on_render_thread(cascade.solver.complete_h0_transition)
	configs = _wave_transition_target_configs
	_current_h0_datas = _wave_transition_target_h0_datas
	_current_render_h0_datas = _wave_transition_target_render_h0_datas
	_coastal_energy_metrics = _wave_transition_target_energy_metrics
	for index in _cascades.size():
		_cascades[index]["config"] = configs[0] if index < 2 else configs[index - 1]
	if _query_reduced != null:
		_query_reduced.complete_spectrum_transition()
	if _query_golden != null:
		_query_golden.set_spectrum(configs, _current_h0_datas)
	if _breaker_pool != null:
		_breaker_pool.complete_wave_transition()
	_reset_wave_transition_state()
	_update_breaking_energy_model()
	_apply_crest_sharpen_config()


func _reset_wave_transition_state() -> void:
	_wave_transition_active = false
	_wave_transition_progress_frozen = false
	_wave_transition_alpha = 0.0
	_wave_transition_elapsed_s = 0.0
	_wave_transition_duration_s = 0.0
	_wave_transition_target_configs = []
	_wave_transition_target_h0_datas = []
	_wave_transition_target_render_h0_datas = []
	_wave_transition_target_energy_metrics = {}


func _transition_topology_is_compatible(target_configs: Array[OpenOceanFFTConfig]) -> bool:
	if configs.size() != target_configs.size():
		return false
	for index in configs.size():
		var current := configs[index]
		var target := target_configs[index]
		if current.resolution != target.resolution \
			or not is_equal_approx(current.domain_size_m, target.domain_size_m) \
			or not is_equal_approx(current.gravity_mps2, target.gravity_mps2):
			return false
	return true


func _interpolated_energy_metrics(current: Dictionary, target: Dictionary, alpha: float) -> Dictionary:
	var result := current.duplicate()
	for key in target:
		if current.has(key) and current[key] is float and target[key] is float:
			result[key] = lerpf(float(current[key]), float(target[key]), alpha)
	return result

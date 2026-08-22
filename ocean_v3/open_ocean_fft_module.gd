class_name OpenOceanFFTModule
extends Node3D
## Orquesta LONG/MID/SHORT como detalles internos del Ãºnico mÃ³dulo open_ocean_fft.

const MODULE_ID := &"open_ocean_fft"
const FFTConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SolverScript := preload("res://ocean_v3/rendering/fft/gpu_stockham_fft.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReferenceScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const QuerySampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")
const CoastalBakerScript := preload("res://ocean_v3/coastal/coastal_propagation_baker.gd")
const CoastalEikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

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
# 3B.1: sólo instrumento MONO; nunca warp definitivo del FFT direccional.
@export var coastal_eikonal_refraction_debug := false
# 3B.2B: split direccional de LONG (COASTAL / REMAINDER).
# Máscara angular suave: plena 1 hasta inner_deg, falloff hasta 0 en outer_deg.
@export_range(0.0, 60.0, 1.0) var coastal_split_inner_deg := 20.0
@export_range(20.0, 90.0, 1.0) var coastal_split_outer_deg := 35.0
@export var coastal_warp_enabled := true

@onready var surface: Node3D = $OceanClipmapSurface

var configs: Array[OpenOceanFFTConfig] = []
var dispatches_per_update := 0

var _cascades: Array[Dictionary] = []
var _query_reduced: RefCounted = null
var _query_native: RefCounted = null
var _query_golden: RefCounted = null
var _enabled := true
var _textures_published := false
var _dispatch_requested := true
var _band_debug: int = BandDebug.ALL
var _sea_state: int = SeaStateScript.State.RACE
var _sea_state_initialized := false
var _coastal_propagation = null
var _coastal_warp = null
var _coastal_energy_metrics: Dictionary = {}


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
	add_to_group(&"ocean_fft")
	_sea_state = SeaStateScript.State.RACE
	_sea_state_initialized = true
	configs = SeaStateScript.build_cascades(_sea_state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		if not config.is_valid():
			push_error("ConfiguraciÃ³n FFT invÃ¡lida para %s." % config.id)
			return
		h0_datas.append(_build_h0(config, SimulationClock.simulation_seed))
	# 3B.2B: LONG se divide en LONG_COASTAL + LONG_REMAINDER (misma física del
	# config LONG, H0 diferentes por máscara direccional). La query física sigue
	# usando el LONG original (configs[0]); sólo el render usa la 4.ª cascada.
	var long_config: OpenOceanFFTConfig = configs[0]
	var split: Dictionary = SpectrumScript.build_h0_split_rgba32f(long_config, SpectrumScript.derive_cascade_seed(SimulationClock.simulation_seed, long_config.id), coastal_split_inner_deg, coastal_split_outer_deg)
	_coastal_energy_metrics = split["coastal_energy_metrics"]
	_cascades.append(_make_cascade(long_config, split["coastal"], "Ocean2B.LONG_COASTAL"))
	_cascades.append(_make_cascade(long_config, split["remainder"], "Ocean2B.LONG_REMAINDER"))
	for index in [1, 2]:
		_cascades.append(_make_cascade(configs[index], h0_datas[index], "Ocean2B.%s" % configs[index].id))

	_enabled = enabled_on_start
	dispatches_per_update = 0
	for cascade in _cascades:
		dispatches_per_update += cascade["config"].compute_pass_count()
	# La referencia CPU recibe EXACTAMENTE los mismos bytes de H0 que la GPU.
	# Backend de producciÃ³n: REDUCED (GDScript), siempre disponible.
	_query_reduced = QueryReducedScript.new()
	_query_reduced.set_spectrum(configs, h0_datas)
	_query_reduced.set_sea_level(surface.clipmap_config.sea_level_y)
	_query_reduced.set_budget(reduced_long_pairs, reduced_mid_pairs, reduced_short_pairs)
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
	surface.configure(_render_configs(), _textures_for(&"displacement"), _textures_for(&"normal"))
	_update_breaking_energy_model()
	rebuild_coastal_propagation()
	surface.set_module_enabled(_enabled)
	surface.set_band_debug(_band_debug)
	OceanModuleRegistry.register_module(MODULE_ID, _enabled)
	OceanModuleRegistry.module_state_changed.connect(_on_module_state_changed)
	SimulationClock.seed_changed.connect(_on_seed_changed)
	SimulationClock.reset_completed.connect(_on_reset_completed)


func _make_cascade(config: OpenOceanFFTConfig, h0_data: PackedByteArray, resource_prefix: String) -> Dictionary:
	var displacement := Texture2DRD.new()
	var normal := Texture2DRD.new()
	var solver := SolverScript.new()
	RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0_data, resource_prefix))
	return {
		"config": config,
		"solver": solver,
		"displacement": displacement,
		"normal": normal,
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
		RenderingServer.call_on_render_thread(cascade.solver.free_resources)
	_cascades.clear()


func _process(_delta: float) -> void:
	_publish_ready_textures()
	surface.set_coastal_time(SimulationClock.get_render_time())
	if not _enabled:
		return
	for cascade in _cascades:
		var is_visible_band: bool = _band_debug == BandDebug.ALL or _band_index(cascade.config.id) == _band_debug
		if not is_visible_band:
			continue
		if cascade.solver.ready and (not SimulationClock.is_paused() or _dispatch_requested):
			RenderingServer.call_on_render_thread(cascade.solver.dispatch.bind(SimulationClock.get_render_time()))
	_dispatch_requested = false


func toggle_enabled() -> void:
	OceanModuleRegistry.set_module_enabled(MODULE_ID, not _enabled)


func set_sea_state(state: int) -> void:
	if not SeaStateScript.is_valid_state(state):
		push_warning("Estado de mar no vÃ¡lido: %s" % state)
		return
	if state == _sea_state and _sea_state_initialized:
		return
	_sea_state = state
	_sea_state_initialized = true
	configs = SeaStateScript.build_cascades(state)
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


func sea_state_name() -> String:
	return SeaStateScript.state_name(_sea_state)


## --- OceanQuery (Fase 2C, backend NATIVE si disponible, fallback REDUCED) ---
## La query fÃ­sica evalÃºa SIEMPRE las tres bandas del sea state activo. El band
## debug (B), los fades visuales y los perfiles de calidad NO alteran la query.
## No hay readback GPU->CPU. Golden Reference sÃ³lo en debug/test.

func sample_water(world_position: Vector3, simulation_time: float):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_coastal():
		return _native_to_sample(_query_native.sample_world(world_position.x, world_position.z, simulation_time))
	if _query_reduced != null:
		return _query_reduced.sample_water(world_position, simulation_time)
	return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)


func sample_water_physics_time(world_position: Vector3):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_coastal():
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
	if _native_query_can_sample_coastal():
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


func prepare_query_time(simulation_time: float) -> void:
	if _native_query_can_sample_coastal():
		_query_native.ensure_prepared(simulation_time)
	if _query_reduced != null:
		_query_reduced.prepare_time(simulation_time)
	if _query_golden != null:
		_query_golden.prepare_time(simulation_time)


func sample_water_prepared(world_position: Vector3):
	if not _enabled:
		return QuerySampleScript.flat(surface.clipmap_config.sea_level_y)
	if _native_query_can_sample_coastal():
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
	if _native_query_can_sample_coastal():
		return "NATIVE"
	return "REDUCED_GDSCRIPT"


func _native_query_can_sample_coastal() -> bool:
	## Durante un hot reload con una DLL anterior, coastal conserva corrección
	## GDScript en vez de declarar falsamente paridad native. Tras rebuild la
	## DLL expone el método y vuelve a NATIVE+AVX2 sin cambiar API pública.
	if _query_native == null:
		return false
	if _query_reduced == null or not _query_reduced.coastal_enabled():
		return true
	return _query_native.has_method(&"set_coastal_runtime")


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
	# El mono de diagnóstico necesita k0/omega aun con la transformación OFF:
	# así C compara la misma onda profunda contra la onda costeña. En uso normal
	# (ambos flags false) conserva el camino abierto y no hornea nada.
	if not coastal_propagation_enabled and not coastal_monochromatic_debug:
		surface.set_coastal_propagation(null)
		return false
	if coastal_bathymetry_data == null or not coastal_bathymetry_data.is_valid():
		push_warning("3B coastal: BathymetryData no asignado o inválido; LONG queda abierto.")
		surface.set_coastal_propagation(null)
		return false
	if coastal_eikonal_refraction_debug:
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
		return false
	# 3B.2B: construir el warp world->deep a partir del campo Eikonal. El eikonal
	# ES la base del warp (propagation_kind==1); el transform visual del FFT se
	# autoriza cuando hay warp activo, o en el camino straight 3B (sin eikonal).
	# Con eikonal debug SIN warp (3B.1), el transform queda OFF (solo MONO).
	var fft_transform_enabled := coastal_propagation_enabled and (not coastal_eikonal_refraction_debug or coastal_warp_enabled)
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
	return coastal_propagation_enabled


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
	if configs.is_empty() or _coastal_energy_metrics.is_empty():
		return
	var total_variance: float = float(_coastal_energy_metrics.get("total_reconstructed_variance", 0.0))
	var coastal_variance: float = float(_coastal_energy_metrics.get("reconstructed_spatial_variance_coastal", 0.0))
	# Las dos partes del split pueden estar correlacionadas; para la proxy de
	# energía local de 4A usamos la fracción positiva de varianza propia, acotada.
	var coastal_fraction := clampf(coastal_variance / maxf(total_variance, 1.0e-8), 0.0, 1.0)
	surface.set_breaking_energy_model(configs[0].target_hs_m, coastal_fraction)


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
	return total


func combined_hs_m() -> float:
	var variance := 0.0
	for config in configs:
		variance += config.measured_hs_m * config.measured_hs_m
	return sqrt(variance)


func _build_h0(config: Resource, simulation_seed: int) -> PackedByteArray:
	return SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id))


func _textures_for(key: StringName) -> Array[Texture2DRD]:
	var textures: Array[Texture2DRD] = []
	for cascade in _cascades:
		textures.append(cascade[key])
	return textures


func _publish_ready_textures() -> void:
	if _textures_published:
		return
	for cascade in _cascades:
		if not cascade.solver.ready:
			return
		cascade.displacement.texture_rd_rid = cascade.solver.displacement_rid
		cascade.normal.texture_rd_rid = cascade.solver.normal_rid
	_textures_published = true


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
	_rebuild_h0_all(simulation_seed)


func _on_reset_completed(_seed: int) -> void:
	_dispatch_requested = true


func _rebuild_h0_all(simulation_seed: int) -> void:
	## Regenera H0 UNA VEZ por cascada y alimenta con los MISMOS bytes a la GPU
	## (upload_h0), al backend REDUCED y a la Golden (sÃ³lo debug/test).
	## 3B.2B: las dos primeras cascadas de RENDER (LONG_COASTAL / LONG_REMAINDER)
	## comparten el config LONG; la query sigue usando el LONG original (configs).
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(_build_h0(config, simulation_seed))
	var long_config: OpenOceanFFTConfig = configs[0]
	var split: Dictionary = SpectrumScript.build_h0_split_rgba32f(long_config, SpectrumScript.derive_cascade_seed(simulation_seed, long_config.id), coastal_split_inner_deg, coastal_split_outer_deg)
	_coastal_energy_metrics = split["coastal_energy_metrics"]
	_update_breaking_energy_model()
	var render_h0 := [split["coastal"], split["remainder"], h0_datas[1], h0_datas[2]]
	for index in _cascades.size():
		RenderingServer.call_on_render_thread(_cascades[index]["solver"].upload_h0.bind(render_h0[index]))
	if _query_reduced != null:
		_query_reduced.set_spectrum(configs, h0_datas)
	if _query_golden != null:
		_query_golden.set_spectrum(configs, h0_datas)
	_dispatch_requested = true

class_name OpenOceanFFTModule
extends Node3D
## Orquesta LONG/MID/SHORT como detalles internos del único módulo open_ocean_fft.

const MODULE_ID := &"open_ocean_fft"
const FFTConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SolverScript := preload("res://ocean_v3/rendering/fft/gpu_stockham_fft.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

enum BandDebug {
	ALL,
	LONG,
	MID,
	SHORT,
}

@export var enabled_on_start := true

@onready var surface: Node3D = $OceanClipmapSurface

var configs: Array[OpenOceanFFTConfig] = []
var dispatches_per_update := 0

var _cascades: Array[Dictionary] = []
var _enabled := true
var _textures_published := false
var _dispatch_requested := true
var _band_debug: int = BandDebug.ALL
var _sea_state: int = SeaStateScript.State.RACE
var _sea_state_initialized := false


func _ready() -> void:
	add_to_group(&"ocean_fft")
	_sea_state = SeaStateScript.State.RACE
	_sea_state_initialized = true
	configs = SeaStateScript.build_cascades(_sea_state)
	for config in configs:
		if not config.is_valid():
			push_error("Configuración FFT inválida para %s." % config.id)
			return
		var displacement := Texture2DRD.new()
		var normal := Texture2DRD.new()
		var solver := SolverScript.new()
		var h0_data := _build_h0(config, SimulationClock.simulation_seed)
		_cascades.append({
			"config": config,
			"solver": solver,
			"displacement": displacement,
			"normal": normal,
		})
		RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0_data, "Ocean1B.%s" % config.id))

	_enabled = enabled_on_start
	dispatches_per_update = 0
	for config in configs:
		dispatches_per_update += config.compute_pass_count()
	surface.configure(configs, _textures_for(&"displacement"), _textures_for(&"normal"))
	surface.set_module_enabled(_enabled)
	surface.set_band_debug(_band_debug)
	OceanModuleRegistry.register_module(MODULE_ID, _enabled)
	OceanModuleRegistry.module_state_changed.connect(_on_module_state_changed)
	SimulationClock.seed_changed.connect(_on_seed_changed)
	SimulationClock.reset_completed.connect(_on_reset_completed)


func _exit_tree() -> void:
	if OceanModuleRegistry.module_state_changed.is_connected(_on_module_state_changed):
		OceanModuleRegistry.module_state_changed.disconnect(_on_module_state_changed)
	OceanModuleRegistry.unregister_module(MODULE_ID)
	for cascade in _cascades:
		cascade.displacement.texture_rd_rid = RID()
		cascade.normal.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(cascade.solver.free_resources)
	_cascades.clear()


func _process(_delta: float) -> void:
	_publish_ready_textures()
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
		push_warning("Estado de mar no válido: %s" % state)
		return
	if state == _sea_state and _sea_state_initialized:
		return
	_sea_state = state
	_sea_state_initialized = true
	configs = SeaStateScript.build_cascades(state)
	for index in _cascades.size():
		var cascade: Dictionary = _cascades[index]
		var config := configs[index]
		cascade["config"] = config
		var h0_data := _build_h0(config, SimulationClock.simulation_seed)
		RenderingServer.call_on_render_thread(cascade["solver"].update_config.bind(config))
		RenderingServer.call_on_render_thread(cascade["solver"].upload_h0.bind(h0_data))
	dispatches_per_update = 0
	for config in configs:
		dispatches_per_update += config.compute_pass_count()
	_dispatch_requested = true


func sea_state_name() -> String:
	return SeaStateScript.state_name(_sea_state)


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
	for config in configs:
		total += config.approximate_gpu_bytes()
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
	for cascade in _cascades:
		var h0_data := _build_h0(cascade.config, simulation_seed)
		RenderingServer.call_on_render_thread(cascade.solver.upload_h0.bind(h0_data))
	_dispatch_requested = true


func _on_reset_completed(_seed: int) -> void:
	_dispatch_requested = true

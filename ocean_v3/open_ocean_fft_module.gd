class_name OpenOceanFFTModule
extends Node3D
## Orquesta una sola cascada FFT de Fase 1A y publica sus texturas al renderer.

const MODULE_ID := &"open_ocean_fft"
const FFTConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SolverScript := preload("res://ocean_v3/rendering/fft/gpu_stockham_fft.gd")

@export var enabled_on_start := true

@onready var surface: MeshInstance3D = $OceanTestSurface

var config := FFTConfigScript.new()
var displacement_texture := Texture2DRD.new()
var normal_texture := Texture2DRD.new()
var solver := SolverScript.new()
var dispatches_per_update := 0

var _enabled := true
var _textures_published := false
var _dispatch_requested := true


func _ready() -> void:
	add_to_group(&"ocean_fft")
	if not config.is_valid():
		push_error("Configuración FFT inválida.")
		return
	_enabled = enabled_on_start
	dispatches_per_update = config.compute_pass_count()
	surface.configure(config, displacement_texture, normal_texture)
	surface.set_module_enabled(_enabled)
	OceanModuleRegistry.register_module(MODULE_ID, _enabled)
	OceanModuleRegistry.module_state_changed.connect(_on_module_state_changed)
	SimulationClock.seed_changed.connect(_on_seed_changed)
	SimulationClock.reset_completed.connect(_on_reset_completed)
	var h0_data: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, SimulationClock.simulation_seed)
	RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0_data))


func _exit_tree() -> void:
	if OceanModuleRegistry.module_state_changed.is_connected(_on_module_state_changed):
		OceanModuleRegistry.module_state_changed.disconnect(_on_module_state_changed)
	OceanModuleRegistry.unregister_module(MODULE_ID)
	displacement_texture.texture_rd_rid = RID()
	normal_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_resources)


func _process(_delta: float) -> void:
	if not _textures_published and solver.ready:
		displacement_texture.texture_rd_rid = solver.displacement_rid
		normal_texture.texture_rd_rid = solver.normal_rid
		_textures_published = true
	if not solver.ready:
		return
	if _enabled and (not SimulationClock.is_paused() or _dispatch_requested):
		_dispatch_requested = false
		RenderingServer.call_on_render_thread(solver.dispatch.bind(SimulationClock.get_render_time()))


func toggle_enabled() -> void:
	OceanModuleRegistry.set_module_enabled(MODULE_ID, not _enabled)


func cycle_debug_mode() -> void:
	surface.cycle_debug_mode()


func is_fft_enabled() -> bool:
	return _enabled


func debug_mode_name() -> String:
	return surface.debug_mode_name()


func gpu_memory_bytes() -> int:
	return config.approximate_gpu_bytes()


func _on_module_state_changed(module_id: StringName, enabled: bool) -> void:
	if module_id != MODULE_ID:
		return
	_enabled = enabled
	surface.set_module_enabled(enabled)
	_dispatch_requested = enabled


func _on_seed_changed(seed: int) -> void:
	var h0_data: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, seed)
	RenderingServer.call_on_render_thread(solver.upload_h0.bind(h0_data))
	_dispatch_requested = true


func _on_reset_completed(_seed: int) -> void:
	_dispatch_requested = true

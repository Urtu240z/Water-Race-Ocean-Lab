extends Node3D

const CALM_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/calm.tres")
const RACE_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/race.tres")
const ROUGH_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/rough.tres")
const FOAM_DEBUG_MODES: PackedInt32Array = [0, 1, 4, 7, 11]

@onready var free_camera: Camera3D = %FreeCamera
@onready var race_camera: Camera3D = %RaceReferenceCamera
@onready var benchmark_hud: CanvasLayer = %BenchmarkHUD
@onready var controls_label: Label = %Controls
@onready var metric_references: Node3D = $MetricReferences
@onready var ocean_v3: OceanV3 = $OceanV3Mount/OceanV3

var _using_race_camera := false
var _query_probe_tool: Node3D
var _foam_debug_index := 0


func _ready() -> void:
	_set_active_camera(false)
	_query_probe_tool = load("res://lab/debug/query_probe_snapshot.gd").new()
	add_child(_query_probe_tool)
	_foam_debug_index = max(FOAM_DEBUG_MODES.find(ocean_v3.foam_debug_mode), 0)
	controls_label.text = "CONTROLES\nTab: cámara libre / referencia\nWASD: mover | Q/E: bajar/subir | Shift: acelerar | Ratón: mirar\nP: pausa/reanuda | R: reset conserva seed | N: nueva seed\nO: océano FFT on/off | B: bandas ALL/LONG/MID/SHORT | V: vista | L: LOD | T: periodicidad | M: referencias métricas\nX: PHILLIPS/JONSWAP | S: shape debug | Z: crest sharpen debug | G: normal VERTEX/FRAGMENT | Y: query probes\nF2: Breaker Ribbons ON/OFF | F3: Foam Debug | F1: HUD\n4/5/6: transición CALM/RACE/ROUGH | Shift+4/5/6: CALM/RACE/ROUGH instantáneo | 1/2/3: DECK/STANDARD/DEV_HIGH | ,/.: escala de tiempo"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
		KEY_TAB:
			_set_active_camera(not _using_race_camera)
		KEY_P:
			SimulationClock.toggle_paused()
		KEY_R:
			SimulationClock.reset_simulation()
		KEY_N:
			SimulationClock.start_simulation_with_seed(SimulationClock.simulation_seed + 1)
		KEY_M:
			metric_references.visible = not metric_references.visible
		KEY_O:
			var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module:
				fft_module.toggle_enabled()
		KEY_V:
			var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module:
				fft_module.cycle_debug_mode()
		KEY_B:
			var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module:
				fft_module.cycle_band_debug()
		KEY_L:
			var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module:
				fft_module.toggle_clipmap_lod_debug()
		KEY_T:
			var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module:
				fft_module.toggle_periodicity_debug()
		KEY_X:
			var fft_module_x := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module_x:
				fft_module_x.cycle_spectrum_model()
		KEY_H:
			var fft_module_s := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module_s:
				fft_module_s.toggle_ocean_shape_debug()
		KEY_Z:
			var fft_module_z := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module_z:
				fft_module_z.toggle_ocean_crest_sharpen_debug()
		KEY_G:
			var fft_module_g := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module_g:
				fft_module_g.toggle_ocean_normal_fragment()
		KEY_Y:
			if _query_probe_tool:
				_query_probe_tool.call("toggle_snapshot")
		KEY_F2:
			var fft_module_breakers := get_tree().get_first_node_in_group(&"ocean_fft")
			if fft_module_breakers and fft_module_breakers.has_method(&"toggle_breaker_ribbons_diagnostic_visibility"):
				fft_module_breakers.call(&"toggle_breaker_ribbons_diagnostic_visibility")
		KEY_F3:
			_foam_debug_index = (_foam_debug_index + 1) % FOAM_DEBUG_MODES.size()
			ocean_v3.foam_debug_mode = FOAM_DEBUG_MODES[_foam_debug_index]
		KEY_4:
			if event.shift_pressed:
				ocean_v3.wave_preset = CALM_WAVE_PRESET
			else:
				ocean_v3.transition_to_wave_preset(CALM_WAVE_PRESET, ocean_v3.wave_transition_duration_s)
		KEY_5:
			if event.shift_pressed:
				ocean_v3.wave_preset = RACE_WAVE_PRESET
			else:
				ocean_v3.transition_to_wave_preset(RACE_WAVE_PRESET, ocean_v3.wave_transition_duration_s)
		KEY_6:
			if event.shift_pressed:
				ocean_v3.wave_preset = ROUGH_WAVE_PRESET
			else:
				ocean_v3.transition_to_wave_preset(ROUGH_WAVE_PRESET, ocean_v3.wave_transition_duration_s)
		KEY_1:
			OceanQualitySettings.set_profile(0) # DECK
		KEY_2:
			OceanQualitySettings.set_profile(1) # STANDARD
		KEY_3:
			OceanQualitySettings.set_profile(2) # DEV_HIGH
		KEY_COMMA:
			SimulationClock.time_scale = maxf(SimulationClock.time_scale * 0.5, 0.125)
		KEY_PERIOD:
			SimulationClock.time_scale = minf(SimulationClock.time_scale * 2.0, 8.0)
		KEY_F1:
			benchmark_hud.visible = not benchmark_hud.visible


func _set_active_camera(use_race_camera: bool) -> void:
	_using_race_camera = use_race_camera
	free_camera.call("set_active", not use_race_camera)
	if use_race_camera:
		race_camera.make_current()

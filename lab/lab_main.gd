extends Node3D

const CALM_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/calm.tres")
const RACE_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/race.tres")
const ROUGH_WAVE_PRESET: OceanWavePreset = preload("res://ocean_v3/presets/waves/rough.tres")
const SEA_STATE_ZONE_SCRIPT := preload("res://ocean_v3/core/ocean_sea_state_zone_3d.gd")
const FOAM_DEBUG_MODES: PackedInt32Array = [0, 1, 4, 7, 11, 14, 15]
const CONTROLS_TEXT := "CONTROLES\nTab: cámara libre / referencia\nWASD: mover | Q/E: bajar/subir | Shift: acelerar | Ratón: mirar\nP: pausa/reanuda | R: reset conserva seed | N: nueva seed\nO: océano FFT on/off | B: bandas ALL/LONG/MID/SHORT | V: vista | L: LOD | Shift+F: clipmap CONTINUOUS/FROZEN | T: periodicidad | M: referencias métricas\nX: PHILLIPS/JONSWAP | H: shape debug | Z: crest sharpen debug | G: normal VERTEX/FRAGMENT | Y: query probes\nF2: Breaker Ribbons ON/OFF | J: Breaker LIP/TAKEOVER/REGION/FORCE_LIP/DETECTOR/OFF | Shift+J: slot 0..7/ALL | Ctrl+J: FORCE SPAWN slot\nF3: Foam Debug | F4: Sea State Zone heatmap ON/OFF | F5: Reflection Debug | F1: HUD\nC: Coastal ON/OFF | Shift+C: FULL/LONG_COASTAL_ONLY | 4/5/6: transición CALM/RACE/ROUGH | Shift+4/5/6: instantáneo | 1/2/3: DECK/STANDARD/DEV_HIGH | ,/.: escala de tiempo"

@onready var free_camera: Camera3D = %FreeCamera
@onready var race_camera: Camera3D = %RaceReferenceCamera
@onready var benchmark_hud: CanvasLayer = %BenchmarkHUD
@onready var controls_label: Label = %Controls
@onready var metric_references: Node3D = $MetricReferences
@onready var ocean_v3: OceanV3 = $OceanV3Mount/OceanV3

var _using_race_camera := false
var _query_probe_tool: Node3D
var _demo_sea_state_zone: OceanSeaStateZone3D
var _foam_debug_index := 0
var _smoothed_frame_ms := 16.67
func _ready() -> void:
	_set_active_camera(false)
	_query_probe_tool = load("res://lab/debug/query_probe_snapshot.gd").new()
	add_child(_query_probe_tool)
	_create_demo_sea_state_zone()
	_foam_debug_index = max(FOAM_DEBUG_MODES.find(ocean_v3.foam_debug_mode), 0)
	_smoothed_frame_ms = 1000.0 / maxf(float(Engine.get_frames_per_second()), 1.0)
	_update_coastal_hud()


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
			ocean_v3.toggle_ocean_enabled()
		KEY_C:
			if event.shift_pressed:
				ocean_v3.cycle_coastal_composition_debug()
			else:
				ocean_v3.set_coastal_enabled(not ocean_v3.coastal_enabled())
			_update_coastal_hud()
		KEY_V:
			ocean_v3.cycle_ocean_debug_mode()
		KEY_B:
			ocean_v3.cycle_ocean_band_debug()
		KEY_L:
			ocean_v3.toggle_ocean_clipmap_lod_debug()
		KEY_F:
			if event.shift_pressed:
				ocean_v3.toggle_ocean_clipmap_tracking_debug_mode()
				_update_coastal_hud()
		KEY_T:
			ocean_v3.toggle_ocean_periodicity_debug()
		KEY_X:
			ocean_v3.cycle_ocean_spectrum_model()
		KEY_H:
			ocean_v3.toggle_ocean_shape_debug()
		KEY_Z:
			ocean_v3.toggle_ocean_crest_sharpen_debug()
		KEY_G:
			ocean_v3.toggle_ocean_normal_fragment()
		KEY_Y:
			if _query_probe_tool:
				_query_probe_tool.call("toggle_snapshot")
		KEY_F2:
			ocean_v3.toggle_breaker_ribbons_diagnostic_visibility()
		KEY_J:
			if event.ctrl_pressed and event.shift_pressed:
				if benchmark_hud != null and benchmark_hud.has_method(&"toggle_breaker_hud_verbose"):
					benchmark_hud.toggle_breaker_hud_verbose()
			elif event.ctrl_pressed:
				ocean_v3.force_spawn_selected_breaker()
			elif event.shift_pressed:
				ocean_v3.cycle_breaker_debug_slot()
			else:
				ocean_v3.cycle_breaker_debug()
		KEY_F3:
			_foam_debug_index = (_foam_debug_index + 1) % FOAM_DEBUG_MODES.size()
			ocean_v3.foam_debug_mode = FOAM_DEBUG_MODES[_foam_debug_index]
		KEY_F4:
			ocean_v3.toggle_sea_state_zone_debug()
			_update_coastal_hud()
		KEY_F5:
			ocean_v3.cycle_reflection_debug()
			_update_coastal_hud()
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


func _process(delta: float) -> void:
	_smoothed_frame_ms = lerpf(_smoothed_frame_ms, delta * 1000.0, 0.12)


func smoothed_frame_time_ms() -> float:
	return _smoothed_frame_ms


func _create_demo_sea_state_zone() -> void:
	if _demo_sea_state_zone != null:
		return
	_demo_sea_state_zone = SEA_STATE_ZONE_SCRIPT.new() as OceanSeaStateZone3D
	_demo_sea_state_zone.name = "DemoSeaStateZone"
	_demo_sea_state_zone.position = Vector3(0.0, 0.0, -80.0)
	_demo_sea_state_zone.box_size_m = Vector2(120.0, 160.0)
	_demo_sea_state_zone.feather_distance_m = 30.0
	_demo_sea_state_zone.long_amplitude_multiplier = 0.35
	_demo_sea_state_zone.mid_amplitude_multiplier = 0.10
	_demo_sea_state_zone.short_amplitude_multiplier = 0.03
	_demo_sea_state_zone.choppiness_multiplier = 0.45
	_demo_sea_state_zone.foam_generation_multiplier = 0.10
	_demo_sea_state_zone.strength = 1.0
	_demo_sea_state_zone.priority = 0
	add_child(_demo_sea_state_zone)
	ocean_v3.register_sea_state_zone(_demo_sea_state_zone)


func _update_coastal_hud() -> void:
	if ocean_v3 == null:
		controls_label.text = CONTROLS_TEXT + "\nBreaker HUD: Ctrl+Shift+J verbose\nClipmap Tracking: UNAVAILABLE\nC: Coastal unavailable | Shift+C: composition\nReflection Debug: UNAVAILABLE"
		return
	var state := "ON" if ocean_v3.coastal_enabled() else "OFF"
	controls_label.text = CONTROLS_TEXT + "\nBreaker HUD: Ctrl+Shift+J verbose\nClipmap Tracking: %s\nCoastal: %s | Composition: %s\nReflection Debug: %s" % [ocean_v3.clipmap_tracking_debug_mode_name(), state, ocean_v3.coastal_composition_debug_name(), ocean_v3.reflection_debug_name()]


func _set_active_camera(use_race_camera: bool) -> void:
	_using_race_camera = use_race_camera
	free_camera.call("set_active", not use_race_camera)
	if use_race_camera:
		race_camera.make_current()

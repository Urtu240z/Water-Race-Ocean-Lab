extends Node3D

@onready var free_camera: Camera3D = %FreeCamera
@onready var race_camera: Camera3D = %RaceReferenceCamera
@onready var benchmark_hud: CanvasLayer = %BenchmarkHUD
@onready var controls_label: Label = %Controls

var _using_race_camera := false


func _ready() -> void:
	_set_active_camera(false)
	controls_label.text = "CONTROLES\nTab: cámara libre / referencia\nWASD: mover | Q/E: bajar/subir | Shift: acelerar | Ratón: mirar\nP: pausa/reanuda | R: reset conserva seed | N: nueva seed\nO: océano FFT on/off | B: bandas ALL/LONG/MID/SHORT | V: vista | L: LOD | T: periodicidad\n1/2/3: DECK/STANDARD/DEV_HIGH | -/=: escala de tiempo | F1: HUD"


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
		KEY_1:
			OceanQualitySettings.set_profile(0) # DECK
		KEY_2:
			OceanQualitySettings.set_profile(1) # STANDARD
		KEY_3:
			OceanQualitySettings.set_profile(2) # DEV_HIGH
		KEY_MINUS:
			SimulationClock.time_scale = maxf(SimulationClock.time_scale * 0.5, 0.125)
		KEY_EQUAL:
			SimulationClock.time_scale = minf(SimulationClock.time_scale * 2.0, 8.0)
		KEY_F1:
			benchmark_hud.visible = not benchmark_hud.visible


func _set_active_camera(use_race_camera: bool) -> void:
	_using_race_camera = use_race_camera
	free_camera.call("set_active", not use_race_camera)
	if use_race_camera:
		race_camera.make_current()

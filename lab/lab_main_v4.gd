extends Node3D
## Controls specific to the V4 comparison lab. This scene never reaches Ocean V3.

const CONTROLS_TEXT := "OCEAN V4 LAB\nTab: cámara libre / referencia\nWASD: mover | Q/E: bajar/subir | Shift: acelerar | Ratón: mirar\nP: pausa/reanuda | R: reset conserva seed | N: nueva seed\nM: referencias métricas | F1: HUD"

@onready var free_camera: Camera3D = %FreeCamera
@onready var race_camera: Camera3D = %RaceReferenceCamera
@onready var benchmark_hud: CanvasLayer = %BenchmarkHUD
@onready var controls_label: Label = %Controls
@onready var metric_references: Node3D = $MetricReferences
@onready var ocean_v4: OceanV4 = $OceanV4Mount/OceanV4

var _using_race_camera := false
var _smoothed_frame_ms := 16.67


func _ready() -> void:
	_set_active_camera(false)
	controls_label.text = CONTROLS_TEXT
	_smoothed_frame_ms = 1000.0 / maxf(float(Engine.get_frames_per_second()), 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_TAB: _set_active_camera(not _using_race_camera)
		KEY_M: metric_references.visible = not metric_references.visible
		KEY_P: ocean_v4.advance_time = not ocean_v4.advance_time
		KEY_B: ocean_v4.cycle_debug_band()
		KEY_R: ocean_v4.reset_simulation(ocean_v4.simulation_seed)
		KEY_N: ocean_v4.reset_simulation(ocean_v4.simulation_seed + 1)
		KEY_F1: benchmark_hud.visible = not benchmark_hud.visible


func _process(delta: float) -> void:
	_smoothed_frame_ms = lerpf(_smoothed_frame_ms, delta * 1000.0, 0.12)


func smoothed_frame_time_ms() -> float:
	return _smoothed_frame_ms


func _set_active_camera(use_race_camera: bool) -> void:
	_using_race_camera = use_race_camera
	free_camera.call("set_active", not use_race_camera)
	if use_race_camera:
		race_camera.make_current()

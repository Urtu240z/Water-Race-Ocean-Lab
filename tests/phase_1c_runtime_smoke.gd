extends SceneTree
## Smoke test normal: mueve la cámara libre y ejercita APIs sin inspección GPU/readback.

const ClockScript := preload("res://ocean_v3/core/simulation_clock.gd")

var _frame := 0
var _free_camera: Camera3D
var _fft_module: Node
var _clock = ClockScript.new()


func _initialize() -> void:
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 5:
		_fft_module = get_first_node_in_group(&"ocean_fft")
		for camera in get_nodes_in_group(&"lab_camera"):
			if camera.has_method(&"set_active"):
				_free_camera = camera
		if _fft_module == null or _free_camera == null:
			push_error("PHASE_1C_RUNTIME_SMOKE: faltan módulo o cámara libre")
			quit(1)
			return false
		_fft_module.cycle_band_debug()
		_fft_module.cycle_debug_mode()
		_fft_module.toggle_clipmap_lod_debug()
		_fft_module.toggle_periodicity_debug()
		_clock.pause()
		_clock.reset_simulation()
		_clock.resume()
	if _free_camera != null and _frame > 5 and _frame < 80:
		_free_camera.global_position += Vector3(80.0, 0.0, -45.0)
	if _frame == 20:
		_fft_module.toggle_enabled()
	if _frame == 21:
		_fft_module.toggle_enabled()
	if _frame == 100:
		print("PHASE_1C_RUNTIME_SMOKE: PASS")
		_clock.free()
		quit(0)
	return false

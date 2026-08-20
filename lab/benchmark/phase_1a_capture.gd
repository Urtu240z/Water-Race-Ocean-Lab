extends SceneTree
## Captura repetible de métricas runtime. Argumento opcional tras `--`: fft-off.

const WARMUP_FRAMES := 180
const SAMPLE_FRAMES := 180

var _frame := 0
var _fps_sum := 0.0
var _process_ms_sum := 0.0
var _physics_ms_sum := 0.0
var _fft_off := false


func _initialize() -> void:
	_fft_off = "fft-off" in OS.get_cmdline_user_args()
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 5 and _fft_off:
		var module := get_first_node_in_group(&"ocean_fft")
		if module:
			module.toggle_enabled()
	if _frame > WARMUP_FRAMES:
		_fps_sum += Engine.get_frames_per_second()
		_process_ms_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_physics_ms_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	if _frame == WARMUP_FRAMES + SAMPLE_FRAMES:
		var divisor := float(SAMPLE_FRAMES)
		print("PHASE_1B_BENCHMARK mode=%s fps=%.2f cpu_process_ms=%.3f physics_ms=%.3f draw_calls=%d primitives=%d static_memory_mib=%.2f" % [
			"FFT_OFF" if _fft_off else "FFT_ON",
			_fps_sum / divisor,
			_process_ms_sum / divisor,
			_physics_ms_sum / divisor,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0),
		])
		quit(0)
	return false

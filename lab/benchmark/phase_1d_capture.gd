extends SceneTree
## Captura reproducible de métricas para Gate 1.
##
## Uso:
##   godot --path . --script res://lab/benchmark/phase_1d_capture.gd -- off|calm|race|rough
##
## Requiere VSync OFF y FPS sin límite (ya configurados en project.godot).
## Misma cámara de referencia, seed, resolución y perfil de calidad en todos
## los modos. Flujo: 3 s de warmup real + 3 muestras de 5 s cada una; se
## reporta la MEDIANA de FPS/frame_ms junto con cada muestra individual.
## CPU process y physics se registran sólo como dato auxiliar; NO se declara
## GPU ms (usar el profiler externo: RenderDoc/Nsight/RGP).

const WARMUP_SECONDS := 3.0
const SAMPLE_SECONDS := 5.0
const SAMPLE_COUNT := 3

const SEA_STATES := {
	"off": -1,
	"calm": 0,
	"race": 1,
	"rough": 2,
}

var _frame := 0
var _mode := "race"
var _phase := "init" # init -> warmup -> sampling -> done
var _phase_start_usec := 0
var _sample_frames := 0
var _process_ms_sum := 0.0
var _physics_ms_sum := 0.0
var _samples: Array[Dictionary] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if SEA_STATES.has(arg):
			_mode = arg
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3:
		_use_race_camera()
	if _frame == 5:
		var module := get_first_node_in_group(&"ocean_fft")
		if module == null:
			push_error("PHASE_1D_BENCHMARK: módulo open_ocean_fft no encontrado")
			quit(1)
			return false
		var state: int = SEA_STATES[_mode]
		if state < 0:
			module.toggle_enabled()
		else:
			module.set_sea_state(state)
		_phase = "warmup"
		_phase_start_usec = Time.get_ticks_usec()
		return false

	match _phase:
		"warmup":
			if _elapsed_sec() >= WARMUP_SECONDS:
				_start_sample()
		"sampling":
			_sample_frames += 1
			_process_ms_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			_physics_ms_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			if _elapsed_sec() >= SAMPLE_SECONDS:
				_record_sample()
	return false


func _elapsed_sec() -> float:
	return float(Time.get_ticks_usec() - _phase_start_usec) / 1000000.0


func _start_sample() -> void:
	_phase = "sampling"
	_phase_start_usec = Time.get_ticks_usec()
	_sample_frames = 0
	_process_ms_sum = 0.0
	_physics_ms_sum = 0.0


func _record_sample() -> void:
	var fps := float(_sample_frames) / _elapsed_sec()
	var sample := {
		"fps": fps,
		"frame_ms": 1000.0 / maxf(fps, 1.0),
		"cpu_process_ms": _process_ms_sum / float(maxi(_sample_frames, 1)),
		"physics_ms": _physics_ms_sum / float(maxi(_sample_frames, 1)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"static_memory_mib": Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0),
	}
	_samples.append(sample)
	print("PHASE_1D_BENCHMARK_SAMPLE mode=%s sample=%d fps=%.2f frame_ms=%.3f cpu_process_ms=%.3f physics_ms=%.3f draw_calls=%d primitives=%d static_memory_mib=%.2f" % [
		_mode, _samples.size(), sample.fps, sample.frame_ms, sample.cpu_process_ms, sample.physics_ms, sample.draw_calls, sample.primitives, sample.static_memory_mib,
	])
	if _samples.size() < SAMPLE_COUNT:
		_start_sample()
	else:
		_finish()


func _finish() -> void:
	var median := _median_sample()
	print("PHASE_1D_BENCHMARK mode=%s median_fps=%.2f median_frame_ms=%.3f cpu_process_ms=%.3f physics_ms=%.3f draw_calls=%d primitives=%d static_memory_mib=%.2f" % [
		_mode, median.fps, median.frame_ms, median.cpu_process_ms, median.physics_ms, median.draw_calls, median.primitives, median.static_memory_mib,
	])
	quit(0)


func _median_sample() -> Dictionary:
	var sorted: Array[float] = []
	for sample in _samples:
		sorted.append(sample.fps)
	sorted.sort()
	var median_fps: float = sorted[sorted.size() / 2]
	for sample in _samples:
		if sample.fps == median_fps:
			return sample
	return _samples[_samples.size() - 1]


func _use_race_camera() -> void:
	var race_camera := get_root().get_node_or_null("LabMain/Cameras/RaceReferenceCamera") as Camera3D
	if race_camera:
		race_camera.make_current()

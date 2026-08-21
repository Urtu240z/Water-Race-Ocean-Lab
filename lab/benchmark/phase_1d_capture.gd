extends SceneTree
## Captura reproducible de métricas para Gate 1.
##
## Uso:
##   godot --path . --script res://lab/benchmark/phase_1d_capture.gd -- off|calm|race|rough
##
## Requiere VSync OFF y FPS sin límite (ya configurados en project.godot).
## Misma resolución, cámara de referencia, seed y perfil de calidad en todos
## los modos. El FPS se mide por tiempo de pared sobre una ventana de muestreo
## fija; no declara GPU ms (usar el profiler externo: RenderDoc/Nsight/RGP).

const WARMUP_FRAMES := 120
const SAMPLE_DURATION_SEC := 2.0

const SEA_STATES := {
	"off": -1,
	"calm": 0,
	"race": 1,
	"rough": 2,
}

var _frame := 0
var _sample_start_usec := 0
var _sample_frames := 0
var _process_ms_sum := 0.0
var _physics_ms_sum := 0.0
var _sampling := false
var _mode := "race"


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

	if _frame <= WARMUP_FRAMES:
		return false
	if not _sampling:
		_sampling = true
		_sample_start_usec = Time.get_ticks_usec()
		_sample_frames = 0
		_process_ms_sum = 0.0
		_physics_ms_sum = 0.0
	_sample_frames += 1
	_process_ms_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_physics_ms_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var elapsed_sec := float(Time.get_ticks_usec() - _sample_start_usec) / 1000000.0
	if elapsed_sec >= SAMPLE_DURATION_SEC:
		var fps := float(_sample_frames) / elapsed_sec
		print("PHASE_1D_BENCHMARK mode=%s fps=%.2f frame_ms=%.3f cpu_process_ms=%.3f physics_ms=%.3f draw_calls=%d primitives=%d static_memory_mib=%.2f" % [
			_mode,
			fps,
			1000.0 / maxf(fps, 1.0),
			_process_ms_sum / float(_sample_frames),
			_physics_ms_sum / float(_sample_frames),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0),
		])
		quit(0)
	return false


func _use_race_camera() -> void:
	var race_camera := get_root().get_node_or_null("LabMain/Cameras/RaceReferenceCamera") as Camera3D
	if race_camera:
		race_camera.make_current()

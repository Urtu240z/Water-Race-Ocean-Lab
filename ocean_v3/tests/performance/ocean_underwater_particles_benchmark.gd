extends Node3D
## PERF-UNDERWATER-PARTICLES: isolated A/B/C frame-time benchmark.
## The scene measures only the camera-local particle layer; GPU milliseconds
## remain unavailable because this runner never synchronizes or reads back GPU.

const DEFAULT_WARMUP_FRAMES := 180
const DEFAULT_MEASUREMENT_FRAMES := 600
const DEFAULT_STABILIZATION_FRAMES := 30
const DEFAULT_REPETITIONS := 3
const CASES := [
	{"name": "A_DISABLED", "enabled": false, "fine": false, "near": false},
	{"name": "B_FINE_ONLY", "enabled": true, "fine": true, "near": false},
	{"name": "C_FINE_NEAR", "enabled": true, "fine": true, "near": true},
]

@export_group("Benchmark schedule")
@export_range(0, 10000, 1) var warmup_frames := DEFAULT_WARMUP_FRAMES
@export_range(1, 20000, 1) var measurement_frames := DEFAULT_MEASUREMENT_FRAMES
@export_range(0, 1000, 1) var stabilization_frames := DEFAULT_STABILIZATION_FRAMES
@export_range(1, 10, 1) var repetitions := DEFAULT_REPETITIONS
@export var auto_start := true
@export var quit_when_complete := true

@onready var _particles: OceanUnderwaterParticles = $OceanUnderwaterParticles
@onready var _camera: Camera3D = $BenchmarkCamera

enum Phase { WAITING, STABILIZING, WARMING_UP, MEASURING, COMPLETE }

var _phase := Phase.WAITING
var _phase_frame := 0
var _case_index := 0
var _repetition_index := 0
var _samples := PackedFloat64Array()
var _results: Array[Dictionary] = []
var _cpu_process_sum_ms := 0.0
var _cpu_process_samples := 0
var _started := false
var _completed := false
var _exit_countdown := -1


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_camera.make_current()
	_particles.set_underwater_state(true)
	_read_command_line_overrides()
	if auto_start:
		call_deferred(&"_start")


func _start() -> void:
	_started = true
	_begin_case()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _started:
		return
	if _completed:
		if _exit_countdown == 0:
			_exit_countdown = -1
			get_tree().quit(0)
		elif _exit_countdown > 0:
			_exit_countdown -= 1
		return

	match _phase:
		Phase.STABILIZING:
			_phase_frame += 1
			if _phase_frame >= stabilization_frames:
				_phase = Phase.WARMING_UP
				_phase_frame = 0
		Phase.WARMING_UP:
			_phase_frame += 1
			if _phase_frame >= warmup_frames:
				_samples = PackedFloat64Array()
				_cpu_process_sum_ms = 0.0
				_cpu_process_samples = 0
				_phase = Phase.MEASURING
				_phase_frame = 0
				print("UNDERWATER PARTICLES BENCHMARK: measuring %s repetition %d/%d" % [
					_current_case_name(), _repetition_index + 1, repetitions
				])
		Phase.MEASURING:
			_samples.append(maxf(delta * 1000.0, 0.0))
			var cpu_process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
			if cpu_process_ms > 0.0:
				_cpu_process_sum_ms += cpu_process_ms
				_cpu_process_samples += 1
			if _samples.size() >= measurement_frames:
				_finish_measurement()


func _read_command_line_overrides() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	for argument in arguments:
		if argument.begins_with("--ocean-particles-benchmark-warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--ocean-particles-benchmark-measure="):
			measurement_frames = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--ocean-particles-benchmark-stabilization="):
			stabilization_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--ocean-particles-benchmark-repetitions="):
			repetitions = clampi(int(argument.get_slice("=", 1)), 1, 10)


func _begin_case() -> void:
	var case: Dictionary = CASES[_case_index]
	_particles.underwater_particles_enabled = bool(case["enabled"])
	_particles.set_benchmark_layers(bool(case["fine"]), bool(case["near"]))
	_particles.set_underwater_state(true)
	_phase = Phase.STABILIZING
	_phase_frame = 0
	print("UNDERWATER PARTICLES BENCHMARK: setup %s repetition %d/%d" % [
		_current_case_name(), _repetition_index + 1, repetitions
	])


func _finish_measurement() -> void:
	var sorted := _samples.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	var average := total / float(sorted.size())
	var p95 := sorted[clampi(ceili(float(sorted.size()) * 0.95) - 1, 0, sorted.size() - 1)]
	var process_ms := _cpu_process_sum_ms / float(_cpu_process_samples) if _cpu_process_samples > 0 else 0.0
	var row := {
		"case": _current_case_name(),
		"repetition": _repetition_index + 1,
		"avg_ms": average,
		"fps": 1000.0 / average if average > 0.0 else 0.0,
		"p95_ms": p95,
		"process_ms": process_ms,
	}
	_results.append(row)
	print("%s rep %d avg=%.4f ms FPS=%.2f P95=%.4f ms CPU=%.4f ms" % [
		row["case"], row["repetition"], row["avg_ms"], row["fps"], row["p95_ms"], row["process_ms"]
	])
	if _repetition_index + 1 < repetitions:
		_repetition_index += 1
	else:
		_repetition_index = 0
		_case_index += 1
	if _case_index >= CASES.size():
		_write_results()
		_completed = true
		_exit_countdown = 30 if quit_when_complete else -1
	else:
		_begin_case()


func _current_case_name() -> String:
	return String(CASES[_case_index]["name"])


func _write_results() -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var directory := "user://ocean_v3_benchmarks"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var csv_path := "%s/underwater_particles_%s.csv" % [directory, stamp]
	var txt_path := "%s/underwater_particles_%s.txt" % [directory, stamp]
	var csv := FileAccess.open(csv_path, FileAccess.WRITE)
	var txt := FileAccess.open(txt_path, FileAccess.WRITE)
	if csv == null or txt == null:
		push_error("UNDERWATER PARTICLES BENCHMARK: could not open result files.")
		return
	csv.store_line("case,repetition,avg_ms,fps,p95_ms,cpu_process_ms")
	for row in _results:
		csv.store_line("%s,%d,%.6f,%.6f,%.6f,%.6f" % [
			row["case"], row["repetition"], row["avg_ms"], row["fps"], row["p95_ms"], row["process_ms"]
		])
		txt.store_line("%s rep %d | avg %.4f ms | FPS %.2f | P95 %.4f ms | CPU %.4f ms" % [
			row["case"], row["repetition"], row["avg_ms"], row["fps"], row["p95_ms"], row["process_ms"]
		])
	print("UNDERWATER PARTICLES BENCHMARK: results=%s and %s" % [csv_path, txt_path])

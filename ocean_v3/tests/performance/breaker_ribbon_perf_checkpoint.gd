extends Node3D
## PERF-P0: controlled CPU checkpoint for BreakerRibbonPool.
##
## The three cases preserve the same scene, camera, seed, resolution, ocean
## profile and debug-off state.  They differ only in pool state:
## A disabled, B enabled frames with zero ACTIVE breakers, and C enabled frames
## with one or more normal ACTIVE breakers.  B/C are frame-qualified instead of
## forcing lifecycle state, so benchmark instrumentation never changes the
## production scheduler.

const BENCHMARK_RESOLUTION := Vector2i(1920, 1080)
const FIXED_SEED := 20260830
const DEFAULT_STABILIZATION_FRAMES := 300
const DEFAULT_MEASUREMENT_FRAMES := 1200
const DEFAULT_MAX_CANDIDATE_FRAMES := 4800
const SHUTDOWN_DRAIN_FRAMES := 120

enum Phase { WAITING_FOR_OCEAN, STABILIZING, MEASURING, COMPLETE }
enum Case { POOL_DISABLED, ENABLED_ZERO_ACTIVE, ENABLED_ACTIVE }

@export_range(0, 10000, 1) var stabilization_frames := DEFAULT_STABILIZATION_FRAMES
@export_range(1, 20000, 1) var measurement_frames := DEFAULT_MEASUREMENT_FRAMES
@export_range(1, 40000, 1) var max_candidate_frames := DEFAULT_MAX_CANDIDATE_FRAMES
@export var auto_start := true
@export var quit_when_complete := true

@onready var _ocean: OceanV3 = $OceanV3
@onready var _camera: Camera3D = $BenchmarkCamera

var _clock: Node
var _module: Node
var _phase := Phase.WAITING_FOR_OCEAN
var _phase_frame := 0
var _case_index := 0
var _started := false
var _completed := false
var _exit_countdown_frames := -1
var _frame_samples := PackedFloat64Array()
var _process_sum_ms := 0.0
var _physics_sum_ms := 0.0
var _cpu_monitor_samples := 0
var _candidate_frames := 0
var _accepted_frames := 0
var _active_breaker_sum := 0.0
var _metric_totals: Dictionary = {}
var _last_diagnostic_snapshot: Dictionary = {}
var _results: Array[Dictionary] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# The pool and OceanV3 children update at default priority.  Sampling after
	# them makes every recorded diagnostic delta correspond to the same frame.
	process_priority = 100
	_configure_window()
	_configure_camera()
	_clock = get_node_or_null(^"/root/SimulationClock")
	_read_command_line_overrides()
	if auto_start:
		call_deferred(&"_start_when_ready")


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _completed:
		_drain_and_quit()
		return
	match _phase:
		Phase.WAITING_FOR_OCEAN:
			if _started and _benchmark_ready():
				_begin_case()
		Phase.STABILIZING:
			_phase_frame += 1
			if _phase_frame >= stabilization_frames:
				_begin_measurement()
		Phase.MEASURING:
			_record_candidate_frame(delta)


func _start_when_ready() -> void:
	_started = true


func _configure_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(BENCHMARK_RESOLUTION)


func _configure_camera() -> void:
	_camera.global_position = Vector3(0.0, 10.0, 36.0)
	_camera.fov = 72.0
	_camera.near = 0.1
	_camera.far = 7000.0
	_camera.look_at(Vector3(0.0, -1.5, -220.0), Vector3.UP)
	_camera.make_current()


func _read_command_line_overrides() -> void:
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--breaker-p0-stabilization="):
			stabilization_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--breaker-p0-measure="):
			measurement_frames = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--breaker-p0-max-candidates="):
			max_candidate_frames = maxi(int(argument.get_slice("=", 1)), measurement_frames)
		elif argument == "--breaker-p0-keep-open":
			quit_when_complete = false


func _benchmark_ready() -> bool:
	if _ocean == null or not is_instance_valid(_ocean):
		return false
	_module = _ocean.get_node_or_null(^"OpenOceanFFT")
	if _module == null or not is_instance_valid(_module):
		return false
	if not _module.has_method(&"coastal_fft_diagnostics") or not _module.has_method(&"breaker_performance_diagnostics_snapshot"):
		return false
	var fft_state: Dictionary = _module.coastal_fft_diagnostics()
	return bool(fft_state.get("ready", false))


func _begin_case() -> void:
	if _case_index >= Case.size():
		_finish_suite()
		return
	_set_clean_benchmark_state()
	var profile := _full_profile()
	if _case_index == Case.POOL_DISABLED:
		# Unlike the broad NO_BREAKERS preset, this leaves legacy PREBREAK on.
		profile["breakers"] = false
	_ocean.set_performance_profile(profile)
	_module.set_breaker_performance_diagnostics_enabled(true)
	_module.reset_breaker_performance_diagnostics()
	_phase = Phase.STABILIZING
	_phase_frame = 0
	print("PERF-P0: case %s; stabilizing %d frames" % [_case_name(), stabilization_frames])


func _set_clean_benchmark_state() -> void:
	if _clock != null:
		_clock.set_seed(FIXED_SEED)
		_clock.time_scale = 1.0
		_clock.resume()
		_clock.reset_simulation(true)
	_ocean.perf_overlay_enabled = false
	_ocean.foam_debug_mode = 0
	if _module != null and _module.has_method(&"set_breaking_debug"):
		_module.set_breaking_debug(0)


func _full_profile() -> Dictionary:
	return {
		"spectral": true,
		"coastal": true,
		"crest_foam_solver": true,
		"surface_foam_solver": true,
		"mid_fold_history": true,
		"surface_foam_render": true,
		"prebreak": true,
		"breakers": true,
		"sspr": true,
		"refraction": true,
	}


func _begin_measurement() -> void:
	_phase = Phase.MEASURING
	_phase_frame = 0
	_candidate_frames = 0
	_accepted_frames = 0
	_active_breaker_sum = 0.0
	_metric_totals.clear()
	_frame_samples = PackedFloat64Array()
	_process_sum_ms = 0.0
	_physics_sum_ms = 0.0
	_cpu_monitor_samples = 0
	_module.reset_breaker_performance_diagnostics()
	_last_diagnostic_snapshot = _module.breaker_performance_diagnostics_snapshot()
	print("PERF-P0: measuring %s; target=%d qualified frames, maximum=%d candidates" % [_case_name(), measurement_frames, max_candidate_frames])


func _record_candidate_frame(delta: float) -> void:
	_candidate_frames += 1
	var summary: Dictionary = _module.breaker_pool_summary()
	var active_count := int(summary.get("active_breaker_count", 0))
	var snapshot: Dictionary = _module.breaker_performance_diagnostics_snapshot()
	var metric_delta := _diagnostic_delta(snapshot, _last_diagnostic_snapshot)
	_last_diagnostic_snapshot = snapshot
	if _frame_qualifies(active_count):
		_accepted_frames += 1
		_frame_samples.append(maxf(delta * 1000.0, 0.0))
		_active_breaker_sum += active_count
		_accumulate_metrics(metric_delta)
		var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
		if process_ms > 0.0 or physics_ms > 0.0:
			_process_sum_ms += process_ms
			_physics_sum_ms += physics_ms
			_cpu_monitor_samples += 1
	if _accepted_frames >= measurement_frames:
		_finish_case()
	elif _candidate_frames >= max_candidate_frames:
		_fail_case(active_count)


func _frame_qualifies(active_count: int) -> bool:
	match _case_index:
		Case.POOL_DISABLED:
			return true
		Case.ENABLED_ZERO_ACTIVE:
			return active_count == 0
		Case.ENABLED_ACTIVE:
			return active_count > 0
	return false


func _diagnostic_delta(current: Dictionary, previous: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in current:
		if key == "enabled":
			continue
		var value: Variant = current[key]
		if value is int or value is float:
			result[key] = maxf(float(value) - float(previous.get(key, 0.0)), 0.0)
	return result


func _accumulate_metrics(delta: Dictionary) -> void:
	for key in delta:
		_metric_totals[key] = float(_metric_totals.get(key, 0.0)) + float(delta[key])


func _finish_case() -> void:
	var statistics := _frame_statistics(_frame_samples)
	var cpu_samples := float(_cpu_monitor_samples)
	_results.append({
		"case": _case_name(),
		"qualified_frames": _accepted_frames,
		"candidate_frames": _candidate_frames,
		"avg_active_breakers": _active_breaker_sum / float(_accepted_frames),
		"avg_ms": statistics["avg_ms"],
		"median_ms": statistics["median_ms"],
		"p99_ms": statistics["p99_ms"],
		"avg_fps": statistics["avg_fps"],
		"process_ms": _process_sum_ms / cpu_samples if cpu_samples > 0.0 else null,
		"physics_ms": _physics_sum_ms / cpu_samples if cpu_samples > 0.0 else null,
		"metrics": _metric_totals.duplicate(),
	})
	print("PERF-P0: %s completed: %d/%d qualified frames" % [_case_name(), _accepted_frames, _candidate_frames])
	_case_index += 1
	_begin_case()


func _fail_case(active_count: int) -> void:
	push_error("PERF-P0: %s collected only %d/%d qualified frames after %d candidates (last active=%d). No partial result is emitted." % [_case_name(), _accepted_frames, measurement_frames, _candidate_frames, active_count])
	_finish_suite()


func _frame_statistics(samples: PackedFloat64Array) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for value in samples:
		total += value
	var average := total / float(samples.size())
	return {
		"avg_ms": average,
		"median_ms": _nearest_rank(sorted, 0.50),
		"p99_ms": _nearest_rank(sorted, 0.99),
		"avg_fps": 1000.0 / average if average > 0.0 else 0.0,
	}


func _nearest_rank(sorted: PackedFloat64Array, percentile: float) -> float:
	var rank := clampi(ceili(float(sorted.size()) * percentile) - 1, 0, sorted.size() - 1)
	return sorted[rank]


func _case_name() -> String:
	match _case_index:
		Case.POOL_DISABLED: return "A_POOL_DISABLED"
		Case.ENABLED_ZERO_ACTIVE: return "B_ENABLED_ZERO_ACTIVE"
		Case.ENABLED_ACTIVE: return "C_ENABLED_ACTIVE"
	return "UNKNOWN"


func _finish_suite() -> void:
	if _completed:
		return
	_completed = true
	_phase = Phase.COMPLETE
	if _module != null and _module.has_method(&"set_breaker_performance_diagnostics_enabled"):
		_module.set_breaker_performance_diagnostics_enabled(false)
	var output := _write_results()
	print(output)
	if quit_when_complete:
		_exit_countdown_frames = SHUTDOWN_DRAIN_FRAMES


func _write_results() -> String:
	var output_dir := "user://ocean_v3_benchmarks"
	var output_absolute := ProjectSettings.globalize_path(output_dir)
	var directory_error := DirAccess.make_dir_recursive_absolute(output_absolute)
	if directory_error != OK and not DirAccess.dir_exists_absolute(output_absolute):
		return "PERF-P0: cannot create result directory %s (error %d)" % [output_absolute, directory_error]
	var path := "%s/breaker_ribbon_p0_%d.json" % [output_dir, Time.get_unix_time_from_system()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "PERF-P0: cannot open result path %s" % ProjectSettings.globalize_path(path)
	file.store_string(JSON.stringify({
		"checkpoint": "PERF-P0",
		"seed": FIXED_SEED,
		"requested_resolution": [BENCHMARK_RESOLUTION.x, BENCHMARK_RESOLUTION.y],
		"stabilization_frames": stabilization_frames,
		"measurement_frames": measurement_frames,
		"max_candidate_frames": max_candidate_frames,
		"frame_time_source": "rendered _process delta",
		"cpu_time_source": "Godot Performance TIME_PROCESS/TIME_PHYSICS_PROCESS",
		"gpu_timing": "unavailable; no synchronization or readback is used",
		"results": _results,
	}, "\t"))
	file.close()
	return "PERF-P0 results: %s" % ProjectSettings.globalize_path(path)


func _drain_and_quit() -> void:
	if _exit_countdown_frames < 0:
		return
	if _exit_countdown_frames == 0:
		_exit_countdown_frames = -1
		get_tree().quit(0)
	else:
		_exit_countdown_frames -= 1

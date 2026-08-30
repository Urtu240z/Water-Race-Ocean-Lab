extends Node3D
## PERF-P1: controlled legacy BreakerRibbonPool scaling benchmark.
##
## Each case uses real pool records and the production _update_tracking -> RK2
## -> CoastalPropagationData path. A benchmark-only fixture pins every active
## record to the same age before pool processing, preventing the normal clock
## from changing RK2 complexity during a 600-frame measurement window.

const BENCHMARK_RESOLUTION := Vector2i(1920, 1080)
const FIXED_SEED := 20260830
const ACTIVE_COUNTS := [0, 1, 2, 4, 8]
const CONTROLLED_AGE_S := 0.70
const DEFAULT_WARMUP_FRAMES := 120
const DEFAULT_MEASUREMENT_FRAMES := 600
const TIMER_CALIBRATION_ITERATIONS := 100000
const SHUTDOWN_DRAIN_FRAMES := 120

enum Phase { WAITING_FOR_OCEAN, WARMING_UP, MEASURING, COMPLETE }

@export_range(0, 10000, 1) var warmup_frames := DEFAULT_WARMUP_FRAMES
@export_range(1, 20000, 1) var measurement_frames := DEFAULT_MEASUREMENT_FRAMES
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
var _measurement_primed := false
var _exit_countdown_frames := -1
var _timer_pair_calibration_usec := 0.0
var _fixture: Dictionary = {}
var _last_snapshot: Dictionary = {}
var _metric_totals: Dictionary = {}
var _frame_samples := PackedFloat64Array()
var _tracking_samples_ms := PackedFloat64Array()
var _process_sum_ms := 0.0
var _physics_sum_ms := 0.0
var _cpu_monitor_samples := 0
var _results: Array[Dictionary] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# This fixture must run before OceanV3 and its BreakerRibbonPool children.
	process_priority = -100
	_configure_window()
	_configure_camera()
	_clock = get_node_or_null(^"/root/SimulationClock")
	_read_command_line_overrides()
	_timer_pair_calibration_usec = _calibrate_timer_pair_usec()
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
		Phase.WARMING_UP:
			_seed_current_fixture()
			_phase_frame += 1
			if _phase_frame >= warmup_frames:
				_begin_measurement()
		Phase.MEASURING:
			if _measurement_primed:
				_record_completed_measurement_frame(delta)
				if _frame_samples.size() >= measurement_frames:
					_finish_case()
					return
			else:
				# Start nested timers only after the warm-up frame has completed.
				# This keeps diagnostic totals exactly aligned with frame_count.
				_module.set_breaker_performance_diagnostics_enabled(true)
				_module.reset_breaker_performance_diagnostics()
				_last_snapshot = _module.breaker_performance_diagnostics_snapshot()
				_module.set_breaker_performance_diagnostics_timing_enabled(true)
			_seed_current_fixture()
			_measurement_primed = true


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
		if argument.begins_with("--breaker-p1-warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--breaker-p1-measure="):
			measurement_frames = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument == "--breaker-p1-keep-open":
			quit_when_complete = false


func _benchmark_ready() -> bool:
	if _ocean == null or not is_instance_valid(_ocean):
		return false
	_module = _ocean.get_node_or_null(^"OpenOceanFFT")
	if _module == null or not is_instance_valid(_module):
		return false
	if not _module.has_method(&"configure_breaker_performance_checkpoint_active_breakers"):
		return false
	var fft_state: Dictionary = _module.coastal_fft_diagnostics()
	return bool(fft_state.get("ready", false))


func _begin_case() -> void:
	if _case_index >= ACTIVE_COUNTS.size():
		_finish_suite()
		return
	_set_clean_benchmark_state()
	_ocean.set_performance_profile(_full_profile())
	_module.set_breaker_performance_diagnostics_enabled(false)
	_module.set_breaker_performance_diagnostics_timing_enabled(false)
	_fixture = _module.configure_breaker_performance_checkpoint_active_breakers(int(ACTIVE_COUNTS[_case_index]), CONTROLLED_AGE_S)
	if not bool(_fixture.get("configured", false)):
		push_error("PERF-P1: fixture unavailable for %d active breakers: %s" % [int(ACTIVE_COUNTS[_case_index]), String(_fixture.get("reason", "UNKNOWN"))])
		_finish_suite()
		return
	_module.set_breaker_performance_diagnostics_enabled(true)
	_module.reset_breaker_performance_diagnostics()
	_phase = Phase.WARMING_UP
	_phase_frame = 0
	print("PERF-P1: case %d active; age=%.3f s; S=%d; warm-up=%d frames" % [int(_fixture["active_count"]), float(_fixture["age_s"]), int(_fixture["steps_per_breaker"]), warmup_frames])


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


func _seed_current_fixture() -> void:
	_fixture = _module.configure_breaker_performance_checkpoint_active_breakers(int(ACTIVE_COUNTS[_case_index]), CONTROLLED_AGE_S)


func _begin_measurement() -> void:
	_phase = Phase.MEASURING
	_phase_frame = 0
	_measurement_primed = false
	_metric_totals.clear()
	_frame_samples = PackedFloat64Array()
	_tracking_samples_ms = PackedFloat64Array()
	_process_sum_ms = 0.0
	_physics_sum_ms = 0.0
	_cpu_monitor_samples = 0
	# The pool still processes after this parent callback, so diagnostics stay
	# disabled for that boundary frame. They are reset and enabled immediately
	# before the first measured fixture frame on the next callback.
	_module.set_breaker_performance_diagnostics_enabled(false)
	_module.reset_breaker_performance_diagnostics()
	_module.set_breaker_performance_diagnostics_timing_enabled(false)
	_last_snapshot = _module.breaker_performance_diagnostics_snapshot()
	print("PERF-P1: measuring %d active breakers for %d frames" % [int(_fixture["active_count"]), measurement_frames])


func _record_completed_measurement_frame(delta: float) -> void:
	var snapshot: Dictionary = _module.breaker_performance_diagnostics_snapshot()
	var metric_delta := _diagnostic_delta(snapshot, _last_snapshot)
	_last_snapshot = snapshot
	_accumulate_metrics(metric_delta)
	_frame_samples.append(maxf(delta * 1000.0, 0.0))
	var tracking_usec := _correct_timer_usec(metric_delta, "tracking_usec", "tracking_timer_pairs")
	_tracking_samples_ms.append(tracking_usec * 0.001)
	var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	if process_ms > 0.0 or physics_ms > 0.0:
		_process_sum_ms += process_ms
		_physics_sum_ms += physics_ms
		_cpu_monitor_samples += 1


func _diagnostic_delta(current: Dictionary, previous: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in current:
		var value: Variant = current[key]
		if value is int or value is float:
			result[key] = maxf(float(value) - float(previous.get(key, 0.0)), 0.0)
	return result


func _accumulate_metrics(delta: Dictionary) -> void:
	for key in delta:
		_metric_totals[key] = float(_metric_totals.get(key, 0.0)) + float(delta[key])


func _correct_timer_usec(metrics: Dictionary, usec_key: String, pair_key: String) -> float:
	return maxf(float(metrics.get(usec_key, 0.0)) - float(metrics.get(pair_key, 0.0)) * _timer_pair_calibration_usec, 0.0)


func _finish_case() -> void:
	_module.set_breaker_performance_diagnostics_timing_enabled(false)
	var frame_statistics := _statistics(_frame_samples)
	var tracking_statistics := _statistics(_tracking_samples_ms)
	var frames := float(_frame_samples.size())
	var velocity_calls := float(_metric_totals.get("velocity_calls", 0.0))
	var coastal_calls := float(_metric_totals.get("coastal_propagation_samples", 0.0))
	var cpu_samples := float(_cpu_monitor_samples)
	_results.append({
		"active_breakers": int(_fixture["active_count"]),
		"controlled_age_s": float(_fixture["age_s"]),
		"controlled_steps_per_breaker": int(_fixture["steps_per_breaker"]),
		"frame_count": int(frames),
		"sum_steps_per_frame": float(_metric_totals.get("trajectory_steps", 0.0)) / frames,
		"velocity_calls_per_frame": velocity_calls / frames,
		"coastal_calls_per_frame": coastal_calls / frames,
		"frame_ms": frame_statistics,
		"tracking_ms": tracking_statistics,
		"process_ms_avg": _process_sum_ms / cpu_samples if cpu_samples > 0.0 else null,
		"physics_ms_avg": _physics_sum_ms / cpu_samples if cpu_samples > 0.0 else null,
		"inclusive_timing": _timing_report(frames, velocity_calls, coastal_calls),
		"velocity_cell_reuse": {
			"accesses_per_frame": float(_metric_totals.get("velocity_cell_accesses", 0.0)) / frames,
			"unique_cells_per_frame": float(_metric_totals.get("velocity_unique_cells", 0.0)) / frames,
			"repeated_accesses_per_frame": float(_metric_totals.get("velocity_repeated_cells", 0.0)) / frames,
		},
		"counters": _metric_totals.duplicate(),
	})
	print("PERF-P1: %d active completed" % int(_fixture["active_count"]))
	_case_index += 1
	_begin_case()


func _timing_report(frames: float, velocity_calls: float, coastal_calls: float) -> Dictionary:
	var tracking_usec := _correct_timer_usec(_metric_totals, "tracking_usec", "tracking_timer_pairs")
	var predicted_usec := _correct_timer_usec(_metric_totals, "predicted_usec", "predicted_timer_pairs")
	var velocity_usec := _correct_timer_usec(_metric_totals, "velocity_usec", "velocity_timer_pairs")
	var velocity_coastal_usec := _correct_timer_usec(_metric_totals, "velocity_coastal_usec", "velocity_coastal_timer_pairs")
	var host_coastal_usec := _correct_timer_usec(_metric_totals, "host_coastal_usec", "host_coastal_timer_pairs")
	var coastal_usec := velocity_coastal_usec + host_coastal_usec
	return {
		"timer_pair_calibration_usec": _timer_pair_calibration_usec,
		"tracking_inclusive_ms_per_frame": tracking_usec * 0.001 / frames,
		"predicted_inclusive_ms_per_frame": predicted_usec * 0.001 / frames,
		"velocity_inclusive_ms_per_frame": velocity_usec * 0.001 / frames,
		"coastal_sample_inclusive_ms_per_frame": coastal_usec * 0.001 / frames,
		"velocity_inclusive_usec_per_call": velocity_usec / velocity_calls if velocity_calls > 0.0 else 0.0,
		"coastal_sample_usec_per_call": coastal_usec / coastal_calls if coastal_calls > 0.0 else 0.0,
		"velocity_wrapper_exclusive_ms_per_frame": maxf(velocity_usec - velocity_coastal_usec, 0.0) * 0.001 / frames,
		"predicted_wrapper_exclusive_ms_per_frame": maxf(predicted_usec - velocity_usec, 0.0) * 0.001 / frames,
	}


func _statistics(samples: PackedFloat64Array) -> Dictionary:
	if samples.is_empty():
		return {"avg": 0.0, "median": 0.0, "p95": 0.0, "p99": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for value in samples:
		total += value
	return {
		"avg": total / float(samples.size()),
		"median": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
	}


func _nearest_rank(sorted: PackedFloat64Array, percentile: float) -> float:
	var rank := clampi(ceili(float(sorted.size()) * percentile) - 1, 0, sorted.size() - 1)
	return sorted[rank]


func _calibrate_timer_pair_usec() -> float:
	# Measures the instrumentation pair plus loop bookkeeping as a conservative
	# correction. Raw inclusive counters remain in JSON for auditability.
	var start_usec := Time.get_ticks_usec()
	var sink := 0
	for index in TIMER_CALIBRATION_ITERATIONS:
		var a := Time.get_ticks_usec()
		var b := Time.get_ticks_usec()
		sink += int(b - a)
	if sink < 0:
		push_error("PERF-P1: timer calibration overflow")
	return float(Time.get_ticks_usec() - start_usec) / float(TIMER_CALIBRATION_ITERATIONS)


func _finish_suite() -> void:
	if _completed:
		return
	_completed = true
	_phase = Phase.COMPLETE
	if _module != null:
		_module.set_breaker_performance_diagnostics_timing_enabled(false)
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
		return "PERF-P1: cannot create result directory %s (error %d)" % [output_absolute, directory_error]
	var path := "%s/breaker_ribbon_p1_%d.json" % [output_dir, Time.get_unix_time_from_system()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "PERF-P1: cannot open result path %s" % ProjectSettings.globalize_path(path)
	file.store_string(JSON.stringify({
		"checkpoint": "PERF-P1",
		"seed": FIXED_SEED,
		"requested_resolution": [BENCHMARK_RESOLUTION.x, BENCHMARK_RESOLUTION.y],
		"warmup_frames": warmup_frames,
		"measurement_frames": measurement_frames,
		"controlled_age_s": CONTROLLED_AGE_S,
		"fixture": "real pool tracking records; spawn time pinned before each pool _process; inactive slots are cooldown-only",
		"frame_time_source": "rendered _process delta",
		"timing": "Time.get_ticks_usec nested inclusive timers; timer-pair calibration is subtracted from reported estimates",
		"gpu_timing": "unavailable; no synchronization or readback is used",
		"results": _results,
	}, "\t"))
	file.close()
	return "PERF-P1 results: %s" % ProjectSettings.globalize_path(path)


func _drain_and_quit() -> void:
	if _exit_countdown_frames < 0:
		return
	if _exit_countdown_frames == 0:
		_exit_countdown_frames = -1
		get_tree().quit(0)
	else:
		_exit_countdown_frames -= 1

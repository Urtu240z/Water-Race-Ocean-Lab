extends Node3D
## PERF-2A: reproducible graphical benchmark and paired foam decomposition for Ocean V3.
##
## The benchmark owns only its camera/window/measurement loop. Ocean workload
## selection is delegated to the PERF-1A API; this script never changes FFT,
## LOD, shader quality, resolution, or update-frequency settings.

const BENCHMARK_RESOLUTION := Vector2i(1920, 1080)
const FIXED_SEED := 20260820
const DEFAULT_WARMUP_FRAMES := 300
const DEFAULT_MEASUREMENT_FRAMES := 1200
const DEFAULT_STABILIZATION_FRAMES := 60
const DEFAULT_REPETITIONS := 3
const DEFAULT_READINESS_TIMEOUT_FRAMES := 1800
const SHUTDOWN_DRAIN_FRAMES := 120
const CORE_PRESETS := [
	"FULL", "BASE", "NO_SSPR", "NO_FOAM", "NO_COASTAL", "NO_BREAKERS"
]
const ISOLATED_PRESETS := [
	"NO_REFRACTION", "NO_PREBREAK", "NO_SURFACE_FOAM_SOLVER", "NO_SURFACE_FOAM_RENDER"
]
const PAIRED_TESTS := [
	"NO_FOAM", "NO_CREST_FOAM", "NO_SURFACE_FOAM_SOLVER", "NO_MID_FOLD_HISTORY", "NO_SURFACE_FOAM_RENDER"
]
const GPU_TIMING_UNAVAILABLE := "unavailable"

@export_group("Benchmark schedule")
@export_range(0, 10000, 1) var warmup_frames := DEFAULT_WARMUP_FRAMES
@export_range(1, 20000, 1) var measurement_frames := DEFAULT_MEASUREMENT_FRAMES
@export_range(0, 1000, 1) var stabilization_frames := DEFAULT_STABILIZATION_FRAMES
@export_range(1, 10, 1) var repetitions := DEFAULT_REPETITIONS
@export_enum("SEQUENTIAL", "PAIRED") var run_mode := "SEQUENTIAL"
@export_range(5, 10, 1) var paired_repetitions := 7
@export_range(1, 10000, 1) var readiness_timeout_frames := DEFAULT_READINESS_TIMEOUT_FRAMES
@export var include_isolated_presets := true
@export var auto_start := true
@export var quit_when_complete := true

@onready var _ocean: OceanV3 = $OceanV3
@onready var _camera: Camera3D = $BenchmarkCamera

enum Phase { WAITING_FOR_OCEAN, STABILIZING, WARMING_UP, MEASURING, COMPLETE }

var _clock: Node
var _phase := Phase.WAITING_FOR_OCEAN
var _phase_frame := 0
var _preset_index := 0
var _repetition_index := 0
var _current_preset := ""
var _started := false
var _completed := false
var _results: Array[Dictionary] = []
var _frame_samples := PackedFloat64Array()
var _process_sum_ms := 0.0
var _physics_sum_ms := 0.0
var _cpu_monitor_samples := 0
var _csv_path := ""
var _summary_path := ""
var _paired_csv_path := ""
var _exit_countdown_frames := -1
var _paired_mode := false
var _paired_side_full := true
var _paired_repetition_index := 0
var _paired_test_index := 0
var _paired_full_statistics: Dictionary = {}
var _paired_deltas: Array[Dictionary] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
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
		if _exit_countdown_frames >= 0:
			if _exit_countdown_frames == 0:
				_exit_countdown_frames = -1
				get_tree().quit(0)
			else:
				_exit_countdown_frames -= 1
		return
	match _phase:
		Phase.WAITING_FOR_OCEAN:
			_phase_frame += 1
			if _benchmark_ready():
				_start_suite()
			elif _phase_frame >= readiness_timeout_frames:
				push_error("PERF-1B: Ocean V3 readiness timeout; run the benchmark with the graphical renderer, not headless mode.")
				_completed = true
				get_tree().quit(2)
		Phase.STABILIZING:
			_phase_frame += 1
			if _phase_frame >= stabilization_frames:
				_begin_warmup()
		Phase.WARMING_UP:
			_phase_frame += 1
			if _phase_frame >= warmup_frames:
				_begin_measurement()
		Phase.MEASURING:
			_record_measurement_frame(delta)
			_phase_frame += 1
			if _phase_frame >= measurement_frames:
				_finish_measurement()


func _start_when_ready() -> void:
	_started = true


func _configure_window() -> void:
	# This is local to the benchmark process; project.godot is not rewritten.
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
	# These options make syntax/smoke validation short without changing the
	# production defaults of 300/1200/3.
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--ocean-benchmark-warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--ocean-benchmark-measure="):
			measurement_frames = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--ocean-benchmark-stabilization="):
			stabilization_frames = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--ocean-benchmark-repetitions="):
			repetitions = clampi(int(argument.get_slice("=", 1)), 1, 10)
		elif argument == "--ocean-benchmark-paired":
			run_mode = "PAIRED"
		elif argument.begins_with("--ocean-benchmark-paired-repetitions="):
			paired_repetitions = clampi(int(argument.get_slice("=", 1)), 5, 10)
		elif argument.begins_with("--ocean-benchmark-ready-timeout="):
			readiness_timeout_frames = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument == "--ocean-benchmark-core-only":
			include_isolated_presets = false
		elif argument == "--ocean-benchmark-keep-open":
			quit_when_complete = false


func _benchmark_presets() -> Array:
	if run_mode.to_upper() == "PAIRED":
		return ["FULL"] + PAIRED_TESTS
	var result: Array = CORE_PRESETS.duplicate()
	if include_isolated_presets:
		result.append_array(ISOLATED_PRESETS)
	return result


func _benchmark_ready() -> bool:
	if not _started or _ocean == null or not is_instance_valid(_ocean):
		return false
	var module := _ocean.get_node_or_null(^"OpenOceanFFT")
	if module == null or not is_instance_valid(module):
		return false
	if not module.has_method(&"coastal_fft_diagnostics"):
		return false
	var fft_state: Dictionary = module.coastal_fft_diagnostics()
	if not bool(fft_state.get("ready", false)):
		return false
	if module.has_method(&"foam_render_diagnostics"):
		var foam_state: Dictionary = module.foam_render_diagnostics()
		var surface_state = foam_state.get("surface", {})
		if surface_state is Dictionary and not surface_state.is_empty() and not bool(surface_state.get("ready", false)):
			return false
	return true


func _start_suite() -> void:
	_paired_mode = run_mode.to_upper() == "PAIRED"
	_phase = Phase.STABILIZING
	_phase_frame = 0
	_preset_index = 0
	_repetition_index = 0
	_results.clear()
	_paired_deltas.clear()
	_paired_repetition_index = 0
	_paired_test_index = 0
	_paired_side_full = true
	_paired_full_statistics = {}
	_set_clean_benchmark_state()
	_apply_current_configuration()
	print("OCEAN V3 BENCHMARK: ready; seed=%d; viewport=%s" % [FIXED_SEED, _viewport_size()])


func _set_clean_benchmark_state() -> void:
	# Keep normal simulation running. Only deterministic setup/debug state is
	# changed; this does not freeze ocean time or alter Ocean V3 quality.
	if _clock != null:
		_clock.set_seed(FIXED_SEED)
		_clock.time_scale = 1.0
		_clock.resume()
		_clock.reset_simulation(true)
	_ocean.perf_overlay_enabled = false
	_ocean.foam_debug_mode = 0
	var module := _ocean.get_node_or_null(^"OpenOceanFFT")
	if module != null and module.has_method(&"set_breaking_debug"):
		module.set_breaking_debug(0)


func _apply_current_configuration() -> void:
	if _paired_mode:
		_current_preset = "FULL" if _paired_side_full else String(PAIRED_TESTS[_paired_test_index])
	else:
		var presets := _benchmark_presets()
		_current_preset = String(presets[_preset_index])
	if CORE_PRESETS.has(_current_preset):
		if not _ocean.apply_performance_preset(StringName(_current_preset)):
			push_error("PERF-1B: failed to apply preset %s" % _current_preset)
	else:
		_ocean.set_performance_profile(_isolated_profile(_current_preset))
	if _paired_mode:
		print("PERF-2A: pair %d/%d %s -> %s" % [_paired_repetition_index + 1, paired_repetitions, "FULL" if _paired_side_full else "TEST", _current_preset])
	else:
		print("PERF-1B: repetition %d/%d -> %s" % [_repetition_index + 1, repetitions, _current_preset])


func _isolated_profile(name: String) -> Dictionary:
	var profile := {
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
	match name:
		"NO_REFRACTION": profile["refraction"] = false
		"NO_PREBREAK": profile["prebreak"] = false
		"NO_SURFACE_FOAM_SOLVER": profile["surface_foam_solver"] = false
		"NO_CREST_FOAM": profile["crest_foam_solver"] = false
		"NO_MID_FOLD_HISTORY": profile["mid_fold_history"] = false
		"NO_SURFACE_FOAM_RENDER": profile["surface_foam_render"] = false
		_: push_error("PERF-1B: unsupported isolated profile %s" % name)
	return profile


func _begin_warmup() -> void:
	_phase = Phase.WARMING_UP
	_phase_frame = 0
	print("%s: warm-up %d frames (%s)" % ["PERF-2A" if _paired_mode else "PERF-1B", warmup_frames, _current_preset])


func _begin_measurement() -> void:
	_phase = Phase.MEASURING
	_phase_frame = 0
	_frame_samples = PackedFloat64Array()
	_frame_samples.resize(measurement_frames)
	_process_sum_ms = 0.0
	_physics_sum_ms = 0.0
	_cpu_monitor_samples = 0
	print("%s: measuring %d frames (%s)" % ["PERF-2A" if _paired_mode else "PERF-1B", measurement_frames, _current_preset])


func _record_measurement_frame(delta: float) -> void:
	var index := _phase_frame
	if index < _frame_samples.size():
		_frame_samples[index] = maxf(delta * 1000.0, 0.0)
	var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	if process_ms > 0.0 or physics_ms > 0.0:
		_process_sum_ms += process_ms
		_physics_sum_ms += physics_ms
		_cpu_monitor_samples += 1


func _finish_measurement() -> void:
	var statistics := _frame_statistics(_frame_samples)
	var process_ms: Variant = _process_sum_ms / float(_cpu_monitor_samples) if _cpu_monitor_samples > 0 else null
	var physics_ms: Variant = _physics_sum_ms / float(_cpu_monitor_samples) if _cpu_monitor_samples > 0 else null
	_results.append({
		"repetition": _paired_repetition_index + 1 if _paired_mode else _repetition_index + 1,
		"preset": _current_preset,
		"avg_ms": statistics["avg_ms"],
		"median_ms": statistics["median_ms"],
		"p95_ms": statistics["p95_ms"],
		"p99_ms": statistics["p99_ms"],
		"min_ms": statistics["min_ms"],
		"max_ms": statistics["max_ms"],
		"avg_fps": statistics["avg_fps"],
		"process_ms": process_ms,
		"physics_ms": physics_ms,
		"gpu_ms": GPU_TIMING_UNAVAILABLE,
	})
	print("%s: %s run %d avg=%.4f ms median=%.4f ms p95=%.4f ms p99=%.4f ms" % [
		"PERF-2A" if _paired_mode else "PERF-1B", _current_preset,
		_paired_repetition_index + 1 if _paired_mode else _repetition_index + 1,
		statistics["avg_ms"], statistics["median_ms"], statistics["p95_ms"], statistics["p99_ms"]
	])
	if _paired_mode:
		if _paired_side_full:
			_paired_full_statistics = statistics
			_paired_side_full = false
			_apply_current_configuration()
			_phase = Phase.STABILIZING
			_phase_frame = 0
			return
		_paired_deltas.append({
			"repetition": _paired_repetition_index + 1,
			"preset": _current_preset,
			"full_avg_ms": _paired_full_statistics["avg_ms"],
			"test_avg_ms": statistics["avg_ms"],
			"delta_ms": _paired_full_statistics["avg_ms"] - statistics["avg_ms"],
			"full_median_ms": _paired_full_statistics["median_ms"],
			"test_median_ms": statistics["median_ms"],
		})
		_paired_test_index += 1
		if _paired_test_index >= PAIRED_TESTS.size():
			_paired_test_index = 0
			_paired_repetition_index += 1
			if _paired_repetition_index >= paired_repetitions:
				_finish_suite()
				return
		_paired_side_full = true
		_apply_current_configuration()
		_phase = Phase.STABILIZING
		_phase_frame = 0
		return
	_advance_configuration()


func _advance_configuration() -> void:
	var presets := _benchmark_presets()
	_preset_index += 1
	if _preset_index >= presets.size():
		_preset_index = 0
		_repetition_index += 1
	if _repetition_index >= repetitions:
		_finish_suite()
		return
	_apply_current_configuration()
	_phase = Phase.STABILIZING
	_phase_frame = 0


func _frame_statistics(samples: PackedFloat64Array) -> Dictionary:
	if samples.is_empty():
		return {"avg_ms": 0.0, "median_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "min_ms": 0.0, "max_ms": 0.0, "avg_fps": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for value in samples:
		total += value
	var average := total / float(samples.size())
	var median := _nearest_rank(sorted, 0.50)
	var p95 := _nearest_rank(sorted, 0.95)
	var p99 := _nearest_rank(sorted, 0.99)
	return {
		"avg_ms": average,
		"median_ms": median,
		"p95_ms": p95,
		"p99_ms": p99,
		"min_ms": sorted[0],
		"max_ms": sorted[sorted.size() - 1],
		"avg_fps": 1000.0 / average if average > 0.0 else 0.0,
	}


func _nearest_rank(sorted: PackedFloat64Array, percentile: float) -> float:
	var rank := clampi(ceili(float(sorted.size()) * percentile) - 1, 0, sorted.size() - 1)
	return sorted[rank]


func _finish_suite() -> void:
	_completed = true
	_phase = Phase.COMPLETE
	var output := _write_results()
	print(output["summary"])
	print("PERF-1B CSV: %s" % output["csv_path"])
	print("PERF-1B SUMMARY: %s" % output["summary_path"])
	if not String(output.get("paired_csv_path", "")).is_empty():
		print("PERF-2A PAIRED CSV: %s" % output["paired_csv_path"])
	if quit_when_complete:
		# Let queued render-thread dispatches and resource publications drain before
		# the OceanV3 node frees its RenderingDevice resources.
		_exit_countdown_frames = SHUTDOWN_DRAIN_FRAMES


func _write_results() -> Dictionary:
	var output_dir := "user://ocean_v3_benchmarks"
	var output_absolute := ProjectSettings.globalize_path(output_dir)
	var directory_error := DirAccess.make_dir_recursive_absolute(output_absolute)
	if directory_error != OK and not DirAccess.dir_exists_absolute(output_absolute):
		push_error("PERF-1B: cannot create result directory %s (error %d)" % [output_absolute, directory_error])
	var timestamp := Time.get_unix_time_from_system()
	var stem := "ocean_v3_perf2a_paired_%d" % timestamp if _paired_mode else "ocean_v3_benchmark_%d" % timestamp
	var csv_path := "%s/%s.csv" % [output_dir, stem]
	var summary_path := "%s/%s.txt" % [output_dir, stem]
	var paired_csv_path := "%s/%s_pairs.csv" % [output_dir, stem] if _paired_mode else ""
	var suffix := 1
	while FileAccess.file_exists(csv_path) or FileAccess.file_exists(summary_path) or (not paired_csv_path.is_empty() and FileAccess.file_exists(paired_csv_path)):
		csv_path = "%s/%s_%d.csv" % [output_dir, stem, suffix]
		summary_path = "%s/%s_%d.txt" % [output_dir, stem, suffix]
		if _paired_mode:
			paired_csv_path = "%s/%s_%d_pairs.csv" % [output_dir, stem, suffix]
		suffix += 1
	_csv_path = csv_path
	_summary_path = summary_path
	_paired_csv_path = paired_csv_path

	var csv := FileAccess.open(csv_path, FileAccess.WRITE)
	if csv == null:
		push_error("PERF-1B: cannot open CSV result path %s" % ProjectSettings.globalize_path(csv_path))
	else:
		var viewport := _viewport_size()
		csv.store_line("# requested_resolution=%dx%d actual_viewport=%dx%d seed=%d warmup_frames=%d measurement_frames=%d stabilization_frames=%d repetitions=%d" % [
			BENCHMARK_RESOLUTION.x, BENCHMARK_RESOLUTION.y, viewport.x, viewport.y, FIXED_SEED, warmup_frames, measurement_frames, stabilization_frames, repetitions
		])
		csv.store_line("repetition,preset,avg_ms,median_ms,p95_ms,p99_ms,min_ms,max_ms,avg_fps,process_ms,physics_ms,gpu_ms")
		for row in _results:
			csv.store_line(",".join([
				str(row["repetition"]), String(row["preset"]), _csv_value(row["avg_ms"]), _csv_value(row["median_ms"]),
				_csv_value(row["p95_ms"]), _csv_value(row["p99_ms"]), _csv_value(row["min_ms"]), _csv_value(row["max_ms"]), _csv_value(row["avg_fps"]),
				_csv_value(row["process_ms"]), _csv_value(row["physics_ms"]), String(row["gpu_ms"])
			]))
		csv.close()

	if _paired_mode:
		var paired_csv := FileAccess.open(paired_csv_path, FileAccess.WRITE)
		if paired_csv == null:
			push_error("PERF-2A: cannot open paired CSV result path %s" % ProjectSettings.globalize_path(paired_csv_path))
		else:
			paired_csv.store_line("# paired_repetitions=%d tests=%s" % [paired_repetitions, ";".join(PAIRED_TESTS)])
			paired_csv.store_line("repetition,test_preset,full_avg_ms,test_avg_ms,delta_ms,full_median_ms,test_median_ms")
			for row in _paired_deltas:
				paired_csv.store_line(",".join([
					str(row["repetition"]), String(row["preset"]), _csv_value(row["full_avg_ms"]),
					_csv_value(row["test_avg_ms"]), _csv_value(row["delta_ms"]),
					_csv_value(row["full_median_ms"]), _csv_value(row["test_median_ms"])
				]))
			paired_csv.close()

	var summary := _build_summary()
	var summary_file := FileAccess.open(summary_path, FileAccess.WRITE)
	if summary_file == null:
		push_error("PERF-1B: cannot open summary result path %s" % ProjectSettings.globalize_path(summary_path))
	else:
		summary_file.store_string(summary)
		summary_file.close()
	return {"csv_path": csv_path, "summary_path": summary_path, "paired_csv_path": paired_csv_path, "summary": summary}


func _build_summary() -> String:
	var lines := PackedStringArray()
	lines.append("=".repeat(60))
	lines.append("OCEAN V3 PERFORMANCE BENCHMARK")
	lines.append("%dx%d | seed=%d | warm-up=%d | measurement=%d | stabilization=%d | %s=%d" % [
		BENCHMARK_RESOLUTION.x, BENCHMARK_RESOLUTION.y, FIXED_SEED, warmup_frames, measurement_frames, stabilization_frames,
		"paired_repetitions" if _paired_mode else "repetitions", paired_repetitions if _paired_mode else repetitions
	])
	lines.append("GPU timing: unavailable in current benchmark instrumentation")
	lines.append("Frame time source: _process delta; CPU source: Godot Performance monitors")
	lines.append("=".repeat(60))
	for preset in _benchmark_presets():
		var aggregate := _aggregate_for(String(preset))
		lines.append("%s | runs=%d" % [preset, aggregate["count"]])
		lines.append("  Avg frame: %8.4f ms | Median: %8.4f ms | P95: %8.4f ms | P99: %8.4f ms" % [aggregate["avg_ms"], aggregate["median_ms"], aggregate["p95_ms"], aggregate["p99_ms"]])
		lines.append("  Min:       %8.4f ms | Max:    %8.4f ms | Avg FPS: %8.2f" % [aggregate["min_ms"], aggregate["max_ms"], aggregate["avg_fps"]])
		lines.append("  Run variance: mean %.4f ms | stdev %.4f ms | range %.4f..%.4f ms" % [aggregate["run_mean_ms"], aggregate["run_stdev_ms"], aggregate["run_min_ms"], aggregate["run_max_ms"]])
		lines.append("  CPU monitors: process=%s ms | physics=%s ms" % [_summary_value(aggregate["process_ms"]), _summary_value(aggregate["physics_ms"])])
	var full := _aggregate_for("FULL")
	lines.append("")
	lines.append("ESTIMATED MARGINAL FRAME COST RELATIVE TO FULL")
	lines.append("delta_ms = FULL_avg_ms - TEST_avg_ms; interactions are not additive costs")
	for preset in _benchmark_presets():
		var name := String(preset)
		if name == "FULL":
			continue
		var aggregate := _aggregate_for(name)
		var delta_ms: float = full["avg_ms"] - aggregate["avg_ms"]
		var percent: float = delta_ms / full["avg_ms"] * 100.0 if full["avg_ms"] > 0.0 else 0.0
		lines.append("%-24s %8.4f ms | %8.2f%%" % [name, delta_ms, percent])
	if _paired_mode:
		lines.append("")
		lines.append("PAIRED FOAM DECOMPOSITION")
		lines.append("Each TEST is immediately paired with a preceding FULL run after the same stabilization/warm-up protocol.")
		for test in PAIRED_TESTS:
			var pair_aggregate := _paired_delta_aggregate(test)
			lines.append("%-24s pairs=%d | delta mean %8.4f ms | median %8.4f ms | stdev %8.4f ms | range %.4f..%.4f ms" % [
				test, pair_aggregate["count"], pair_aggregate["mean_ms"], pair_aggregate["median_ms"],
				pair_aggregate["stdev_ms"], pair_aggregate["min_ms"], pair_aggregate["max_ms"]
			])
		var additive := 0.0
		for test in ["NO_CREST_FOAM", "NO_SURFACE_FOAM_SOLVER", "NO_MID_FOLD_HISTORY", "NO_SURFACE_FOAM_RENDER"]:
			additive += float(_paired_delta_aggregate(test)["mean_ms"])
		var observed_no_foam := _paired_delta_aggregate("NO_FOAM")
		lines.append("Additive interaction: sum(individual foam deltas)=%.4f ms | NO_FOAM paired delta=%.4f ms | residual=%.4f ms" % [
			additive, observed_no_foam["mean_ms"], observed_no_foam["mean_ms"] - additive
		])
	lines.append("")
	lines.append("Notes: no GPU sync/readback is used. GPU time is unavailable; do not infer GPU cost from FPS.")
	lines.append("Coastal bake is resident and included; no per-frame bake is performed by the benchmark.")
	lines.append("=".repeat(60))
	return "\n".join(lines)


func _paired_delta_aggregate(test: String) -> Dictionary:
	var values := PackedFloat64Array()
	for row in _paired_deltas:
		if String(row["preset"]) == test:
			values.append(float(row["delta_ms"]))
	if values.is_empty():
		return {"count": 0, "mean_ms": 0.0, "median_ms": 0.0, "stdev_ms": 0.0, "min_ms": 0.0, "max_ms": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var mean := _mean_packed(values)
	var variance := 0.0
	for value in values:
		variance += (value - mean) * (value - mean)
	return {
		"count": values.size(),
		"mean_ms": mean,
		"median_ms": _nearest_rank(sorted, 0.50),
		"stdev_ms": sqrt(variance / float(values.size())),
		"min_ms": sorted[0],
		"max_ms": sorted[sorted.size() - 1],
	}


func _aggregate_for(preset: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	for row in _results:
		if String(row["preset"]) == preset:
			rows.append(row)
	if rows.is_empty():
		return {"count": 0, "avg_ms": 0.0, "median_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "min_ms": 0.0, "max_ms": 0.0, "avg_fps": 0.0, "process_ms": null, "physics_ms": null, "run_mean_ms": 0.0, "run_stdev_ms": 0.0, "run_min_ms": 0.0, "run_max_ms": 0.0}
	var average := _mean_field(rows, "avg_ms")
	var frame_medians := PackedFloat64Array()
	var frame_p95s := PackedFloat64Array()
	var frame_p99s := PackedFloat64Array()
	var frame_mins := PackedFloat64Array()
	var frame_maxs := PackedFloat64Array()
	for row in rows:
		frame_medians.append(float(row["median_ms"]))
		frame_p95s.append(float(row["p95_ms"]))
		frame_p99s.append(float(row["p99_ms"]))
		frame_mins.append(float(row["min_ms"]))
		frame_maxs.append(float(row["max_ms"]))
	var cpu_process: Variant = _mean_optional_field(rows, "process_ms")
	var cpu_physics: Variant = _mean_optional_field(rows, "physics_ms")
	var run_min := average
	var run_max := average
	var variance := 0.0
	for row in rows:
		var value := float(row["avg_ms"])
		run_min = minf(run_min, value)
		run_max = maxf(run_max, value)
		variance += (value - average) * (value - average)
	return {
		"count": rows.size(),
		"avg_ms": average,
		"median_ms": _mean_packed(frame_medians),
		"p95_ms": _mean_packed(frame_p95s),
		"p99_ms": _mean_packed(frame_p99s),
		"min_ms": _mean_packed(frame_mins),
		"max_ms": _mean_packed(frame_maxs),
		"avg_fps": 1000.0 / average if average > 0.0 else 0.0,
		"process_ms": cpu_process,
		"physics_ms": cpu_physics,
		"run_mean_ms": average,
		"run_stdev_ms": sqrt(variance / float(rows.size())),
		"run_min_ms": run_min,
		"run_max_ms": run_max,
	}


func _mean_field(rows: Array[Dictionary], key: String) -> float:
	var total := 0.0
	for row in rows:
		total += float(row[key])
	return total / float(rows.size())


func _mean_optional_field(rows: Array[Dictionary], key: String):
	var total := 0.0
	var count := 0
	for row in rows:
		if row[key] != null:
			total += float(row[key])
			count += 1
	return total / float(count) if count > 0 else null


func _mean_packed(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _csv_value(value) -> String:
	return "unavailable" if value == null else "%.6f" % float(value)


func _summary_value(value) -> String:
	return "unavailable" if value == null else "%.4f" % float(value)


func _viewport_size() -> Vector2i:
	return Vector2i(get_viewport().size)

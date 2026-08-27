extends CanvasLayer
## Sólo muestra monitores proporcionados por Godot y estados propios del laboratorio.

@onready var metrics_label: Label = $Margin/Panel/Metrics
@onready var lab_main: Node = get_parent()
var _breaker_hud_verbose := false


func _process(_delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	var frame_time_ms := 1000.0 / maxf(float(fps), 1.0)
	if lab_main != null and lab_main.has_method(&"smoothed_frame_time_ms"):
		frame_time_ms = float(lab_main.call("smoothed_frame_time_ms"))
	var planar_lines: Array = []
	if lab_main != null and lab_main.has_method(&"planar_hud_lines"):
		planar_lines = lab_main.call("planar_hud_lines")
	var viewport_size := get_viewport().get_visible_rect().size
	var fft_module := get_tree().get_first_node_in_group(&"ocean_fft")
	var fft_line := "FFT: unavailable"
	if fft_module:
		fft_line = "FFT bands: %s | %s | %d cascades | %d dispatches | Hs %.3f m" % [
			fft_module.band_debug_name(),
			"ON" if fft_module.is_fft_enabled() else "OFF",
			fft_module.render_cascade_count(),
			fft_module.dispatches_per_update if fft_module.is_fft_enabled() else 0,
			fft_module.combined_hs_m(),
		]
	var lines := PackedStringArray([
		"OCEAN LAB — FASE 2A / QUERY REFERENCE",
		"Sea State: %s" % (fft_module.sea_state_name() if fft_module else "unavailable"),
		"Spectrum: %s | Shape: %s | Crest sharpen: %s | Normal: %s" % [
			fft_module.spectrum_model_name() if fft_module else "unavailable",
			fft_module.ocean_shape_debug_name() if fft_module else "unavailable",
			fft_module.ocean_crest_sharpen_debug_name() if fft_module else "unavailable",
			fft_module.ocean_normal_fragment_name() if fft_module else "unavailable",
		],
		_hs_line(fft_module),
		"Query probes: %s | Query backend: %s [%s]" % [
			"ON" if _probe_tool_enabled() else "OFF",
			fft_module.query_backend_name() if fft_module else "unavailable",
			fft_module.query_backend_reason() if fft_module and fft_module.has_method(&"query_backend_reason") else "unavailable",
		],
		"FPS: %d | Frame: %.2f ms" % [fps, frame_time_ms],
		"CPU process: %.2f ms | Physics: %.2f ms" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		],
		"Physics ticks: %d/s | Resolution: %d x %d" % [
			Engine.physics_ticks_per_second, int(viewport_size.x), int(viewport_size.y),
		],
		"Draw calls: %d | Primitives: %d" % [
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		],
		"Static memory: %s" % _format_bytes(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"Simulation: %.3f s%s | Seed: %d" % [
			SimulationClock.simulation_time,
			" (PAUSED)" if SimulationClock.is_paused() else "",
			SimulationClock.simulation_seed,
		],
		"Profile: %s | Ocean modules: %d | Disturbance tiles: 0" % [
			OceanQualitySettings.profile_name(),
			OceanModuleRegistry.active_module_count(),
		],
		fft_line,
		_foam_line(fft_module),
		_crest_transition_lines(fft_module),
		_foam_debug_line(fft_module),
		_breaker_line(fft_module),
		"Clipmap: ON | Levels: %d | Near spacing: %.2f m | Extent: %.0f m | Triangles: %d" % [
			fft_module.clipmap_level_count() if fft_module else 0,
			fft_module.clipmap_near_spacing_m() if fft_module else 0.0,
			fft_module.clipmap_extent_m() if fft_module else 0.0,
			fft_module.clipmap_triangle_count() if fft_module else 0,
		],
		"Clipmap LOD: %s | Periodicity grid: %s" % [fft_module.clipmap_lod_debug_name() if fft_module else "unavailable", fft_module.periodicity_debug_name() if fft_module else "unavailable"],
		"Surface debug: %s | GPU allocation: %s" % [fft_module.debug_mode_name() if fft_module else "unavailable", _format_bytes(fft_module.gpu_memory_bytes()) if fft_module else "unavailable"],
		"GPU frame time: unavailable at runtime — use the external profiler.",
	])
	for planar_line in planar_lines:
		lines.append(str(planar_line))
	metrics_label.text = "\n".join(lines)


func toggle_breaker_hud_verbose() -> void:
	_breaker_hud_verbose = not _breaker_hud_verbose


func breaker_hud_verbose() -> bool:
	return _breaker_hud_verbose


func _hs_line(fft_module) -> String:
	## 5R.1B: target/measured Hs por banda (LONG/MID/SHORT).
	if fft_module == null:
		return "Hs bands: unavailable"
	var bands: Array = fft_module.spectrum_band_diagnostics()
	if bands.is_empty():
		return "Hs bands: pending"
	var parts: PackedStringArray = []
	for band in bands:
		parts.append("%s %.3f/%.3f" % [band["id"], band["target_hs_m"], band["measured_hs_m"]])
	return "Hs " + " | ".join(parts)


func _foam_line(fft_module) -> String:
	if fft_module == null or not fft_module.has_method(&"foam_render_diagnostics"):
		return "Foam diagnostics: unavailable"
	var diagnostics: Dictionary = fft_module.foam_render_diagnostics()
	var crest_parts: PackedStringArray = []
	for cascade in diagnostics.get("crest", []):
		crest_parts.append("%s %d² %.1f/s" % [cascade.get("id", "?"), cascade.get("resolution", 0), cascade.get("updates_per_second", 0.0)])
	var surface: Dictionary = diagnostics.get("surface", {})
	return "Foam: Crest[%s] | Surface jobs %.1f/s passes %.1f/s | FFT/field %d/%d" % [
		" ".join(crest_parts),
		surface.get("jobs_per_second", 0.0),
		surface.get("passes_per_second", 0.0),
		diagnostics.get("surface_fft_resolution", 0),
		diagnostics.get("surface_field_resolution", 0),
	]


func _foam_debug_line(fft_module) -> String:
	if fft_module == null:
		return "Foam Debug: unavailable"
	var ocean_v3: Node = fft_module.get_parent()
	if ocean_v3 == null:
		return "Foam Debug: unavailable"
	return "Foam Debug: %s" % _foam_debug_name(int(ocean_v3.get("foam_debug_mode")))


func _foam_debug_name(mode: int) -> String:
	match mode:
		1:
			return "CREST_FINAL"
		4:
			return "SURFACE_FINAL"
		7:
			return "SURFACE_PLUS_CREST"
		11:
			return "FILIGREE"
		14:
			return "CREST_FRESH_RAW"
		15:
			return "CREST_RESIDUAL_RAW"
	return "OFF"


func _crest_transition_lines(fft_module) -> String:
	if fft_module == null or not fft_module.has_method(&"foam_render_diagnostics"):
		return "Crest transition: unavailable"
	var diagnostics: Dictionary = fft_module.foam_render_diagnostics()
	var cascades: Array = diagnostics.get("crest", [])
	var transition_active := false
	for cascade in cascades:
		if bool(cascade.get("h0_transition_active", false)):
			transition_active = true
			break
	if not transition_active:
		return "Crest transition: inactive"

	var lines: PackedStringArray = []
	for cascade in cascades:
		lines.append("CREST %s" % cascade.get("id", "?"))
		lines.append("H0Target %s | a %.2f | Enabled %s/%s | %.1f Hz" % [
			"YES" if bool(cascade.get("h0_transition_active", false)) else "NO",
			float(cascade.get("crest_transition_alpha", 0.0)),
			"YES" if bool(cascade.get("current_foam_enabled", false)) else "NO",
			"YES" if bool(cascade.get("target_foam_enabled", false)) else "NO",
			float(cascade.get("crest_updates_per_second", 0.0)),
		])
		lines.append("W %.3f > %.3f > %.3f | Amt %.3f > %.3f > %.3f" % [
			float(cascade.get("current_whitecap", 0.0)),
			float(cascade.get("effective_whitecap", 0.0)),
			float(cascade.get("target_whitecap", 0.0)),
			float(cascade.get("current_foam_amount", 0.0)),
			float(cascade.get("effective_foam_amount", 0.0)),
			float(cascade.get("target_foam_amount", 0.0)),
		])
		lines.append("Decay %.3f > %.3f > %.3f | Weight %.3f > %.3f > %.3f" % [
			float(cascade.get("current_foam_decay", 0.0)),
			float(cascade.get("effective_foam_decay", 0.0)),
			float(cascade.get("target_foam_decay", 0.0)),
			float(cascade.get("current_foam_cascade_weight", 0.0)),
			float(cascade.get("effective_foam_cascade_weight", 0.0)),
			float(cascade.get("target_foam_cascade_weight", 0.0)),
		])
	return "\n".join(lines)


func _breaker_line(fft_module) -> String:
	if fft_module == null or not fft_module.has_method(&"breaker_pool_summary"):
		return "Breaker Ribbons: unavailable"
	var diagnostics: Dictionary = fft_module.breaker_pool_summary()
	if diagnostics.is_empty():
		return "Breaker Ribbons: unavailable"
	var breaker_backend: String = str(diagnostics.get("breaker_query_backend", "unavailable"))
	var tracking: Array = fft_module.breaker_tracking_snapshot() if fft_module.has_method(&"breaker_tracking_snapshot") else []
	var slots := int(diagnostics.get("slots", 0))
	var debug_name := str(diagnostics.get("debug", "OFF"))
	var debug_slot := int(diagnostics.get("debug_slot", 0))
	var lines := PackedStringArray([
		"Breaker: %s | anchors %d | active %d | Debug %s slot %s" % [
			"ON" if bool(diagnostics.get("breaker_enabled", false)) else "OFF",
			slots,
			int(diagnostics.get("active_breaker_count", 0)),
			debug_name,
			"ALL" if debug_slot < 0 else str(debug_slot),
		],
		"Detector: %d Hz | %d/%d pts | slope %d/%d | %.2f ms | backend %s" % [
			int(diagnostics.get("detector_hz", 0)),
			int(diagnostics.get("queried_slots_last_tick", 0)),
			int(diagnostics.get("queried_points_last_tick", 0)),
			int(diagnostics.get("detector_slope_queries_last_tick", 0)),
			int(diagnostics.get("detector_slope_points_last_tick", 0)),
			float(diagnostics.get("detector_query_elapsed_ms_last_tick", 0.0)),
			breaker_backend,
		],
	])
	if debug_name == "DETECTOR":
		if debug_slot < 0:
			lines.append("BREAKER DETECTOR — ALL")
			for index in slots:
				lines.append(_breaker_slot_short(index, tracking[index] if index < tracking.size() else {}))
		else:
			lines.append(_breaker_detector_detail(debug_slot, tracking[debug_slot] if debug_slot < tracking.size() else {}))
	elif debug_slot >= 0 and debug_slot < tracking.size() and str(tracking[debug_slot].get("state", "DETECT")) == "ACTIVE":
		lines.append(_breaker_active_detail(debug_slot, tracking[debug_slot]))
	elif _breaker_hud_verbose:
		lines.append("Breaker verbose: query=%s | coastal=%s | corridor eval=%d (%.2f ms) | force=%s" % [
			str(diagnostics.get("breaker_query_backend_reason", "unavailable")),
			"ON" if bool(diagnostics.get("coastal_runtime_enabled", false)) else "OFF",
			int(diagnostics.get("corridor_evaluation_count", 0)),
			float(diagnostics.get("corridor_evaluation_ms", 0.0)),
			str(diagnostics.get("force_spawn_last_result", "never_requested")),
		])
	return "\n".join(lines)


func _breaker_slot_short(index: int, slot: Dictionary) -> String:
	var reason := str(slot.get("detector_gate_reason", "pending"))
	if reason == "INVALID_QUERY_SAMPLE":
		return "S%d INVALID samples=%s" % [index, str(slot.get("invalid_sample_indices", "unknown"))]
	return "S%d %s score %.2f wave %d gate %s" % [index, str(slot.get("state", "DETECT")), float(slot.get("final_score", 0.0)), int(slot.get("wave", 0)), reason]


func _breaker_detector_detail(index: int, slot: Dictionary) -> String:
	return "BREAKER DETECTOR — SLOT %d\nState: %s  Wave: %d  s/lambda: %+.2f  Window: %s\nDepth: %.2f m  Pressure: %.2f  Prom: %.2f  Slope: %.2f\nScore: %.2f  Best: %.2f @ s %.2f m  Prob: %.2f  Roll: %.2f\nGate: %s\nStencil: %d valid [%d..%d]" % [
		index,
		str(slot.get("state", "DETECT")),
		int(slot.get("wave", 0)),
		float(slot.get("candidate_s_lambda", 0.0)),
		"YES" if bool(slot.get("in_window", false)) else "NO",
		float(slot.get("spawn_depth_m", slot.get("current_depth_m", 0.0))),
		float(slot.get("pressure", 0.0)),
		float(slot.get("prominence", 0.0)),
		float(slot.get("slope_long", 0.0)),
		float(slot.get("final_score", 0.0)),
		float(slot.get("best_score", 0.0)),
		float(slot.get("best_candidate_s", 0.0)),
		float(slot.get("probability", 0.0)),
		float(slot.get("roll", 0.0)),
		str(slot.get("detector_gate_reason", "pending")),
		int(slot.get("stencil_valid_count", 0)),
		int(slot.get("stencil_valid_start", -1)),
		int(slot.get("stencil_valid_end", -1)),
	]


func _breaker_active_detail(index: int, slot: Dictionary) -> String:
	var camera := get_viewport().get_camera_3d()
	var tracked := Vector2(slot.get("tracked_xz", Vector2.ZERO))
	var camera_distance := 0.0
	if camera != null:
		camera_distance = camera.global_position.distance_to(Vector3(tracked.x, 0.0, tracked.y))
	return "BREAKER SLOT %d — ACTIVE\nphase: %s  life %.2f  stage %.2f  alpha %.2f\nspawn depth %.2f m  current depth %.2f m\nV/H weights %.2f / %.2f  travelled %.2f m  remaining %.2f m  camera %.1f m" % [
		index,
		str(slot.get("lifecycle_phase", "ACTIVE")),
		float(slot.get("life_t", 0.0)),
		float(slot.get("stage", 0.0)),
		float(slot.get("alpha", 0.0)),
		float(slot.get("spawn_depth_m", 0.0)),
		float(slot.get("current_depth_m", 0.0)),
		float(slot.get("shore_vertical_weight", 1.0)),
		float(slot.get("shore_horizontal_weight", 1.0)),
		float(slot.get("distance_travelled_m", 0.0)),
		float(slot.get("distance_remaining_in_corridor_m", 0.0)),
		camera_distance,
	]


func _probe_tool_enabled() -> bool:
	var probe_tool := get_tree().get_first_node_in_group(&"query_probes")
	return probe_tool != null and probe_tool.is_enabled()


func _format_bytes(bytes: float) -> String:
	if bytes < 1024.0 * 1024.0:
		return "%.0f KiB" % (bytes / 1024.0)
	return "%.2f MiB" % (bytes / (1024.0 * 1024.0))

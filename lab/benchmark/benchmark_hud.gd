extends CanvasLayer
## Sólo muestra monitores proporcionados por Godot y estados propios del laboratorio.

@onready var metrics_label: Label = $Margin/Panel/Metrics
@onready var lab_main: Node = get_parent()


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
	var breaker_backend: String = fft_module.breaker_query_backend_name() if fft_module.has_method(&"breaker_query_backend_name") else "unavailable"
	var breaker_reason: String = fft_module.breaker_query_backend_reason() if fft_module.has_method(&"breaker_query_backend_reason") else "unavailable"
	return "Breaker Query: %s [%s] | Ribbons: %s | TRANS %s %.2f | anchors %d | active %d | track %d/%d" % [
		breaker_backend,
		breaker_reason,
		"ON" if fft_module.breaker_ribbons_diagnostic_visible() else "OFF",
		"ON" if bool(diagnostics.get("transition_active", false)) else "OFF",
		float(diagnostics.get("transition_alpha", 0.0)),
		int(diagnostics.get("transition_anchor_count", diagnostics.get("slots", 0))),
		int(diagnostics.get("active_breaker_count", 0)),
		int(diagnostics.get("active_tracking_queries_last_tick", 0)),
		int(diagnostics.get("active_tracking_points_last_tick", 0)),
	]


func _probe_tool_enabled() -> bool:
	var probe_tool := get_tree().get_first_node_in_group(&"query_probes")
	return probe_tool != null and probe_tool.is_enabled()


func _format_bytes(bytes: float) -> String:
	if bytes < 1024.0 * 1024.0:
		return "%.0f KiB" % (bytes / 1024.0)
	return "%.2f MiB" % (bytes / (1024.0 * 1024.0))

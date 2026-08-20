extends CanvasLayer
## Sólo muestra monitores proporcionados por Godot y estados propios del laboratorio.

@onready var metrics_label: Label = $Margin/Panel/Metrics


func _process(_delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	var frame_time_ms := 1000.0 / maxf(float(fps), 1.0)
	var viewport_size := get_viewport().get_visible_rect().size
	metrics_label.text = "\n".join([
		"OCEAN LAB — BASELINE SIN OCÉANO",
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
		"GPU frame time: unavailable at runtime — use the external profiler.",
	])


func _format_bytes(bytes: float) -> String:
	if bytes < 1024.0 * 1024.0:
		return "%.0f KiB" % (bytes / 1024.0)
	return "%.2f MiB" % (bytes / (1024.0 * 1024.0))

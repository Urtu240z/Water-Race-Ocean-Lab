extends SceneTree
## Captura headless de 10 s sobre lab/lab_main.tscn.
## Activa DETECTOR por la misma API que usa J y sólo lee los snapshots ya
## calculados por BreakerRibbonPool; no añade queries ni altera tuning.

const CAPTURE_DURATION_S := 10.0
const REPORT_INTERVAL_S := 1.0

var _scene: Node = null
var _ocean: Node = null
var _elapsed := 0.0
var _next_report := 0.0
var _started := false
var _force_spawn_done := false


func _process(delta: float) -> bool:
	if not _started:
		_scene = load("res://lab/lab_main.tscn").instantiate()
		root.add_child(_scene)
		_started = true
		return false
	if _ocean == null:
		_ocean = _scene.get_node_or_null("OceanV3Mount/OceanV3")
		if _ocean == null:
			return false
		# LIP -> TAKEOVER -> REGION -> FORCE_LIP -> DETECTOR.
		for _mode in 4:
			_ocean.call("cycle_breaker_debug")
	_elapsed += delta
	if not _force_spawn_done and _elapsed >= 2.0:
		_force_spawn_done = true
		print("FORCE_SPAWN_RESULT selected_slot=0 ok=%s" % ("YES" if bool(_ocean.call("force_spawn_selected_breaker")) else "NO"))
	if _elapsed >= _next_report:
		_print_snapshot()
		_next_report += REPORT_INTERVAL_S
	if _elapsed >= CAPTURE_DURATION_S:
		print("BREAKER_DETECTOR_RUNTIME_CAPTURE: COMPLETE duration=%.2fs" % _elapsed)
		quit(0)
	return false


func _print_snapshot() -> void:
	var summary: Dictionary = _ocean.call("breaker_pool_summary")
	var tracking: Array = _ocean.call("breaker_tracking_snapshot")
	print("DETECTOR_CAPTURE t=%.2f tick=%d queried=%d/%d slope=%d/%d elapsed_ms=%.3f backend=%s reason=%s anchors=%d active=%d" % [
		_elapsed,
		int(summary.get("detector_tick", 0)),
		int(summary.get("queried_slots_last_tick", 0)),
		int(summary.get("queried_points_last_tick", 0)),
		int(summary.get("slope_queries_last_tick", 0)),
		int(summary.get("slope_points_last_tick", 0)),
		float(summary.get("detector_query_elapsed_ms_last_tick", 0.0)),
		str(summary.get("breaker_query_backend", "unknown")),
		str(summary.get("breaker_query_backend_reason", "unknown")),
		int(summary.get("slots", 0)),
		int(summary.get("active_breaker_count", 0)),
	])
	for index in tracking.size():
		var slot: Dictionary = tracking[index]
		print("DETECTOR_SLOT t=%.2f slot=%d state=%s s/lambda=%+.3f/%+.3f prev=%+.3f wave=%d advancing=%s in_window=%s pressure=%.4f prominence=%.4f local_hs=%.4f slope_long=%.4f raw=%.4f eligibility=%.4f zone=%.4f final=%.4f probability=%.4f roll=%.4f cooldown=%s last_decided=%d reason=%s" % [
			_elapsed,
			index,
			str(slot.get("state", "DETECT")),
			float(slot.get("candidate_s", 0.0)),
			float(slot.get("candidate_s_lambda", 0.0)),
			float(slot.get("previous_s_lambda", 0.0)),
			int(slot.get("wave", 0)),
			"YES" if bool(slot.get("advancing", false)) else "NO",
			"YES" if bool(slot.get("in_window", false)) else "NO",
			float(slot.get("pressure", 0.0)),
			float(slot.get("prominence", 0.0)),
			float(slot.get("local_hs", 0.0)),
			float(slot.get("slope_long", 0.0)),
			float(slot.get("raw_score", 0.0)),
			float(slot.get("anchor_eligibility", 0.0)),
			float(slot.get("zone_activity", 0.0)),
			float(slot.get("final_score", 0.0)),
			float(slot.get("probability", 0.0)),
			float(slot.get("roll", 0.0)),
			"YES" if bool(slot.get("cooldown_done", true)) else "NO",
			int(slot.get("last_decided_wave_serial", -1)),
			str(slot.get("detector_gate_reason", "pending")),
		])

extends SceneTree
## Paradise Island RACE: validación de auto-spawn real sin FORCE SPAWN.

const CAPTURE_DURATION_S := 30.0

var _scene: Node = null
var _ocean: Node = null
var _elapsed := 0.0
var _started := false
var _previous_active: Array[bool] = []
var _auto_spawns := 0
var _active_max := 0
var _spawn_times: Array[float] = []


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
	var summary: Dictionary = _ocean.call("breaker_pool_summary")
	var tracking: Array = _ocean.call("breaker_tracking_snapshot")
	var active_count := int(summary.get("active_breaker_count", 0))
	_active_max = maxi(_active_max, active_count)
	if _previous_active.size() != tracking.size():
		_previous_active.resize(tracking.size())
	for index in tracking.size():
		var active := str(tracking[index].get("state", "DETECT")) == "ACTIVE"
		if active and not _previous_active[index]:
			_auto_spawns += 1
			_spawn_times.append(_elapsed)
		_previous_active[index] = active
	if _elapsed >= CAPTURE_DURATION_S:
		var intervals: Array[float] = []
		for index in range(1, _spawn_times.size()):
			intervals.append(_spawn_times[index] - _spawn_times[index - 1])
		var min_interval := 0.0
		var max_interval := 0.0
		if not intervals.is_empty():
			min_interval = intervals[0]
			max_interval = intervals[0]
			for interval in intervals:
				min_interval = minf(min_interval, interval)
				max_interval = maxf(max_interval, interval)
		print("BREAKER_AUTO_SPAWN_30S: spawns=%d active_max=%d intervals=%.3f..%.3f anchors=%d detector_hz=%d" % [
			_auto_spawns,
			_active_max,
			min_interval,
			max_interval,
			int(summary.get("slots", 0)),
			int(summary.get("detector_hz", 0)),
		])
		if _auto_spawns == 0:
			push_error("BREAKER_AUTO_SPAWN_30S: no hubo auto-spawns naturales")
			quit(1)
		else:
			print("BREAKER_AUTO_SPAWN_30S: PASS")
			quit(0)
	return false

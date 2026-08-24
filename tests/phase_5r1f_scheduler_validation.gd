extends SceneTree
## 5R.1F: validación del scheduler del detector (20 Hz, round robin 2 slots/tick).
## Usa un MOCK de OceanQuery que cuenta llamadas y devuelve muestras controladas;
## NO toca OceanQuery NATIVE ni el detector real. Verifica:
##  - ACTIVE: 0 queries (autónomo, avanza cada frame)
##  - COOLDOWN: 0 queries (sólo countdown)
##  - DETECT: ticks a 20 Hz (render_time), máx 2 slots/tick, 14 puntos, round robin
##  - pause: sin ticks nuevos con render_time congelado; salto sin catch-up
##  - reset/rebuild: scheduler reiniciado de forma determinista
##  - lifecycle DETECT -> ACTIVE -> COOLDOWN -> DETECT

const ANCHOR_COUNT := 4
const Z0 := 0.0
const Z_SPACING := 10.0
const WAVELENGTH := 16.0
const PHASE_SPEED := 8.0
const DURATION := 1.7 # clamp(0.85 * (16/8), 1, 3)
const INTERVAL := 2.0 # clamp(0.9 * (16/8), 2, 3)

var _failures := 0
var _ran := false
var _clock = null
var _pool_script: GDScript = null
var _sample_script: GDScript = null
var _mock_calls := 0
var _mock_points := 0
var _mock_calls_history: Array = []
var _mock_measurement := {}
var _mock_mode := "flat"


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run_all()
	return false


func _run_all() -> void:
	# En modo --script los autoloads no son identificadores globales en compile
	# time; el pool referencia SimulationClock, así que se carga en runtime (en
	# _process los autoloads ya están registrados). Mismo patrón que phase_2a.
	_clock = root.get_node_or_null("SimulationClock")
	_pool_script = load("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	_sample_script = load("res://ocean_v3/physics/ocean_query_sample.gd")
	if _clock == null or _pool_script == null or _sample_script == null:
		push_error("PHASE_5R1F: dependencias no disponibles")
		_failures += 1
	else:
		_clock.set_paused(true)
		_clock.simulation_seed = 12345
		_test_rate_and_round_robin()
		_test_active_zero_queries()
		_test_lifecycle()
		_test_pause()
		_test_reset()
	if _failures == 0:
		print("PHASE_5R1F: PASS")
		quit(0)
	else:
		push_error("PHASE_5R1F: %d fallos" % _failures)
		quit(1)


func _make_pool(mode: String):
	var pool = _pool_script.new()
	root.add_child(pool)
	pool._sea_level_y = 0.0
	pool._long_hs_m = 2.5
	pool._coastal_fraction = 0.5
	for i in ANCHOR_COUNT:
		pool._anchors.append({
			"xz": Vector2(0.0, Z0 + float(i) * Z_SPACING),
			"direction": Vector2.RIGHT,
			"depth_m": 5.0,
			"pressure": 1.5,
			"wavelength_m": WAVELENGTH,
			"local_k": 0.4,
			"shoaling": 1.0,
			"phase_speed_mps": PHASE_SPEED,
		})
	pool._ensure_material()
	for i in ANCHOR_COUNT:
		var ribbon := MeshInstance3D.new()
		ribbon.name = "Ribbon%d" % i
		ribbon.material_override = pool._material
		pool.add_child(ribbon)
		pool._ribbons.append(ribbon)
	pool.set_query_source(Callable(self, "_mock_query"))
	_mock_calls = 0
	_mock_points = 0
	_mock_calls_history = []
	_mock_measurement = {}
	_mock_mode = mode
	return pool


func _set_time(t: float) -> void:
	_clock.simulation_time = t
	_clock._previous_simulation_time = t


func _step(pool, t: float) -> void:
	_set_time(t)
	pool._update_tracking()


func _mock_query(positions: Array, _render_time: float) -> Array:
	_mock_calls += 1
	_mock_points = positions.size()
	var samples: Array = []
	var slot_ids := PackedInt32Array()
	var i := 0
	while i < positions.size():
		var slot := int(round((positions[i].z - Z0) / Z_SPACING))
		slot_ids.append(slot)
		var meas: int = int(_mock_measurement.get(slot, 0)) + 1
		_mock_measurement[slot] = meas
		var peak_idx := 1 # candidato fuera de ventana (init) / sin avance con flat
		if _mock_mode == "peak" and meas >= 2:
			peak_idx = 2 # en ventana de spawn y avanzando -> spawn garantizado
		for k in 7:
			var s = _sample_script.new()
			s.valid = true
			s.height = 1.0 if k == peak_idx else 0.0
			s.normal = Vector3.UP
			if _mock_mode == "peak" and peak_idx == 2 and k == peak_idx:
				s.normal = Vector3(0.7, 0.3, 0.7).normalized()
			samples.append(s)
		i += 7
	_mock_calls_history.append(slot_ids)
	return samples


# --- Test 1: 20 Hz + round robin (todos DETECT, mock flat) -------------------

func _test_rate_and_round_robin() -> void:
	var pool = _make_pool("flat")
	for frame in 60:
		_step(pool, float(frame) / 60.0)
	# A 60 Hz, los ticks caen en los cruces de ~0.05 s; la aritmética float puede
	# desplazar el cruce ±1 frame, así que 20 Hz se comprueba como rango.
	_check(_mock_calls >= 17 and _mock_calls <= 21, "20 Hz: %d ticks en 1 s (rango 17..21)" % _mock_calls)
	_check(_mock_points == 14, "14 puntos por tick (2 slots x 7 muestras)")
	var sum: Dictionary = pool.summary()
	_check(int(sum["detector_hz"]) == 20, "detector_hz = 20")
	_check(int(sum["detector_tick"]) == _mock_calls, "detector_tick == llamadas (%d)" % _mock_calls)
	_check(int(sum["queried_slots_last_tick"]) == 2, "queried_slots_last_tick = 2")
	_check(int(sum["queried_points_last_tick"]) == 14, "queried_points_last_tick = 14")
	_check(_round_robin_ok(), "round robin: call k -> {0,1},{2,3},{0,1},...")
	pool.queue_free()


func _round_robin_ok() -> bool:
	for k in _mock_calls_history.size():
		var ids: PackedInt32Array = _mock_calls_history[k]
		if ids.size() != 2:
			return false
		var expected_a: int = 2 * (k % 2)
		if ids[0] != expected_a or ids[1] != expected_a + 1:
			return false
	return true


# --- Test 2: ACTIVE = 0 queries; ACTIVE avanza cada frame --------------------

func _test_active_zero_queries() -> void:
	var pool = _make_pool("flat")
	pool._tracking.resize(ANCHOR_COUNT)
	for i in 2:
		pool._tracking[i] = {
			"active": true,
			"valid": 1.0,
			"spawn_time": 0.0,
			"spawn_xz": Vector2(0.0, Z0 + float(i) * Z_SPACING),
			"spawn_direction": Vector2(-1.0, 0.0),
			"spawn_phase_speed": PHASE_SPEED,
			"lifecycle_duration": DURATION,
			"next_spawn_time": INTERVAL,
			"stage": 0.5,
			"alpha": 0.5,
			"life_t": 0.1,
			"tracked_xz": Vector2(0.0, Z0 + float(i) * Z_SPACING),
			"phase_speed": PHASE_SPEED,
		}
	_mock_calls = 0
	_mock_calls_history = []
	_mock_measurement = {}
	var prev_x := 0.0
	var moved := true
	for frame in 30:
		var t := float(frame) / 60.0
		_step(pool, t)
		var x: float = float(pool._tracking[0]["tracked_xz"].x)
		if frame > 0:
			var step := x - prev_x
			if absf(step + PHASE_SPEED / 60.0) > 1.0e-6:
				moved = false
		prev_x = x
	_check(_mock_calls > 0, "detector sigue consultando slots DETECT (%d calls)" % _mock_calls)
	var only_23 := true
	for ids in _mock_calls_history:
		for id in ids:
			if id < 2:
				only_23 = false
	_check(only_23, "ACTIVE (0,1) nunca consultado; sólo DETECT (2,3)")
	_check(moved, "ACTIVE avanza suave cada frame (%d Hz)" % int(round(PHASE_SPEED * 60.0 / PHASE_SPEED)))
	pool.queue_free()


# --- Test 3: lifecycle DETECT -> ACTIVE -> COOLDOWN -> DETECT (mock peak) ----

func _test_lifecycle() -> void:
	var pool = _make_pool("peak")
	var calls_at_all_active := -1
	var calls_at_1_9 := -1
	var all_active_at := -1.0
	var all_cooldown_at := -1.0
	var detect_again_at := -1.0
	var queried_zero_during_active := true
	var frames := int(2.5 * 60.0)
	for frame in frames:
		var t := float(frame) / 60.0
		_step(pool, t)
		var snap: Array = pool.tracking_snapshot()
		var names := PackedStringArray()
		for s in snap:
			names.append(s["state"])
		if all_active_at < 0.0 and names.size() == ANCHOR_COUNT and _all_equal(names, "ACTIVE"):
			all_active_at = t
			calls_at_all_active = _mock_calls
		if frame == 114: # t = 1.90, todos en COOLDOWN
			calls_at_1_9 = _mock_calls
		if frame == 30: # t = 0.50, todos ACTIVE: ninguna query en el tick
			if _mock_calls != calls_at_all_active:
				queried_zero_during_active = false
			if int(pool.summary()["queried_slots_last_tick"]) != 0:
				queried_zero_during_active = false
		if all_cooldown_at < 0.0 and names.size() == ANCHOR_COUNT and _all_equal(names, "COOLDOWN"):
			all_cooldown_at = t
		if all_cooldown_at > 0.0 and detect_again_at < 0.0 and names.size() == ANCHOR_COUNT and _all_equal(names, "DETECT"):
			detect_again_at = t
	_check(all_active_at >= 0.0, "DETECT -> ACTIVE (todos) en t=%.2f" % all_active_at)
	_check(all_cooldown_at >= 0.0, "ACTIVE -> COOLDOWN (todos) en t=%.2f" % all_cooldown_at)
	_check(detect_again_at >= 0.0, "COOLDOWN -> DETECT (todos) en t=%.2f" % detect_again_at)
	_check(calls_at_all_active >= 0 and calls_at_1_9 == calls_at_all_active,
		"ACTIVE/COOLDOWN: 0 queries desde ACTIVE hasta COOLDOWN (%d == %d)" % [calls_at_1_9, calls_at_all_active])
	_check(queried_zero_during_active, "queried_slots_last_tick = 0 durante ACTIVE")
	pool.queue_free()


func _all_equal(names: PackedStringArray, value: String) -> bool:
	for name in names:
		if name != value:
			return false
	return true


# --- Test 4: pause / salto de tiempo ------------------------------------------

func _test_pause() -> void:
	var pool = _make_pool("flat")
	_step(pool, 0.0) # tick
	var calls_after_first := _mock_calls
	_step(pool, 0.0) # render_time congelado -> sin tick
	_check(_mock_calls == calls_after_first, "pause: sin ticks nuevos con render_time congelado")
	_step(pool, 0.1) # salto -> UN tick, sin catch-up
	_check(_mock_calls == calls_after_first + 1, "salto de tiempo: un único tick, sin catch-up")
	pool.queue_free()


# --- Test 5: reset determinista ------------------------------------------------

func _test_reset() -> void:
	var pool = _make_pool("flat")
	for frame in 10:
		_step(pool, float(frame) / 60.0)
	_check(pool._detector_tick > 0, "detector avanzó antes del reset")
	pool.disable()
	_check(pool._next_detector_time == 0.0 and pool._detector_cursor == 0 and pool._detector_tick == 0,
		"disable()/rebuild reinicia el scheduler de forma determinista")
	pool.queue_free()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

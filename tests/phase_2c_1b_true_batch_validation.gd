extends SceneTree
## Fase 2C.1B: TRUE_BATCH / warm-start contra DIRECT_SCALAR nativo.
## No valida contra PATCH: PatchCore continúa siendo un prototipo aislado.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

const SEED := 20260820
const S_STRIDE := 15
const WARM_STRIDE := 17
const COUNTS := [1, 4, 8, 16, 64]
const EPS := 1.0e-11

var _native = null
var _failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		print("PHASE_2C_1B_TRUE_BATCH: SKIP (OceanQueryNative no disponible)")
		quit(0)
		return
	_native = ClassDB.instantiate(&"OceanQueryNative")
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		_setup_native(_build_reduced(state))
		_validate_cold(state)
		_validate_warm_sequence(state)
		_validate_sea_level(state)
	if _failures == 0:
		print("PHASE_2C_1B_TRUE_BATCH: PASS")
		quit(0)
	else:
		push_error("PHASE_2C_1B_TRUE_BATCH: %d fallos" % _failures)
		quit(1)


func _build_reduced(state: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var reduced = preload("res://ocean_v3/physics/ocean_query_reduced.gd").new()
	reduced.set_budget(1024, 1024, 1024)
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _setup_native(reduced) -> void:
	_native.clear()
	_native.set_sea_level(0.0)
	for cascade in reduced.get_cascades_compact():
		_native.set_cascade_data(cascade.index, cascade.inv_n2, cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2, cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight, cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	_native.finalize_spectrum()


func _positions(count: int, origin := Vector3.ZERO, yaw := 0.0) -> PackedVector3Array:
	var result := PackedVector3Array()
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	for i in count:
		var u := -1.55 + 3.10 * float(i % 4) / 3.0
		var v := -0.60 + 1.20 * float(i / 4) / maxf(1.0, ceil(float(count) / 4.0) - 1.0)
		result.append(origin + right * u + forward * v)
	return result


func _validate_cold(state: int) -> void:
	_native.ensure_prepared(2.3)
	for count in COUNTS:
		var points := _positions(count, Vector3(13.0, 0.0, -7.0), 0.37)
		var direct: PackedFloat64Array = _native.sample_batch_prepared(points)
		var batch: PackedFloat64Array = _native.sample_batch_true_prepared(points)
		_check(batch.size() == count * S_STRIDE, "%s cold stride N=%d" % [SeaStateScript.state_name(state), count])
		_compare_flat("%s cold N=%d" % [SeaStateScript.state_name(state), count], direct, batch, S_STRIDE)
		var again: PackedFloat64Array = _native.sample_batch_true_prepared(points)
		_compare_flat("%s determinism N=%d" % [SeaStateScript.state_name(state), count], batch, again, S_STRIDE)
		var hist: PackedInt32Array = _native.get_diag_last_newton_histogram()
		_check(hist.size() == 5 and hist[0] + hist[1] + hist[2] + hist[3] + hist[4] == count,
			"%s histograma N=%d" % [SeaStateScript.state_name(state), count])


func _validate_warm_sequence(state: int) -> void:
	var previous := _positions(16, Vector3(-8.0, 0.0, 3.0), 0.0)
	var warm_q := PackedVector3Array() # primer tick: guess inválido => world.
	var max_warm_delta := 0.0
	for tick in 120:
		var t := float(tick) / 60.0
		var yaw := 0.012 * float(tick) + 0.00012 * float(tick * tick)
		var current := _positions(16, Vector3(-8.0 + 0.13 * tick, 0.0, 3.0 + 0.04 * tick), yaw)
		# Predictor temporal exigido: q_prev + (world_actual - world_prev).
		var guess := PackedVector3Array()
		if warm_q.size() == current.size():
			for i in current.size():
				guess.append(warm_q[i] + (current[i] - previous[i]))
		_native.ensure_prepared(t)
		var direct: PackedFloat64Array = _native.sample_batch_prepared(current)
		var cold: PackedFloat64Array = _native.sample_batch_true_prepared(current)
		var warm: PackedFloat64Array = _native.sample_batch_warm_prepared(current, guess)
		_compare_flat("%s temporal cold tick=%d" % [SeaStateScript.state_name(state), tick], direct, cold, S_STRIDE)
		_check(warm.size() == 16 * WARM_STRIDE, "%s warm stride tick=%d" % [SeaStateScript.state_name(state), tick])
		if warm_q.size() != current.size():
			warm_q.resize(current.size())
		for i in 16:
			for field in S_STRIDE:
				var delta := absf(direct[i * S_STRIDE + field] - warm[i * WARM_STRIDE + field])
				if field >= 1 and field <= 11:
					max_warm_delta = maxf(max_warm_delta, delta)
				if field in [0, 12] and (direct[i * S_STRIDE + field] > 0.5) != (warm[i * WARM_STRIDE + field] > 0.5):
					_check(false, "%s warm signo/valid mismatch tick=%d point=%d field=%d" % [SeaStateScript.state_name(state), tick, i, field])
					return
				if field == 13 and warm[i * WARM_STRIDE + field] > 1.0e-3:
					_check(false, "%s warm residual fuera de contrato tick=%d point=%d" % [SeaStateScript.state_name(state), tick, i])
					return
			warm_q[i] = Vector3(warm[i * WARM_STRIDE + S_STRIDE], 0.0, warm[i * WARM_STRIDE + S_STRIDE + 1])
		previous = current
	_check(true, "%s temporal warm/direct 120 ticks max_delta=%s" % [SeaStateScript.state_name(state), String.num_scientific(max_warm_delta)])


func _validate_sea_level(state: int) -> void:
	_native.set_sea_level(4.25)
	_native.ensure_prepared(1.5)
	var points := _positions(8, Vector3(2.0, 0.0, 5.0), 0.2)
	var direct: PackedFloat64Array = _native.sample_batch_prepared(points)
	var batch: PackedFloat64Array = _native.sample_batch_true_prepared(points)
	_compare_flat("%s sea-level" % SeaStateScript.state_name(state), direct, batch, S_STRIDE)
	_native.set_sea_level(0.0)


func _compare_flat(label: String, expected: PackedFloat64Array, actual: PackedFloat64Array, stride: int) -> void:
	if expected.size() != actual.size():
		_check(false, "%s: tamaño distinto" % label)
		return
	for i in expected.size():
		if absf(expected[i] - actual[i]) > EPS:
			_check(false, "%s: diff %.3e index=%d field=%d" % [label, absf(expected[i] - actual[i]), i, i % stride])
			return
	_check(true, label)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

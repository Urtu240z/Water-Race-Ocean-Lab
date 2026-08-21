extends SceneTree
## Fase 2C.1C: dispatch AVX2, fallback scalar y precisión contra DIRECT.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const SEED := 20260820
const STRIDE := 15
const COUNTS := [1, 4, 8, 16, 32, 64]

var _native = null
var _failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		print("PHASE_2C_1C_AVX2: SKIP (OceanQueryNative no disponible)")
		quit(0)
		return
	_native = ClassDB.instantiate(&"OceanQueryNative")
	var supported: bool = _native.get_cpu_supports_avx2()
	print("PHASE_2C_1C_AVX2 CPU support=", supported)
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		_setup(_build_reduced(state))
		_validate_dispatch(state, supported)
		_validate_accuracy(state, supported)
		_validate_sea_level(state, supported)
	if _failures == 0:
		print("PHASE_2C_1C_AVX2: PASS")
		quit(0)
	else:
		push_error("PHASE_2C_1C_AVX2: %d fallos" % _failures)
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


func _setup(reduced) -> void:
	_native.clear()
	_native.set_sea_level(0.0)
	for cascade in reduced.get_cascades_compact():
		_native.set_cascade_data(cascade.index, cascade.inv_n2, cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2, cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight, cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	_native.finalize_spectrum()


func _positions() -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in 64:
		points.append(Vector3(-31.0 + float(i % 8) * 8.7, 0.0, 47.0 - float(i / 8) * 7.1))
	return points


func _validate_dispatch(state: int, supported: bool) -> void:
	_native.set_force_scalar(true)
	_check(_native.get_query_execution_backend() == "SCALAR", "%s force scalar backend" % SeaStateScript.state_name(state))
	_native.set_force_scalar(false)
	if supported:
		_check(_native.get_query_execution_backend() == "AVX2", "%s AVX2 dispatch" % SeaStateScript.state_name(state))
	else:
		_check(_native.get_query_execution_backend() == "SCALAR", "%s CPU fallback" % SeaStateScript.state_name(state))


func _validate_accuracy(state: int, supported: bool) -> void:
	var points := _positions()
	for time in [0.0, 1.3, 3.5]:
		_native.ensure_prepared(time)
		for count in COUNTS:
			var subset := PackedVector3Array()
			for i in count:
				subset.append(points[i])
			_native.set_force_scalar(true)
			var scalar: PackedFloat64Array = _native.sample_batch_prepared(subset)
			_native.set_force_scalar(false)
			var simd: PackedFloat64Array = _native.sample_batch_prepared(subset)
			_check(simd.size() == count * STRIDE, "%s N=%d stride" % [SeaStateScript.state_name(state), count])
			if supported:
				_compare_samples("%s t=%.1f N=%d" % [SeaStateScript.state_name(state), time, count], scalar, simd)
				var repeat: PackedFloat64Array = _native.sample_batch_prepared(subset)
				for k in repeat.size():
					if absf(repeat[k] - simd[k]) > 1.0e-12:
						_check(false, "%s AVX2 no determinista index=%d" % [SeaStateScript.state_name(state), k])
						return
				_check(true, "%s AVX2 determinista N=%d" % [SeaStateScript.state_name(state), count])


func _validate_sea_level(state: int, supported: bool) -> void:
	var points := _positions()
	_native.set_sea_level(6.5)
	_native.ensure_prepared(2.1)
	_native.set_force_scalar(true)
	var scalar: PackedFloat64Array = _native.sample_batch_prepared(points.slice(0, 16))
	_native.set_force_scalar(false)
	var simd: PackedFloat64Array = _native.sample_batch_prepared(points.slice(0, 16))
	if supported:
		_compare_samples("%s sea level" % SeaStateScript.state_name(state), scalar, simd)
	_native.set_sea_level(0.0)


func _compare_samples(label: String, scalar: PackedFloat64Array, simd: PackedFloat64Array) -> void:
	for i in scalar.size() / STRIDE:
		var b := i * STRIDE
		_check(absf(scalar[b + 1] - simd[b + 1]) <= 0.001, "%s height p=%d" % [label, i])
		_check(absf(scalar[b + 2] - simd[b + 2]) <= 0.001 and absf(scalar[b + 4] - simd[b + 4]) <= 0.001, "%s horiz p=%d" % [label, i])
		var dot := clampf(scalar[b + 5] * simd[b + 5] + scalar[b + 6] * simd[b + 6] + scalar[b + 7] * simd[b + 7], -1.0, 1.0)
		_check(rad_to_deg(acos(dot)) <= 0.10, "%s normal p=%d" % [label, i])
		_check(absf(scalar[b + 8] - simd[b + 8]) <= 0.01 and absf(scalar[b + 9] - simd[b + 9]) <= 0.01 and absf(scalar[b + 10] - simd[b + 10]) <= 0.01, "%s velocity p=%d" % [label, i])
		_check(absf(scalar[b + 11] - simd[b + 11]) <= 0.002, "%s detJ p=%d" % [label, i])
		_check(simd[b + 13] <= 0.001, "%s residual p=%d" % [label, i])
		_check((scalar[b] > 0.5) == (simd[b] > 0.5), "%s valid p=%d" % [label, i])
		_check((scalar[b + 12] > 0.5) == (simd[b + 12] > 0.5), "%s fold p=%d" % [label, i])


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

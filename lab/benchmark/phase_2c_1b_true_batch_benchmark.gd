extends SceneTree
## E2E GDExtension 2C.1B. No cambia el backend por defecto del juego.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const SEED := 20260820
const REPS := 5
const COUNTS := [1, 4, 8, 16, 32, 64]


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		print("PHASE_2C_1B_E2E: SKIP (OceanQueryNative no disponible)")
		quit(0)
		return
	var native = ClassDB.instantiate(&"OceanQueryNative")
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		_setup(native, _build_reduced(state))
		native.ensure_prepared(3.5)
		var positions := _positions()
		for count in COUNTS:
			var subset := PackedVector3Array()
			for i in count:
				subset.append(positions[i])
			print("2C.1B E2E %s N=%d direct=%.3f cold=%.3f warm=%.3f ms" % [
				SeaStateScript.state_name(state), count,
				_median(func(): native.sample_batch_prepared(subset)),
				_median(func(): native.sample_batch_true_prepared(subset)),
				_median(func(): native.sample_batch_warm_prepared(subset, PackedVector3Array()))])
	quit(0)


func _median(callable: Callable) -> float:
	var times: Array[float] = []
	for rep in REPS:
		var start := Time.get_ticks_usec()
		callable.call()
		times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	times.sort()
	return times[REPS / 2]


func _positions() -> PackedVector3Array:
	var result := PackedVector3Array()
	for i in 64:
		result.append(Vector3(-10.0 + float(i % 8) * 2.8, 0.0, -10.0 + float(i / 8) * 2.8))
	return result


func _build_reduced(state: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var reduced = preload("res://ocean_v3/physics/ocean_query_reduced.gd").new()
	reduced.set_budget(1024, 1024, 1024)
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _setup(native, reduced) -> void:
	native.clear()
	for cascade in reduced.get_cascades_compact():
		native.set_cascade_data(cascade.index, cascade.inv_n2, cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2, cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight, cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	native.finalize_spectrum()

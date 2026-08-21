extends SceneTree
## E2E AVX2 2C.1C: instancias separadas por modo para evitar contaminación.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const SEED := 20260820
const REPS := 7


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		print("PHASE_2C_1C_E2E: SKIP (OceanQueryNative no disponible)")
		quit(0)
		return
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var reduced = _build_reduced(state)
		for count in [16, 64]:
			var scalar := _measure(reduced, count, true)
			var avx2 := _measure(reduced, count, false)
			print("2C.1C E2E %s N=%d scalar=%.3f AVX2=%.3f speedup=%.2f backend=%s" % [
				SeaStateScript.state_name(state), count, scalar.time_ms, avx2.time_ms,
				scalar.time_ms / maxf(avx2.time_ms, 0.0001), avx2.backend])
	quit(0)


func _measure(reduced, count: int, force_scalar: bool) -> Dictionary:
	var native = ClassDB.instantiate(&"OceanQueryNative")
	_setup(native, reduced)
	native.set_force_scalar(force_scalar)
	native.ensure_prepared(3.5)
	var points := PackedVector3Array()
	for i in count:
		points.append(Vector3(-10.0 + float(i % 8) * 2.8, 0.0, -10.0 + float(i / 8) * 2.8))
	for warmup in 3:
		native.sample_batch_prepared(points)
	var times: Array[float] = []
	for rep in REPS:
		var start := Time.get_ticks_usec()
		native.sample_batch_prepared(points)
		times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	times.sort()
	return {"time_ms": times[REPS / 2], "backend": native.get_query_execution_backend()}


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
	for cascade in reduced.get_cascades_compact():
		native.set_cascade_data(cascade.index, cascade.inv_n2, cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2, cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight, cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	native.finalize_spectrum()

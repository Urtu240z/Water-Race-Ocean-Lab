extends SceneTree
## Benchmark de Fase 2C: compara REDUCED GDScript vs NATIVE en la MISMA
## ejecuciÃ³n (si la DLL estÃ¡ disponible). Si no, SKIP.
##
## El benchmark nativo REAL de referencia (core C++ independiente) se ejecuta
## con: native/ocean_query/bench/build_bench.bat + bench_main.exe.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const SEED := 20260820
const REPETITIONS := 5
const COUNTS := [1, 4, 8, 16, 32, 64]


func _initialize() -> void:
	var native = null
	# Godot registra la GDExtension al arrancar si existe; aquí sólo ClassDB.
	if ClassDB.class_exists(&"OceanQueryNative"):
		native = ClassDB.instantiate(&"OceanQueryNative")
	if native == null:
		print("PHASE_2C_NATIVE_BENCHMARK: SKIP (OceanQueryNative no disponible; usar el core C++ independiente en native/ocean_query/bench)")
		quit(0)
		return
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var reduced = _build_reduced(state)
		_setup_native(native, reduced)
		_benchmark(reduced, native, state_name)
	quit(0)


func _build_reduced(state: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var reduced = QueryReducedScript.new()
	reduced.set_budget(1024, 1024, 1024)
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _setup_native(native, reduced) -> void:
	native.clear()
	for cascade in reduced.get_cascades_compact():
		native.set_cascade_data(
			cascade.index, cascade.inv_n2,
			cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2,
			cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight,
			cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	native.finalize_spectrum()


func _benchmark(reduced, native, state_name: String) -> void:
	var positions := PackedVector3Array()
	for i in 64:
		positions.append(Vector3(-10.0 + float(i % 8) * 2.8, 0.0, -10.0 + float(i / 8) * 2.8))
	# prepare (GDScript vs native).
	var start := Time.get_ticks_usec()
	for rep in REPETITIONS:
		reduced.prepare_time(1.0 + rep)
	var gd_prepare := float(Time.get_ticks_usec() - start) / float(REPETITIONS) / 1000.0
	start = Time.get_ticks_usec()
	for rep in REPETITIONS:
		native.ensure_prepared(1.0 + rep)
	var nat_prepare := float(Time.get_ticks_usec() - start) / float(REPETITIONS) / 1000.0
	print("2C BENCH %s prepare_ms GDS=%.3f NAT=%.3f (x%.1f)" % [state_name, gd_prepare, nat_prepare, gd_prepare / maxf(nat_prepare, 0.0001)])
	# queries preparadas.
	reduced.prepare_time(3.5)
	native.ensure_prepared(3.5)
	for count in COUNTS:
		var gd_times: Array[float] = []
		var nat_times: Array[float] = []
		for rep in REPETITIONS:
			start = Time.get_ticks_usec()
			for i in count:
				reduced.sample_water_prepared(Vector3(positions[i].x, 0.0, positions[i].z))
			gd_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
			start = Time.get_ticks_usec()
			for i in count:
				native.sample_prepared(positions[i].x, positions[i].z)
			nat_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		gd_times.sort()
		nat_times.sort()
		var gd := gd_times[REPETITIONS / 2]
		var nat := nat_times[REPETITIONS / 2]
		print("2C BENCH %s queries %2d ms GDS=%.3f NAT=%.3f (x%.1f)" % [state_name, count, gd, nat, gd / maxf(nat, 0.0001)])


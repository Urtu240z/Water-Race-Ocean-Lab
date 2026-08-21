extends SceneTree
## Benchmark de Fase 2C: compara REDUCED GDScript vs NATIVE en la MISMA
## ejecución (si la DLL está disponible). Si no, SKIP.
##
## El benchmark nativo REAL de referencia (core C++ independiente) se ejecuta
## con: native/ocean_query/bench/build_bench.bat + bench_main.exe.
##
## METODOLOGÍA (v3): los counts NATIVE de AMBOS estados se miden primero, y
## después los GDS. Se ha verificado que medir el backend NATIVE después de una
## fase GDScript pesada en el mismo proceso lo degrada ~2-4x (estado térmico /
## asignador del proceso): ROUGH native daba 9.3ms @16 medido tras la fase GDS
## vs 2.26ms aislado, mientras el core standalone confirmaba 2.29ms. Con este
## orden, los números NATIVE reproducen el core standalone y los GDS se miden
## con el mismo estado térmico acumulado (comparación GDS/NAT válida).

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
	var states: Array[int] = [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]
	var reducers: Array = []
	for state in states:
		var reduced = _build_reduced(state)
		_setup_native(native, reduced)
		reducers.append(reduced)
	# 1) NATIVE primero: todos los counts de ambos estados, sin fase GDS previa.
	var native_medians: Array[Array] = []
	for idx in states.size():
		var state_name := SeaStateScript.state_name(states[idx])
		var positions := _positions()
		native.ensure_prepared(3.5)
		for i in 64:
			var _warm = native.sample_prepared(positions[i].x, positions[i].z)
		var per_state: Array[float] = []
		for count in COUNTS:
			var nat_times: Array[float] = []
			for rep in REPETITIONS:
				var start := Time.get_ticks_usec()
				for i in count:
					var _d = native.sample_prepared(positions[i].x, positions[i].z)
				nat_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
			nat_times.sort()
			per_state.append(nat_times[REPETITIONS / 2])
		native_medians.append(per_state)
		print("2C BENCH %s queries NAT ms %s" % [state_name, _fmt(per_state)])
	# prepare GDScript vs native (por estado, barato).
	for idx in states.size():
		var state_name := SeaStateScript.state_name(states[idx])
		var reduced = reducers[idx]
		var start := Time.get_ticks_usec()
		for rep in REPETITIONS:
			reduced.prepare_time(1.0 + rep)
		var gd_prepare := float(Time.get_ticks_usec() - start) / float(REPETITIONS) / 1000.0
		start = Time.get_ticks_usec()
		for rep in REPETITIONS:
			native.ensure_prepared(1.0 + rep)
		var nat_prepare := float(Time.get_ticks_usec() - start) / float(REPETITIONS) / 1000.0
		print("2C BENCH %s prepare_ms GDS=%.3f NAT=%.3f (x%.1f)" % [state_name, gd_prepare, nat_prepare, gd_prepare / maxf(nat_prepare, 0.0001)])
	# 2) GDS después: todos los counts de ambos estados.
	for idx in states.size():
		var state_name := SeaStateScript.state_name(states[idx])
		var reduced = reducers[idx]
		var positions := _positions()
		reduced.prepare_time(3.5)
		var gd_medians: Array[float] = []
		for count in COUNTS:
			var gd_times: Array[float] = []
			for rep in REPETITIONS:
				var start := Time.get_ticks_usec()
				for i in count:
					reduced.sample_water_prepared(Vector3(positions[i].x, 0.0, positions[i].z))
				gd_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
			gd_times.sort()
			gd_medians.append(gd_times[REPETITIONS / 2])
		print("2C BENCH %s queries GDS ms %s" % [state_name, _fmt(gd_medians)])
		for ci in COUNTS.size():
			var gd: float = gd_medians[ci]
			var nat: float = native_medians[idx][ci]
			print("2C BENCH %s queries %2d ms GDS=%.3f NAT=%.3f (x%.1f)" % [state_name, COUNTS[ci], gd, nat, gd / maxf(nat, 0.0001)])
	quit(0)


func _fmt(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append("%.3f" % v)
	return ", ".join(parts)


func _positions() -> PackedVector3Array:
	var positions := PackedVector3Array()
	for i in 64:
		positions.append(Vector3(-10.0 + float(i % 8) * 2.8, 0.0, -10.0 + float(i / 8) * 2.8))
	return positions


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

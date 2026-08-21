extends SceneTree
## Benchmark de producción de OceanQueryReduced (Fase 2B).
##
## Mide por separado:
##  A. coste de prepare_time (preparación temporal del espectro).
##  B. coste de query con tiempo ya preparado: 1/4/8/16/32/64 queries world.
##  C. individual vs batch.
## Estados RACE y ROUGH, posiciones en una zona ~20×20 m, warmup, varias
## repeticiones y MEDIANA. No declara GPU ms.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const REPETITIONS := 5
const WARMUP_QUERIES := 4
const QUERY_COUNTS := [1, 4, 8, 16, 32, 64]
const BUDGETS := [1024, 1024, 1024]


func _initialize() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var reduced = _build_reduced(state)
		print("=== 2B BENCHMARK %s (pairs=%s) ===" % [state_name, str(reduced.selected_pair_counts())])
		_benchmark_rebuild(state, state_name)
		_benchmark_prepare(reduced, state_name)
		_benchmark_queries(reduced, state_name)
	quit(0)


func _benchmark_rebuild(state: int, state_name: String) -> void:
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(20260820, config.id)))
	var reduced = QueryReducedScript.new()
	var start := Time.get_ticks_usec()
	reduced.set_spectrum(configs, h0_datas)
	var rebuild_ms := float(Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	reduced.set_budget(1024, 1024, 1024)
	var selection_ms := float(Time.get_ticks_usec() - start) / 1000.0
	print("2B BENCHMARK %s | set_spectrum (rebuild+selección) = %.1f ms | set_budget (re-selección) = %.3f ms" % [state_name, rebuild_ms, selection_ms])


func _build_reduced(state: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(20260820, config.id)))
	var reduced = QueryReducedScript.new()
	reduced.set_budget(BUDGETS[0], BUDGETS[1], BUDGETS[2])
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _benchmark_prepare(reduced, state_name: String) -> void:
	var start := Time.get_ticks_usec()
	for rep in REPETITIONS:
		reduced.prepare_time(1.0 + float(rep))
		reduced.prepare_time(1.0 + float(rep)) # cacheado (segunda llamada)
	var elapsed := float(Time.get_ticks_usec() - start) / 1000.0
	print("2B BENCHMARK %s | prepare_time (media, incl. cache) = %.3f ms" % [state_name, elapsed / float(REPETITIONS)])


func _benchmark_queries(reduced, state_name: String) -> void:
	var positions: Array[Vector3] = []
	for i in 64:
		positions.append(Vector3(-10.0 + float(i % 8) * 2.8, 0.0, -10.0 + float(i / 8) * 2.8))
	reduced.prepare_time(3.5)
	# Calentamiento.
	for i in WARMUP_QUERIES:
		reduced.sample_water_prepared(positions[i])
	for count in QUERY_COUNTS:
		var times: Array[float] = []
		for rep in REPETITIONS:
			var start := Time.get_ticks_usec()
			for i in count:
				reduced.sample_water_prepared(positions[i])
			times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		times.sort()
		print("2B BENCHMARK %s | %2d queries = %.3f ms (mediana) | %.3f ms/query" % [state_name, count, times[REPETITIONS / 2], times[REPETITIONS / 2] / float(count)])
	# Batch.
	var batch_times: Array[float] = []
	for rep in REPETITIONS:
		var start := Time.get_ticks_usec()
		var batch = reduced.sample_water_batch_prepared(positions.slice(0, 16))
		batch_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	batch_times.sort()
	print("2B BENCHMARK %s | batch 16 = %.3f ms (mediana) | invalid=%d last_iter=%d" % [state_name, batch_times[REPETITIONS / 2], reduced.diagnostic_non_converged, reduced.diagnostic_last_iterations])

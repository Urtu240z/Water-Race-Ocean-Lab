extends SceneTree
## Herramienta de Fase 2C: vierte los arrays compactos de OceanQueryReduced a
## ficheros de texto para el benchmark C++ independiente (bench_main) y mide el
## tiempo GDScript equivalente. Uso: godot --headless --script res://native/ocean_query/bench/dump_data.gd

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const DATA_DIR := "res://native/ocean_query/bench/"
const BUDGETS := [1024, 1024, 1024]
const SEED := 20260820
const POSITIONS: Array[Vector3] = [
	Vector3(-10.0, 0.0, -10.0), Vector3(-7.2, 0.0, -10.0), Vector3(-4.4, 0.0, -10.0), Vector3(-1.6, 0.0, -10.0),
	Vector3(1.2, 0.0, -10.0), Vector3(4.0, 0.0, -10.0), Vector3(6.8, 0.0, -10.0), Vector3(9.6, 0.0, -10.0),
	Vector3(-10.0, 0.0, -7.2), Vector3(-7.2, 0.0, -7.2), Vector3(-4.4, 0.0, -7.2), Vector3(-1.6, 0.0, -7.2),
	Vector3(1.2, 0.0, -7.2), Vector3(4.0, 0.0, -7.2), Vector3(6.8, 0.0, -7.2), Vector3(9.6, 0.0, -7.2),
]


func _initialize() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var reduced = _build_reduced(state)
		_dump_state(reduced, state_name)
		_benchmark_gdscript(reduced, state_name)
	print("DUMP_DONE")
	quit(0)


func _build_reduced(state: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var reduced = QueryReducedScript.new()
	reduced.set_budget(BUDGETS[0], BUDGETS[1], BUDGETS[2])
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _line(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append(str(v))
	return " ".join(parts)


func _dump_state(reduced, state_name: String) -> void:
	var data_path := DATA_DIR + "data_%s.txt" % state_name.to_lower()
	var ref_path := DATA_DIR + "ref_%s.txt" % state_name.to_lower()
	var cascades = reduced.get_cascades_compact()
	var data := FileAccess.open(data_path, FileAccess.WRITE)
	var ref := FileAccess.open(ref_path, FileAccess.WRITE)
	if data == null or ref == null:
		push_error("dump: no se pudo escribir en %s" % data_path)
		return
	data.store_line(_line([cascades.size(), 0.0]))
	for cascade in cascades:
		data.store_line(_line([cascade.index, cascade.inv_n2, cascade.kx.size()]))
		data.store_line(_line(cascade.kx))
		data.store_line(_line(cascade.ky))
		data.store_line(_line(cascade.omega))
		data.store_line(_line(cascade.a1))
		data.store_line(_line(cascade.a2))
		data.store_line(_line(cascade.c11))
		data.store_line(_line(cascade.c12))
		data.store_line(_line(cascade.c21))
		data.store_line(_line(cascade.c22))
		data.store_line(_line(cascade.parity))
		data.store_line(_line(cascade.weight))
		data.store_line(_line(cascade.h0_re))
		data.store_line(_line(cascade.h0_im))
		data.store_line(_line(cascade.h0n_re))
		data.store_line(_line(cascade.h0n_im))
	data.close()
	# Referencia GDScript (16 posiciones, t=3.5) en el mismo formato de salida.
	reduced.prepare_time(3.5)
	for i in 16:
		var s = reduced.sample_water_prepared(POSITIONS[i])
		var out := [
			"1" if s.valid else "0", s.height, s.displacement.x, s.displacement.y, s.displacement.z,
			s.normal.x, s.normal.y, s.normal.z, s.surface_velocity.x, s.surface_velocity.y, s.surface_velocity.z,
			s.jacobian_det, "1" if s.foldover_risk else "0", s.query_residual_m, s.query_iterations,
		]
		ref.store_line(_line(out))
	ref.close()
	print("DUMP %s: %s (%d pares)" % [state_name, data_path.get_file(), reduced.selected_pair_counts()])


func _benchmark_gdscript(reduced, state_name: String) -> void:
	reduced.prepare_time(3.5)
	var start := Time.get_ticks_usec()
	for rep in 5:
		reduced.prepare_time(1.0 + rep)
		reduced.prepare_time(1.0 + rep)
	var prepare_ms := float(Time.get_ticks_usec() - start) / 5000.0
	print("GDS_BENCH %s prepare_time_ms %.4f" % [state_name, prepare_ms])
	for count in [1, 4, 8, 16, 32, 64]:
		var times: Array[float] = []
		for rep in 5:
			start = Time.get_ticks_usec()
			for i in count:
				reduced.sample_water_prepared(POSITIONS[i % 16])
			times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		times.sort()
		print("GDS_BENCH %s individual %d %.4f" % [state_name, count, times[2]])

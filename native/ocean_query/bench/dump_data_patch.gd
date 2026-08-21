extends SceneTree
## Herramienta de Fase 2C.1A: vierte los arrays compactos de OceanQueryReduced a
## ficheros de texto para el benchmark PATCH C++ independiente (bench_patch_main).
## Genera 2 seeds × 2 estados con el MISMO formato que dump_data.gd de 2C.
## Uso: godot --headless --script res://native/ocean_query/bench/dump_data_patch.gd

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const DATA_DIR := "res://native/ocean_query/bench/"
const BUDGETS := [1024, 1024, 1024]
const SEEDS := [20260820, 20260821]


func _initialize() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		for seed in SEEDS:
			var reduced = _build_reduced(state, seed)
			_dump_state(reduced, state_name, seed)
	print("DUMP_PATCH_DONE")
	quit(0)


func _build_reduced(state: int, seed: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(seed, config.id)))
	var reduced = QueryReducedScript.new()
	reduced.set_budget(BUDGETS[0], BUDGETS[1], BUDGETS[2])
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _line(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append(str(v))
	return " ".join(parts)


func _dump_state(reduced, state_name: String, seed: int) -> void:
	var data_path := DATA_DIR + "data_%s_%d.txt" % [state_name.to_lower(), seed]
	var cascades = reduced.get_cascades_compact()
	var data := FileAccess.open(data_path, FileAccess.WRITE)
	if data == null:
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
	print("DUMP_PATCH %s seed=%d: %s (%d pares)" % [state_name, seed, data_path.get_file(), reduced.selected_pair_counts()])

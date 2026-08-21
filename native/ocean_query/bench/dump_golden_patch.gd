extends SceneTree
## Herramienta de Fase 2C.1A: evalúa la GOLDEN REFERENCE (OceanQueryReference,
## todos los modos de las tres cascadas, 3×N²) en las queries volcadas por
## bench_patch_main --dump-queries, y escribe el ref en el formato stride-15.
## Uso:
##   godot --headless --script res://native/ocean_query/bench/dump_golden_patch.gd -- <data_tag> <queries_file> <ref_file>
## donde <data_tag> es "race_20260820", "rough_20260821", etc.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryReferenceScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")

const BUDGETS := [1024, 1024, 1024] # solo para el patch; el GOLDEN usa todos los modos


func _initialize() -> void:
	var data_tag := ""
	var queries_path := ""
	var ref_path := ""
	var args := OS.get_cmdline_user_args()
	if args.size() >= 3:
		data_tag = args[0]
		queries_path = args[1]
		ref_path = args[2]
	else:
		print("uso: -- <data_tag> <queries_file> <ref_file>")
		quit(1)
		return
	var state := SeaStateScript.State.RACE if data_tag.begins_with("race") else SeaStateScript.State.ROUGH
	var seed := int(data_tag.get_slice("_", 1))
	var state_name := SeaStateScript.state_name(state)

	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(seed, config.id)))
	var golden := QueryReferenceScript.new()
	golden.set_spectrum(configs, h0_datas)

	var qf := FileAccess.open(queries_path, FileAccess.READ)
	var rf := FileAccess.open(ref_path, FileAccess.WRITE)
	if qf == null or rf == null:
		push_error("dump_golden: no se pudo abrir queries/ref")
		quit(1)
		return
	var n := 0
	while not qf.eof_reached():
		var line := qf.get_line()
		if line.strip_edges().is_empty():
			continue
		var parts := line.split(" ")
		if parts.size() < 3:
			continue
		var t := float(parts[0])
		var wx := float(parts[1])
		var wz := float(parts[2])
		var s = golden.sample_water(Vector3(wx, 0.0, wz), t)
		var out := [
			"1" if s.valid else "0", s.height, s.displacement.x, s.displacement.y, s.displacement.z,
			s.normal.x, s.normal.y, s.normal.z, s.surface_velocity.x, s.surface_velocity.y, s.surface_velocity.z,
			s.jacobian_det, "1" if s.foldover_risk else "0", s.query_residual_m, s.query_iterations,
		]
		rf.store_line(_line(out))
		n += 1
	qf.close()
	rf.close()
	print("GOLDEN_DUMP %s %s: %d queries" % [state_name, data_tag, n])
	quit(0)


func _line(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append(str(v))
	return " ".join(parts)

extends SceneTree
## ValidaciÃ³n rÃ¡pida de Fase 2B: OceanQueryReduced (pares Â±k, FULL_PAIRS,
## selecciÃ³n por importancia, world-space, batch). Cubre Aâ€“N de la
## especificaciÃ³n. CPU pura + un pequeÃ±o smoke runtime del mÃ³dulo.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QualityScript := preload("res://ocean_v3/core/ocean_quality_settings.gd")
const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const QueryRefScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const SampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")

const _SEED := 20260820
const _POS := Vector3(37.5, 0.0, -12.25)
const _TIME := 1.75

var _failures := 0
var _frame := 0
var _runtime_checked := false


func _initialize() -> void:
	_validate_lambda_regression()
	_validate_flat_spectrum()
	_validate_single_wave_pairs()
	_validate_full_pairs_equals_golden_synthetic()
	_validate_full_pairs_equals_golden_race()
	_validate_deterministic_selection()
	_validate_seed_changes()
	_validate_world_round_trip()
	_validate_sea_level()
	_validate_prepared_caching()
	_validate_quality_profile_invariance()
	_validate_no_readback_source()
	_validate_no_per_query_allocations()
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3 and not _runtime_checked:
		_runtime_checked = true
		_validate_runtime_module()
		_finish()
	return false


func _small_config(n: int, domain: float, choppiness := 1.0):
	var config := ConfigScript.new()
	config.resolution = n
	config.domain_size_m = domain
	config.gravity_mps2 = 9.81
	config.choppiness = choppiness
	config.target_hs_m = 1.0
	config.min_wavelength_m = 0.5
	config.max_wavelength_m = domain * 0.7
	return config


func _build_spectrum_state(state: int, simulation_seed: int) -> Array:
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id)))
	return [configs, h0_datas]


# N. Lambda negativa formalizada (regression).
func _validate_lambda_regression() -> void:
	var source := _read_file("res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl")
	_check(source.contains("float lambda = -params.values.z"), "N: lambda negativa formalizada en evolve shader")


# C. Espectro plano.
func _validate_flat_spectrum() -> void:
	var config = _small_config(16, 32.0)
	var h0 := PackedFloat32Array()
	h0.resize(16 * 16 * 4)
	var reduced = QueryReducedScript.new()
	reduced.set_mode(QueryReducedScript.MODE_FULL_PAIRS)
	reduced.set_spectrum([config], [h0.to_byte_array()])
	var sample = reduced.sample_water(_POS, _TIME)
	_check(sample.valid, "C: plano vÃ¡lido")
	_check(sample.height == 0.0, "C: height 0 plano")
	_check(sample.displacement == Vector3.ZERO, "C: displacement 0 plano")
	_check(sample.normal == Vector3.UP, "C: normal UP plano")
	_check(sample.surface_velocity == Vector3.ZERO, "C: velocity 0 plano")
	_check(sample.jacobian_det == 1.0, "C: detJ 1 plano")


# B. Onda Ãºnica +k/-k (compresiÃ³n de pares) contra forma cerrada.
func _validate_single_wave_pairs() -> void:
	var n := 8
	var domain := 16.0
	var config = _small_config(n, domain)
	var half := n / 2
	var floats := PackedFloat32Array()
	floats.resize(n * n * 4)
	var index_plus := half * n + (half + 1)
	var index_minus := half * n + (half - 1)
	floats[index_plus * 4] = 1.0
	floats[index_plus * 4 + 2] = 1.0
	floats[index_minus * 4] = 1.0
	floats[index_minus * 4 + 2] = 1.0
	var reduced = QueryReducedScript.new()
	reduced.set_mode(QueryReducedScript.MODE_FULL_PAIRS)
	reduced.set_spectrum([config], [floats.to_byte_array()])
	var counts := reduced.selected_pair_counts()
	_check(counts.size() == 1 and counts[0] == 40, "B: nº de pares canónicos (N=8 -> 40, got %s)" % str(counts))

	var kx := TAU / domain
	var omega := sqrt(9.81 * kx)
	var inv16 := 1.0 / 16.0
	var t := 0.0
	for qx: float in [0.0, 2.0, 4.0, 6.0]:
		var expected_h := -inv16 * cos(omega * t) * cos(kx * qx)
		var expected_dx := inv16 * cos(omega * t) * sin(kx * qx)
		var world_x := qx + expected_dx
		var sample = reduced.sample_water(Vector3(world_x, 0.0, 0.0), t)
		_check(is_equal_approx(sample.height, expected_h), "B: pares single-wave height (%.6f ≈ %.6f)" % [sample.height, expected_h])
		_check(is_equal_approx(sample.displacement.x, expected_dx), "B: pares single-wave Dx (%.6f ≈ %.6f)" % [sample.displacement.x, expected_dx])
		_check(is_equal_approx(sample.displacement.z, 0.0), "B: pares single-wave Dz 0")


# A. FULL_PAIRS â‰¡ Golden en caso sintÃ©tico (paramÃ©trico, varias q/t).
func _validate_full_pairs_equals_golden_synthetic() -> void:
	var config = _small_config(16, 64.0, 0.8)
	# H0 real consistente (conjugado-simÃ©trico) vÃ­a TessendorfSpectrum.
	var h0 := SpectrumScript.build_h0_rgba32f(config, 12345)
	var golden = QueryRefScript.new()
	golden.set_spectrum([config], [h0])
	var reduced = QueryReducedScript.new()
	reduced.set_mode(QueryReducedScript.MODE_FULL_PAIRS)
	reduced.set_spectrum([config], [h0])
	for t: float in [0.0, 0.7, 3.1]:
		for q in [Vector3(2.0, 0.0, 5.0), Vector3(11.0, 0.0, -7.0), Vector3(-13.0, 0.0, 21.0)]:
			var g = golden.sample_water(q, t)
			var r = reduced.sample_water(q, t)
			_check(g.valid and r.valid, "A: samples vÃ¡lidos (q=%s t=%.1f)" % [q, t])
			_check(absf(r.height - g.height) < 1.0e-9, "A: FULL_PAIRS height â‰¡ Golden (%s)" % String.num_scientific(absf(r.height - g.height)))
			_check(r.displacement.distance_to(g.displacement) < 1.0e-8, "A: FULL_PAIRS displacement â‰¡ Golden")
			_check(r.normal.distance_to(g.normal) < 1.0e-8, "A: FULL_PAIRS normal â‰¡ Golden")
			_check(r.surface_velocity.distance_to(g.surface_velocity) < 1.0e-8, "A: FULL_PAIRS velocity â‰¡ Golden")
			_check(absf(r.jacobian_det - g.jacobian_det) < 1.0e-8, "A: FULL_PAIRS detJ â‰¡ Golden")


# A. FULL_PAIRS â‰¡ Golden en RACE real (world-space, Newton).
func _validate_full_pairs_equals_golden_race() -> void:
	var spectrum := _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var golden = QueryRefScript.new()
	golden.set_spectrum(spectrum[0], spectrum[1])
	var reduced = QueryReducedScript.new()
	reduced.set_mode(QueryReducedScript.MODE_FULL_PAIRS)
	reduced.set_spectrum(spectrum[0], spectrum[1])
	for world_pos in [Vector3(10.0, 0.0, 20.0), Vector3(37.5, 0.0, -12.25)]:
		var g = golden.sample_water(world_pos, 1.3)
		var r = reduced.sample_water(world_pos, 1.3)
		_check(g.valid and r.valid, "A: RACE world samples vÃ¡lidos (%s)" % world_pos)
		_check(absf(r.height - g.height) < 1.0e-4, "A: RACE FULL_PAIRS height â‰¡ Golden (%s)" % String.num_scientific(absf(r.height - g.height)))
		_check(r.displacement.distance_to(g.displacement) < 1.0e-4, "A: RACE FULL_PAIRS displacement â‰¡ Golden")
		_check(r.normal.distance_to(g.normal) < 1.0e-4, "A: RACE FULL_PAIRS normal â‰¡ Golden")
		_check(r.surface_velocity.distance_to(g.surface_velocity) < 1.0e-4, "A: RACE FULL_PAIRS velocity â‰¡ Golden")


# D/E. SelecciÃ³n determinista: mismo H0 => mismos pares.
func _validate_deterministic_selection() -> void:
	var spectrum := _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var first = QueryReducedScript.new()
	first.set_budget(16, 12, 8)
	first.set_spectrum(spectrum[0], spectrum[1])
	var second = QueryReducedScript.new()
	second.set_budget(16, 12, 8)
	second.set_spectrum(spectrum[0], spectrum[1])
	_check(first.selected_pair_counts() == second.selected_pair_counts(), "E: mismo H0 => mismos pares seleccionados (%s)" % str(first.selected_pair_counts()))
	var s1 = first.sample_water(_POS, _TIME)
	var s2 = second.sample_water(_POS, _TIME)
	_check(is_equal_approx(s1.height, s2.height) and s1.displacement == s2.displacement, "D: selecciÃ³n determinista => samples idÃ©nticos")
	var counts := first.selected_pair_counts()
	_check(counts == [16, 12, 8], "D: presupuesto aplicado por banda (%s)" % str(counts))


# F. Seed distinta cambia amplitudes pero sigue determinista.
func _validate_seed_changes() -> void:
	var spectrum_a = _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var spectrum_b = _build_spectrum_state(SeaStateScript.State.RACE, _SEED + 1)
	var reduced_a = QueryReducedScript.new()
	reduced_a.set_budget(16, 12, 8)
	reduced_a.set_spectrum(spectrum_a[0], spectrum_a[1])
	var reduced_b = QueryReducedScript.new()
	reduced_b.set_budget(16, 12, 8)
	reduced_b.set_spectrum(spectrum_b[0], spectrum_b[1])
	var sa = reduced_a.sample_water(_POS, _TIME)
	var sb = reduced_b.sample_water(_POS, _TIME)
	_check(not is_equal_approx(sa.height, sb.height), "F: seed distinta cambia height")
	var sa2 = reduced_a.sample_water(_POS, _TIME)
	_check(is_equal_approx(sa.height, sa2.height), "F: misma seed determinista")


# G. InversiÃ³n world-space del Reduced (round-trip).
func _validate_world_round_trip() -> void:
	var spectrum := _build_spectrum_state(SeaStateScript.State.ROUGH, _SEED)
	var reduced = QueryReducedScript.new()
	reduced.set_budget(32, 24, 16)
	reduced.set_spectrum(spectrum[0], spectrum[1])
	# q conocido -> world_xz = q + Dxz(q) -> query world -> recupera q.
	for q in [Vector3(10.0, 0.0, 20.0), Vector3(50.0, 0.0, -30.0)]:
		var param = reduced.sample_parametric(q, _TIME)
		var world_xz := Vector2(q.x + param.displacement.x, q.z + param.displacement.z)
		var world = reduced.sample_water(Vector3(world_xz.x, 0.0, world_xz.y), _TIME)
		_check(world.valid, "G: world query convergida (%s, iter %d)" % [q, world.query_iterations])
		_check(world.query_residual_m <= 1.0e-3, "G: residual <= 1e-3 (%s)" % String.num_scientific(world.query_residual_m))
		_check(absf(world.height - param.height) < 1.0e-3, "G: height round-trip")
		var recovered := Vector2(world_xz.x - world.displacement.x, world_xz.y - world.displacement.z)
		_check(recovered.distance_to(Vector2(q.x, q.z)) < 2.0e-3, "G: q recuperado")


# H. Sea level.
func _validate_sea_level() -> void:
	var spectrum := _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var reduced = QueryReducedScript.new()
	reduced.set_budget(16, 12, 8)
	reduced.set_spectrum(spectrum[0], spectrum[1])
	reduced.set_sea_level(7.25)
	var sample = reduced.sample_water(Vector3(12.0, 0.0, -5.0), 1.5)
	_check(absf(sample.height - (7.25 + sample.displacement.y)) < 1.0e-6, "H: height == 7.25 + displacement.y")
	var flat = SampleScript.flat(7.25)
	_check(flat.height == 7.25 and flat.normal == Vector3.UP and flat.surface_velocity == Vector3.ZERO, "H: OFF flat 7.25")


# I. Prepared caching.
func _validate_prepared_caching() -> void:
	var spectrum := _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var reduced = QueryReducedScript.new()
	reduced.set_budget(16, 12, 8)
	reduced.set_spectrum(spectrum[0], spectrum[1])
	reduced.ensure_prepared(1.0)
	var direct = reduced.sample_water(_POS, 1.0)
	reduced.ensure_prepared(1.0)
	var cached = reduced.sample_water_prepared(_POS)
	_check(is_equal_approx(direct.height, cached.height), "I: ensure_prepared reutiliza el tiempo preparado")
	reduced.ensure_prepared(2.0)
	var later = reduced.sample_water_prepared(_POS)
	_check(not is_equal_approx(cached.height, later.height), "I: cambiar tiempo cambia el sample")


# K. Perfil de calidad no altera el reduced.
func _validate_quality_profile_invariance() -> void:
	var quality := QualityScript.new()
	var spectrum := _build_spectrum_state(SeaStateScript.State.RACE, _SEED)
	var reduced = QueryReducedScript.new()
	reduced.set_budget(16, 12, 8)
	reduced.set_spectrum(spectrum[0], spectrum[1])
	var before = reduced.sample_water(_POS, _TIME)
	quality.set_profile(QualityScript.Profile.DECK)
	quality.set_profile(QualityScript.Profile.DEV_HIGH)
	var after = reduced.sample_water(_POS, _TIME)
	_check(is_equal_approx(before.height, after.height), "K: perfil no altera query reduced")
	quality.free()


# L. Sin readback.
func _validate_no_readback_source() -> void:
	for path in ["res://ocean_v3/physics/ocean_query_reduced.gd", "res://ocean_v3/physics/ocean_query_sample.gd"]:
		var source := _read_file(path)
		for forbidden in ["texture_get_data", "buffer_get_data", ".sync(", "submit("]:
			_check(forbidden not in source, "L: sin readback en %s (%s)" % [path.get_file(), forbidden])


# M. Sin allocations evidentes por query en el hot path.
func _validate_no_per_query_allocations() -> void:
	var source := _read_file("res://ocean_v3/physics/ocean_query_reduced.gd")
	var accumulate := _extract_func(source, "func _accumulate", "func _prepare_time")
	var sample_world := _extract_func(source, "func _sample_world", "func _build_sample")
	for forbidden in ["PackedFloat64Array(", "Dictionary", "Array[", "new()", ".append("]:
		_check(forbidden not in accumulate, "M: _accumulate sin %s" % forbidden)
		_check(forbidden not in sample_world, "M: _sample_world sin %s" % forbidden)


# J. Band debug no altera la query (mÃ³dulo runtime).
func _validate_runtime_module() -> void:
	var module := get_first_node_in_group(&"ocean_fft")
	if module == null:
		_check(false, "J: mÃ³dulo no disponible")
		return
	_check(module.query_backend_name() == "REDUCED", "J: backend por defecto REDUCED")
	var before = module.sample_water(_POS, _TIME)
	module.cycle_band_debug()
	module.cycle_band_debug()
	var after = module.sample_water(_POS, _TIME)
	_check(is_equal_approx(before.height, after.height) and before.displacement == after.displacement, "J: band debug no altera query")
	# Batch API.
	var positions: Array[Vector3] = [_POS, Vector3(40.0, 0.0, -15.0), Vector3(35.0, 0.0, -10.0)]
	var batch = module.sample_water_batch_physics_time(positions)
	_check(batch.size() == 3, "J: batch devuelve 3 samples")
	for index in 3:
		var single = module.sample_water_physics_time(positions[index])
		_check(is_equal_approx(batch[index].height, single.height), "J: batch == individual (%d)" % index)


func _extract_func(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	if start < 0:
		return ""
	var end := source.find(end_marker, start + 1)
	if end < 0:
		return source.substr(start)
	return source.substr(start, end - start)


func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _finish() -> void:
	if _failures == 0:
		print("PHASE_2B_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_2B_VALIDATION: %d fallos" % _failures)
		quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)



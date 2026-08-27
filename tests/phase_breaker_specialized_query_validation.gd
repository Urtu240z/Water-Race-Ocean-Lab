extends SceneTree
## Breaker Specialized Query: validación offline del sampler coastal LONG-only.
## No carga escenas ni assets horneados del usuario: construye un banco pequeño
## en memoria y verifica el contrato de preparación, altura, slope y determinismo.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

const SEED := 20260827
const TIME := 2.375
var _failures := 0


func _initialize() -> void:
	_validate_wiring_contract()
	var query = _make_query()
	var native = null
	if ClassDB.class_exists(&"OceanQueryNative"):
		native = ClassDB.instantiate(&"OceanQueryNative")
		query.configure_native_backend(native)
	var coastal := _bake_coastal()
	query.configure_coastal(coastal.warp, coastal.propagation, 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	_validate_preparation_contract(query)
	_validate_samples(query)
	_validate_repeatability(query)
	_validate_native_specialized(query, native)
	if _failures == 0:
		print("PHASE_BREAKER_SPECIALIZED_QUERY: PASS")
		quit(0)
	else:
		push_error("PHASE_BREAKER_SPECIALIZED_QUERY: %d fallos" % _failures)
		quit(1)


func _validate_wiring_contract() -> void:
	var module_source := FileAccess.get_file_as_string("res://ocean_v3/open_ocean_fft_module.gd")
	var pool_source := FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	var query_source := FileAccess.get_file_as_string("res://ocean_v3/physics/ocean_query_reduced.gd")
	_check(module_source.contains("set_breaker_query_sources"), "OpenOceanFFT cablea la fuente especializada")
	_check(module_source.contains("sample_coastal_breaker_heights_batch_at_time"), "existe batch de alturas coastal")
	_check(pool_source.contains("_call_breaker_heights") and pool_source.contains("_call_breaker_slopes"), "pool separa altura y slope")
	_check(pool_source.contains("const DETECTOR_INTERVAL := 0.05") and pool_source.contains("const DETECTOR_SLOTS_PER_TICK := 2"), "scheduler 20 Hz/2 slots intacto")
	var specialized_start := query_source.find("func _sample_breaker_point")
	var specialized_end := query_source.find("func _band_height", specialized_start)
	var specialized_body := query_source.substr(specialized_start, specialized_end - specialized_start)
	_check(specialized_start >= 0 and specialized_body.find("_sample_world") < 0, "sampler breaker no invierte con Newton")
	_check(specialized_body.find("_accumulate_breaker_long") >= 0 and specialized_body.find("_accumulate_coastal_long") < 0, "sampler breaker usa acumulador LONG dedicado")


func _make_query():
	var configs = SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	for config in configs:
		config.resolution = 32
	var h0s: Array[PackedByteArray] = []
	for config in configs:
		h0s.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var query = ReducedScript.new()
	query.set_spectrum(configs, h0s)
	query.set_mode(ReducedScript.MODE_REDUCED)
	query.set_budget(128, 128, 128)
	query.set_sea_level(0.0)
	return query


func _bake_coastal() -> Dictionary:
	var bathymetry = BathymetryDataScript.new()
	bathymetry.world_origin_xz = Vector2(-32.0, -24.0)
	bathymetry.width = 65
	bathymetry.height = 49
	bathymetry.cell_size_m = 1.0
	bathymetry.sea_level_y = 0.0
	var count: int = bathymetry.width * bathymetry.height
	bathymetry.depth_m.resize(count)
	bathymetry.gradient_x.resize(count)
	bathymetry.gradient_z.resize(count)
	bathymetry.slope_magnitude.resize(count)
	bathymetry.land_water_mask.resize(count)
	for z in bathymetry.height:
		for x in bathymetry.width:
			var index: int = z * bathymetry.width + x
			var world: Vector2 = bathymetry.world_origin_xz + Vector2(float(x), float(z))
			bathymetry.depth_m[index] = 18.0 - 17.5 * exp(-(world.x * world.x / 900.0 + world.y * world.y / 1800.0))
			bathymetry.land_water_mask[index] = 1
	var eikonal = EikonalBakerScript.new()
	eikonal.bathymetry_data = bathymetry
	eikonal.incoming_direction_xz = Vector2(1.0, 0.15).normalized()
	eikonal.reference_wavelength_m = 16.0
	var propagation = eikonal.bake()
	var warp_baker = WarpBakerScript.new()
	warp_baker.propagation = propagation
	return {"propagation": propagation, "warp": warp_baker.bake()}


func _validate_preparation_contract(query) -> void:
	var positions: Array[Vector3] = [Vector3(-5.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(8.0, 0.0, 2.0)]
	query.prepare_breaker_time(TIME)
	var heights = query.sample_coastal_breaker_heights_prepared(positions)
	_check(bool(query._breaker_prepared_valid), "prepare_breaker_time habilita el estado LONG")
	_check(not bool(query._prepared_valid), "prepare_breaker_time no prepara MID/SHORT ni activa la query general")
	_check(heights.size() == positions.size(), "batch de alturas conserva el cardinal recibido")
	_check(query.selected_pair_counts().size() == 3, "el sampler reutiliza las tres selecciones existentes sin crear un presupuesto nuevo")


func _validate_samples(query) -> void:
	var positions: Array[Vector3] = [Vector3(-5.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(8.0, 0.0, 2.0)]
	var heights = query.sample_coastal_breaker_heights_prepared(positions)
	var slopes = query.sample_coastal_breaker_slopes_prepared(positions)
	var valid_count := 0
	for index in positions.size():
		var height_sample = heights[index]
		var slope_sample = slopes[index]
		_check(height_sample != null and slope_sample != null, "samplers devuelven muestras no nulas")
		if height_sample == null or slope_sample == null:
			continue
		_check(is_finite(height_sample.height) and is_finite(slope_sample.height), "altura LONG coastal finita")
		_check(is_finite(slope_sample.normal.x) and is_finite(slope_sample.normal.y) and is_finite(slope_sample.normal.z), "slope del candidato finito")
		_check(height_sample.normal == Vector3.UP, "batch de perfil no calcula slope innecesario")
		if height_sample.valid and slope_sample.valid:
			valid_count += 1
	_check(valid_count > 0, "el banco controlado produce muestras coastal válidas")


func _validate_repeatability(query) -> void:
	var positions: Array[Vector3] = [Vector3(-5.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(8.0, 0.0, 2.0)]
	var first = query.sample_coastal_breaker_heights_prepared(positions)
	query.prepare_breaker_time(TIME)
	var second = query.sample_coastal_breaker_heights_prepared(positions)
	var max_delta := 0.0
	for index in positions.size():
		max_delta = maxf(max_delta, absf(first[index].height - second[index].height))
	print("BREAKER SPECIALIZED samples=%d max_repeat_height_delta=%.9f long_pairs=%d" % [positions.size(), max_delta, query.selected_pair_counts()[0]])
	_check(max_delta == 0.0, "misma seed/H0/tiempo produce altura idéntica")


func _validate_native_specialized(query, native) -> void:
	if native == null:
		print("NATIVE BREAKER: SKIP (OceanQueryNative no disponible)")
		return
	_check(native.has_method(&"prepare_breaker_time"), "DLL expone prepare_breaker_time")
	_check(native.has_method(&"sample_coastal_breaker_batch_prepared"), "DLL expone batch breaker especializado")
	_check(native.has_method(&"set_coastal_runtime"), "DLL expone set_coastal_runtime para breakers")
	if not native.has_method(&"sample_coastal_breaker_batch_prepared"):
		return
	var positions: PackedVector3Array = [Vector3(-5.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(8.0, 0.0, 2.0)]
	native.prepare_breaker_time(TIME)
	var native_heights: PackedFloat64Array = native.sample_coastal_breaker_batch_prepared(positions, false)
	var native_slopes: PackedFloat64Array = native.sample_coastal_breaker_batch_prepared(positions, true)
	var reduced_heights = query.sample_coastal_breaker_heights_prepared(positions)
	var reduced_slopes = query.sample_coastal_breaker_slopes_prepared(positions)
	var max_height_delta := 0.0
	var max_slope_delta := 0.0
	for index in positions.size():
		max_height_delta = maxf(max_height_delta, absf(native_heights[index * 15 + 1] - reduced_heights[index].height))
		for field in [5, 6, 7]:
			var reduced_normal: float = [reduced_slopes[index].normal.x, reduced_slopes[index].normal.y, reduced_slopes[index].normal.z][field - 5]
			max_slope_delta = maxf(max_slope_delta, absf(native_slopes[index * 15 + field] - reduced_normal))
	_check(max_height_delta < 2.0e-7, "Native breaker height == Reduced especializado")
	_check(max_slope_delta < 2.0e-7, "Native breaker slope == Reduced especializado")
	_check(native_heights[6] == 1.0, "Native height-only conserva normal UP")
	var pair_counts: PackedInt64Array = native.get_coastal_pair_counts()
	print("BREAKER NATIVE pairs_nonzero=%d total=%d height_delta=%.9f slope_delta=%.9f" % [pair_counts[0], pair_counts[1], max_height_delta, max_slope_delta])


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

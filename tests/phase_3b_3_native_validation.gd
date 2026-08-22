extends SceneTree
## 3B.3: paridad REDUCED/NATIVE scalar/AVX2 y microbenchmark prepared RACE.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

const TIME := 2.3
const SEED := 20260822
var _failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		push_error("PHASE_3B_3_NATIVE: OceanQueryNative no cargado")
		quit(1)
		return
	var native = ClassDB.instantiate(&"OceanQueryNative")
	_check(native.has_method(&"set_coastal_runtime"), "DLL 3B.3 expone runtime coastal")
	var reduced = _make_reduced()
	reduced.configure_native_backend(native)
	var bank = _bake_bank()
	reduced.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	_validate_parity(reduced, native)
	_validate_batch(native)
	if not OS.get_cmdline_user_args().has("--skip-bench"):
		_benchmark(native, reduced, bank)
	if _failures == 0:
		print("PHASE_3B_3_NATIVE: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_3_NATIVE: %d fallos" % _failures)
		quit(1)


func _make_reduced():
	var configs = SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	var h0s: Array[PackedByteArray] = []
	for config in configs:
		h0s.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var query = ReducedScript.new()
	query.set_spectrum(configs, h0s)
	query.set_mode(ReducedScript.MODE_REDUCED)
	query.set_budget(1024, 1024, 1024)
	query.set_sea_level(0.0)
	return query


func _bake_bank() -> Dictionary:
	var data = BathymetryDataScript.new()
	data.world_origin_xz = Vector2(-32.0, -24.0)
	data.width = 65
	data.height = 49
	data.cell_size_m = 1.0
	var count: int = data.width * data.height
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var point: Vector2 = data.world_origin_xz + Vector2(float(x), float(z))
			data.depth_m[index] = 18.0 - 17.5 * exp(-(point.x * point.x / 900.0 + point.y * point.y / 1800.0))
			data.land_water_mask[index] = 1
	var eikonal = EikonalBakerScript.new()
	eikonal.bathymetry_data = data
	eikonal.incoming_direction_xz = Vector2(1.0, 0.15).normalized()
	eikonal.reference_wavelength_m = 16.0
	var propagation = eikonal.bake()
	var baker = WarpBakerScript.new()
	baker.propagation = propagation
	return {"propagation": propagation, "warp": baker.bake()}


func _native_error(reduced_sample, raw: PackedFloat64Array) -> float:
	var displacement_error: float = reduced_sample.displacement.distance_to(Vector3(raw[2], raw[3], raw[4]))
	var normal_error: float = reduced_sample.normal.distance_to(Vector3(raw[5], raw[6], raw[7]))
	var velocity_error: float = reduced_sample.surface_velocity.distance_to(Vector3(raw[8], raw[9], raw[10]))
	return maxf(maxf(absf(reduced_sample.height - raw[1]), displacement_error), maxf(normal_error, velocity_error))


func _validate_parity(reduced, native) -> void:
	var positions: Array[Vector3] = [Vector3(-20.0, 0.0, 0.0), Vector3(-8.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(8.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0)]
	var packed := PackedVector3Array()
	for point in positions:
		packed.append(point)
	reduced.ensure_prepared(TIME)
	native.ensure_prepared(TIME)
	var scalar_batch: PackedFloat64Array = native.sample_batch_scalar_prepared(packed)
	native.set_force_scalar(false)
	var avx_batch: PackedFloat64Array = native.sample_batch_prepared(packed)
	var max_reduced_scalar := 0.0
	var max_scalar_avx := 0.0
	for point_index in positions.size():
		var point: Vector3 = positions[point_index]
		var reference = reduced.sample_water_prepared(point)
		var scalar := scalar_batch.slice(point_index * 15, (point_index + 1) * 15)
		var avx := avx_batch.slice(point_index * 15, (point_index + 1) * 15)
		max_reduced_scalar = maxf(max_reduced_scalar, _native_error(reference, scalar))
		var scalar_avx := 0.0
		for index in 15:
			scalar_avx = maxf(scalar_avx, absf(scalar[index] - avx[index]))
		max_scalar_avx = maxf(max_scalar_avx, scalar_avx)
	print("3B.3 NATIVE reduced_scalar=%.9f scalar_avx=%.9f backend=%s" % [max_reduced_scalar, max_scalar_avx, native.get_query_execution_backend()])
	_check(max_reduced_scalar < 2.0e-5, "REDUCED coastal == NATIVE scalar")
	_check(max_scalar_avx < 2.0e-7, "NATIVE scalar == AVX2")


func _validate_batch(native) -> void:
	var points := PackedVector3Array()
	for index in 16:
		points.append(Vector3(-24.0 + float(index) * 3.0, 0.0, 2.0 * sin(float(index))))
	native.ensure_prepared(TIME)
	var batch: PackedFloat64Array = native.sample_batch_prepared(points)
	var max_error := 0.0
	for index in points.size():
		var scalar: PackedFloat64Array = native.sample_prepared(points[index].x, points[index].z)
		for field in 15:
			max_error = maxf(max_error, absf(batch[index * 15 + field] - scalar[field]))
	print("3B.3 NATIVE batch_scalar=%.9f" % max_error)
	_check(max_error < 2.0e-7, "NATIVE coastal batch == scalar")


func _benchmark(native, reduced, bank: Dictionary) -> void:
	var point_sets := [16, 64]
	for count in point_sets:
		reduced.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
		var points := PackedVector3Array()
		points.resize(count)
		for index in count:
			points[index] = Vector3(-30.0 + float(index % 16) * 4.0, 0.0, -20.0 + float(index / 16) * 8.0)
		native.ensure_prepared(TIME)
		for _warmup in 20:
			native.sample_batch_prepared(points)
		var start := Time.get_ticks_usec()
		for _iteration in 80:
			native.sample_batch_prepared(points)
		var coastal_ms := float(Time.get_ticks_usec() - start) / 80.0 / 1000.0
		reduced.clear_coastal()
		native.clear_coastal()
		for _warmup in 20:
			native.sample_batch_prepared(points)
		start = Time.get_ticks_usec()
		for _iteration in 80:
			native.sample_batch_prepared(points)
		var open_ms := float(Time.get_ticks_usec() - start) / 80.0 / 1000.0
		print("3B.3 PERF %d: open=%.3f ms coastal=%.3f ms overhead=%.1f%%" % [count, open_ms, coastal_ms, 100.0 * (coastal_ms - open_ms) / maxf(open_ms, 0.001)])
		_check(coastal_ms <= (1.0 if count == 16 else 4.0), "coastal %d queries dentro de línea de alarma" % count)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

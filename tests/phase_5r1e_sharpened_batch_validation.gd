extends SceneTree
## 5R.1E: paridad del batch NATIVE sharpened (crest sharpening ON) contra el
## ORACLE scalar, y microbenchmark del batch real de 56 queries (8 anchors × 7).
## NO modifica el detector: sólo valida la ruta OceanQuery NATIVE.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

const TIME := 2.3
const SEED := 20260822
const STRIDE := 15
var _failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		push_error("PHASE_5R1E: OceanQueryNative no cargado")
		quit(1)
		return
	var native = ClassDB.instantiate(&"OceanQueryNative")
	var reduced: RefCounted = _make_reduced()
	reduced.configure_native_backend(native)
	native.set_crest_sharpen(_sharp_config())
	print("5R.1E backend=%s avx2=%s" % [native.get_query_execution_backend(), native.get_cpu_supports_avx2()])

	_validate_parity(native, "OPEN", _make_points(56))

	var bank: Dictionary = _bake_bank()
	reduced.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	native.set_crest_sharpen(_sharp_config())
	_validate_parity(native, "COASTAL", _make_points(56))

	_benchmark(native)

	if _failures == 0:
		print("PHASE_5R1E: PASS")
		quit(0)
	else:
		push_error("PHASE_5R1E: %d fallos" % _failures)
		quit(1)


func _sharp_config() -> Dictionary:
	# Mismo cfg que _crest_sharpen_config() del módulo para ROUGH (local_hs = 2.50).
	return {
		"strength": 1.0,
		"threshold": 0.15,
		"max_gain": 0.30,
		"long_weight": 1.0,
		"mid_weight": 0.5,
		"direction_x": 1.0,
		"direction_z": 0.0,
		"eps": 1.92,
		"local_hs": 2.50,
	}


func _make_reduced() -> RefCounted:
	var configs: Array = SeaStateScript.build_cascades(SeaStateScript.State.ROUGH)
	var h0s: Array[PackedByteArray] = []
	for config in configs:
		h0s.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var query: RefCounted = ReducedScript.new()
	query.set_spectrum(configs, h0s)
	query.set_mode(ReducedScript.MODE_REDUCED)
	query.set_budget(1024, 1024, 1024)
	query.set_sea_level(0.0)
	return query


func _make_points(count: int) -> PackedVector3Array:
	# Distribución tipo BreakerRibbonPool: 8 anchors en x, 7 muestras en z.
	var points := PackedVector3Array()
	points.resize(count)
	var anchors := 8
	var per_anchor := 7
	var idx := 0
	for a in anchors:
		for s in per_anchor:
			var x := -28.0 + float(a) * 8.0
			var z := -15.0 + float(s) * 5.0
			points[idx] = Vector3(x, 0.0, z)
			idx += 1
	return points


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


func _validate_parity(native, label: String, points: PackedVector3Array) -> void:
	native.ensure_prepared(TIME)
	var scalar: PackedFloat64Array = native.sample_batch_scalar_prepared(points)
	var fast: PackedFloat64Array = native.sample_batch_prepared(points)
	var n := points.size()
	var max_height := 0.0
	var max_disp := 0.0
	var max_field := 0.0
	var max_residual_fast := 0.0
	var sum_height := 0.0
	var sum_disp := 0.0
	var iter_mismatch := 0
	var valid_mismatch := 0
	for i in n:
		var b := i * STRIDE
		var dh := absf(scalar[b + 1] - fast[b + 1])
		max_height = maxf(max_height, dh)
		sum_height += dh * dh
		var disp_err := Vector3(scalar[b + 2] - fast[b + 2], scalar[b + 3] - fast[b + 3], scalar[b + 4] - fast[b + 4]).length()
		max_disp = maxf(max_disp, disp_err)
		sum_disp += disp_err * disp_err
		for f in STRIDE:
			max_field = maxf(max_field, absf(scalar[b + f] - fast[b + f]))
		max_residual_fast = maxf(max_residual_fast, absf(fast[b + 13]))
		if int(scalar[b + 14]) != int(fast[b + 14]):
			iter_mismatch += 1
		if (scalar[b] > 0.5) != (fast[b] > 0.5):
			valid_mismatch += 1
	var rms_height := sqrt(sum_height / float(n))
	var rms_disp := sqrt(sum_disp / float(n))
	print("5R.1E PARITY %s N=%d height max=%.9f rms=%.9f | disp max=%.9f rms=%.9f | field max=%.9f | residual_fast max=%.9f | iter_mismatch=%d valid_mismatch=%d" % [
		label, n, max_height, rms_height, max_disp, rms_disp, max_field, max_residual_fast, iter_mismatch, valid_mismatch])
	_check(max_height < 1.0e-3, "%s height FAST==SCALAR submilimétrico" % label)
	_check(max_disp < 1.0e-3, "%s displacement FAST==SCALAR submilimétrico" % label)
	_check(max_field < 1.0e-3, "%s todos los campos FAST==SCALAR" % label)
	_check(iter_mismatch == 0, "%s mismas iteraciones de Newton" % label)
	_check(valid_mismatch == 0, "%s mismas flags de convergencia" % label)


func _benchmark(native) -> void:
	var points := _make_points(56)
	native.ensure_prepared(TIME)
	for _warmup in 20:
		native.sample_batch_scalar_prepared(points)
	for _warmup in 20:
		native.sample_batch_prepared(points)
	var iterations := 80
	var start := Time.get_ticks_usec()
	for _iteration in iterations:
		native.sample_batch_scalar_prepared(points)
	var scalar_ms := float(Time.get_ticks_usec() - start) / float(iterations) / 1000.0
	start = Time.get_ticks_usec()
	for _iteration in iterations:
		native.sample_batch_prepared(points)
	var fast_ms := float(Time.get_ticks_usec() - start) / float(iterations) / 1000.0
	print("5R.1E PERF 56q scalar=%.3f ms fast=%.3f ms speedup=%.2fx backend=%s" % [
		scalar_ms, fast_ms, scalar_ms / maxf(fast_ms, 0.0001), native.get_query_execution_backend()])
	_check(fast_ms < scalar_ms, "FAST batch (%.3f ms) más rápido que scalar (%.3f ms)" % [fast_ms, scalar_ms])


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

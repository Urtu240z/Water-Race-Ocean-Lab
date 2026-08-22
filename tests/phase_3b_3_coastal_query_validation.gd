extends SceneTree
## 3B.3: validación barata de la superficie paramétrica coastal en GDScript.
## La referencia FULL_PAIRS y REDUCED comparten exactamente el mismo sampler
## world/parametric -> deep configurado aquí; native se valida aparte al cargar
## la DLL reconstruida.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")
const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

const SEED := 20260822
const TIME := 1.7
var _failures := 0


func _initialize() -> void:
	var query = _make_query(ReducedScript.MODE_FULL_PAIRS, 4096)
	var flat = _bake(_make_bathymetry(true))
	var bank = _bake(_make_bathymetry(false))
	_validate_open_regression(query)
	_validate_flat(query, flat)
	_validate_bank_parametric_round_trip(query, bank)
	_validate_reduced_and_batch(bank)
	_validate_continuity(query, bank)
	if _failures == 0:
		print("PHASE_3B_3_COASTAL_QUERY: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_3_COASTAL_QUERY: %d fallos" % _failures)
		quit(1)


func _make_query(mode: int, budget: int):
	var configs = SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	# Resolución pequeña: test de fórmula/Newton, no benchmark ni calibración.
	for config in configs:
		config.resolution = 32
	var h0s: Array[PackedByteArray] = []
	for config in configs:
		h0s.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(SEED, config.id)))
	var query = ReducedScript.new()
	query.set_spectrum(configs, h0s)
	query.set_mode(mode)
	query.set_budget(budget, budget, budget)
	query.set_sea_level(0.0)
	return query


func _make_bathymetry(flat: bool):
	var data = BathymetryDataScript.new()
	data.world_origin_xz = Vector2(-32.0, -24.0)
	data.width = 65
	data.height = 49
	data.cell_size_m = 1.0
	data.sea_level_y = 0.0
	var count: int = data.width * data.height
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var world: Vector2 = data.world_origin_xz + Vector2(float(x), float(z))
			data.depth_m[index] = 18.0 if flat else 18.0 - 17.5 * exp(-(world.x * world.x / 900.0 + world.y * world.y / 1800.0))
			data.land_water_mask[index] = 1
	return data


func _bake(data) -> Dictionary:
	var eikonal = EikonalBakerScript.new()
	eikonal.bathymetry_data = data
	eikonal.incoming_direction_xz = Vector2(1.0, 0.15).normalized()
	eikonal.reference_wavelength_m = 16.0
	var propagation = eikonal.bake()
	var baker = WarpBakerScript.new()
	baker.propagation = propagation
	var warp = baker.bake()
	return {"propagation": propagation, "warp": warp}


func _sample_difference(a, b) -> float:
	var error := maxf(absf(a.height - b.height), a.displacement.distance_to(b.displacement))
	error = maxf(error, a.surface_velocity.distance_to(b.surface_velocity))
	return maxf(error, a.normal.distance_to(b.normal))


func _validate_open_regression(query) -> void:
	var point := Vector3(80.0, 0.0, 30.0)
	var before = query.sample_water(point, TIME)
	query.clear_coastal()
	var after = query.sample_water(point, TIME)
	var error := _sample_difference(before, after)
	print("3B.3 OPEN regression=%.12f" % error)
	_check(error == 0.0, "open/null conserva resultado exactamente")


func _validate_flat(query, flat: Dictionary) -> void:
	query.configure_coastal(flat["warp"], flat["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	var point := Vector3(4.0, 0.0, -3.0)
	var coastal = query.sample_water(point, TIME)
	query.clear_coastal()
	var open = query.sample_water(point, TIME)
	var error := _sample_difference(coastal, open)
	print("3B.3 FLAT error=%.9f" % error)
	_check(error < 2.0e-5, "flat F≈identity y S≈1 conserva query")


func _validate_bank_parametric_round_trip(query, bank: Dictionary) -> void:
	query.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	var q := Vector3(-5.0, 0.0, 0.0)
	var parametric = query.sample_parametric(q, TIME)
	var world := Vector3(q.x + parametric.displacement.x, 0.0, q.z + parametric.displacement.z)
	var recovered = query.sample_water(world, TIME)
	var height_error := absf(recovered.height - parametric.height)
	var displacement_error: float = recovered.displacement.distance_to(parametric.displacement)
	print("3B.3 BANK roundtrip residual=%.8f iter=%d h=%.9f disp=%.9f" % [recovered.query_residual_m, recovered.query_iterations, height_error, displacement_error])
	_check(recovered.valid and recovered.query_residual_m <= 1.0e-4, "bank Newton resuelve P_coastal(q)")
	_check(height_error < 2.0e-4 and displacement_error < 2.0e-4, "parametric -> world -> query recupera superficie coastal")
	query.clear_coastal()
	var open = query.sample_water(world, TIME)
	_check(absf(open.height - recovered.height) > 1.0e-7, "bank cambia físicamente LONG coastal")


func _validate_reduced_and_batch(bank: Dictionary) -> void:
	var full = _make_query(ReducedScript.MODE_FULL_PAIRS, 4096)
	var reduced = _make_query(ReducedScript.MODE_REDUCED, 256)
	full.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	reduced.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	full.ensure_prepared(TIME)
	reduced.ensure_prepared(TIME)
	var positions: Array[Vector3] = [Vector3(-20.0, 0.0, 0.0), Vector3(-5.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0)]
	var batch = reduced.sample_water_batch_prepared(positions)
	var max_batch_error := 0.0
	var max_full_reduced := 0.0
	for index in positions.size():
		var scalar = reduced.sample_water_prepared(positions[index])
		var reference = full.sample_water_prepared(positions[index])
		max_batch_error = maxf(max_batch_error, _sample_difference(batch[index], scalar))
		max_full_reduced = maxf(max_full_reduced, _sample_difference(reference, scalar))
	print("3B.3 REDUCED batch_error=%.12f full_vs_reduced=%.6f" % [max_batch_error, max_full_reduced])
	_check(max_batch_error == 0.0, "coastal batch == scalar")
	_check(max_full_reduced < 0.20, "reduced coastal permanece acotado frente FULL_PAIRS")


func _validate_continuity(query, bank: Dictionary) -> void:
	## Línea explícita: outside -> transition -> coastal -> transition -> outside.
	query.configure_coastal(bank["warp"], bank["propagation"], 20.0, 35.0, Vector2(1.0, 0.15).normalized())
	var edge_height := 0.0
	var edge_displacement := 0.0
	var edge_normal_angle := 0.0
	var edge_velocity := 0.0
	var natural_height := 0.0
	var natural_displacement := 0.0
	var natural_normal_angle := 0.0
	var natural_velocity := 0.0
	for sample_time in [0.0, TIME, 5.1]:
		var previous = null
		var previous_x := 0.0
		for sample_index in 321:
			var x := -40.0 + float(sample_index) * 0.25
			var current = query.sample_water(Vector3(x, 0.0, 0.0), sample_time)
			if previous != null:
				var height_delta := absf(current.height - previous.height)
				var displacement_delta: float = current.displacement.distance_to(previous.displacement)
				var normal_angle := acos(clampf(current.normal.dot(previous.normal), -1.0, 1.0))
				var velocity_delta: float = current.surface_velocity.distance_to(previous.surface_velocity)
				if absf(x) >= 28.0 or absf(previous_x) >= 28.0:
					edge_height = maxf(edge_height, height_delta)
					edge_displacement = maxf(edge_displacement, displacement_delta)
					edge_normal_angle = maxf(edge_normal_angle, normal_angle)
					edge_velocity = maxf(edge_velocity, velocity_delta)
				if absf(x) <= 12.0 and absf(previous_x) <= 12.0:
					natural_height = maxf(natural_height, height_delta)
					natural_displacement = maxf(natural_displacement, displacement_delta)
					natural_normal_angle = maxf(natural_normal_angle, normal_angle)
					natural_velocity = maxf(natural_velocity, velocity_delta)
			previous = current
			previous_x = x
	print("3B.3A CONTINUITY edge h=%.6f disp=%.6f n=%.6f vel=%.6f | natural h=%.6f disp=%.6f n=%.6f vel=%.6f" % [edge_height, edge_displacement, edge_normal_angle, edge_velocity, natural_height, natural_displacement, natural_normal_angle, natural_velocity])
	_check(edge_height <= maxf(natural_height * 4.0, 0.02) and edge_displacement <= maxf(natural_displacement * 4.0, 0.02) and edge_normal_angle <= maxf(natural_normal_angle * 4.0, 0.04) and edge_velocity <= maxf(natural_velocity * 4.0, 0.05), "continuidad outside/transition/coastal sin seam artificial")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

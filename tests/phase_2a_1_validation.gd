extends SceneTree
## Validación de Fase 2A.1: OceanQueryReference como GOLDEN REFERENCE en
## coordenadas MUNDIALES (inversión world_xz -> q con Newton-Raphson 2D).
##
## Cubre: round-trip forward->inverse (RACE/ROUGH), inversión analítica de una
## sola onda, sea level absoluto, invalidación de prepared, jacobiano/foldover
## y coste orientativo de world query. CPU pura, sin readback GPU.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const QueryRefScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const SampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")

const _SEED := 20260820
const _TIME := 2.5

var _failures := 0


func _initialize() -> void:
	_validate_flat_jacobian()
	_validate_single_wave_inverse()
	_validate_round_trip(SeaStateScript.State.RACE)
	_validate_round_trip(SeaStateScript.State.ROUGH)
	_validate_sea_level()
	_validate_prepared_invalidation()
	_measure_world_cost()
	if _failures == 0:
		print("PHASE_2A_1_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_2A_1_VALIDATION: %d fallos" % _failures)
		quit(1)


func _build_spectrum(state: int, simulation_seed: int) -> Array:
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id)))
	return [configs, h0_datas]


func _build_reference(state: int, simulation_seed: int):
	var spectrum := _build_spectrum(state, simulation_seed)
	var reference = QueryRefScript.new()
	reference.set_spectrum(spectrum[0], spectrum[1])
	return reference


# Sección 18: jacobiano de superficie plana.
func _validate_flat_jacobian() -> void:
	var config := ConfigScript.new()
	config.resolution = 16
	config.domain_size_m = 32.0
	var h0 := PackedFloat32Array()
	h0.resize(16 * 16 * 4)
	var reference = QueryRefScript.new()
	reference.set_spectrum([config], [h0.to_byte_array()])
	var sample = reference.sample_water(Vector3(5.0, 0.0, 7.0), 1.0)
	_check(sample.valid, "plano: sample válido")
	_check(sample.jacobian_det == 1.0, "plano: detJ == 1")
	_check(sample.foldover_risk == false, "plano: sin foldover")
	_check(sample.query_residual_m < 1.0e-4, "plano: residual ~0")
	_check(sample.query_iterations == 0, "plano: 0 iteraciones (q0 ya resuelve)")
	_check(sample.height == 0.0, "plano: height 0 con sea_level 0")


# Secciones 14 y 18: inversión analítica de una sola onda + jacobiano esperado.
func _validate_single_wave_inverse() -> void:
	var n := 8
	var domain := 16.0
	var config := ConfigScript.new()
	config.resolution = n
	config.domain_size_m = domain
	config.gravity_mps2 = 9.81
	config.choppiness = 1.0 # lambda = -1
	config.target_hs_m = 1.0
	var half := n / 2
	var floats := PackedFloat32Array()
	floats.resize(n * n * 4)
	var index_plus := half * n + (half + 1)
	var index_minus := half * n + (half - 1)
	floats[index_plus * 4] = 1.0
	floats[index_plus * 4 + 2] = 1.0
	floats[index_minus * 4] = 1.0
	floats[index_minus * 4 + 2] = 1.0
	var reference = QueryRefScript.new()
	reference.set_spectrum([config], [floats.to_byte_array()])

	var kx := TAU / domain
	var omega := sqrt(9.81 * kx)
	var inv16 := 1.0 / 16.0
	var coeff := kx / 16.0

	# Jacobiano analítico en qx=0, t=0: 1 + (kx/16)·cos(ωt)·cos(kx·qx).
	var det_sample = reference.sample_parametric(Vector3(0.0, 0.0, 0.0), 0.0)
	_check(absf(det_sample.jacobian_det - (1.0 + coeff)) < 1.0e-4, "jacobiano: detJ single-wave ≈ 1 + kx/16 (%.6f ≈ %.6f)" % [det_sample.jacobian_det, 1.0 + coeff])
	_check(is_finite(det_sample.jacobian_det), "jacobiano: detJ finito")

	var t := 0.0
	for qx: float in [0.0, 2.0, 4.0, 6.0]:
		var expected_h := -inv16 * cos(omega * t) * cos(kx * qx)
		var expected_dx := inv16 * cos(omega * t) * sin(kx * qx)
		var world_x := qx + expected_dx
		var world = reference.sample_water(Vector3(world_x, 0.0, 0.0), t)
		_check(world.valid, "onda única: world query válida qx=%.1f" % qx)
		_check(world.query_residual_m <= 1.0e-4, "onda única: residual XZ (%s)" % _sci(world.query_residual_m))
		_check(absf(world.height - expected_h) < 1.0e-4, "onda única: height en world (%.6f ≈ %.6f)" % [world.height, expected_h])
		_check(absf(world.displacement.x - expected_dx) < 1.0e-4, "onda única: Dx en world (%.6f ≈ %.6f)" % [world.displacement.x, expected_dx])
		_check(absf(world.displacement.z) < 1.0e-4, "onda única: Dz 0 en world")
		var recovered_q: float = world_x - world.displacement.x
		_check(absf(recovered_q - qx) < 2.0e-3, "onda única: q recuperado (%.6f ≈ %.6f)" % [recovered_q, qx])
		var expected_normal := Vector3(-coeff * cos(omega * t) * sin(kx * qx), 1.0 + coeff * cos(omega * t) * cos(kx * qx), 0.0).normalized()
		_check(world.normal.distance_to(expected_normal) < 1.0e-4, "onda única: normal en world")
		print("INFO: onda única qx=%.1f iter=%d residual=%s detJ=%.4f" % [qx, world.query_iterations, _sci(world.query_residual_m), world.jacobian_det])

	# Velocidad en t = π/(2ω), qx=0: vh = ω/16, vx = 0.
	t = PI / (2.0 * omega)
	var world = reference.sample_water(Vector3(0.0, 0.0, 0.0), t)
	_check(absf(world.surface_velocity.y - (omega / 16.0)) < 1.0e-4, "onda única: vh en world (%.6f ≈ %.6f)" % [world.surface_velocity.y, omega / 16.0])
	_check(absf(world.surface_velocity.x) < 1.0e-4, "onda única: vx 0 en world")


# Secciones 13 y 15: round-trip forward -> inverse en RACE y ROUGH.
func _validate_round_trip(state: int) -> void:
	var reference = _build_reference(state, _SEED)
	var state_name := SeaStateScript.state_name(state)
	var points := [
		Vector3(10.0, 0.0, 20.0),
		Vector3(50.0, 0.0, -30.0),
		Vector3(120.0, 0.0, 80.0),
	]
	var round_trips := 0
	for q in points:
		var param = reference.sample_parametric(q, _TIME)
		if not param.valid or param.jacobian_det <= 0.2:
			print("INFO: %s skip q=%s (detJ %.3f, riesgo foldover)" % [state_name, q, param.jacobian_det])
			continue
		var world_xz := Vector2(q.x + param.displacement.x, q.z + param.displacement.z)
		var world = reference.sample_water(Vector3(world_xz.x, 0.0, world_xz.y), _TIME)
		round_trips += 1
		_check(world.valid, "%s: world query convergida q=%s (iter %d)" % [state_name, q, world.query_iterations])
		_check(world.query_residual_m <= 1.0e-4, "%s: residual XZ <= 1e-4 (%s)" % [state_name, _sci(world.query_residual_m)])
		_check(absf(world.height - param.height) < 1.0e-3, "%s: height round-trip (%.6f ≈ %.6f)" % [state_name, world.height, param.height])
		_check(world.displacement.distance_to(param.displacement) < 1.0e-3, "%s: displacement round-trip" % state_name)
		_check(world.normal.distance_to(param.normal) < 1.0e-3, "%s: normal round-trip" % state_name)
		_check(world.surface_velocity.distance_to(param.surface_velocity) < 1.0e-3, "%s: velocity round-trip" % state_name)
		var recovered_q := Vector2(world_xz.x - world.displacement.x, world_xz.y - world.displacement.z)
		_check(recovered_q.distance_to(Vector2(q.x, q.z)) < 2.0e-3, "%s: q recuperado (%.3f, %.3f) ≈ (%.1f, %.1f)" % [state_name, recovered_q.x, recovered_q.y, q.x, q.z])
		print("INFO: %s round-trip q=%s iter=%d residual=%s detJ=%.3f" % [state_name, q, world.query_iterations, _sci(world.query_residual_m), world.jacobian_det])
	_check(round_trips >= 2, "%s: suficientes puntos round-trip válidos (%d)" % [state_name, round_trips])


# Sección 16: sea level absoluto.
func _validate_sea_level() -> void:
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	reference.set_sea_level(7.25)
	var sample = reference.sample_water(Vector3(12.0, 0.0, -5.0), 1.5)
	_check(sample.valid, "sea level: sample válido")
	_check(absf(sample.height - (7.25 + sample.displacement.y)) < 1.0e-6, "sea level: height == 7.25 + displacement.y (%.6f)" % sample.height)

	var flat = SampleScript.flat(7.25)
	_check(flat.height == 7.25 and flat.normal == Vector3.UP and flat.surface_velocity == Vector3.ZERO, "sea level: OFF height 7.25, normal UP, velocity 0")

	var empty = QueryRefScript.new()
	empty.set_sea_level(7.25)
	var empty_sample = empty.sample_water(Vector3(0.0, 0.0, 0.0), 0.0)
	_check(empty_sample.height == 7.25 and empty_sample.normal == Vector3.UP and empty_sample.surface_velocity == Vector3.ZERO, "sea level: referencia vacía -> flat 7.25")


# Sección 17: invalidación de prepared.
func _validate_prepared_invalidation() -> void:
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	reference.prepare_time(1.0)
	var first = reference.sample_prepared(Vector3(10.0, 0.0, 10.0))
	_check(first.valid, "prepared: válido tras prepare_time")

	var spectrum = _build_spectrum(SeaStateScript.State.ROUGH, _SEED)
	reference.set_spectrum(spectrum[0], spectrum[1])
	var stale = reference.sample_prepared(Vector3(10.0, 0.0, 10.0))
	_check(not stale.valid, "prepared: invalidado tras set_spectrum (no devuelve datos antiguos)")

	reference.prepare_time(2.0)
	var second = reference.sample_prepared(Vector3(10.0, 0.0, 10.0))
	_check(second.valid, "prepared: vuelve a funcionar tras nuevo prepare_time")


# Sección 21: coste orientativo de world query.
func _measure_world_cost() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var reference = _build_reference(state, _SEED)
		var start := Time.get_ticks_usec()
		var sample = reference.sample_water(Vector3(15.0, 0.0, 25.0), 3.0)
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		print("INFO: %s world query %.0f ms | iter %d | residual %s | detJ %.3f" % [SeaStateScript.state_name(state), elapsed_ms, sample.query_iterations, _sci(sample.query_residual_m), sample.jacobian_det])


func _sci(value: float) -> String:
	return String.num_scientific(value)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

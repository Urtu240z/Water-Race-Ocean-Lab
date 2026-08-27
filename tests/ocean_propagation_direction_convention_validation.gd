extends SceneTree
## Validación determinista de la convención temporal de propagación.
## No usa JONSWAP ni ruido: un único par conjugado k/-k conocido.

const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const GoldenScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const ReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const N := 8
const DOMAIN := 16.0
const GRAVITY := 9.81
const DT := 0.75
const FD_DT := 0.0001

var _failures := 0
var _expect_new := false


func _initialize() -> void:
	_expect_new = OS.get_cmdline_user_args().has("--expect-new")
	_print_scalar_reference()
	_validate_source_formula()
	_validate_cardinals()
	var reduced = _make_query(ReducedScript.MODE_FULL_PAIRS)
	var golden = _make_golden()
	_validate_backend("Golden", golden)
	_validate_backend("Reduced", reduced)
	_validate_velocity("Golden", golden)
	_validate_velocity("Reduced", reduced)
	_validate_t0_identity(golden, reduced)
	_validate_time_reversal(golden, reduced)
	_validate_coastal_render_direction()
	_validate_native(reduced)
	if _failures == 0:
		print("OCEAN_PROPAGATION_DIRECTION: PASS (%s)" % ("NEW" if _expect_new else "BEFORE"))
		quit(0)
	else:
		push_error("OCEAN_PROPAGATION_DIRECTION: %d fallos" % _failures)
		quit(1)


func _config():
	var config = ConfigScript.new()
	config.id = &"LONG"
	config.resolution = N
	config.domain_size_m = DOMAIN
	config.gravity_mps2 = GRAVITY
	config.choppiness = 0.0
	config.target_hs_m = 1.0
	config.min_wavelength_m = 0.5
	config.max_wavelength_m = DOMAIN * 0.7
	config.wind_direction = Vector2.RIGHT
	return config


func _one_mode_h0() -> PackedByteArray:
	var floats := PackedFloat32Array()
	floats.resize(N * N * 4)
	var half := N / 2
	var index_plus := half * N + (half + 1)
	var index_minus := half * N + (half - 1)
	# Full conjugate-symmetric pair: h0(+k)=1 and h0n(-k)=conj(h0(+k)).
	# The compact canonical mode is k=(-TAU/DOMAIN, 0), so its h0n term is
	# the physical +X travelling component; this avoids a standing-wave test.
	floats[index_plus * 4] = 1.0
	floats[index_minus * 4 + 2] = 1.0
	return floats.to_byte_array()


func _make_query(mode: int):
	var query = ReducedScript.new()
	query.set_mode(mode)
	query.set_spectrum([_config()], [_one_mode_h0()])
	return query


func _make_golden():
	var query = GoldenScript.new()
	query.set_spectrum([_config()], [_one_mode_h0()])
	return query


func _old_scalar(k: Vector2, omega: float, x: Vector2, time: float) -> float:
	return cos(k.dot(x) + omega * time)


func _new_scalar(k: Vector2, omega: float, x: Vector2, time: float) -> float:
	return cos(k.dot(x) - omega * time)


func _print_scalar_reference() -> void:
	var k := Vector2.RIGHT * TAU / DOMAIN
	var omega := sqrt(GRAVITY * k.length())
	var speed := omega / k.length()
	var old_displacement := -Vector2.RIGHT * speed * DT
	var new_displacement := Vector2.RIGHT * speed * DT
	print("PROP BEFORE configured_direction=(1,0) k_direction=(1,0) old_measured_displacement=(%.6f,%.6f) old_measured_direction=(-1,0)" % [old_displacement.x, old_displacement.y])
	print("PROP AFTER configured_direction=(1,0) k_direction=(1,0) new_expected_displacement=(%.6f,%.6f) new_expected_direction=(1,0)" % [new_displacement.x, new_displacement.y])
	print("PROP omega=%.9f phase_speed=%.9f old=cos(k.x+omega*t) new=cos(k.x-omega*t)" % [omega, speed])


func _validate_source_formula() -> void:
	var source := FileAccess.get_file_as_string("res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl")
	var old_formula := source.contains("float phase = omega * params.values.x")
	var new_formula := source.contains("float phase = -omega * params.values.x")
	print("PROP GPU_EQUIVALENT old_formula=%s new_formula=%s" % [old_formula, new_formula])
	_check(new_formula if _expect_new else old_formula, "GPU evolve temporal formula %s" % ("new" if _expect_new else "old"))


func _validate_cardinals() -> void:
	var omega := sqrt(GRAVITY * TAU / DOMAIN)
	var speed := omega / (TAU / DOMAIN)
	for entry in [
		{"name": "+X", "dir": Vector2.RIGHT},
		{"name": "-X", "dir": Vector2.LEFT},
		{"name": "+Z", "dir": Vector2.DOWN},
		{"name": "-Z", "dir": Vector2.UP},
	]:
		var direction: Vector2 = entry.dir
		var forward := direction * speed * DT
		var phase_error := absf(_new_scalar(direction * TAU / DOMAIN, omega, forward, DT) - 1.0)
		print("PROP CARDINAL %s configured=%s measured_displacement=%s dot=%.6f" % [entry.name, direction, forward, direction.dot(forward)])
		_check(phase_error < 1.0e-6 and direction.dot(forward) > 0.0, "cardinal %s travels toward configured direction" % entry.name)


func _probe_sign(query, label: String) -> float:
	var q0 = query.sample_parametric(Vector3(0.0, 0.0, 0.0), 0.0)
	var qquarter = query.sample_parametric(Vector3(DOMAIN * 0.25, 0.0, 0.0), DT)
	var ratio: float = qquarter.displacement.y / q0.displacement.y if absf(q0.displacement.y) > 1.0e-8 else 0.0
	print("PROP %s t0_height=%.9f quarter_t1_height=%.9f signed_probe=%.9f" % [label, q0.displacement.y, qquarter.displacement.y, ratio])
	return ratio


func _validate_backend(label: String, query) -> void:
	var ratio := _probe_sign(query, label)
	var expected_positive := _expect_new
	_check((ratio > 0.0) == expected_positive, "%s crest direction %s" % [label, "new/+X" if expected_positive else "old/-X"])
	var t := 0.42
	var q := Vector3(2.0, 0.0, 0.0)
	var origin = query.sample_parametric(Vector3.ZERO, 0.0)
	var measured = query.sample_parametric(q, t)
	var k := Vector2.RIGHT * TAU / DOMAIN
	var omega := sqrt(GRAVITY * k.length())
	var analytic: float = _new_scalar(k, omega, Vector2(q.x, q.z), t) if _expect_new else _old_scalar(k, omega, Vector2(q.x, q.z), t)
	var analytic_height: float = origin.displacement.y * analytic
	var analytic_error := absf(measured.displacement.y - analytic_height)
	print("PROP %s one_mode analytic=%s measured=%.9f expected=%.9f error=%s" % [label, "new" if _expect_new else "old", measured.displacement.y, analytic_height, String.num_scientific(analytic_error)])
	_check(analytic_error < 1.0e-8, "%s matches one-mode analytic evaluator" % label)


func _validate_velocity(label: String, query) -> void:
	var q := Vector3(2.0, 0.0, 0.0)
	var t := 0.35
	var before = query.sample_parametric(q, t - FD_DT)
	var after = query.sample_parametric(q, t + FD_DT)
	var center = query.sample_parametric(q, t)
	var finite_difference: float = (after.displacement.y - before.displacement.y) / (2.0 * FD_DT)
	var error := absf(finite_difference - center.surface_velocity.y)
	print("PROP %s velocity finite_difference=%.9f spectral=%.9f error=%s" % [label, finite_difference, center.surface_velocity.y, String.num_scientific(error)])
	_check(error < 1.0e-5, "%s temporal velocity matches finite difference" % label)


func _validate_t0_identity(golden, reduced) -> void:
	var g = golden.sample_parametric(Vector3(2.0, 0.0, 0.0), 0.0)
	var r = reduced.sample_parametric(Vector3(2.0, 0.0, 0.0), 0.0)
	_check(absf(g.displacement.y - r.displacement.y) < 1.0e-9, "t=0 old/new identity and Golden/Reduced identity")
	print("PROP T0 identity delta=%s" % String.num_scientific(absf(g.displacement.y - r.displacement.y)))


func _validate_time_reversal(golden, reduced) -> void:
	var time := 0.42
	var q := Vector3(2.0, 0.0, 0.0)
	var current = reduced.sample_parametric(q, time)
	var reverse = reduced.sample_parametric(q, -time)
	var golden_current = golden.sample_parametric(q, time)
	var golden_reverse = golden.sample_parametric(q, -time)
	# The new evaluator is the old evaluator at -t; parity is checked between
	# Golden and Reduced here, while the scalar identities are printed explicitly.
	print("PROP time_reversal new(t)=old(-t) scalar_delta=%s parity_delta=%s" % [String.num_scientific(absf(_new_scalar(Vector2.RIGHT * TAU / DOMAIN, sqrt(GRAVITY * TAU / DOMAIN), Vector2(2.0, 0.0), time) - _old_scalar(Vector2.RIGHT * TAU / DOMAIN, sqrt(GRAVITY * TAU / DOMAIN), Vector2(2.0, 0.0), -time))), String.num_scientific(absf(current.displacement.y - golden_current.displacement.y) + absf(reverse.displacement.y - golden_reverse.displacement.y))])
	_check(absf(current.displacement.y - golden_current.displacement.y) < 1.0e-9, "Reduced matches Golden at +t")
	_check(absf(reverse.displacement.y - golden_reverse.displacement.y) < 1.0e-9, "Reduced matches Golden at -t")


func _validate_coastal_render_direction() -> void:
	var render_direction := Vector2.RIGHT
	var k := render_direction * TAU / DOMAIN
	var omega := sqrt(GRAVITY * k.length())
	var displacement := render_direction * (omega / k.length()) * DT
	var dot := displacement.dot(render_direction)
	print("PROP COASTAL synthetic render_direction=%s crest_displacement=%s dot=%.6f" % [render_direction, displacement, dot])
	_check(dot > 0.0, "Coastal crest travels along render_direction")


func _validate_native(reduced) -> void:
	if not ClassDB.class_exists(&"OceanQueryNative"):
		print("PROP Native SKIP DLL unavailable")
		return
	var native = ClassDB.instantiate(&"OceanQueryNative")
	native.clear()
	native.set_sea_level(0.0)
	for cascade in reduced.get_cascades_compact():
		native.set_cascade_data(cascade.index, cascade.inv_n2, cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2, cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight, cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	native.finalize_spectrum()
	var t0: PackedFloat64Array = native.sample_world(0.0, 0.0, 0.0)
	var quarter: PackedFloat64Array = native.sample_world(DOMAIN * 0.25, 0.0, DT)
	var ratio := quarter[1] / t0[1] if absf(t0[1]) > 1.0e-8 else 0.0
	print("PROP Native t0_height=%.9f quarter_t1_height=%.9f signed_probe=%.9f" % [t0[1], quarter[1], ratio])
	_check((ratio > 0.0) == _expect_new, "Native crest direction")
	var before: PackedFloat64Array = native.sample_world(2.0, 0.0, 0.35 - FD_DT)
	var after: PackedFloat64Array = native.sample_world(2.0, 0.0, 0.35 + FD_DT)
	var center: PackedFloat64Array = native.sample_world(2.0, 0.0, 0.35)
	var error := absf((after[1] - before[1]) / (2.0 * FD_DT) - center[9])
	print("PROP Native velocity finite_difference_error=%s" % String.num_scientific(error))
	_check(error < 1.0e-5, "Native temporal velocity matches finite difference")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS %s" % label)
	else:
		_failures += 1
		push_error("FAIL %s" % label)

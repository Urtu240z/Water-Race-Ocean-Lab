extends SceneTree
## Validación de Fase 2A: OceanQueryReference CPU frente al océano FFT GPU.
##
## Cubre los puntos A–L de la especificación. La parte CPU se ejecuta en
## _initialize; las comprobaciones de runtime (H/J/K/L sobre el módulo real)
## se ejecutan tras instanciar lab_main.tscn. Sin readback GPU->CPU.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QualityScript := preload("res://ocean_v3/core/ocean_quality_settings.gd")
const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const QueryRefScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")

const _SEED := 20260820
const _POS := Vector3(37.5, 0.0, -12.25)
const _TIME := 1.75

var _failures := 0
var _frame := 0
var _runtime_checked := false


func _initialize() -> void:
	_validate_lambda_regression()
	_validate_negative_choppiness_rejected()
	_validate_determinism()
	_validate_seed_changes()
	_validate_states_distinct()
	_validate_finite()
	_validate_flat_spectrum()
	_validate_single_mode()
	_validate_prepared_matches_direct()
	_validate_quality_profile_invariance()
	_measure_cost()
	_validate_no_readback_source()
	change_scene_to_file("res://lab/lab_main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3 and not _runtime_checked:
		_runtime_checked = true
		_validate_runtime()
		_finish()
	return false


# --- CPU -------------------------------------------------------------------

func _build_reference(state: int, simulation_seed: int):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id)))
	var reference = QueryRefScript.new()
	reference.set_spectrum(configs, h0_datas)
	return reference


# A. Mismo H0 + posición + tiempo => mismo sample.
func _validate_determinism() -> void:
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	var first = reference.sample_water(_POS, _TIME)
	var second = reference.sample_water(_POS, _TIME)
	_check(_samples_equal(first, second), "A: misma entrada => mismo sample")


# B. Seed distinta => sample distinto.
func _validate_seed_changes() -> void:
	var reference_a = _build_reference(SeaStateScript.State.RACE, _SEED)
	var reference_b = _build_reference(SeaStateScript.State.RACE, _SEED + 1)
	var any_different := false
	for index in 3:
		var position := Vector3(_POS.x + index * 13.0, 0.0, _POS.z - index * 7.0)
		var sa = reference_a.sample_water(position, _TIME)
		var sb = reference_b.sample_water(position, _TIME)
		if not _samples_equal(sa, sb):
			any_different = true
			break
	_check(any_different, "B: seed distinta => sample distinto")


# C. CALM/RACE/ROUGH producen samples distintos.
func _validate_states_distinct() -> void:
	var calm = _build_reference(SeaStateScript.State.CALM, _SEED)
	var race = _build_reference(SeaStateScript.State.RACE, _SEED)
	var rough = _build_reference(SeaStateScript.State.ROUGH, _SEED)
	var calm_sample = calm.sample_water(_POS, _TIME)
	var race_sample = race.sample_water(_POS, _TIME)
	var rough_sample = rough.sample_water(_POS, _TIME)
	_check(not _samples_equal(calm_sample, race_sample), "C: CALM != RACE")
	_check(not _samples_equal(race_sample, rough_sample), "C: RACE != ROUGH")
	_check(not _samples_equal(calm_sample, rough_sample), "C: CALM != ROUGH")


# D. Sample finito (sin NaN/Inf).
func _validate_finite() -> void:
	for state in [SeaStateScript.State.CALM, SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var reference = _build_reference(state, _SEED)
		var state_name := SeaStateScript.state_name(state)
		for position in [Vector3(0, 0, 0), _POS, Vector3(512.3, 0, 137.9)]:
			var sample = reference.sample_water(position, _TIME + position.x * 0.01)
			var finite: bool = sample.valid and is_finite(sample.height) and is_finite(sample.displacement.x) and is_finite(sample.displacement.y) and is_finite(sample.displacement.z) and is_finite(sample.normal.x) and is_finite(sample.normal.y) and is_finite(sample.normal.z) and is_finite(sample.surface_velocity.x) and is_finite(sample.surface_velocity.y) and is_finite(sample.surface_velocity.z)
			_check(finite, "D: sample finito %s @ %s" % [state_name, position])


# E. Espectro plano => height 0, normal UP, velocity 0.
func _validate_flat_spectrum() -> void:
	var config := ConfigScript.new()
	config.resolution = 16
	config.domain_size_m = 32.0
	var h0 := PackedFloat32Array()
	h0.resize(16 * 16 * 4)
	var reference = QueryRefScript.new()
	reference.set_spectrum([config], [h0.to_byte_array()])
	var sample = reference.sample_water(_POS, _TIME)
	_check(sample.valid, "E: espectro plano válido")
	_check(sample.height == 0.0, "E: height 0 con espectro plano")
	_check(sample.displacement == Vector3.ZERO, "E: displacement 0 con espectro plano")
	_check(sample.normal == Vector3.UP, "E: normal UP con espectro plano")
	_check(sample.surface_velocity == Vector3.ZERO, "E: velocity 0 con espectro plano")


# F/G. Test analítico de una sola onda + signo de lambda.
func _validate_single_mode() -> void:
	var n := 8
	var domain := 16.0
	var config := ConfigScript.new()
	config.resolution = n
	config.domain_size_m = domain
	config.gravity_mps2 = 9.81
	config.choppiness = 1.0 # lambda = -1 internamente
	config.target_hs_m = 1.0
	var half := n / 2
	var floats := PackedFloat32Array()
	floats.resize(n * n * 4)
	# Modo único m0 = (1,0): h0(k0) = 1, h0(-k0) = conj(1) = 1.
	var index_plus := half * n + (half + 1) # texel c = (5, 4)
	var index_minus := half * n + (half - 1) # texel c = (3, 4)
	floats[index_plus * 4] = 1.0
	floats[index_plus * 4 + 2] = 1.0
	floats[index_minus * 4] = 1.0
	floats[index_minus * 4 + 2] = 1.0
	var reference = QueryRefScript.new()
	reference.set_spectrum([config], [floats.to_byte_array()])

	var kx := TAU / domain
	var omega := sqrt(9.81 * kx)
	var inv16 := 1.0 / 16.0

	# Punto 1: t=0, wx=2.0 (pendiente creciente hacia la cresta en wx=8).
	var wx := 2.0
	var t := 0.0
	var sample = reference.sample_parametric(Vector3(wx, 0.0, 0.0), t)
	var expected_height := -inv16 * cos(omega * t) * cos(kx * wx)
	var expected_dx := inv16 * cos(omega * t) * sin(kx * wx)
	_check(is_equal_approx(sample.height, expected_height), "F: height single-mode (%.6f ≈ %.6f)" % [sample.height, expected_height])
	_check(is_equal_approx(sample.displacement.x, expected_dx), "F: Dx single-mode (%.6f ≈ %.6f)" % [sample.displacement.x, expected_dx])
	_check(is_equal_approx(sample.displacement.z, 0.0), "F: Dz 0 en modo kx")
	_check(is_equal_approx(sample.surface_velocity.y, 0.0), "F: dHeight/dt 0 en t=0")
	_check(sample.displacement.x > 0.0 and expected_dx > 0.0, "G: lambda negativa -> Dx hacia la cresta en pendiente creciente")
	_check(is_equal_approx(sample.surface_velocity.x, 0.0), "F: dDx/dt 0 en t=0")

	# Punto 2: t = π/(2ω), wx=0.
	wx = 0.0
	t = PI / (2.0 * omega)
	sample = reference.sample_parametric(Vector3(wx, 0.0, 0.0), t)
	var expected_vy := (omega / 16.0) * sin(omega * t) * cos(kx * wx)
	_check(is_equal_approx(sample.height, 0.0), "F: height 0 en nodo")
	_check(is_equal_approx(sample.surface_velocity.y, expected_vy), "F: dHeight/dt (%.6f ≈ %.6f)" % [sample.surface_velocity.y, expected_vy])
	_check(is_equal_approx(sample.surface_velocity.x, 0.0), "F: dDx/dt 0 en wx=0")
	_check(sample.normal.y > 0.0, "F: normal.y > 0 en superficie normal")
	_check(sample.normal.distance_to(Vector3.UP) < 0.0001, "F: normal UP en nodo")


# prepared_time debe coincidir con sample_water directo.
func _validate_prepared_matches_direct() -> void:
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	var direct = reference.sample_water(_POS, _TIME)
	reference.prepare_time(_TIME)
	var prepared = reference.sample_prepared(_POS)
	_check(_samples_equal(direct, prepared), "prepared_time coincide con sample directo")


# I. Los perfiles de calidad no alteran la query reference.
func _validate_quality_profile_invariance() -> void:
	var quality := QualityScript.new()
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	var before = reference.sample_water(_POS, _TIME)
	quality.set_profile(QualityScript.Profile.DECK)
	quality.set_profile(QualityScript.Profile.STANDARD)
	quality.set_profile(QualityScript.Profile.DEV_HIGH)
	var after = reference.sample_water(_POS, _TIME)
	_check(_samples_equal(before, after), "I: perfil de calidad no altera query reference")
	quality.free()


# Coste aproximado del backend paramétrico (la query mundial se mide en 2A.1).
func _measure_cost() -> void:
	var reference = _build_reference(SeaStateScript.State.RACE, _SEED)
	var start := Time.get_ticks_usec()
	reference.sample_parametric(_POS, _TIME)
	var one_us := Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for index in 4:
		reference.sample_parametric(Vector3(_POS.x + index * 3.0, 0.0, _POS.z), _TIME)
	var four_us := Time.get_ticks_usec() - start
	reference.prepare_time(_TIME)
	start = Time.get_ticks_usec()
	for index in 9:
		reference.sample_prepared(Vector3(_POS.x + index * 2.0, 0.0, _POS.z))
	var nine_prepared_us := Time.get_ticks_usec() - start
	print("INFO: coste 1 sample paramétrico = %.1f ms | 4 = %.1f ms | 9 preparados = %.1f ms" % [one_us / 1000.0, four_us / 1000.0, nine_prepared_us / 1000.0])


# Lambda formalizada: regression check del signo.
func _validate_lambda_regression() -> void:
	var source := _read_file("res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl")
	_check(source.contains("float lambda = -params.values.z"), "regression: lambda negativa formalizada en evolve shader")
	_check(not source.contains("minus_i_h * (k.x / k_length) * params.values.z"), "regression: sin usar el signo positivo de choppiness")
	_check(not source.contains("minus_i_h * (k.x / k_length) * -params.values.z"), "regression: sin el inline negativo temporal")


# La configuración exige choppiness >= 0 (lambda negativa es interna).
func _validate_negative_choppiness_rejected() -> void:
	var config := ConfigScript.new()
	config.choppiness = -0.5
	_check(not config.is_valid(), "config: choppiness negativo rechazado")
	config.choppiness = 0.0
	_check(config.is_valid(), "config: choppiness cero aceptado")


# Sin readback en los nuevos ficheros de query.
func _validate_no_readback_source() -> void:
	for path in ["res://ocean_v3/physics/ocean_query_reference.gd", "res://ocean_v3/physics/ocean_query_sample.gd"]:
		var source := _read_file(path)
		for forbidden in ["texture_get_data", "buffer_get_data", ".sync(", "submit("]:
			_check(forbidden not in source, "sin readback: %s no usa %s" % [path.get_file(), forbidden])


# --- Runtime (módulo real) -------------------------------------------------

func _validate_runtime() -> void:
	var module := get_first_node_in_group(&"ocean_fft")
	if module == null:
		_check(false, "runtime: módulo open_ocean_fft no disponible")
		return

	# L. La query del módulo usa exactamente el mismo H0 que la construcción canónica.
	var canonical = _build_reference(SeaStateScript.State.RACE, _SEED)
	var module_sample = module.sample_water(_POS, _TIME)
	var canonical_sample = canonical.sample_water(_POS, _TIME)
	_check(module_sample.valid and canonical_sample.valid, "L: samples válidos")
	_check(is_equal_approx(module_sample.height, canonical_sample.height) and module_sample.displacement.distance_to(canonical_sample.displacement) < 0.0001, "L: query del módulo coincide con referencia canónica (mismo H0 GPU/CPU)")

	# H. El band debug visual no altera la query.
	var before_band = module.sample_water(_POS, _TIME)
	module.cycle_band_debug()
	module.cycle_band_debug()
	var after_band = module.sample_water(_POS, _TIME)
	_check(_samples_equal(before_band, after_band), "H: band debug no altera query")

	# J. Reset conservando seed reproduce el sample.
	var before_reset = module.sample_water(_POS, _TIME)
	var clock := root.get_node_or_null("SimulationClock")
	if clock != null:
		clock.reset_simulation()
		var after_reset = module.sample_water(_POS, _TIME)
		_check(_samples_equal(before_reset, after_reset), "J: reset con misma seed reproduce sample")
	else:
		_check(false, "J: SimulationClock no disponible")

	# K. Cambiar sea state actualiza el H0 CPU que usa la query.
	module.set_sea_state(SeaStateScript.State.CALM)
	var calm_module = module.sample_water(_POS, _TIME)
	var calm_canonical = _build_reference(SeaStateScript.State.CALM, _SEED)
	var calm_can = calm_canonical.sample_water(_POS, _TIME)
	_check(is_equal_approx(calm_module.height, calm_can.height) and calm_module.displacement.distance_to(calm_can.displacement) < 0.0001, "K: set_sea_state actualiza H0 CPU de la query")
	_check(not _samples_equal(calm_module, before_band), "K: CALM produce sample distinto de RACE")
	module.set_sea_state(SeaStateScript.State.RACE)


func _samples_equal(a, b) -> bool:
	if a == null or b == null:
		return false
	return a.height == b.height and a.displacement == b.displacement and a.normal == b.normal and a.surface_velocity == b.surface_velocity


func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _finish() -> void:
	if _failures == 0:
		print("PHASE_2A_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_2A_VALIDATION: %d fallos" % _failures)
		quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

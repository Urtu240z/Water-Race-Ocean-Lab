extends SceneTree
## ValidaciÃ³n de Fase 2C: OceanQueryNative (GDExtension) vs OceanQueryReduced
## GDScript. Ejecutan el MISMO conjunto de pares compactos, por lo que deben
## coincidir con tolerancias numÃ©ricas estrictas (~1e-7, diferencias libm).
##
## Si la DLL nativa no estÃ¡ construida, el test hace SKIP (no falla).

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const SEED := 20260820
const EXTENSION_PATH := "res://native/ocean_query/water_race_ocean_query.gdextension"
# Contrato del buffer plano nativo (stride 15; ver ocean_query_native.h).
const S_STRIDE := 15
const S_HEIGHT := 1

var _failures := 0
var _native = null


func _initialize() -> void:
	_native = _try_load_native()
	if _native == null:
		print("PHASE_2C_VALIDATION: SKIP (OceanQueryNative no disponible; la DLL no estÃ¡ construida)")
		quit(0)
		return
	_validate_synthetic()
	_validate_real_states()
	_validate_batch()
	_validate_sea_level()
	if _failures == 0:
		print("PHASE_2C_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_2C_VALIDATION: %d fallos" % _failures)
		quit(1)


func _try_load_native():
	if not ResourceLoader.exists(EXTENSION_PATH):
		return null
	if not FileAccess.file_exists("res://native/ocean_query/bin/water_race_ocean_query.dll"):
		return null
	load(EXTENSION_PATH)
	if not ClassDB.class_exists(&"OceanQueryNative"):
		return null
	return ClassDB.instantiate(&"OceanQueryNative")


func _build_reduced(state: int, seed: int, budget := 1024):
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(seed, config.id)))
	var reduced = QueryReducedScript.new()
	reduced.set_budget(budget, budget, budget)
	reduced.set_spectrum(configs, h0_datas)
	return reduced


func _setup_native(reduced):
	_native.clear()
	_native.set_sea_level(0.0)
	for cascade in reduced.get_cascades_compact():
		_native.set_cascade_data(
			cascade.index, cascade.inv_n2,
			cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2,
			cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight,
			cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	_native.finalize_spectrum()


# SintÃ©tico pequeÃ±o (N=16): equivalencia paramÃ©trica + world.
func _validate_synthetic() -> void:
	var config := ConfigScript.new()
	config.resolution = 16
	config.domain_size_m = 64.0
	config.gravity_mps2 = 9.81
	config.choppiness = 0.8
	config.target_hs_m = 1.0
	config.min_wavelength_m = 0.5
	config.max_wavelength_m = 44.8
	var h0 := SpectrumScript.build_h0_rgba32f(config, 12345)
	var reduced = QueryReducedScript.new()
	reduced.set_budget(16, 16, 16)
	reduced.set_spectrum([config], [h0])
	_setup_native(reduced)
	for t: float in [0.0, 1.3]:
		for p in [Vector3(2.0, 0.0, 5.0), Vector3(11.0, 0.0, -7.0), Vector3(-13.0, 0.0, 21.0)]:
			var g = reduced.sample_water(p, t)
			var out = _native.sample_world(p.x, p.z, t)
			_compare_sample("sintÃ©tico q=%s t=%.1f" % [p, t], g, out)


# RACE y ROUGH reales (world-space, Newton independiente).
func _validate_real_states() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var reduced = _build_reduced(state, SEED)
		_setup_native(reduced)
		for t: float in [0.0, 2.3]:
			for p in [Vector3(10.0, 0.0, 20.0), Vector3(37.5, 0.0, -12.25), Vector3(-25.0, 0.0, 60.0)]:
				var g = reduced.sample_water(p, t)
				var out = _native.sample_world(p.x, p.z, t)
				_compare_sample("%s world q=%s t=%.1f" % [state_name, p, t], g, out)
		print("PASS: %s world-space (3 posiciones Ã— 2 tiempos)" % state_name)


# Batch == individual (la matemÃ¡tica no cambia en batch).
func _validate_batch() -> void:
	var reduced = _build_reduced(SeaStateScript.State.RACE, SEED)
	_setup_native(reduced)
	var positions := PackedVector3Array()
	for i in 8:
		positions.append(Vector3(-8.0 + i * 2.0, 0.0, 4.0))
	_native.ensure_prepared(1.7)
	var batch_out = _native.sample_batch_prepared(positions)
	_check(batch_out.size() == 8 * 15, "batch: stride correcto (%d)" % batch_out.size())
	for i in 8:
		var individual = _native.sample_prepared(positions[i].x, positions[i].z)
		for field in 15:
			if absf(batch_out[i * 15 + field] - individual[field]) > 1.0e-12:
				_check(false, "batch != individual en pos %d campo %d" % [i, field])
				return
	_check(true, "batch == individual (8 posiciones, 15 campos)")


# Sea level absoluto.
func _validate_sea_level() -> void:
	var reduced = _build_reduced(SeaStateScript.State.RACE, SEED)
	_native.set_sea_level(7.25)
	_setup_native(reduced) # set_sea_level despuÃ©s de finalize
	_native.set_sea_level(7.25)
	var out = _native.sample_world(12.0, -5.0, 1.5)
	_check(out[S_HEIGHT] > 7.0, "sea level: height nativa por encima de 7.25")
	var g = reduced.sample_water(Vector3(12.0, 0.0, -5.0), 1.5)
	_check(absf(out[1] - (7.25 + g.displacement.y)) < 1.0e-6, "sea level: height == 7.25 + displacement.y")


func _compare_sample(label: String, g, out: PackedFloat64Array) -> void:
	if out.size() != 15:
		_check(false, "%s: stride invÃ¡lido (%d)" % [label, out.size()])
		return
	_check((out[0] > 0.5) == g.valid, "%s: valid" % label)
	_check(absf(out[1] - g.height) < 1.0e-7, "%s: height (%.3e)" % [label, absf(out[1] - g.height)])
	for i in 3:
		_check(absf(out[2 + i] - g.displacement[i]) < 1.0e-7, "%s: displacement[%d]" % [label, i])
		_check(absf(out[5 + i] - g.normal[i]) < 1.0e-7, "%s: normal[%d]" % [label, i])
		_check(absf(out[8 + i] - g.surface_velocity[i]) < 1.0e-7, "%s: velocity[%d]" % [label, i])
	_check(absf(out[11] - g.jacobian_det) < 1.0e-7, "%s: jacobian_det" % label)
	_check((out[12] > 0.5) == g.foldover_risk, "%s: foldover" % label)
	_check(absf(out[13] - g.query_residual_m) < 1.0e-7, "%s: residual" % label)
	_check(int(out[14]) == g.query_iterations, "%s: iterations" % label)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)



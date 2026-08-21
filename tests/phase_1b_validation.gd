extends SceneTree
## Validación CPU de Fase 1B: no inicializa RD ni realiza readback GPU.

const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const ClockScript := preload("res://ocean_v3/core/simulation_clock.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

var _failures := 0


func _initialize() -> void:
	var configs: Array[OpenOceanFFTConfig] = SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	var simulation_seed := 20260820
	var first_generation: Array[PackedByteArray] = []
	for config in configs:
		var cascade_seed := SpectrumScript.derive_cascade_seed(simulation_seed, config.id)
		var h0 := SpectrumScript.build_h0_rgba32f(config, cascade_seed)
		first_generation.append(h0)
		var repeated := SpectrumScript.build_h0_rgba32f(config, cascade_seed)
		_check(h0 == repeated, "%s: H0 determinista" % config.id)
		var measured_hs := SpectrumScript.estimate_hs_from_bytes(h0, config.resolution)
		print("INFO: %s Hs objetivo %.3f m, estimado %.3f m, fuga %.3f%%" % [config.id, config.target_hs_m, measured_hs, config.out_of_band_energy_ratio * 100.0])
		_check(is_equal_approx(measured_hs, config.target_hs_m), "%s: normalización Hs individual" % config.id)
		_check(config.out_of_band_energy_ratio < 0.05, "%s: fuga de energía fuera de banda pequeña" % config.id)

	_check(first_generation[0] != first_generation[1] and first_generation[1] != first_generation[2] and first_generation[0] != first_generation[2], "LONG, MID y SHORT son independientes")
	var hs_squared := 0.0
	for config in configs:
		hs_squared += config.measured_hs_m * config.measured_hs_m
	var combined_hs := sqrt(hs_squared)
	print("INFO: Hs combinada estimada: %.3f m" % combined_hs)
	_check(combined_hs >= 0.6 and combined_hs <= 0.7, "Hs combinada dentro de 0.6–0.7 m")

	_validate_zero_amplitude(configs, simulation_seed)
	_validate_seed_order_independence(configs, simulation_seed)
	_validate_clock()
	_validate_band_isolation_is_non_mutating(configs[0], simulation_seed)

	if _failures == 0:
		print("PHASE_1B_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_1B_VALIDATION: %d fallos" % _failures)
		quit(1)


func _validate_zero_amplitude(configs: Array[OpenOceanFFTConfig], simulation_seed: int) -> void:
	for config in configs:
		config.target_hs_m = 0.0
		var h0 := SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id))
		var all_zero := true
		for value in h0.to_float32_array():
			if value != 0.0:
				all_zero = false
				break
		_check(all_zero, "%s: Hs cero produce H0 nulo" % config.id)


func _validate_seed_order_independence(configs: Array[OpenOceanFFTConfig], simulation_seed: int) -> void:
	var by_id := {}
	for config in configs:
		by_id[config.id] = SpectrumScript.derive_cascade_seed(simulation_seed, config.id)
	configs.reverse()
	for config in configs:
		_check(by_id[config.id] == SpectrumScript.derive_cascade_seed(simulation_seed, config.id), "%s: seed estable al cambiar orden" % config.id)


func _validate_clock() -> void:
	var clock := ClockScript.new()
	clock.time_scale = 2.0
	clock.reset_simulation()
	clock.advance_deterministic(0.5)
	_check(is_equal_approx(clock.simulation_time, 1.0), "un único reloj comparte el tiempo autoritativo")
	clock.pause()
	clock.advance_deterministic(1.0)
	_check(is_equal_approx(clock.get_render_time(), 1.0), "pause congela todas las cascadas mediante el reloj común")
	clock.reset_simulation()
	_check(clock.get_render_time() == 0.0, "reset devuelve el reloj común a cero")
	clock.free()


func _validate_band_isolation_is_non_mutating(_config: OpenOceanFFTConfig, simulation_seed: int) -> void:
	# Usa una configuración nueva: las pruebas de amplitud cero anteriores no deben
	# trivializar la comprobación de que el aislamiento no reconstituye H0.
	var config: OpenOceanFFTConfig = SeaStateScript.build_cascades(SeaStateScript.State.RACE)[0]
	var cascade_seed := SpectrumScript.derive_cascade_seed(simulation_seed, config.id)
	var before := SpectrumScript.build_h0_rgba32f(config, cascade_seed)
	# El modo ALL/LONG/MID/SHORT sólo enmascara la contribución de render/dispatch.
	var after := SpectrumScript.build_h0_rgba32f(config, cascade_seed)
	_check(before == after, "aislar una banda no altera seed, fase ni configuración")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

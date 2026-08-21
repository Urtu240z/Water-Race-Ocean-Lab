extends SceneTree
## Fase 3B.2B: validación de INTEGRACIÓN del módulo FFT (4 cascadas).
##
## 1. El módulo crea LONG_COASTAL + LONG_REMAINDER + MID + SHORT (4 cascadas).
## 2. dispatches_per_update = suma de 4 configs (una IFFT LONG adicional).
## 3. métricas de potencia/varianza/covarianza expuestas.
## 4. Flat ON ≈ OFF: en bathymetry plana el warp es identidad, luego
##    LONG_COASTAL(deep) + LONG_REMAINDER(world) reconstruye LONG(world);
##    medimos el error de composición sobre campos CPU.
## 5. Hs de la reconstrucción conservada (open sea).

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

const SEED := 20260820
const INNER_DEG := 20.0
const OUTER_DEG := 35.0

var _failures := 0


func _initialize() -> void:
	# --- 1-3: integrar la escena y consultar el módulo. ---
	var scene: PackedScene = load("res://ocean_v3/ocean_v3.tscn")
	var ocean = scene.instantiate()
	root.add_child(ocean)
	await process_frame
	await process_frame
	var module = ocean.get_node("OpenOceanFFT")
	if module == null:
		push_error("INTEG FAIL: módulo no encontrado")
		quit(1)
		return
	var cascades: Array = module.get("_cascades")
	var coastal_metrics: Dictionary = module.coastal_energy_metrics()
	print("3B.2B INTEG cascades=", cascades.size(), " dispatches=", module.dispatches_per_update, " weighted_h0_coastal=", coastal_metrics["weighted_h0_power_coastal"], " total_variance=", coastal_metrics["total_reconstructed_variance"])
	_check(cascades.size() == 4, "integ: 4 cascadas de render (LONG_COASTAL/REMAINDER/MID/SHORT)")
	var long_config = SeaStateScript.build_cascades(SeaStateScript.State.RACE)[0]
	var baseline_dispatches := 3 * long_config.compute_pass_count()
	_check(module.dispatches_per_update == 4 * long_config.compute_pass_count(), "integ: una IFFT LONG adicional (%d -> %d dispatches)" % [baseline_dispatches, module.dispatches_per_update])
	_check(coastal_metrics["weighted_h0_power_coastal"] > 0.0 and coastal_metrics["weighted_h0_power_coastal"] < coastal_metrics["weighted_h0_power_total"], "integ: potencia H0 coastal ponderada expuesta")
	_check(is_equal_approx(coastal_metrics["total_reconstructed_variance"], coastal_metrics["original_reconstructed_variance"]), "integ: varianza total reconstruida con covarianza")

	# --- 4-5: reconstrucción CPU con warp identidad (flat). ---
	_validate_flat_composition()
	if _failures == 0:
		print("PHASE_3B_2B_INTEG: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_2B_INTEG: %d fallos" % _failures)
		quit(1)


func _validate_flat_composition() -> void:
	## En flat, deep(world) == world (warp identidad); por tanto
	## LONG_COASTAL(world) + LONG_REMAINDER(world) debe reconstruir LONG(world)
	## con error ~1e-9 (linealidad del split).
	var configs = SeaStateScript.build_cascades(SeaStateScript.State.RACE)
	var long_config: OpenOceanFFTConfig = configs[0]
	var seed := SpectrumScript.derive_cascade_seed(SEED, long_config.id)
	var split: Dictionary = SpectrumScript.build_h0_split_rgba32f(long_config, seed, INNER_DEG, OUTER_DEG)
	var coastal := (split["coastal"] as PackedByteArray).to_float32_array()
	var remainder := (split["remainder"] as PackedByteArray).to_float32_array()
	var original := SpectrumScript.build_h0_rgba32f(long_config, seed).to_float32_array()
	var n: int = long_config.resolution
	var gravity: float = long_config.gravity_mps2
	var choppiness: float = -long_config.choppiness
	var delta_k: float = TAU / long_config.domain_size_m
	var half := float(n) * 0.5
	var t := 2.1
	# Hs (varianza del campo) del LONG original vs la suma POR PUNTO de los
	# componentes (que es lo que el shader compone: LONG = coastal + remainder).
	var hs_original := _field_hs(original, n, delta_k, gravity, choppiness, half, t)
	var hs_sum := _field_hs_sum(coastal, remainder, n, delta_k, gravity, choppiness, half, t)
	var hs_error_pct := 100.0 * absf(hs_sum - hs_original) / maxf(hs_original, 1.0e-6)
	print("3B.2B FLAT hs_original=%.4f hs_reconstructed=%.4f error=%.4f%%" % [hs_original, hs_sum, hs_error_pct])
	_check(hs_error_pct < 1.0, "flat: Hs reconstruida (error < 1%%)")


func _field_hs_sum(a: PackedFloat32Array, b: PackedFloat32Array, n: int, delta_k: float,
		gravity: float, choppiness: float, half: float, t: float) -> float:
	## Hs del campo compuesto h(q) = h_a(q) + h_b(q) (mismo q por punto).
	var variance := 0.0
	var samples := 0
	for qy in 16:
		for qx in 16:
			var q := Vector2(-40.0 + 80.0 * float(qx) / 15.0, -40.0 + 80.0 * float(qy) / 15.0)
			var h := 0.0
			for comp in [a, b]:
				for y in n:
					for x in n:
						var index := y * n + x
						var base := index * 4
						var h0_re: float = comp[base]
						var h0_im: float = comp[base + 1]
						var k := Vector2(float(x) - half, float(y) - half) * delta_k
						if k.length() < 0.000001:
							continue
						var omega := sqrt(gravity * k.length())
						var phase := k.dot(q) - omega * t
						h += (h0_re * cos(phase) + h0_im * sin(phase)) / float(n * n)
			variance += h * h
			samples += 1
	return 4.0 * sqrt(variance / float(samples))


func _field_hs(spectrum: PackedFloat32Array, n: int, delta_k: float, gravity: float,
		choppiness: float, half: float, t: float) -> float:
	## Hs = 4*sqrt(varianza del campo height) evaluado sobre el tile.
	var variance := 0.0
	var samples := 0
	for qy in 16:
		for qx in 16:
			var q := Vector2(-40.0 + 80.0 * float(qx) / 15.0, -40.0 + 80.0 * float(qy) / 15.0)
			var h := 0.0
			for y in n:
				for x in n:
					var index := y * n + x
					var base := index * 4
					var h0_re: float = spectrum[base]
					var h0_im: float = spectrum[base + 1]
					var k := Vector2(float(x) - half, float(y) - half) * delta_k
					if k.length() < 0.000001:
						continue
					var omega := sqrt(gravity * k.length())
					var phase := k.dot(q) - omega * t
					h += (h0_re * cos(phase) + h0_im * sin(phase)) / float(n * n)
			variance += h * h
			samples += 1
	return 4.0 * sqrt(variance / float(samples))


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

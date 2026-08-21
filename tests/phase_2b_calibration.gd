extends SceneTree
## CalibraciÃ³n de Fase 2B: elige presupuestos de pares por banda para
## OceanQueryReduced contra la Golden Reference (dataset fijo).
##
## No forma parte del test rÃ¡pido diario. Construye un dataset Golden UNA vez
## (3 estados Ã— 2 seeds Ã— 3 tiempos Ã— 2 posiciones = 36 samples world) y luego
## evalÃºa muchos presupuestos contra esos mismos samples.
##
## Uso: godot --headless --script res://tests/phase_2b_calibration.gd
## Puede tardar 1-2 minutos.

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")
const QueryRefScript := preload("res://ocean_v3/physics/ocean_query_reference.gd")
const QueryReducedScript := preload("res://ocean_v3/physics/ocean_query_reduced.gd")

const STATES := [SeaStateScript.State.CALM, SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]
const SEEDS := [20260820, 20260821]
const TIMES := [0.0, 3.7, 11.3]
const POSITIONS := [Vector3(10.0, 0.0, 20.0), Vector3(45.0, 0.0, -35.0)]
const BUDGETS := [16, 32, 64, 128, 256, 512, 1024]

# Objetivos de precisiÃ³n por estado (secciÃ³n 21).
const TARGETS := {
	SeaStateScript.State.RACE: {
		"height_rmse": 0.015, "height_p95": 0.030, "height_max": 0.050,
		"normal_rmse": 1.5, "normal_p95": 3.0, "normal_max": 6.0,
		"vel_rmse": 0.15, "vel_p95": 0.30, "disp_rmse": 0.020,
	},
	SeaStateScript.State.ROUGH: {
		"height_rmse": 0.025, "height_p95": 0.050, "height_max": 0.080,
		"normal_rmse": 2.5, "normal_p95": 5.0, "normal_max": 8.0,
		"vel_rmse": 0.25, "vel_p95": 0.45, "disp_rmse": 0.035,
	},
}

var _golden_samples: Array = [] # {state, seed, time, pos, sample}
var _reduced_pool: Dictionary = {} # key "state:seed" -> reduced


func _initialize() -> void:
	print("=== PHASE_2B_CALIBRATION: construyendo dataset Golden (36 samples) ===")
	_build_golden_dataset()
	print("=== PHASE_2B_CALIBRATION: barriendo presupuestos ===")
	var best: Dictionary = {}
	var best_total := 1 << 30
	for long_pairs: int in BUDGETS:
		for mid_pairs: int in BUDGETS:
			for short_pairs: int in BUDGETS:
				var metrics := _evaluate_budget(long_pairs, mid_pairs, short_pairs)
				var total := long_pairs + mid_pairs + short_pairs
				var line := "BUDGET L=%d M=%d S=%d T=%d" % [long_pairs, mid_pairs, short_pairs, total]
				for state_name in ["CALM", "RACE", "ROUGH"]:
					var m: Dictionary = metrics[state_name]
					line += " | %s H%.4f/%.4f/%.4f N%.2f/%.2f/%.2f V%.3f/%.3f D%.4f" % [
						state_name,
						m.height_rmse, m.height_p95, m.height_max,
						m.normal_rmse, m.normal_p95, m.normal_max,
						m.vel_rmse, m.vel_p95, m.disp_rmse,
					]
				print(line)
				if _meets_targets(metrics) and total < best_total:
					best_total = total
					best = {"long": long_pairs, "mid": mid_pairs, "short": short_pairs, "metrics": metrics}
	if best.is_empty():
		print("=== PHASE_2B_CALIBRATION: NINGÃšN presupuesto razonable cumple los objetivos ===")
	else:
		print("=== PHASE_2B_CALIBRATION: MEJOR = LONG %d | MID %d | SHORT %d | TOTAL %d pares ===" % [best.long, best.mid, best.short, best.long + best.mid + best.short])
		var energy := _energy_fractions(best.long, best.mid, best.short)
		for state_name in ["CALM", "RACE", "ROUGH"]:
			var m: Dictionary = best.metrics[state_name]
			print("  %s: H RMSE %.4f P95 %.4f MAX %.4f | N RMSE %.2fÂ° P95 %.2fÂ° MAX %.2fÂ° | V RMSE %.3f P95 %.3f | D RMSE %.4f | detJ min %.3f / golden %.3f / sign-diff %d%%" % [
				state_name, m.height_rmse, m.height_p95, m.height_max,
				m.normal_rmse, m.normal_p95, m.normal_max,
				m.vel_rmse, m.vel_p95, m.disp_rmse,
				m.det_min_red, m.det_min_golden, m.det_sign_diff,
			])
		for i in 3:
			var band: String = ["LONG", "MID", "SHORT"][i]
			print("  EnergÃ­a %s (L%d/M%d/S%d): height %.1f%% slope %.1f%% velocity %.1f%% jacobian %.1f%%" % [
				band, best.long, best.mid, best.short,
				energy[i].height * 100.0, energy[i].slope * 100.0, energy[i].velocity * 100.0, energy[i].jacobian * 100.0,
			])
	print("=== PHASE_2B_CALIBRATION: FIN ===")
	quit(0)


func _build_golden_dataset() -> void:
	_golden_samples.clear()
	_reduced_pool.clear()
	for state in STATES:
		for seed in SEEDS:
			var spectrum := _build_spectrum(state, seed)
			var golden = QueryRefScript.new()
			golden.set_spectrum(spectrum[0], spectrum[1])
			var reduced = QueryReducedScript.new()
			reduced.set_spectrum(spectrum[0], spectrum[1])
			_reduced_pool["%d:%d" % [state, seed]] = reduced
			for time in TIMES:
				for position in POSITIONS:
					var sample = golden.sample_water(position, time)
					_golden_samples.append({
						"state": state, "seed": seed, "time": time, "pos": position, "sample": sample,
					})
			print("  dataset: state=%s seed=%d (Golden listo)" % [SeaStateScript.state_name(state), seed])


func _build_spectrum(state: int, simulation_seed: int) -> Array:
	var configs = SeaStateScript.build_cascades(state)
	var h0_datas: Array[PackedByteArray] = []
	for config in configs:
		h0_datas.append(SpectrumScript.build_h0_rgba32f(config, SpectrumScript.derive_cascade_seed(simulation_seed, config.id)))
	return [configs, h0_datas]


func _evaluate_budget(long_pairs: int, mid_pairs: int, short_pairs: int) -> Dictionary:
	# Aplica el presupuesto a todos los reduced del pool (sin re-decodificar).
	for reduced in _reduced_pool.values():
		reduced.set_budget(long_pairs, mid_pairs, short_pairs)
	var metrics: Dictionary = {}
	for state in STATES:
		metrics[SeaStateScript.state_name(state)] = _state_metrics(state, long_pairs, mid_pairs, short_pairs)
	return metrics


func _state_metrics(state: int, _l: int, _m: int, _s: int) -> Dictionary:
	var h_errors: Array[float] = []
	var disp_errors: Array[float] = []
	var normal_errors: Array[float] = []
	var vel_errors: Array[float] = []
	var jacobian_errors: Array[float] = []
	var det_min_red := 1.0e9
	var det_min_golden := 1.0e9
	var det_sign_diff := 0
	var invalid := 0
	var max_residual := 0.0
	var iter_sum := 0
	var iter_count := 0
	var iter_max := 0
	var count := 0
	for entry in _golden_samples:
		if entry.state != state:
			continue
		var reduced = _reduced_pool["%d:%d" % [state, entry.seed]]
		var r = reduced.sample_water(entry.pos, entry.time)
		var g = entry.sample
		count += 1
		if not r.valid:
			invalid += 1
			continue
		h_errors.append(absf(r.height - g.height))
		disp_errors.append(Vector2(r.displacement.x - g.displacement.x, r.displacement.z - g.displacement.z).length())
		var dot := clampf(g.normal.dot(r.normal), -1.0, 1.0)
		normal_errors.append(rad_to_deg(acos(dot)))
		vel_errors.append(r.surface_velocity.distance_to(g.surface_velocity))
		jacobian_errors.append(absf(r.jacobian_det - g.jacobian_det))
		det_min_red = minf(det_min_red, r.jacobian_det)
		det_min_golden = minf(det_min_golden, g.jacobian_det)
		if (r.jacobian_det <= 0.0) != (g.jacobian_det <= 0.0):
			det_sign_diff += 1
		max_residual = maxf(max_residual, r.query_residual_m)
		iter_sum += r.query_iterations
		iter_max = maxi(iter_max, r.query_iterations)
		iter_count += 1
	var m: Dictionary = {}
	m.height_rmse = _rmse(h_errors)
	m.height_p95 = _p95(h_errors)
	m.height_max = _max(h_errors)
	m.disp_rmse = _rmse(disp_errors)
	m.disp_p95 = _p95(disp_errors)
	m.normal_rmse = _rmse(normal_errors)
	m.normal_p95 = _p95(normal_errors)
	m.normal_max = _max(normal_errors)
	m.vel_rmse = _rmse(vel_errors)
	m.vel_p95 = _p95(vel_errors)
	m.det_rmse = _rmse(jacobian_errors)
	m.det_min_red = det_min_red
	m.det_min_golden = det_min_golden
	m.det_sign_diff = det_sign_diff
	m.invalid = invalid
	m.invalid_pct = 100.0 * invalid / float(maxi(count, 1))
	m.max_residual = max_residual
	m.iter_avg = float(iter_sum) / float(maxi(iter_count, 1))
	m.iter_max = iter_max
	return m


func _meets_targets(metrics: Dictionary) -> bool:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var t: Dictionary = TARGETS[state]
		var m: Dictionary = metrics[SeaStateScript.state_name(state)]
		if m.height_rmse > t.height_rmse or m.height_p95 > t.height_p95 or m.height_max > t.height_max:
			return false
		if m.normal_rmse > t.normal_rmse or m.normal_p95 > t.normal_p95 or m.normal_max > t.normal_max:
			return false
		if m.vel_rmse > t.vel_rmse or m.vel_p95 > t.vel_p95:
			return false
		if m.disp_rmse > t.disp_rmse:
			return false
		if m.invalid_pct > 0.0:
			return false
	return true


func _energy_fractions(long_pairs: int, mid_pairs: int, short_pairs: int) -> Array:
	var result: Array = []
	var reduced = _reduced_pool["%d:%d" % [SeaStateScript.State.RACE, SEEDS[0]]]
	# Reusa un reduced para consultar las fracciones por banda del estado RACE.
	reduced.set_budget(long_pairs, mid_pairs, short_pairs)
	var fractions = reduced.captured_energy_fractions()
	for i in 3:
		result.append(fractions[i])
	return result


func _rmse(errors: Array[float]) -> float:
	if errors.is_empty():
		return 0.0
	var sum := 0.0
	for e in errors:
		sum += e * e
	return sqrt(sum / float(errors.size()))


func _p95(errors: Array[float]) -> float:
	if errors.is_empty():
		return 0.0
	var sorted := errors.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size()) * 0.95)) - 1, 0, sorted.size() - 1)
	return sorted[index]


func _max(errors: Array[float]) -> float:
	if errors.is_empty():
		return 0.0
	var result := 0.0
	for e in errors:
		result = maxf(result, e)
	return result



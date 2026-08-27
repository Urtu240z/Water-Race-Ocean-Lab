class_name OceanQueryReduced
extends RefCounted
## Evaluador de PRODUCCIÓN de OceanQuery (Fase 2B).
##
## Misma semántica que la Golden Reference (Fase 2A.1): superficie paramétrica
## P(q,t).xz = q + Dxz(q,t), y sample_water(world_xz,t) invierte world_xz -> q
## Convención: wind_direction/incoming_direction apuntan HACIA la propagación;
## la fase temporal usa e^{-iωt} junto a la reconstrucción e^{+ik·x}.
## con Newton-Raphson. Mismo H0 que la GPU. Lambda negativa interna.
##
## Dos etapas obligatorias:
##  ETAPA A: compresión EXACTA de pares +k/-k (representación canónica).
##           FULL_PAIRS debe ser matemáticamente equivalente a Golden.
##  ETAPA B: selección aproximada de pares por importancia multiojetivo
##           (height/slope/velocity/jacobian), con presupuestos por banda.
##
## Almacenamiento plano (PackedFloat64Array) preparado al cambiar seed/state/H0;
## sin Dictionary/RefCounted por modo, sin allocations por query (los
## acumuladores son miembros reutilizados).

const SampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")
const CoastalRuntimeScript := preload("res://ocean_v3/physics/ocean_query_coastal_runtime.gd")
const SeaStateZoneMathScript := preload("res://ocean_v3/core/sea_state_zone_math.gd")

const MODE_FULL_PAIRS := 0
const MODE_REDUCED := 1

# Newton de producción (REDUCED).
const MAX_ITERATIONS := 3
const POSITION_TOLERANCE_M := 1.0e-3
const JACOBIAN_EPSILON := 1.0e-6
# Newton de equivalencia (FULL_PAIRS, mismos valores que Golden).
const FULL_MAX_ITERATIONS := 8
const FULL_POSITION_TOLERANCE_M := 1.0e-4

const DEFAULT_BUDGET := 128

# Codificación de orden total para selección (sort nativo de ints).
const IMPORTANCE_QUANT := 1 << 23
const KEY_SCALE := 1 << 32


class _CascadeData:
	var lambda := 0.0
	var transition_lambda := 0.0
	var inv_n2 := 0.0
	# Pares canónicos completos (para selección y modo FULL_PAIRS).
	var f_kx := PackedFloat64Array()
	var f_ky := PackedFloat64Array()
	var f_omega := PackedFloat64Array()
	var f_h0_re := PackedFloat64Array()
	var f_h0_im := PackedFloat64Array()
	var f_h0n_re := PackedFloat64Array()
	var f_h0n_im := PackedFloat64Array()
	var f_parity := PackedFloat64Array()
	var f_weight := PackedFloat64Array()
	var f_importance := PackedFloat64Array()
	# 3B.3: pesos de H0 para las dos mitades canónicas +k/-k. No se promedian:
	# el renderer aplica w(k) a A y w(-k) a B por separado.
	var f_coastal_weight_pos := PackedFloat64Array()
	var f_coastal_weight_neg := PackedFloat64Array()
	# Índices de los pares ordenados por importancia DESC (una vez por espectro).
	var sorted_indices := PackedInt32Array()
	# Conjunto compacto seleccionado (usa el evaluador).
	var kx := PackedFloat64Array()
	var ky := PackedFloat64Array()
	var omega := PackedFloat64Array()
	var a1 := PackedFloat64Array()
	var a2 := PackedFloat64Array()
	var c11 := PackedFloat64Array()
	var c12 := PackedFloat64Array()
	var c21 := PackedFloat64Array()
	var c22 := PackedFloat64Array()
	var parity := PackedFloat64Array()
	var weight := PackedFloat64Array()
	var h0_re := PackedFloat64Array()
	var h0_im := PackedFloat64Array()
	var h0n_re := PackedFloat64Array()
	var h0n_im := PackedFloat64Array()
	# Endpoint B, allocated only while a global spectrum transition is active.
	var transition_h0_re := PackedFloat64Array()
	var transition_h0_im := PackedFloat64Array()
	var transition_h0n_re := PackedFloat64Array()
	var transition_h0n_im := PackedFloat64Array()
	var coastal_weight_pos := PackedFloat64Array()
	var coastal_weight_neg := PackedFloat64Array()
	var transition_coastal_weight_pos := PackedFloat64Array()
	var transition_coastal_weight_neg := PackedFloat64Array()
	# Tiempo preparado (ev_h/ev_v por modo).
	var ev_h_re := PackedFloat64Array()
	var ev_h_im := PackedFloat64Array()
	var ev_v_re := PackedFloat64Array()
	var ev_v_im := PackedFloat64Array()
	# A/B evolucionados por separado: necesarios para C(q) con w(k),w(-k).
	var ev_a_h_re := PackedFloat64Array()
	var ev_a_h_im := PackedFloat64Array()
	var ev_b_h_re := PackedFloat64Array()
	var ev_b_h_im := PackedFloat64Array()
	var ev_a_v_re := PackedFloat64Array()
	var ev_a_v_im := PackedFloat64Array()
	var ev_b_v_re := PackedFloat64Array()
	var ev_b_v_im := PackedFloat64Array()
	var count := 0


var _cascades: Array[_CascadeData] = []
var _sea_level := 0.0
var _prepared_valid := false
var _prepared_time := 0.0
var _breaker_prepared_valid := false
var _breaker_prepared_time := 0.0
var _crest_sharpen: Dictionary = {} # 5R1D: config de crest sharpening (world-space).
var _mode := MODE_REDUCED
var _budgets: Array[int] = [DEFAULT_BUDGET, DEFAULT_BUDGET, DEFAULT_BUDGET]
var _native_backend: RefCounted = null
var _coastal_runtime = null
var _coastal_wind_direction := Vector2.RIGHT
var _coastal_inner_deg := 20.0
var _coastal_outer_deg := 35.0
var _spectrum_transition_active := false
var _spectrum_transition_alpha := 0.0
var _spectrum_transition_target_cascades: Array[_CascadeData] = []
var _spectrum_transition_target_wind_direction := Vector2.RIGHT
var _sea_state_zone_descriptors: Array[Dictionary] = []

# Reused local-zone state and gradients. Zone targets are absolute global
# multipliers; gradients are required by the displaced-surface Jacobian.
var _zone_long_amplitude := 1.0
var _zone_mid_amplitude := 1.0
var _zone_short_amplitude := 1.0
var _zone_choppiness := 1.0
var _zone_grad_long_x := 0.0
var _zone_grad_long_z := 0.0
var _zone_grad_mid_x := 0.0
var _zone_grad_mid_z := 0.0
var _zone_grad_short_x := 0.0
var _zone_grad_short_z := 0.0
var _zone_grad_chop_x := 0.0
var _zone_grad_chop_z := 0.0

# Per-band accumulators reused by _accumulate: LONG, MID, SHORT, stride 12.
var _band_acc := PackedFloat64Array()

# Diagnóstico (sin push_warning por query).
var diagnostic_non_converged := 0
var diagnostic_last_iterations := 0
var diagnostic_last_residual := 0.0

# Acumuladores miembro reutilizados por evaluación (sin allocation por query).
var _acc_h := 0.0
var _acc_dx := 0.0
var _acc_dz := 0.0
var _acc_dhx := 0.0
var _acc_dhz := 0.0
var _acc_dxx := 0.0
var _acc_dxz := 0.0
var _acc_dzx := 0.0
var _acc_dzz := 0.0
var _acc_vh := 0.0
var _acc_vx := 0.0
var _acc_vz := 0.0

# Acumulador reutilizado para C(q) / C(F(q)); no se aloca por query.
var _coastal_h := 0.0
var _coastal_dx := 0.0
var _coastal_dz := 0.0
var _coastal_dhx := 0.0
var _coastal_dhz := 0.0
var _coastal_dxx := 0.0
var _coastal_dxz := 0.0
var _coastal_dzx := 0.0
var _coastal_dzz := 0.0
var _coastal_vh := 0.0
var _coastal_vx := 0.0
var _coastal_vz := 0.0

# Specialized Coastal breaker sampler. It intentionally keeps only the scalar
# LONG_COASTAL height gradient; no horizontal displacement/Jacobian/velocity.
var _breaker_long_h := 0.0
var _breaker_long_dhx := 0.0
var _breaker_long_dhz := 0.0


func _init() -> void:
	_band_acc.resize(36)


func _invalidate_prepared() -> void:
	_prepared_valid = false
	_breaker_prepared_valid = false


func set_sea_state_zones(descriptors: Array[Dictionary]) -> void:
	# Descriptors are rebuilt only when a zone changes; query evaluation only
	# reads this stable compact list and allocates nothing per sample.
	_sea_state_zone_descriptors = descriptors.duplicate()


func _evaluate_sea_state_zones(qx: float, qz: float) -> void:
	_zone_long_amplitude = 1.0
	_zone_mid_amplitude = 1.0
	_zone_short_amplitude = 1.0
	_zone_choppiness = 1.0
	_zone_grad_long_x = 0.0
	_zone_grad_long_z = 0.0
	_zone_grad_mid_x = 0.0
	_zone_grad_mid_z = 0.0
	_zone_grad_short_x = 0.0
	_zone_grad_short_z = 0.0
	_zone_grad_chop_x = 0.0
	_zone_grad_chop_z = 0.0
	if _sea_state_zone_descriptors.is_empty():
		return
	var point := Vector2(qx, qz)
	for descriptor in _sea_state_zone_descriptors:
		var center: Vector2 = descriptor["center"]
		var axis: Vector2 = descriptor["axis"]
		var half_extents: Vector2 = descriptor["half_extents"]
		var feather: float = float(descriptor["feather"])
		var zone_strength: float = clampf(float(descriptor["strength"]), 0.0, 1.0)
		var sdf_weight := SeaStateZoneMathScript.weight_and_gradient(point, center, axis, half_extents, feather)
		var blend_weight := clampf(sdf_weight.x * zone_strength, 0.0, 1.0)
		if blend_weight <= 0.0:
			continue
		var grad_weight_x := sdf_weight.y * zone_strength
		var grad_weight_z := sdf_weight.z * zone_strength
		var target: Vector4 = descriptor["target"]
		var old_long := _zone_long_amplitude
		var old_mid := _zone_mid_amplitude
		var old_short := _zone_short_amplitude
		var old_chop := _zone_choppiness
		_zone_long_amplitude = lerpf(old_long, target.x, blend_weight)
		_zone_mid_amplitude = lerpf(old_mid, target.y, blend_weight)
		_zone_short_amplitude = lerpf(old_short, target.z, blend_weight)
		_zone_choppiness = lerpf(old_chop, target.w, blend_weight)
		_zone_grad_long_x = _zone_grad_long_x * (1.0 - blend_weight) + (target.x - old_long) * grad_weight_x
		_zone_grad_long_z = _zone_grad_long_z * (1.0 - blend_weight) + (target.x - old_long) * grad_weight_z
		_zone_grad_mid_x = _zone_grad_mid_x * (1.0 - blend_weight) + (target.y - old_mid) * grad_weight_x
		_zone_grad_mid_z = _zone_grad_mid_z * (1.0 - blend_weight) + (target.y - old_mid) * grad_weight_z
		_zone_grad_short_x = _zone_grad_short_x * (1.0 - blend_weight) + (target.z - old_short) * grad_weight_x
		_zone_grad_short_z = _zone_grad_short_z * (1.0 - blend_weight) + (target.z - old_short) * grad_weight_z
		_zone_grad_chop_x = _zone_grad_chop_x * (1.0 - blend_weight) + (target.w - old_chop) * grad_weight_x
		_zone_grad_chop_z = _zone_grad_chop_z * (1.0 - blend_weight) + (target.w - old_chop) * grad_weight_z


func set_spectrum(configs: Array[OpenOceanFFTConfig], h0_datas: Array[PackedByteArray]) -> void:
	assert(configs.size() == h0_datas.size())
	_spectrum_transition_active = false
	_spectrum_transition_alpha = 0.0
	_spectrum_transition_target_cascades = []
	_spectrum_transition_target_wind_direction = Vector2.RIGHT
	_cascades.clear()
	for index in configs.size():
		_cascades.append(_decode_cascade(configs[index], h0_datas[index]))
	if not configs.is_empty():
		_coastal_wind_direction = configs[0].wind_direction.normalized()
		_refresh_coastal_long_weights()
	_rebuild_selection()


func begin_spectrum_transition(target_configs: Array[OpenOceanFFTConfig], target_h0_datas: Array[PackedByteArray], initial_alpha := 0.0) -> void:
	var payload := prepare_spectrum_transition_target(
		target_configs, target_h0_datas, _budgets, _mode,
		_coastal_runtime != null and _coastal_runtime.enabled,
		_coastal_inner_deg, _coastal_outer_deg
	)
	begin_prepared_spectrum_transition(payload, initial_alpha)


static func prepare_spectrum_transition_target(target_configs: Array[OpenOceanFFTConfig], target_h0_datas: Array[PackedByteArray],
		budgets: Array[int], mode: int, coastal_active: bool, coastal_inner_deg: float, coastal_outer_deg: float) -> Dictionary:
	if target_configs.size() != target_h0_datas.size() or target_configs.size() != budgets.size():
		return {}
	var targets: Array[_CascadeData] = []
	for index in target_configs.size():
		var target := _decode_cascade(target_configs[index], target_h0_datas[index])
		if index == 0:
			_fill_coastal_weights_for_transition(target, target_configs[index].wind_direction, coastal_active, coastal_inner_deg, coastal_outer_deg)
		_compact_cascade(target, budgets[index], mode)
		targets.append(target)
	return {
		"cascades": targets,
		"long_wind_direction": target_configs[0].wind_direction.normalized() if not target_configs.is_empty() else Vector2.RIGHT,
	}


func begin_prepared_spectrum_transition(payload: Dictionary, initial_alpha := 0.0) -> bool:
	var targets: Array = payload.get("cascades", [])
	if _cascades.size() != targets.size() or targets.is_empty():
		push_error("OceanQuery prepared transition endpoints are incompatible.")
		return false
	for index in _cascades.size():
		var source: _CascadeData = _cascades[index]
		var target: _CascadeData = targets[index]
		if source.f_kx.size() != target.f_kx.size() \
			or not is_equal_approx(source.inv_n2, target.inv_n2):
			push_error("OceanQuery prepared transition topology differs.")
			return false
		_compact_transition_cascade(source, target, _budgets[index])
	_spectrum_transition_target_cascades = []
	for target in targets:
		_spectrum_transition_target_cascades.append(target as _CascadeData)
	_spectrum_transition_target_wind_direction = Vector2(payload.get("long_wind_direction", Vector2.RIGHT)).normalized()
	_spectrum_transition_active = true
	_spectrum_transition_alpha = clampf(initial_alpha, 0.0, 1.0)
	_invalidate_prepared()
	return true


func install_prepared_spectrum(payload: Dictionary) -> bool:
	var prepared: Array = payload.get("cascades", [])
	if prepared.is_empty():
		return false
	_cascades = []
	for cascade in prepared:
		_cascades.append(cascade as _CascadeData)
	_spectrum_transition_target_cascades = []
	_spectrum_transition_target_wind_direction = Vector2.RIGHT
	_spectrum_transition_active = false
	_spectrum_transition_alpha = 0.0
	_coastal_wind_direction = Vector2(payload.get("long_wind_direction", Vector2.RIGHT)).normalized()
	_invalidate_prepared()
	_sync_native()
	return true


func complete_spectrum_transition() -> void:
	if not _spectrum_transition_active or _spectrum_transition_target_cascades.is_empty():
		return
	_cascades = _spectrum_transition_target_cascades
	_spectrum_transition_target_cascades = []
	_coastal_wind_direction = _spectrum_transition_target_wind_direction
	_spectrum_transition_target_wind_direction = Vector2.RIGHT
	_spectrum_transition_active = false
	_spectrum_transition_alpha = 0.0
	_invalidate_prepared()
	_sync_native()


func set_spectrum_transition_alpha(alpha: float) -> void:
	if not _spectrum_transition_active:
		return
	_spectrum_transition_alpha = clampf(alpha, 0.0, 1.0)
	_invalidate_prepared()


func spectrum_transition_active() -> bool:
	return _spectrum_transition_active


func spectrum_transition_preparation_settings() -> Dictionary:
	return {
		"budgets": _budgets.duplicate(),
		"mode": _mode,
		"coastal_active": _coastal_runtime != null and _coastal_runtime.enabled,
		"coastal_inner_deg": _coastal_inner_deg,
		"coastal_outer_deg": _coastal_outer_deg,
	}


func configure_coastal(warp_data, propagation_data, inner_deg: float, outer_deg: float,
		long_wind_direction: Vector2) -> bool:
	## Se llama sólo tras bake/rebuild coastal; guarda referencias a los arrays
	## horneados y recalcula pesos sin RNG ni H0 nuevos.
	var runtime = CoastalRuntimeScript.new()
	if not runtime.configure(warp_data, propagation_data):
		clear_coastal()
		return false
	_coastal_runtime = runtime
	_coastal_inner_deg = inner_deg
	_coastal_outer_deg = outer_deg
	_coastal_wind_direction = long_wind_direction.normalized()
	if _coastal_wind_direction.length_squared() <= 1.0e-8:
		_coastal_wind_direction = Vector2.RIGHT
	_refresh_coastal_long_weights()
	_rebuild_selection()
	return true


func clear_coastal() -> void:
	_coastal_runtime = null
	_refresh_coastal_long_weights()
	_rebuild_selection()


func coastal_enabled() -> bool:
	return _coastal_runtime != null and _coastal_runtime.enabled


func set_sea_level(sea_level_y: float) -> void:
	_sea_level = sea_level_y
	if _native_backend != null:
		_native_backend.set_sea_level(_sea_level)


func set_crest_sharpen(config: Dictionary) -> void:
	## 5R1D: misma configuración que render (módulo como autoridad única).
	_crest_sharpen = config
	if _native_backend != null and _native_backend.has_method(&"set_crest_sharpen"):
		_native_backend.set_crest_sharpen(config)


func set_mode(mode: int) -> void:
	_mode = mode
	_rebuild_selection()


func set_budget(long_pairs: int, mid_pairs: int, short_pairs: int) -> void:
	_budgets = [long_pairs, mid_pairs, short_pairs]
	_rebuild_selection()


func is_ready() -> bool:
	return not _cascades.is_empty()


func mode_name() -> String:
	return "FULL_PAIRS" if _mode == MODE_FULL_PAIRS else "REDUCED"


func selected_pair_counts() -> Array[int]:
	var result: Array[int] = []
	for cascade in _cascades:
		result.append(cascade.count)
	return result


func captured_energy_fractions() -> Array:
	## Fracción de energía (height/slope/velocity/jacobian) representada por los
	## pares SELECCIONADOS frente al total, por cascada (LONG/MID/SHORT).
	var result: Array = []
	for cascade in _cascades:
		var lambda_sq := cascade.lambda * cascade.lambda
		var selected_e := 0.0
		var selected_slope := 0.0
		var selected_vel := 0.0
		var selected_jac := 0.0
		var total_e := 0.0
		var total_slope := 0.0
		var total_vel := 0.0
		var total_jac := 0.0
		var full_count := cascade.f_kx.size()
		for i in full_count:
			var e := cascade.f_h0_re[i] * cascade.f_h0_re[i] + cascade.f_h0_im[i] * cascade.f_h0_im[i] + cascade.f_h0n_re[i] * cascade.f_h0n_re[i] + cascade.f_h0n_im[i] * cascade.f_h0n_im[i]
			var k2 := cascade.f_kx[i] * cascade.f_kx[i] + cascade.f_ky[i] * cascade.f_ky[i]
			var w2 := cascade.f_omega[i] * cascade.f_omega[i]
			total_e += e
			total_slope += k2 * e
			total_vel += w2 * e
			total_jac += lambda_sq * k2 * e
		for idx in cascade.count:
			var e := cascade.h0_re[idx] * cascade.h0_re[idx] + cascade.h0_im[idx] * cascade.h0_im[idx] + cascade.h0n_re[idx] * cascade.h0n_re[idx] + cascade.h0n_im[idx] * cascade.h0n_im[idx]
			var k2 := cascade.kx[idx] * cascade.kx[idx] + cascade.ky[idx] * cascade.ky[idx]
			var w2 := cascade.omega[idx] * cascade.omega[idx]
			selected_e += e
			selected_slope += k2 * e
			selected_vel += w2 * e
			selected_jac += lambda_sq * k2 * e
		result.append({
			"height": selected_e / total_e if total_e > 0.0 else 0.0,
			"slope": selected_slope / total_slope if total_slope > 0.0 else 0.0,
			"velocity": selected_vel / total_vel if total_vel > 0.0 else 0.0,
			"jacobian": selected_jac / total_jac if total_jac > 0.0 else 0.0,
		})
	return result


func ensure_prepared(simulation_time: float) -> void:
	if _prepared_valid and _prepared_time == simulation_time:
		return
	_prepare_time(simulation_time)


func prepare_time(simulation_time: float) -> void:
	_prepare_time(simulation_time)


func sample_water(world_position: Vector3, simulation_time: float):
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	ensure_prepared(simulation_time)
	return _sample_world(Vector2(world_position.x, world_position.z))


func sample_water_prepared(world_position: Vector3):
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	if not _prepared_valid:
		diagnostic_non_converged += 1
		return SampleScript.invalid()
	return _sample_world(Vector2(world_position.x, world_position.z))


func sample_water_open_reference(world_position: Vector3, simulation_time: float):
	## Sólo Lab/debug 3B.3: compara la misma query sin corrección coastal, sin
	## tocar H0 ni el target world. No se usa en la ruta de producción.
	var saved_runtime = _coastal_runtime
	_coastal_runtime = null
	var result = sample_water(world_position, simulation_time)
	_coastal_runtime = saved_runtime
	return result


func sample_parametric(parametric_position: Vector3, simulation_time: float):
	## Helper de tests/debug: evalúa en la coordenada paramétrica q directamente
	## (sin inversión world-space).
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	_accumulate(parametric_position.x, parametric_position.z, false, simulation_time)
	return _build_sample(0.0, 0, true)


func sample_water_batch_prepared(positions: Array[Vector3]) -> Array:
	var result: Array = []
	result.resize(positions.size())
	for index in positions.size():
		result[index] = _sample_world(Vector2(positions[index].x, positions[index].z))
	return result


func prepare_breaker_time(simulation_time: float) -> void:
	## Prepara sólo LONG con el mismo H0, transición y tiempo que OceanQuery.
	if _breaker_prepared_valid and _breaker_prepared_time == simulation_time:
		return
	if _prepared_valid and _prepared_time == simulation_time:
		_breaker_prepared_valid = true
		_breaker_prepared_time = simulation_time
		return
	if _cascades.is_empty():
		_breaker_prepared_valid = false
		return
	_prepare_cascade_time(_cascades[0], simulation_time)
	_breaker_prepared_valid = true
	_breaker_prepared_time = simulation_time


func sample_coastal_breaker_heights_prepared(positions: Array[Vector3]) -> Array:
	## Muestras para DETECT/ACTIVE: LONG_COASTAL height-only, sin Newton.
	var result: Array = []
	result.resize(positions.size())
	for index in positions.size():
		result[index] = _sample_breaker_point(Vector2(positions[index].x, positions[index].z), false)
	return result


func sample_coastal_breaker_slopes_prepared(positions: Array[Vector3]) -> Array:
	## Muestras para break_score: sólo los candidatos seleccionados piden slope.
	var result: Array = []
	result.resize(positions.size())
	for index in positions.size():
		result[index] = _sample_breaker_point(Vector2(positions[index].x, positions[index].z), true)
	return result


func _sample_breaker_point(world_xz: Vector2, include_slope: bool):
	var sample = SampleScript.new()
	if not _breaker_prepared_valid or _cascades.is_empty() or _coastal_runtime == null or not _coastal_runtime.enabled:
		sample.valid = false
		return sample
	_evaluate_sea_state_zones(world_xz.x, world_xz.y)
	var confidence: float = float(_coastal_runtime.sample(world_xz.x, world_xz.y))
	var deep_x: float = float(_coastal_runtime.deep_sample_x)
	var deep_z: float = float(_coastal_runtime.deep_sample_z)
	var shoaling: float = float(_coastal_runtime.effective_shoaling) if confidence > 0.0 else 1.0
	_accumulate_breaker_long(world_xz.x, world_xz.y)
	var open_h := _breaker_long_h
	var open_dhx := _breaker_long_dhx
	var open_dhz := _breaker_long_dhz
	var composed_h := open_h
	var composed_dhx := open_dhx
	var composed_dhz := open_dhz
	if confidence > 0.0:
		_accumulate_breaker_long(deep_x, deep_z)
		var deep_h := _breaker_long_h
		var deep_dhx := _breaker_long_dhx
		var deep_dhz := _breaker_long_dhz
		var scaled_open: float = shoaling * (1.0 - confidence)
		var scaled_deep: float = shoaling * confidence
		composed_h = scaled_open * open_h + scaled_deep * deep_h - open_h
		composed_dhx = scaled_open * open_dhx + scaled_deep * (_coastal_runtime.sample_j00 * deep_dhx + _coastal_runtime.sample_j10 * deep_dhz) - open_dhx
		composed_dhz = scaled_open * open_dhz + scaled_deep * (_coastal_runtime.sample_j01 * deep_dhx + _coastal_runtime.sample_j11 * deep_dhz) - open_dhz
	# Same LONG amplitude/product-rule convention as the full evaluator; no
	# choppiness/Jacobian is needed for a height-only breaker sample.
	var base_h := composed_h
	composed_h *= _zone_long_amplitude
	if include_slope:
		composed_dhx = _zone_long_amplitude * composed_dhx + base_h * _zone_grad_long_x
		composed_dhz = _zone_long_amplitude * composed_dhz + base_h * _zone_grad_long_z
	sample.valid = true
	sample.height = _sea_level + composed_h
	if include_slope:
		var normal := Vector3(-composed_dhx, 1.0, -composed_dhz)
		sample.normal = normal.normalized() if normal.length_squared() > 1.0e-8 else Vector3.UP
	else:
		sample.normal = Vector3.UP
	return sample


func _accumulate_breaker_long(qx: float, qz: float) -> void:
	_breaker_long_h = 0.0
	_breaker_long_dhx = 0.0
	_breaker_long_dhz = 0.0
	if _cascades.is_empty():
		return
	var cascade: _CascadeData = _cascades[0]
	var alpha := _spectrum_transition_alpha if _spectrum_transition_active else 0.0
	var h := 0.0
	var dhx := 0.0
	var dhz := 0.0
	for idx in cascade.count:
		var h_re := cascade.coastal_weight_pos[idx] * cascade.ev_a_h_re[idx] + cascade.coastal_weight_neg[idx] * cascade.ev_b_h_re[idx]
		var h_im := cascade.coastal_weight_pos[idx] * cascade.ev_a_h_im[idx] + cascade.coastal_weight_neg[idx] * cascade.ev_b_h_im[idx]
		if _spectrum_transition_active:
			var wp := lerpf(cascade.coastal_weight_pos[idx], cascade.transition_coastal_weight_pos[idx], alpha)
			var wn := lerpf(cascade.coastal_weight_neg[idx], cascade.transition_coastal_weight_neg[idx], alpha)
			h_re = wp * cascade.ev_a_h_re[idx] + wn * cascade.ev_b_h_re[idx]
			h_im = wp * cascade.ev_a_h_im[idx] + wn * cascade.ev_b_h_im[idx]
		var phi := cascade.kx[idx] * qx + cascade.ky[idx] * qz
		var p_im := h_re * sin(phi) + h_im * cos(phi)
		var sig := cascade.parity[idx] * cascade.weight[idx]
		h += sig * (h_re * cos(phi) - h_im * sin(phi))
		dhx += sig * -cascade.kx[idx] * p_im
		dhz += sig * -cascade.ky[idx] * p_im
	_breaker_long_h = h * cascade.inv_n2
	_breaker_long_dhx = dhx * cascade.inv_n2
	_breaker_long_dhz = dhz * cascade.inv_n2


func _band_height(qx: float, qz: float, band_index: int) -> float:
	## 5R1D: altura de UNA banda (LONG=0, MID=1) en q, con espectro prepared.
	var cascade: _CascadeData = _cascades[band_index]
	var total := 0.0
	var kx_arr := cascade.kx
	var ky_arr := cascade.ky
	var par_arr := cascade.parity
	var w_arr := cascade.weight
	var ev_hr := cascade.ev_h_re
	var ev_hi := cascade.ev_h_im
	for idx in cascade.count:
		var phi: float = kx_arr[idx] * qx + ky_arr[idx] * qz
		var p_re: float = ev_hr[idx] * cos(phi) - ev_hi[idx] * sin(phi)
		total += par_arr[idx] * w_arr[idx] * p_re
	var band_height := total * cascade.inv_n2
	if band_index == 0:
		return band_height * _zone_long_amplitude
	if band_index == 1:
		return band_height * _zone_mid_amplitude
	return band_height * _zone_short_amplitude


func _compute_sharpen(qx: float, qz: float) -> float:
	## 5R1D: máscara 5R.1C del shader (sobre FFT base). Devuelve sharpen ∈ [0,1].
	if _crest_sharpen.is_empty():
		return 0.0
	var strength: float = float(_crest_sharpen.get("strength", 0.0))
	if strength <= 0.0:
		return 0.0
	var threshold: float = float(_crest_sharpen.get("threshold", 0.15))
	var long_w: float = float(_crest_sharpen.get("long_weight", 1.0))
	var mid_w: float = float(_crest_sharpen.get("mid_weight", 0.5))
	var dir := Vector2(float(_crest_sharpen.get("direction_x", 1.0)), float(_crest_sharpen.get("direction_z", 0.0)))
	var eps: float = float(_crest_sharpen.get("eps", 1.92))
	var local_hs: float = maxf(float(_crest_sharpen.get("local_hs", 0.5)), 0.05)

	var l_c := _band_height(qx, qz, 0)
	var l_l := _band_height(qx - dir.x * eps, qz - dir.y * eps, 0)
	var l_r := _band_height(qx + dir.x * eps, qz + dir.y * eps, 0)
	var m_c := _band_height(qx, qz, 1)
	var m_l := _band_height(qx - dir.x * eps, qz - dir.y * eps, 1)
	var m_r := _band_height(qx + dir.x * eps, qz + dir.y * eps, 1)

	var curv_long := l_l - 2.0 * l_c + l_r
	var curv_mid := m_l - 2.0 * m_c + m_r
	var crest_long := clampf(-curv_long / local_hs, 0.0, 2.0) * long_w
	var crest_mid := clampf(-curv_mid / maxf(local_hs * 0.4, 0.02), 0.0, 2.0) * mid_w
	var crestness := crest_long + crest_mid
	var face_slope := absf(l_r - l_l) / (2.0 * eps)
	var compression := smoothstep(0.03, 0.22, face_slope)
	return smoothstep(threshold, threshold + 0.25, crestness) * compression * strength


func _evaluate_final(qx: float, qz: float) -> Vector2:
	## 5R1D-hotfix: superficie FINAL (base FFT + crest sharpening). Deja _acc_h/dx/dz
	## corregidos para el sample y devuelve el dx/dz final.
	_accumulate(qx, qz, true, _prepared_time)
	var s := _compute_sharpen(qx, qz)
	if s > 0.0:
		var g: float = float(_crest_sharpen.get("max_gain", 0.30))
		var hs: float = maxf(float(_crest_sharpen.get("local_hs", 0.5)), 0.05)
		_acc_h += s * g * hs
		var scale := 1.0 + s * g * 0.35
		_acc_dx *= scale
		_acc_dz *= scale
	return Vector2(_acc_dx, _acc_dz)


func _finite_jacobian(qx: float, qz: float) -> Dictionary:
	## 5R1D-hotfix: Jacobian 2D de q + final_dx/dz por diferencias finitas centrales.
	var d := 0.05
	var xp := _evaluate_final(qx + d, qz)
	var xm := _evaluate_final(qx - d, qz)
	var zp := _evaluate_final(qx, qz + d)
	var zm := _evaluate_final(qx, qz - d)
	return {
		"a": 1.0 + (xp.x - xm.x) / (2.0 * d),
		"b": (zp.x - zm.x) / (2.0 * d),
		"c": (xp.y - xm.y) / (2.0 * d),
		"d": 1.0 + (zp.y - zm.y) / (2.0 * d),
	}


## --- Inversión world_xz -> q -------------------------------------------------

func _sample_world(target_xz: Vector2):
	var q := target_xz
	var max_iter := FULL_MAX_ITERATIONS if _mode == MODE_FULL_PAIRS else MAX_ITERATIONS
	var tolerance := FULL_POSITION_TOLERANCE_M if _mode == MODE_FULL_PAIRS else POSITION_TOLERANCE_M
	var iterations := 0
	var converged := false
	var residual := 0.0
	while true:
		_evaluate_final(q.x, q.y)
		var fx: float = q.x + _acc_dx - target_xz.x
		var fz: float = q.y + _acc_dz - target_xz.y
		residual = sqrt(fx * fx + fz * fz)
		if residual <= tolerance or iterations >= max_iter:
			converged = residual <= tolerance
			break
		var jac := _finite_jacobian(q.x, q.y)
		var det: float = float(jac.a) * float(jac.d) - float(jac.b) * float(jac.c)
		if absf(det) <= JACOBIAN_EPSILON:
			break
		var inv: float = 1.0 / det
		q.x -= inv * (jac.d * fx - jac.b * fz)
		q.y -= inv * (-jac.c * fx + jac.a * fz)
		iterations += 1
	# Deja _acc_* con la superficie FINAL en q resuelto (no aplicar sharpening 2 veces).
	_evaluate_final(q.x, q.y)
	diagnostic_last_iterations = iterations
	diagnostic_last_residual = residual
	if not converged:
		diagnostic_non_converged += 1
	return _build_sample(residual, iterations, converged)


func _build_sample(residual: float, iterations: int, converged: bool):
	var displacement := Vector3(_acc_dx, _acc_h, _acc_dz)
	var tangent_x := Vector3(1.0 + _acc_dxx, _acc_dhx, _acc_dzx)
	var tangent_z := Vector3(_acc_dxz, _acc_dhz, 1.0 + _acc_dzz)
	var normal := tangent_z.cross(tangent_x)
	if normal.length_squared() > 0.0000001:
		normal = normal.normalized()
		if normal.y < 0.0:
			normal = -normal
	else:
		normal = Vector3.UP
	var velocity := Vector3(_acc_vx, _acc_vh, _acc_vz)
	var det_j: float = (1.0 + _acc_dxx) * (1.0 + _acc_dzz) - _acc_dxz * _acc_dzx
	if not _is_finite(displacement) or not _is_finite(normal) or not _is_finite(velocity) or not is_finite(det_j):
		return SampleScript.invalid()

	var sample := SampleScript.new()
	sample.valid = converged
	sample.height = _sea_level + _acc_h
	sample.displacement = displacement
	sample.normal = normal
	sample.surface_velocity = velocity
	sample.jacobian_det = det_j
	sample.foldover_risk = det_j <= 0.0
	sample.query_residual_m = residual
	sample.query_iterations = iterations
	return sample


## --- Evaluación paramétrica (acumuladores miembro) ----------------------------

func _accumulate(qx: float, qz: float, use_prepared: bool, simulation_time: float) -> void:
	# El sampler se evalúa sobre q, dentro de Newton. c=0 conserva el hot path
	# open-ocean: no se evalúa C(q) ni C(F(q)).
	_evaluate_sea_state_zones(qx, qz)
	var coastal_confidence := 0.0
	var coastal_shoaling := 1.0
	var coastal_deep_x := qx
	var coastal_deep_z := qz
	var coastal_j00 := 1.0
	var coastal_j01 := 0.0
	var coastal_j10 := 0.0
	var coastal_j11 := 1.0
	if _coastal_runtime != null and _coastal_runtime.enabled:
		coastal_confidence = _coastal_runtime.sample(qx, qz)
		if coastal_confidence > 0.0:
			coastal_shoaling = _coastal_runtime.effective_shoaling
			coastal_deep_x = _coastal_runtime.deep_sample_x
			coastal_deep_z = _coastal_runtime.deep_sample_z
			coastal_j00 = _coastal_runtime.sample_j00
			coastal_j01 = _coastal_runtime.sample_j01
			coastal_j10 = _coastal_runtime.sample_j10
			coastal_j11 = _coastal_runtime.sample_j11
	var total_h := 0.0
	var total_dx := 0.0
	var total_dz := 0.0
	var total_dhx := 0.0
	var total_dhz := 0.0
	var total_dxx := 0.0
	var total_dxz := 0.0
	var total_dzx := 0.0
	var total_dzz := 0.0
	var total_vh := 0.0
	var total_vx := 0.0
	var total_vz := 0.0

	for band_index in _cascades.size():
		var cascade: _CascadeData = _cascades[band_index]
		var inv_n2 := cascade.inv_n2
		var count := cascade.count
		var kx_arr := cascade.kx
		var ky_arr := cascade.ky
		var om_arr := cascade.omega
		var par_arr := cascade.parity
		var w_arr := cascade.weight
		var h0r_arr := cascade.h0_re
		var h0i_arr := cascade.h0_im
		var h0nr_arr := cascade.h0n_re
		var h0ni_arr := cascade.h0n_im
		var target_h0r_arr := cascade.transition_h0_re
		var target_h0i_arr := cascade.transition_h0_im
		var target_h0nr_arr := cascade.transition_h0n_re
		var target_h0ni_arr := cascade.transition_h0n_im
		var transition_alpha := _spectrum_transition_alpha if _spectrum_transition_active else 0.0
		var effective_lambda := lerpf(cascade.lambda, cascade.transition_lambda, transition_alpha) if _spectrum_transition_active else cascade.lambda
		var ev_hr_arr := cascade.ev_h_re
		var ev_hi_arr := cascade.ev_h_im
		var ev_vr_arr := cascade.ev_v_re
		var ev_vi_arr := cascade.ev_v_im
		var lh := 0.0
		var ldx := 0.0
		var ldz := 0.0
		var ldhx := 0.0
		var ldhz := 0.0
		var ldxx := 0.0
		var ldxz := 0.0
		var ldzx := 0.0
		var ldzz := 0.0
		var lvh := 0.0
		var lvx := 0.0
		var lvz := 0.0
		for idx in count:
			var h_re := 0.0
			var h_im := 0.0
			var v_re := 0.0
			var v_im := 0.0
			if use_prepared:
				h_re = ev_hr_arr[idx]
				h_im = ev_hi_arr[idx]
				v_re = ev_vr_arr[idx]
				v_im = ev_vi_arr[idx]
			else:
				var wt := om_arr[idx] * simulation_time
				var c := cos(wt)
				var sn := sin(wt)
				var h0_re := lerpf(h0r_arr[idx], target_h0r_arr[idx], transition_alpha) if _spectrum_transition_active else h0r_arr[idx]
				var h0_im := lerpf(h0i_arr[idx], target_h0i_arr[idx], transition_alpha) if _spectrum_transition_active else h0i_arr[idx]
				var h0n_re := lerpf(h0nr_arr[idx], target_h0nr_arr[idx], transition_alpha) if _spectrum_transition_active else h0nr_arr[idx]
				var h0n_im := lerpf(h0ni_arr[idx], target_h0ni_arr[idx], transition_alpha) if _spectrum_transition_active else h0ni_arr[idx]
				var a_re := h0_re * c + h0_im * sn
				var a_im := -h0_re * sn + h0_im * c
				var b_re := h0n_re * c - h0n_im * sn
				var b_im := h0n_re * sn + h0n_im * c
				h_re = a_re + b_re
				h_im = a_im + b_im
				v_re = om_arr[idx] * (a_im - b_im)
				v_im = om_arr[idx] * (-a_re + b_re)
			var phi := kx_arr[idx] * qx + ky_arr[idx] * qz
			var cp := cos(phi)
			var sp := sin(phi)
			var p_re := h_re * cp - h_im * sp
			var p_im := h_re * sp + h_im * cp
			var q_re := v_re * cp - v_im * sp
			var q_im := v_re * sp + v_im * cp
			var sig := par_arr[idx] * w_arr[idx]
			lh += sig * p_re
			var k_len := sqrt(kx_arr[idx] * kx_arr[idx] + ky_arr[idx] * ky_arr[idx])
			var a1 := effective_lambda * kx_arr[idx] / k_len if k_len > 0.000001 else 0.0
			var a2 := effective_lambda * ky_arr[idx] / k_len if k_len > 0.000001 else 0.0
			ldx += sig * a1 * p_im
			ldz += sig * a2 * p_im
			ldhx += sig * -kx_arr[idx] * p_im
			ldhz += sig * -ky_arr[idx] * p_im
			ldxx += sig * a1 * kx_arr[idx] * p_re
			ldxz += sig * a1 * ky_arr[idx] * p_re
			ldzx += sig * a2 * kx_arr[idx] * p_re
			ldzz += sig * a2 * ky_arr[idx] * p_re
			lvh += sig * q_re
			lvx += sig * a1 * q_im
			lvz += sig * a2 * q_im
		var base: int = band_index * 12
		_band_acc[base] = lh * inv_n2
		_band_acc[base + 1] = ldx * inv_n2
		_band_acc[base + 2] = ldz * inv_n2
		_band_acc[base + 3] = ldhx * inv_n2
		_band_acc[base + 4] = ldhz * inv_n2
		_band_acc[base + 5] = ldxx * inv_n2
		_band_acc[base + 6] = ldxz * inv_n2
		_band_acc[base + 7] = ldzx * inv_n2
		_band_acc[base + 8] = ldzz * inv_n2
		_band_acc[base + 9] = lvh * inv_n2
		_band_acc[base + 10] = lvx * inv_n2
		_band_acc[base + 11] = lvz * inv_n2

	var long_h := _band_acc[0]
	var long_dx := _band_acc[1]
	var long_dz := _band_acc[2]
	var long_dhx := _band_acc[3]
	var long_dhz := _band_acc[4]
	var long_dxx := _band_acc[5]
	var long_dxz := _band_acc[6]
	var long_dzx := _band_acc[7]
	var long_dzz := _band_acc[8]
	var long_vh := _band_acc[9]
	var long_vx := _band_acc[10]
	var long_vz := _band_acc[11]
	var mid_h := _band_acc[12]
	var mid_dx := _band_acc[13]
	var mid_dz := _band_acc[14]
	var mid_dhx := _band_acc[15]
	var mid_dhz := _band_acc[16]
	var mid_dxx := _band_acc[17]
	var mid_dxz := _band_acc[18]
	var mid_dzx := _band_acc[19]
	var mid_dzz := _band_acc[20]
	var mid_vh := _band_acc[21]
	var mid_vx := _band_acc[22]
	var mid_vz := _band_acc[23]
	var short_h := _band_acc[24]
	var short_dx := _band_acc[25]
	var short_dz := _band_acc[26]
	var short_dhx := _band_acc[27]
	var short_dhz := _band_acc[28]
	var short_dxx := _band_acc[29]
	var short_dxz := _band_acc[30]
	var short_dzx := _band_acc[31]
	var short_dzz := _band_acc[32]
	var short_vh := _band_acc[33]
	var short_vx := _band_acc[34]
	var short_vz := _band_acc[35]

	if coastal_confidence > 0.0:
		# LONG_eff = LONG + S_eff*((1-c) C(q) + c C(F(q))) - C(q).
		# c/S se tratan constantes en la derivada local (misma aproximación
		# explícita del renderer); la posición sí los remuestrea por iteración.
		_accumulate_coastal_long(qx, qz, use_prepared, simulation_time)
		var cq_h := _coastal_h
		var cq_dx := _coastal_dx
		var cq_dz := _coastal_dz
		var cq_dhx := _coastal_dhx
		var cq_dhz := _coastal_dhz
		var cq_dxx := _coastal_dxx
		var cq_dxz := _coastal_dxz
		var cq_dzx := _coastal_dzx
		var cq_dzz := _coastal_dzz
		var cq_vh := _coastal_vh
		var cq_vx := _coastal_vx
		var cq_vz := _coastal_vz
		_accumulate_coastal_long(coastal_deep_x, coastal_deep_z, use_prepared, simulation_time)
		var blend_open := 1.0 - coastal_confidence
		var blend_deep := coastal_confidence
		var scaled_open := coastal_shoaling * blend_open
		var scaled_deep := coastal_shoaling * blend_deep
		long_h += scaled_open * cq_h + scaled_deep * _coastal_h - cq_h
		long_dx += scaled_open * cq_dx + scaled_deep * _coastal_dx - cq_dx
		long_dz += scaled_open * cq_dz + scaled_deep * _coastal_dz - cq_dz
		long_vh += scaled_open * cq_vh + scaled_deep * _coastal_vh - cq_vh
		long_vx += scaled_open * cq_vx + scaled_deep * _coastal_vx - cq_vx
		long_vz += scaled_open * cq_vz + scaled_deep * _coastal_vz - cq_vz
		# grad h_world = J^T grad h_deep; derivative D_world = derivative D_deep * J.
		long_dhx += scaled_open * cq_dhx + scaled_deep * (coastal_j00 * _coastal_dhx + coastal_j10 * _coastal_dhz) - cq_dhx
		long_dhz += scaled_open * cq_dhz + scaled_deep * (coastal_j01 * _coastal_dhx + coastal_j11 * _coastal_dhz) - cq_dhz
		long_dxx += scaled_open * cq_dxx + scaled_deep * (_coastal_dxx * coastal_j00 + _coastal_dxz * coastal_j10) - cq_dxx
		long_dxz += scaled_open * cq_dxz + scaled_deep * (_coastal_dxx * coastal_j01 + _coastal_dxz * coastal_j11) - cq_dxz
		long_dzx += scaled_open * cq_dzx + scaled_deep * (_coastal_dzx * coastal_j00 + _coastal_dzz * coastal_j10) - cq_dzx
		long_dzz += scaled_open * cq_dzz + scaled_deep * (_coastal_dzx * coastal_j01 + _coastal_dzz * coastal_j11) - cq_dzz

	# Apply local state after coastal LONG composition. The same amplitude scale
	# affects vertical displacement and the horizontal scale is amplitude*chop.
	# Product-rule terms keep the query Jacobian exact at zone boundaries.
	var long_hscale := _zone_long_amplitude * _zone_choppiness
	var mid_hscale := _zone_mid_amplitude * _zone_choppiness
	var short_hscale := _zone_short_amplitude * _zone_choppiness
	var grad_long_hscale_x := _zone_grad_long_x * _zone_choppiness + _zone_long_amplitude * _zone_grad_chop_x
	var grad_long_hscale_z := _zone_grad_long_z * _zone_choppiness + _zone_long_amplitude * _zone_grad_chop_z
	var grad_mid_hscale_x := _zone_grad_mid_x * _zone_choppiness + _zone_mid_amplitude * _zone_grad_chop_x
	var grad_mid_hscale_z := _zone_grad_mid_z * _zone_choppiness + _zone_mid_amplitude * _zone_grad_chop_z
	var grad_short_hscale_x := _zone_grad_short_x * _zone_choppiness + _zone_short_amplitude * _zone_grad_chop_x
	var grad_short_hscale_z := _zone_grad_short_z * _zone_choppiness + _zone_short_amplitude * _zone_grad_chop_z
	var base_long_h := long_h
	var base_long_dx := long_dx
	var base_long_dz := long_dz
	var base_mid_h := mid_h
	var base_mid_dx := mid_dx
	var base_mid_dz := mid_dz
	var base_short_h := short_h
	var base_short_dx := short_dx
	var base_short_dz := short_dz

	long_h *= _zone_long_amplitude
	long_dx = base_long_dx * long_hscale
	long_dz = base_long_dz * long_hscale
	long_dhx = _zone_long_amplitude * long_dhx + base_long_h * _zone_grad_long_x
	long_dhz = _zone_long_amplitude * long_dhz + base_long_h * _zone_grad_long_z
	long_dxx = long_hscale * long_dxx + base_long_dx * grad_long_hscale_x
	long_dxz = long_hscale * long_dxz + base_long_dx * grad_long_hscale_z
	long_dzx = long_hscale * long_dzx + base_long_dz * grad_long_hscale_x
	long_dzz = long_hscale * long_dzz + base_long_dz * grad_long_hscale_z
	long_vh *= _zone_long_amplitude
	long_vx *= long_hscale
	long_vz *= long_hscale

	mid_h *= _zone_mid_amplitude
	mid_dx = base_mid_dx * mid_hscale
	mid_dz = base_mid_dz * mid_hscale
	mid_dhx = _zone_mid_amplitude * mid_dhx + base_mid_h * _zone_grad_mid_x
	mid_dhz = _zone_mid_amplitude * mid_dhz + base_mid_h * _zone_grad_mid_z
	mid_dxx = mid_hscale * mid_dxx + base_mid_dx * grad_mid_hscale_x
	mid_dxz = mid_hscale * mid_dxz + base_mid_dx * grad_mid_hscale_z
	mid_dzx = mid_hscale * mid_dzx + base_mid_dz * grad_mid_hscale_x
	mid_dzz = mid_hscale * mid_dzz + base_mid_dz * grad_mid_hscale_z
	mid_vh *= _zone_mid_amplitude
	mid_vx *= mid_hscale
	mid_vz *= mid_hscale

	short_h *= _zone_short_amplitude
	short_dx = base_short_dx * short_hscale
	short_dz = base_short_dz * short_hscale
	short_dhx = _zone_short_amplitude * short_dhx + base_short_h * _zone_grad_short_x
	short_dhz = _zone_short_amplitude * short_dhz + base_short_h * _zone_grad_short_z
	short_dxx = short_hscale * short_dxx + base_short_dx * grad_short_hscale_x
	short_dxz = short_hscale * short_dxz + base_short_dx * grad_short_hscale_z
	short_dzx = short_hscale * short_dzx + base_short_dz * grad_short_hscale_x
	short_dzz = short_hscale * short_dzz + base_short_dz * grad_short_hscale_z
	short_vh *= _zone_short_amplitude
	short_vx *= short_hscale
	short_vz *= short_hscale

	total_h = long_h + mid_h + short_h
	total_dx = long_dx + mid_dx + short_dx
	total_dz = long_dz + mid_dz + short_dz
	total_dhx = long_dhx + mid_dhx + short_dhx
	total_dhz = long_dhz + mid_dhz + short_dhz
	total_dxx = long_dxx + mid_dxx + short_dxx
	total_dxz = long_dxz + mid_dxz + short_dxz
	total_dzx = long_dzx + mid_dzx + short_dzx
	total_dzz = long_dzz + mid_dzz + short_dzz
	total_vh = long_vh + mid_vh + short_vh
	total_vx = long_vx + mid_vx + short_vx
	total_vz = long_vz + mid_vz + short_vz

	_acc_h = total_h
	_acc_dx = total_dx
	_acc_dz = total_dz
	_acc_dhx = total_dhx
	_acc_dhz = total_dhz
	_acc_dxx = total_dxx
	_acc_dxz = total_dxz
	_acc_dzx = total_dzx
	_acc_dzz = total_dzz
	_acc_vh = total_vh
	_acc_vx = total_vx
	_acc_vz = total_vz


func _accumulate_coastal_long(qx: float, qz: float, use_prepared: bool, simulation_time: float) -> void:
	## Evalúa sólo C de LONG. A/B se ponderan individualmente con w(k), w(-k),
	## igual que build_h0_split_rgba32f antes de reconstruir los pares canónicos.
	_coastal_h = 0.0
	_coastal_dx = 0.0
	_coastal_dz = 0.0
	_coastal_dhx = 0.0
	_coastal_dhz = 0.0
	_coastal_dxx = 0.0
	_coastal_dxz = 0.0
	_coastal_dzx = 0.0
	_coastal_dzz = 0.0
	_coastal_vh = 0.0
	_coastal_vx = 0.0
	_coastal_vz = 0.0
	if _cascades.is_empty():
		return
	var cascade: _CascadeData = _cascades[0]
	var alpha := _spectrum_transition_alpha if _spectrum_transition_active else 0.0
	var effective_lambda := lerpf(cascade.lambda, cascade.transition_lambda, alpha) if _spectrum_transition_active else cascade.lambda
	var lh := 0.0
	var ldx := 0.0
	var ldz := 0.0
	var ldhx := 0.0
	var ldhz := 0.0
	var ldxx := 0.0
	var ldxz := 0.0
	var ldzx := 0.0
	var ldzz := 0.0
	var lvh := 0.0
	var lvx := 0.0
	var lvz := 0.0
	for idx in cascade.count:
		var a_hr := 0.0
		var a_hi := 0.0
		var b_hr := 0.0
		var b_hi := 0.0
		var a_vr := 0.0
		var a_vi := 0.0
		var b_vr := 0.0
		var b_vi := 0.0
		if use_prepared:
			a_hr = cascade.ev_a_h_re[idx]
			a_hi = cascade.ev_a_h_im[idx]
			b_hr = cascade.ev_b_h_re[idx]
			b_hi = cascade.ev_b_h_im[idx]
			a_vr = cascade.ev_a_v_re[idx]
			a_vi = cascade.ev_a_v_im[idx]
			b_vr = cascade.ev_b_v_re[idx]
			b_vi = cascade.ev_b_v_im[idx]
		else:
			var wt := cascade.omega[idx] * simulation_time
			var c := cos(wt)
			var sn := sin(wt)
			var h0_re := lerpf(cascade.h0_re[idx], cascade.transition_h0_re[idx], alpha) if _spectrum_transition_active else cascade.h0_re[idx]
			var h0_im := lerpf(cascade.h0_im[idx], cascade.transition_h0_im[idx], alpha) if _spectrum_transition_active else cascade.h0_im[idx]
			var h0n_re := lerpf(cascade.h0n_re[idx], cascade.transition_h0n_re[idx], alpha) if _spectrum_transition_active else cascade.h0n_re[idx]
			var h0n_im := lerpf(cascade.h0n_im[idx], cascade.transition_h0n_im[idx], alpha) if _spectrum_transition_active else cascade.h0n_im[idx]
			a_hr = h0_re * c + h0_im * sn
			a_hi = -h0_re * sn + h0_im * c
			b_hr = h0n_re * c - h0n_im * sn
			b_hi = h0n_re * sn + h0n_im * c
			a_vr = cascade.omega[idx] * a_hi
			a_vi = -cascade.omega[idx] * a_hr
			b_vr = -cascade.omega[idx] * b_hi
			b_vi = cascade.omega[idx] * b_hr
		var wp := lerpf(cascade.coastal_weight_pos[idx], cascade.transition_coastal_weight_pos[idx], alpha) if _spectrum_transition_active else cascade.coastal_weight_pos[idx]
		var wn := lerpf(cascade.coastal_weight_neg[idx], cascade.transition_coastal_weight_neg[idx], alpha) if _spectrum_transition_active else cascade.coastal_weight_neg[idx]
		var h_re := wp * a_hr + wn * b_hr
		var h_im := wp * a_hi + wn * b_hi
		var v_re := wp * a_vr + wn * b_vr
		var v_im := wp * a_vi + wn * b_vi
		var phi := cascade.kx[idx] * qx + cascade.ky[idx] * qz
		var cp := cos(phi)
		var sp := sin(phi)
		var p_re := h_re * cp - h_im * sp
		var p_im := h_re * sp + h_im * cp
		var q_re := v_re * cp - v_im * sp
		var q_im := v_re * sp + v_im * cp
		var sig := cascade.parity[idx] * cascade.weight[idx]
		lh += sig * p_re
		var k_len := sqrt(cascade.kx[idx] * cascade.kx[idx] + cascade.ky[idx] * cascade.ky[idx])
		var a1 := effective_lambda * cascade.kx[idx] / k_len if k_len > 0.000001 else 0.0
		var a2 := effective_lambda * cascade.ky[idx] / k_len if k_len > 0.000001 else 0.0
		ldx += sig * a1 * p_im
		ldz += sig * a2 * p_im
		ldhx += sig * -cascade.kx[idx] * p_im
		ldhz += sig * -cascade.ky[idx] * p_im
		ldxx += sig * a1 * cascade.kx[idx] * p_re
		ldxz += sig * a1 * cascade.ky[idx] * p_re
		ldzx += sig * a2 * cascade.kx[idx] * p_re
		ldzz += sig * a2 * cascade.ky[idx] * p_re
		lvh += sig * q_re
		lvx += sig * a1 * q_im
		lvz += sig * a2 * q_im
	_coastal_h = lh * cascade.inv_n2
	_coastal_dx = ldx * cascade.inv_n2
	_coastal_dz = ldz * cascade.inv_n2
	_coastal_dhx = ldhx * cascade.inv_n2
	_coastal_dhz = ldhz * cascade.inv_n2
	_coastal_dxx = ldxx * cascade.inv_n2
	_coastal_dxz = ldxz * cascade.inv_n2
	_coastal_dzx = ldzx * cascade.inv_n2
	_coastal_dzz = ldzz * cascade.inv_n2
	_coastal_vh = lvh * cascade.inv_n2
	_coastal_vx = lvx * cascade.inv_n2
	_coastal_vz = lvz * cascade.inv_n2


func _prepare_time(simulation_time: float) -> void:
	_prepared_valid = true
	_prepared_time = simulation_time
	for cascade in _cascades:
		_prepare_cascade_time(cascade, simulation_time)
	_breaker_prepared_valid = not _cascades.is_empty()
	_breaker_prepared_time = simulation_time


func _prepare_cascade_time(cascade: _CascadeData, simulation_time: float) -> void:
	var count := cascade.count
	var alpha := _spectrum_transition_alpha if _spectrum_transition_active else 0.0
	for idx in count:
		var wt := cascade.omega[idx] * simulation_time
		var c := cos(wt)
		var sn := sin(wt)
		var a_re := cascade.h0_re[idx] * c + cascade.h0_im[idx] * sn
		var a_im := -cascade.h0_re[idx] * sn + cascade.h0_im[idx] * c
		var b_re := cascade.h0n_re[idx] * c - cascade.h0n_im[idx] * sn
		var b_im := cascade.h0n_re[idx] * sn + cascade.h0n_im[idx] * c
		if _spectrum_transition_active:
			var ta_re := cascade.transition_h0_re[idx] * c + cascade.transition_h0_im[idx] * sn
			var ta_im := -cascade.transition_h0_re[idx] * sn + cascade.transition_h0_im[idx] * c
			var tb_re := cascade.transition_h0n_re[idx] * c - cascade.transition_h0n_im[idx] * sn
			var tb_im := cascade.transition_h0n_re[idx] * sn + cascade.transition_h0n_im[idx] * c
			a_re = lerpf(a_re, ta_re, alpha)
			a_im = lerpf(a_im, ta_im, alpha)
			b_re = lerpf(b_re, tb_re, alpha)
			b_im = lerpf(b_im, tb_im, alpha)
		cascade.ev_h_re[idx] = a_re + b_re
		cascade.ev_h_im[idx] = a_im + b_im
		cascade.ev_v_re[idx] = cascade.omega[idx] * (a_im - b_im)
		cascade.ev_v_im[idx] = cascade.omega[idx] * (-a_re + b_re)
		cascade.ev_a_h_re[idx] = a_re
		cascade.ev_a_h_im[idx] = a_im
		cascade.ev_b_h_re[idx] = b_re
		cascade.ev_b_h_im[idx] = b_im
		cascade.ev_a_v_re[idx] = cascade.omega[idx] * a_im
		cascade.ev_a_v_im[idx] = -cascade.omega[idx] * a_re
		cascade.ev_b_v_re[idx] = -cascade.omega[idx] * b_im
		cascade.ev_b_v_im[idx] = cascade.omega[idx] * b_re


## --- Selección ----------------------------------------------------------------

func _refresh_coastal_long_weights() -> void:
	if _cascades.is_empty():
		return
	_fill_coastal_weights(_cascades[0], _coastal_wind_direction)


func _fill_coastal_weights(cascade: _CascadeData, direction: Vector2) -> void:
	var active: bool = _coastal_runtime != null and _coastal_runtime.enabled
	_fill_coastal_weights_for_transition(cascade, direction, active, _coastal_inner_deg, _coastal_outer_deg)


static func _fill_coastal_weights_for_transition(cascade: _CascadeData, direction: Vector2,
		active: bool, inner_deg: float, outer_deg: float) -> void:
	var safe_direction := direction.normalized() if direction.length_squared() > 1.0e-8 else Vector2.RIGHT
	for index in cascade.f_kx.size():
		if active:
			cascade.f_coastal_weight_pos[index] = _coastal_angular_weight_for_transition(cascade.f_kx[index], cascade.f_ky[index], safe_direction, inner_deg, outer_deg)
			cascade.f_coastal_weight_neg[index] = _coastal_angular_weight_for_transition(-cascade.f_kx[index], -cascade.f_ky[index], safe_direction, inner_deg, outer_deg)
		else:
			cascade.f_coastal_weight_pos[index] = 0.0
			cascade.f_coastal_weight_neg[index] = 0.0


func _coastal_angular_weight(kx: float, ky: float) -> float:
	return _coastal_angular_weight_for_direction(kx, ky, _coastal_wind_direction)


func _coastal_angular_weight_for_direction(kx: float, ky: float, direction: Vector2) -> float:
	return _coastal_angular_weight_for_transition(kx, ky, direction, _coastal_inner_deg, _coastal_outer_deg)


static func _coastal_angular_weight_for_transition(kx: float, ky: float, direction: Vector2,
		inner_deg: float, outer_deg: float) -> float:
	var k_len := sqrt(kx * kx + ky * ky)
	if k_len <= 1.0e-6:
		return 1.0
	var dot_wind := clampf((kx * direction.x + ky * direction.y) / k_len, -1.0, 1.0)
	var angle_deg := rad_to_deg(acos(dot_wind))
	if angle_deg <= inner_deg:
		return 1.0
	if angle_deg >= outer_deg:
		return 0.0
	var t := (angle_deg - inner_deg) / maxf(outer_deg - inner_deg, 1.0e-6)
	return 1.0 - smoothstep(0.0, 1.0, t)

func _rebuild_selection() -> void:
	for index in _cascades.size():
		_compact_cascade(_cascades[index], _budgets[index], _mode)
	_invalidate_prepared()
	_sync_native()


## --- Backend nativo (Fase 2C) ------------------------------------------------
## OceanQueryReduced conserva la selección (GDScript) y empuja los arrays
## compactos al backend nativo cuando cambia H0/seed/state/budget. El native no
## reconstruye ni reinterpreta el pairing canónico: weight/parity/kx/... son
## verdad de entrada.

func configure_native_backend(native) -> void:
	_native_backend = native
	_sync_native()


func native_backend():
	return _native_backend


func get_cascades_compact() -> Array:
	## Exporta los arrays compactos seleccionados (para native / dump / tests).
	var result: Array = []
	for index in _cascades.size():
		var cascade := _cascades[index]
		result.append({
			"index": index,
			"inv_n2": cascade.inv_n2,
			"kx": cascade.kx, "ky": cascade.ky, "omega": cascade.omega,
			"a1": cascade.a1, "a2": cascade.a2,
			"c11": cascade.c11, "c12": cascade.c12, "c21": cascade.c21, "c22": cascade.c22,
			"parity": cascade.parity, "weight": cascade.weight,
			"h0_re": cascade.h0_re, "h0_im": cascade.h0_im,
			"h0n_re": cascade.h0n_re, "h0n_im": cascade.h0n_im,
			"coastal_weight_pos": cascade.coastal_weight_pos,
			"coastal_weight_neg": cascade.coastal_weight_neg,
		})
	return result


func _sync_native() -> void:
	if _native_backend == null or _spectrum_transition_active:
		return
	_native_backend.clear()
	_native_backend.set_sea_level(_sea_level)
	for cascade in get_cascades_compact():
		_native_backend.set_cascade_data(
			cascade.index, cascade.inv_n2,
			cascade.kx, cascade.ky, cascade.omega,
			cascade.a1, cascade.a2,
			cascade.c11, cascade.c12, cascade.c21, cascade.c22,
			cascade.parity, cascade.weight,
			cascade.h0_re, cascade.h0_im, cascade.h0n_re, cascade.h0n_im)
	if _coastal_runtime != null and _coastal_runtime.enabled and not _cascades.is_empty() and _native_backend.has_method(&"set_coastal_runtime"):
		var long_cascade: _CascadeData = _cascades[0]
		_native_backend.set_coastal_long_weights(long_cascade.coastal_weight_pos, long_cascade.coastal_weight_neg)
		_native_backend.set_coastal_runtime(
			_coastal_runtime.origin_x, _coastal_runtime.origin_z, _coastal_runtime.width, _coastal_runtime.height,
			_coastal_runtime.cell_size, _coastal_runtime.detj_safe_threshold,
			_coastal_runtime.deep_x, _coastal_runtime.deep_z, _coastal_runtime.det_j,
			_coastal_runtime.j00, _coastal_runtime.j01, _coastal_runtime.j10, _coastal_runtime.j11,
			_coastal_runtime.warp_valid, _coastal_runtime.shoaling, _coastal_runtime.propagation_valid)
	elif _native_backend.has_method(&"clear_coastal"):
		_native_backend.clear_coastal()
	_native_backend.finalize_spectrum()


func _compact_transition_cascade(current: _CascadeData, target: _CascadeData, budget: int) -> void:
	var current_keep: int = current.f_kx.size() if _mode == MODE_FULL_PAIRS else min(budget, current.f_kx.size())
	var target_keep: int = target.f_kx.size() if _mode == MODE_FULL_PAIRS else min(budget, target.f_kx.size())
	var current_selected := {}
	var target_selected := {}
	for position in current_keep:
		current_selected[current.sorted_indices[position] if current_keep < current.f_kx.size() else position] = true
	for position in target_keep:
		target_selected[target.sorted_indices[position] if target_keep < target.f_kx.size() else position] = true
	var selected: Array[int] = []
	for index in current_selected:
		selected.append(index)
	for index in target_selected:
		if not current_selected.has(index):
			selected.append(index)
	selected.sort()
	var count := selected.size()
	current.kx.resize(count); current.ky.resize(count); current.omega.resize(count)
	current.a1.resize(count); current.a2.resize(count); current.c11.resize(count); current.c12.resize(count); current.c21.resize(count); current.c22.resize(count)
	current.parity.resize(count); current.weight.resize(count)
	current.h0_re.resize(count); current.h0_im.resize(count); current.h0n_re.resize(count); current.h0n_im.resize(count)
	current.transition_h0_re.resize(count); current.transition_h0_im.resize(count); current.transition_h0n_re.resize(count); current.transition_h0n_im.resize(count)
	current.coastal_weight_pos.resize(count); current.coastal_weight_neg.resize(count)
	current.transition_coastal_weight_pos.resize(count); current.transition_coastal_weight_neg.resize(count)
	current.ev_h_re.resize(count); current.ev_h_im.resize(count); current.ev_v_re.resize(count); current.ev_v_im.resize(count)
	current.ev_a_h_re.resize(count); current.ev_a_h_im.resize(count); current.ev_b_h_re.resize(count); current.ev_b_h_im.resize(count)
	current.ev_a_v_re.resize(count); current.ev_a_v_im.resize(count); current.ev_b_v_re.resize(count); current.ev_b_v_im.resize(count)
	for slot in count:
		var index: int = selected[slot]
		var kx := current.f_kx[index]
		var ky := current.f_ky[index]
		var k_len := sqrt(kx * kx + ky * ky)
		var kx_hat := kx / k_len if k_len > 0.000001 else 0.0
		var ky_hat := ky / k_len if k_len > 0.000001 else 0.0
		current.kx[slot] = kx; current.ky[slot] = ky; current.omega[slot] = current.f_omega[index]
		current.a1[slot] = current.lambda * kx_hat; current.a2[slot] = current.lambda * ky_hat
		current.c11[slot] = current.a1[slot] * kx; current.c12[slot] = current.a1[slot] * ky
		current.c21[slot] = current.a2[slot] * kx; current.c22[slot] = current.a2[slot] * ky
		current.parity[slot] = current.f_parity[index]; current.weight[slot] = current.f_weight[index]
		if current_selected.has(index):
			current.h0_re[slot] = current.f_h0_re[index]; current.h0_im[slot] = current.f_h0_im[index]
			current.h0n_re[slot] = current.f_h0n_re[index]; current.h0n_im[slot] = current.f_h0n_im[index]
			current.coastal_weight_pos[slot] = current.f_coastal_weight_pos[index]; current.coastal_weight_neg[slot] = current.f_coastal_weight_neg[index]
		else:
			current.h0_re[slot] = 0.0; current.h0_im[slot] = 0.0; current.h0n_re[slot] = 0.0; current.h0n_im[slot] = 0.0
			current.coastal_weight_pos[slot] = 0.0; current.coastal_weight_neg[slot] = 0.0
		if target_selected.has(index):
			current.transition_h0_re[slot] = target.f_h0_re[index]; current.transition_h0_im[slot] = target.f_h0_im[index]
			current.transition_h0n_re[slot] = target.f_h0n_re[index]; current.transition_h0n_im[slot] = target.f_h0n_im[index]
			current.transition_coastal_weight_pos[slot] = target.f_coastal_weight_pos[index]; current.transition_coastal_weight_neg[slot] = target.f_coastal_weight_neg[index]
		else:
			current.transition_h0_re[slot] = 0.0; current.transition_h0_im[slot] = 0.0; current.transition_h0n_re[slot] = 0.0; current.transition_h0n_im[slot] = 0.0
			current.transition_coastal_weight_pos[slot] = 0.0; current.transition_coastal_weight_neg[slot] = 0.0
	current.transition_lambda = target.lambda
	current.count = count


static func _compact_cascade(cascade: _CascadeData, budget: int, mode: int) -> void:
	var full_count := cascade.f_kx.size()
	var keep := budget
	if mode == MODE_FULL_PAIRS or keep >= full_count:
		keep = full_count
	var selected: PackedInt32Array = []
	if keep == full_count:
		selected.resize(full_count)
		for i in full_count:
			selected[i] = i
	else:
		# Orden precomputado (importancia DESC, índice ASC), determinista.
		selected = cascade.sorted_indices.slice(0, keep)
	var count := keep
	cascade.kx.resize(count)
	cascade.ky.resize(count)
	cascade.omega.resize(count)
	cascade.a1.resize(count)
	cascade.a2.resize(count)
	cascade.c11.resize(count)
	cascade.c12.resize(count)
	cascade.c21.resize(count)
	cascade.c22.resize(count)
	cascade.parity.resize(count)
	cascade.weight.resize(count)
	cascade.h0_re.resize(count)
	cascade.h0_im.resize(count)
	cascade.h0n_re.resize(count)
	cascade.h0n_im.resize(count)
	cascade.coastal_weight_pos.resize(count)
	cascade.coastal_weight_neg.resize(count)
	cascade.ev_h_re.resize(count)
	cascade.ev_h_im.resize(count)
	cascade.ev_v_re.resize(count)
	cascade.ev_v_im.resize(count)
	cascade.ev_a_h_re.resize(count)
	cascade.ev_a_h_im.resize(count)
	cascade.ev_b_h_re.resize(count)
	cascade.ev_b_h_im.resize(count)
	cascade.ev_a_v_re.resize(count)
	cascade.ev_a_v_im.resize(count)
	cascade.ev_b_v_re.resize(count)
	cascade.ev_b_v_im.resize(count)
	var lambda := cascade.lambda
	for s in count:
		var i := selected[s]
		var kx := cascade.f_kx[i]
		var ky := cascade.f_ky[i]
		cascade.kx[s] = kx
		cascade.ky[s] = ky
		cascade.omega[s] = cascade.f_omega[i]
		var k_len := sqrt(kx * kx + ky * ky)
		var kx_hat := kx / k_len if k_len > 0.000001 else 0.0
		var ky_hat := ky / k_len if k_len > 0.000001 else 0.0
		var a1 := lambda * kx_hat
		var a2 := lambda * ky_hat
		cascade.a1[s] = a1
		cascade.a2[s] = a2
		cascade.c11[s] = a1 * kx
		cascade.c12[s] = a1 * ky
		cascade.c21[s] = a2 * kx
		cascade.c22[s] = a2 * ky
		cascade.parity[s] = cascade.f_parity[i]
		cascade.weight[s] = cascade.f_weight[i]
		cascade.h0_re[s] = cascade.f_h0_re[i]
		cascade.h0_im[s] = cascade.f_h0_im[i]
		cascade.h0n_re[s] = cascade.f_h0n_re[i]
		cascade.h0n_im[s] = cascade.f_h0n_im[i]
		cascade.coastal_weight_pos[s] = cascade.f_coastal_weight_pos[i]
		cascade.coastal_weight_neg[s] = cascade.f_coastal_weight_neg[i]
	cascade.count = count


## --- Decodificación de H0 a pares canónicos ±k ---------------------------------

static func _decode_cascade(config: OpenOceanFFTConfig, h0_bytes: PackedByteArray) -> _CascadeData:
	var n := config.resolution
	var delta_k := TAU / config.domain_size_m
	var lambda := -config.choppiness
	var floats := h0_bytes.to_float32_array()
	var half: int = n >> 1
	var result := _CascadeData.new()
	result.lambda = lambda
	result.inv_n2 = 1.0 / float(n * n)
	for y in n:
		for x in n:
			# Modos "borde" (mx = -N/2 o my = -N/2): su conjugado +N/2 no existe
			# en el espectro discreto; NO forman pares ±k (φ no se invierte).
			# Se incluyen individualmente con peso 1, igual que en Golden.
			var is_boundary := x == 0 or y == 0
			var include := false
			var weight := 1.0
			if is_boundary:
				include = true
			else:
				# Interior: verdadero par ±k (x,y) <-> (N-x, N-y).
				var nx_ := (n - x) % n
				var ny_ := (n - y) % n
				include = x < nx_ or (x == nx_ and y <= ny_)
				if not (x == nx_ and y == ny_):
					weight = 2.0
			if not include:
				continue
			var index := y * n + x
			var base := index * 4
			var h0_re := floats[base]
			var h0_im := floats[base + 1]
			var h0n_re := floats[base + 2]
			var h0n_im := floats[base + 3]
			var mx := x - half
			var my := y - half
			var kx := float(mx) * delta_k
			var ky := float(my) * delta_k
			var k_len := sqrt(kx * kx + ky * ky)
			var omega := 0.0
			if k_len > 0.000001:
				omega = sqrt(config.gravity_mps2 * k_len)
			var parity := 1.0 if (mx + my) & 1 == 0 else -1.0
			result.f_kx.append(kx)
			result.f_ky.append(ky)
			result.f_omega.append(omega)
			result.f_h0_re.append(h0_re)
			result.f_h0_im.append(h0_im)
			result.f_h0n_re.append(h0n_re)
			result.f_h0n_im.append(h0n_im)
			result.f_parity.append(parity)
			result.f_weight.append(weight)
			result.f_coastal_weight_pos.append(0.0)
			result.f_coastal_weight_neg.append(0.0)
	_compute_importance(result)
	return result


static func _compute_importance(cascade: _CascadeData) -> void:
	# Energías totales por métrica dentro de la cascada (normalización unitaria).
	var total_e := 0.0
	var total_slope := 0.0
	var total_vel := 0.0
	var total_jac := 0.0
	var lambda_sq := cascade.lambda * cascade.lambda
	var count := cascade.f_kx.size()
	for i in count:
		var e := cascade.f_h0_re[i] * cascade.f_h0_re[i] + cascade.f_h0_im[i] * cascade.f_h0_im[i] + cascade.f_h0n_re[i] * cascade.f_h0n_re[i] + cascade.f_h0n_im[i] * cascade.f_h0n_im[i]
		var k2 := cascade.f_kx[i] * cascade.f_kx[i] + cascade.f_ky[i] * cascade.f_ky[i]
		var w2 := cascade.f_omega[i] * cascade.f_omega[i]
		total_e += e
		total_slope += k2 * e
		total_vel += w2 * e
		total_jac += lambda_sq * k2 * e
	cascade.f_importance.resize(count)
	for i in count:
		var e := cascade.f_h0_re[i] * cascade.f_h0_re[i] + cascade.f_h0_im[i] * cascade.f_h0_im[i] + cascade.f_h0n_re[i] * cascade.f_h0n_re[i] + cascade.f_h0n_im[i] * cascade.f_h0n_im[i]
		var k2 := cascade.f_kx[i] * cascade.f_kx[i] + cascade.f_ky[i] * cascade.f_ky[i]
		var w2 := cascade.f_omega[i] * cascade.f_omega[i]
		var nh := e / total_e if total_e > 0.0 else 0.0
		var ns := (k2 * e) / total_slope if total_slope > 0.0 else 0.0
		var nv := (w2 * e) / total_vel if total_vel > 0.0 else 0.0
		var nj := (lambda_sq * k2 * e) / total_jac if total_jac > 0.0 else 0.0
		cascade.f_importance[i] = maxf(nh, maxf(ns, maxf(nv, nj)))
	# Orden total determinista por sort nativo de enteros: importancia DESC,
	# índice ASC. Se cuantiza a 2^23 (≈1e-7) y se empaqueta con el índice.
	var keys := PackedInt64Array()
	keys.resize(count)
	for i in count:
		var q := int(cascade.f_importance[i] * float(IMPORTANCE_QUANT))
		keys[i] = (IMPORTANCE_QUANT - q) * KEY_SCALE + i
	keys.sort()
	cascade.sorted_indices.resize(count)
	for j in count:
		cascade.sorted_indices[j] = int(keys[j] & (KEY_SCALE - 1))


func _is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

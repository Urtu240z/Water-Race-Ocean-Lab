class_name OceanQueryReduced
extends RefCounted
## Evaluador de PRODUCCIÓN de OceanQuery (Fase 2B).
##
## Misma semántica que la Golden Reference (Fase 2A.1): superficie paramétrica
## P(q,t).xz = q + Dxz(q,t), y sample_water(world_xz,t) invierte world_xz -> q
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
	# Tiempo preparado (ev_h/ev_v por modo).
	var ev_h_re := PackedFloat64Array()
	var ev_h_im := PackedFloat64Array()
	var ev_v_re := PackedFloat64Array()
	var ev_v_im := PackedFloat64Array()
	var count := 0


var _cascades: Array[_CascadeData] = []
var _sea_level := 0.0
var _prepared_valid := false
var _prepared_time := 0.0
var _mode := MODE_REDUCED
var _budgets: Array[int] = [DEFAULT_BUDGET, DEFAULT_BUDGET, DEFAULT_BUDGET]
var _native_backend: RefCounted = null

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


func set_spectrum(configs: Array[OpenOceanFFTConfig], h0_datas: Array[PackedByteArray]) -> void:
	assert(configs.size() == h0_datas.size())
	_cascades.clear()
	for index in configs.size():
		_cascades.append(_decode_cascade(configs[index], h0_datas[index]))
	_rebuild_selection()


func set_sea_level(sea_level_y: float) -> void:
	_sea_level = sea_level_y
	if _native_backend != null:
		_native_backend.set_sea_level(_sea_level)


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


## --- Inversión world_xz -> q -------------------------------------------------

func _sample_world(target_xz: Vector2):
	var q := target_xz
	_accumulate(q.x, q.y, true, _prepared_time)
	var fx: float = q.x + _acc_dx - target_xz.x
	var fz: float = q.y + _acc_dz - target_xz.y
	var residual := sqrt(fx * fx + fz * fz)
	var iterations := 0
	var max_iter := FULL_MAX_ITERATIONS if _mode == MODE_FULL_PAIRS else MAX_ITERATIONS
	var tolerance := FULL_POSITION_TOLERANCE_M if _mode == MODE_FULL_PAIRS else POSITION_TOLERANCE_M
	var converged := residual <= tolerance
	while not converged and iterations < max_iter:
		var det_j: float = (1.0 + _acc_dxx) * (1.0 + _acc_dzz) - _acc_dxz * _acc_dzx
		if absf(det_j) <= JACOBIAN_EPSILON:
			break
		var inv_det := 1.0 / det_j
		var delta_x: float = inv_det * ((1.0 + _acc_dzz) * fx - _acc_dxz * fz)
		var delta_z: float = inv_det * (-_acc_dzx * fx + (1.0 + _acc_dxx) * fz)
		q.x -= delta_x
		q.y -= delta_z
		_accumulate(q.x, q.y, true, _prepared_time)
		fx = q.x + _acc_dx - target_xz.x
		fz = q.y + _acc_dz - target_xz.y
		residual = sqrt(fx * fx + fz * fz)
		iterations += 1
		converged = residual <= tolerance
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

	for cascade in _cascades:
		var inv_n2 := cascade.inv_n2
		var count := cascade.count
		var kx_arr := cascade.kx
		var ky_arr := cascade.ky
		var om_arr := cascade.omega
		var a1_arr := cascade.a1
		var a2_arr := cascade.a2
		var c11_arr := cascade.c11
		var c12_arr := cascade.c12
		var c21_arr := cascade.c21
		var c22_arr := cascade.c22
		var par_arr := cascade.parity
		var w_arr := cascade.weight
		var h0r_arr := cascade.h0_re
		var h0i_arr := cascade.h0_im
		var h0nr_arr := cascade.h0n_re
		var h0ni_arr := cascade.h0n_im
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
				var a_re := h0r_arr[idx] * c - h0i_arr[idx] * sn
				var a_im := h0r_arr[idx] * sn + h0i_arr[idx] * c
				var b_re := h0nr_arr[idx] * c + h0ni_arr[idx] * sn
				var b_im := -h0nr_arr[idx] * sn + h0ni_arr[idx] * c
				h_re = a_re + b_re
				h_im = a_im + b_im
				v_re = om_arr[idx] * (-a_im + b_im)
				v_im = om_arr[idx] * (a_re - b_re)
			var phi := kx_arr[idx] * qx + ky_arr[idx] * qz
			var cp := cos(phi)
			var sp := sin(phi)
			var p_re := h_re * cp - h_im * sp
			var p_im := h_re * sp + h_im * cp
			var q_re := v_re * cp - v_im * sp
			var q_im := v_re * sp + v_im * cp
			var sig := par_arr[idx] * w_arr[idx]
			lh += sig * p_re
			ldx += sig * a1_arr[idx] * p_im
			ldz += sig * a2_arr[idx] * p_im
			ldhx += sig * -kx_arr[idx] * p_im
			ldhz += sig * -ky_arr[idx] * p_im
			ldxx += sig * c11_arr[idx] * p_re
			ldxz += sig * c12_arr[idx] * p_re
			ldzx += sig * c21_arr[idx] * p_re
			ldzz += sig * c22_arr[idx] * p_re
			lvh += sig * q_re
			lvx += sig * a1_arr[idx] * q_im
			lvz += sig * a2_arr[idx] * q_im
		total_h += lh * inv_n2
		total_dx += ldx * inv_n2
		total_dz += ldz * inv_n2
		total_dhx += ldhx * inv_n2
		total_dhz += ldhz * inv_n2
		total_dxx += ldxx * inv_n2
		total_dxz += ldxz * inv_n2
		total_dzx += ldzx * inv_n2
		total_dzz += ldzz * inv_n2
		total_vh += lvh * inv_n2
		total_vx += lvx * inv_n2
		total_vz += lvz * inv_n2

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


func _prepare_time(simulation_time: float) -> void:
	_prepared_valid = true
	_prepared_time = simulation_time
	for cascade in _cascades:
		var count := cascade.count
		var om_arr := cascade.omega
		var h0r_arr := cascade.h0_re
		var h0i_arr := cascade.h0_im
		var h0nr_arr := cascade.h0n_re
		var h0ni_arr := cascade.h0n_im
		var ev_hr_arr := cascade.ev_h_re
		var ev_hi_arr := cascade.ev_h_im
		var ev_vr_arr := cascade.ev_v_re
		var ev_vi_arr := cascade.ev_v_im
		for idx in count:
			var wt := om_arr[idx] * simulation_time
			var c := cos(wt)
			var sn := sin(wt)
			var a_re := h0r_arr[idx] * c - h0i_arr[idx] * sn
			var a_im := h0r_arr[idx] * sn + h0i_arr[idx] * c
			var b_re := h0nr_arr[idx] * c + h0ni_arr[idx] * sn
			var b_im := -h0nr_arr[idx] * sn + h0ni_arr[idx] * c
			ev_hr_arr[idx] = a_re + b_re
			ev_hi_arr[idx] = a_im + b_im
			ev_vr_arr[idx] = om_arr[idx] * (-a_im + b_im)
			ev_vi_arr[idx] = om_arr[idx] * (a_re - b_re)


## --- Selección ----------------------------------------------------------------

func _rebuild_selection() -> void:
	for index in _cascades.size():
		_compact_cascade(_cascades[index], _budgets[index])
	_prepared_valid = false
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
		})
	return result


func _sync_native() -> void:
	if _native_backend == null:
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
	_native_backend.finalize_spectrum()


func _compact_cascade(cascade: _CascadeData, budget: int) -> void:
	var full_count := cascade.f_kx.size()
	var keep := budget
	if _mode == MODE_FULL_PAIRS or keep >= full_count:
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
	cascade.ev_h_re.resize(count)
	cascade.ev_h_im.resize(count)
	cascade.ev_v_re.resize(count)
	cascade.ev_v_im.resize(count)
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
	cascade.count = count


## --- Decodificación de H0 a pares canónicos ±k ---------------------------------

func _decode_cascade(config: OpenOceanFFTConfig, h0_bytes: PackedByteArray) -> _CascadeData:
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
	_compute_importance(result)
	return result


func _compute_importance(cascade: _CascadeData) -> void:
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

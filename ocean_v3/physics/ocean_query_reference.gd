class_name OceanQueryReference
extends RefCounted
## GOLDEN REFERENCE CPU del océano FFT GPU en coordenadas MUNDIALES (Fase 2A.1).
##
## La superficie Tessendorf con choppiness es PARAMÉTRICA, no un heightfield:
##   P(q,t).xz = q + Dxz(q,t)
##   P(q,t).y  = sea_level + H(q,t)
## donde q es la coordenada espectral original. sample_water(world_xz, t)
## invierte world_xz -> q (Newton-Raphson 2D) y evalúa en ese q.
##
## - sample_water(...)   -> superficie bajo un XZ mundial (semántica pública).
## - sample_parametric(...) -> evalúa en q directo (helper de tests/debug).
##
## Reutiliza exactamente el mismo H0 que la GPU (misma seed, configs, tiempo,
## dispersión y lambda negativa). Es intencionadamente lenta: evalúa TODOS los
## modos de las tres cascadas (3 × N²). Referencia para Fase 2B.
##
## Normalización (derivada del pipeline): suma directa con 1/N² sobre índices
## centrados; el checkerboard del assemble cancela con k = (c - N/2)·Δk y
## queda el factor σ = (-1)^(mx+my) de la convención de origen del clipmap.

const SampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")

# Parámetros de inversión world_xz -> q (referencia, no solver infinito).
const MAX_ITERATIONS := 8
const POSITION_TOLERANCE_M := 1.0e-4
const JACOBIAN_EPSILON := 1.0e-6


class _ModeData:
	var kx := 0.0
	var ky := 0.0
	var omega := 0.0
	# h0(k) y conj(h0(-k)) tal como se empaquetan en el RGBA de H0.
	var h0_re := 0.0
	var h0_im := 0.0
	var h0n_re := 0.0
	var h0n_im := 0.0
	# Coeficientes de derivada/velocidad precalculados (no dependen de x,z,t).
	var a1 := 0.0 # lambda·kx_hat  -> contribuye a Dx y dDx/dt
	var a2 := 0.0 # lambda·ky_hat  -> contribuye a Dz y dDz/dt
	var b1 := 0.0 # kx             -> d/dwx
	var b2 := 0.0 # ky             -> d/dwz
	var c11 := 0.0
	var c12 := 0.0
	var c21 := 0.0
	var c22 := 0.0
	var parity := 1.0 # (-1)^(mx+my)
	# Estado preparado para un tiempo fijo (Newton interno y probes).
	var ev_h_re := 0.0
	var ev_h_im := 0.0
	var ev_v_re := 0.0
	var ev_v_im := 0.0


class _CascadeData:
	var inv_n2 := 0.0
	var modes: Array[_ModeData] = []


var _cascades: Array[_CascadeData] = []
var _sea_level := 0.0
var _prepared_valid := false
var _prepared_time := 0.0
var _crest_sharpen: Dictionary = {} # 5R1D: config de crest sharpening.


func set_spectrum(configs: Array[OpenOceanFFTConfig], h0_datas: Array[PackedByteArray]) -> void:
	assert(configs.size() == h0_datas.size())
	_cascades.clear()
	for index in configs.size():
		_cascades.append(_decode_cascade(configs[index], h0_datas[index]))
	_prepared_valid = false


func set_sea_level(sea_level_y: float) -> void:
	_sea_level = sea_level_y


func set_crest_sharpen(config: Dictionary) -> void:
	## 5R1D: misma configuración que render.
	_crest_sharpen = config


func is_ready() -> bool:
	return not _cascades.is_empty()


func sample_water(world_position: Vector3, simulation_time: float):
	## Superficie que existe bajo este XZ mundial: invierte world_xz -> q con
	## Newton-Raphson y evalúa height/normal/velocity en ese q.
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	prepare_time(simulation_time)
	var solved := _solve_world_to_q(Vector2(world_position.x, world_position.z))
	return _build_sample(solved.acc, solved.residual, solved.iterations, solved.converged)


func sample_parametric(parametric_position: Vector3, simulation_time: float):
	## Helper de tests/debug: evalúa en la coordenada paramétrica q directamente.
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	var acc := _parametric_accumulators(parametric_position.x, parametric_position.z, false, simulation_time)
	return _build_sample(acc, 0.0, 0, true)


func prepare_time(simulation_time: float) -> void:
	## Precalcula el espectro evolucionado h(j,t) y dh/dt para un tiempo fijo;
	## las evaluaciones posteriores (Newton, probes) no recalculan las fases ω·t.
	if _cascades.is_empty():
		return
	_prepared_valid = true
	_prepared_time = simulation_time
	for cascade in _cascades:
		for mode in cascade.modes:
			var wt := mode.omega * simulation_time
			var c := cos(wt)
			var s := sin(wt)
			var a_re := mode.h0_re * c - mode.h0_im * s
			var a_im := mode.h0_re * s + mode.h0_im * c
			var b_re := mode.h0n_re * c + mode.h0n_im * s
			var b_im := -mode.h0n_re * s + mode.h0n_im * c
			mode.ev_h_re = a_re + b_re
			mode.ev_h_im = a_im + b_im
			mode.ev_v_re = mode.omega * (-a_im + b_im)
			mode.ev_v_im = mode.omega * (a_re - b_re)


func sample_prepared(world_position: Vector3):
	if _cascades.is_empty():
		return SampleScript.flat(_sea_level)
	if not _prepared_valid:
		push_warning("OceanQueryReference.sample_prepared llamado sin prepare_time válido; devuelve sample inválido.")
		return SampleScript.invalid()
	var solved := _solve_world_to_q(Vector2(world_position.x, world_position.z))
	return _build_sample(solved.acc, solved.residual, solved.iterations, solved.converged)


func _band_height(qx: float, qz: float, band_index: int) -> float:
	## 5R1D: altura de UNA banda (LONG=0, MID=1) en q, con espectro prepared.
	var cascade: _CascadeData = _cascades[band_index]
	var total := 0.0
	for mode in cascade.modes:
		var phi := mode.kx * qx + mode.ky * qz
		var p_re := mode.ev_h_re * cos(phi) - mode.ev_h_im * sin(phi)
		total += mode.parity * p_re
	return total * cascade.inv_n2


func _apply_crest_sharpen(qx: float, qz: float, acc: Dictionary) -> void:
	## 5R1D: misma matemática 5R.1C del shader (sobre FFT base, no recursiva).
	if _crest_sharpen.is_empty():
		return
	var strength: float = float(_crest_sharpen.get("strength", 0.0))
	if strength <= 0.0:
		return
	var threshold: float = float(_crest_sharpen.get("threshold", 0.15))
	var max_gain: float = float(_crest_sharpen.get("max_gain", 0.30))
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
	var sharpen := smoothstep(threshold, threshold + 0.25, crestness) * compression * strength

	acc["h"] += sharpen * max_gain * local_hs
	var h_scale := 1.0 + sharpen * max_gain * 0.35
	acc["dx"] *= h_scale
	acc["dz"] *= h_scale


## --- Inversión world_xz -> q (Newton-Raphson 2D) ----------------------------

func _solve_world_to_q(target_xz: Vector2) -> Dictionary:
	## Resuelve F(q) = q + Dxz(q) - target_xz = 0.
	## J = [[1+dDx/dx, dDx/dz], [dDz/dx, 1+dDz/dz]]
	var q := target_xz
	var acc := _parametric_accumulators(q.x, q.y, true, _prepared_time)
	var fx: float = q.x + acc.dx - target_xz.x
	var fz: float = q.y + acc.dz - target_xz.y
	var residual := sqrt(fx * fx + fz * fz)
	var iterations := 0
	var converged := residual <= POSITION_TOLERANCE_M
	while not converged and iterations < MAX_ITERATIONS:
		var det_j: float = (1.0 + acc.dxx) * (1.0 + acc.dzz) - acc.dxz * acc.dzx
		if absf(det_j) <= JACOBIAN_EPSILON:
			break # parametrización singular/localmente no invertible
		var inv_det: float = 1.0 / det_j
		var delta_x: float = inv_det * ((1.0 + acc.dzz) * fx - acc.dxz * fz)
		var delta_z: float = inv_det * (-acc.dzx * fx + (1.0 + acc.dxx) * fz)
		q.x -= delta_x
		q.y -= delta_z
		acc = _parametric_accumulators(q.x, q.y, true, _prepared_time)
		fx = q.x + acc.dx - target_xz.x
		fz = q.y + acc.dz - target_xz.y
		residual = sqrt(fx * fx + fz * fz)
		iterations += 1
		converged = residual <= POSITION_TOLERANCE_M
	_apply_crest_sharpen(q.x, q.y, acc)
	return {
		"acc": acc,
		"residual": residual,
		"iterations": iterations,
		"converged": converged,
	}


## --- Evaluación paramétrica -------------------------------------------------

func _parametric_accumulators(qx: float, qz: float, use_prepared: bool, simulation_time: float) -> Dictionary:
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
		for mode in cascade.modes:
			var h_re := 0.0
			var h_im := 0.0
			var v_re := 0.0
			var v_im := 0.0
			if use_prepared:
				h_re = mode.ev_h_re
				h_im = mode.ev_h_im
				v_re = mode.ev_v_re
				v_im = mode.ev_v_im
			else:
				var wt := mode.omega * simulation_time
				var c := cos(wt)
				var s := sin(wt)
				var a_re := mode.h0_re * c - mode.h0_im * s
				var a_im := mode.h0_re * s + mode.h0_im * c
				var b_re := mode.h0n_re * c + mode.h0n_im * s
				var b_im := -mode.h0n_re * s + mode.h0n_im * c
				h_re = a_re + b_re
				h_im = a_im + b_im
				v_re = mode.omega * (-a_im + b_im)
				v_im = mode.omega * (a_re - b_re)
			var phi := mode.kx * qx + mode.ky * qz
			var cp := cos(phi)
			var sp := sin(phi)
			# P = h·e^{iφ}, Q = v·e^{iφ}
			var p_re := h_re * cp - h_im * sp
			var p_im := h_re * sp + h_im * cp
			var q_re := v_re * cp - v_im * sp
			var q_im := v_re * sp + v_im * cp
			var sig := mode.parity
			lh += sig * p_re
			ldx += sig * mode.a1 * p_im
			ldz += sig * mode.a2 * p_im
			ldhx += sig * -mode.b1 * p_im
			ldhz += sig * -mode.b2 * p_im
			ldxx += sig * mode.c11 * p_re
			ldxz += sig * mode.c12 * p_re
			ldzx += sig * mode.c21 * p_re
			ldzz += sig * mode.c22 * p_re
			lvh += sig * q_re
			lvx += sig * mode.a1 * q_im
			lvz += sig * mode.a2 * q_im
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

	return {
		"h": total_h, "dx": total_dx, "dz": total_dz,
		"dhx": total_dhx, "dhz": total_dhz,
		"dxx": total_dxx, "dxz": total_dxz, "dzx": total_dzx, "dzz": total_dzz,
		"vh": total_vh, "vx": total_vx, "vz": total_vz,
	}


func _build_sample(acc: Dictionary, residual: float, iterations: int, converged: bool):
	var displacement := Vector3(acc.dx, acc.h, acc.dz)
	var tangent_x := Vector3(1.0 + acc.dxx, acc.dhx, acc.dzx)
	var tangent_z := Vector3(acc.dxz, acc.dhz, 1.0 + acc.dzz)
	var normal := tangent_z.cross(tangent_x)
	if normal.length_squared() > 0.0000001:
		normal = normal.normalized()
		if normal.y < 0.0:
			normal = -normal
	else:
		normal = Vector3.UP
	var velocity := Vector3(acc.vx, acc.vh, acc.vz)
	var det_j: float = (1.0 + acc.dxx) * (1.0 + acc.dzz) - acc.dxz * acc.dzx
	if not _is_finite(displacement) or not _is_finite(normal) or not _is_finite(velocity) or not is_finite(det_j):
		return SampleScript.invalid()

	var sample := SampleScript.new()
	sample.valid = converged
	sample.height = _sea_level + acc.h
	sample.displacement = displacement
	sample.normal = normal
	sample.surface_velocity = velocity
	sample.jacobian_det = det_j
	sample.foldover_risk = det_j <= 0.0
	sample.query_residual_m = residual
	sample.query_iterations = iterations
	return sample


## --- Decodificación de H0 ---------------------------------------------------

func _decode_cascade(config: OpenOceanFFTConfig, h0_bytes: PackedByteArray) -> _CascadeData:
	var n := config.resolution
	var delta_k := TAU / config.domain_size_m
	var lambda := -config.choppiness
	var floats := h0_bytes.to_float32_array()
	var half: int = n >> 1
	var modes: Array[_ModeData] = []
	modes.resize(n * n)
	for y in n:
		for x in n:
			var index := y * n + x
			var mode := _ModeData.new()
			var mx := x - half
			var my := y - half
			mode.kx = float(mx) * delta_k
			mode.ky = float(my) * delta_k
			var k_len := sqrt(mode.kx * mode.kx + mode.ky * mode.ky)
			var base := index * 4
			mode.h0_re = floats[base]
			mode.h0_im = floats[base + 1]
			mode.h0n_re = floats[base + 2]
			mode.h0n_im = floats[base + 3]
			if k_len > 0.000001:
				mode.omega = sqrt(config.gravity_mps2 * k_len)
				var kx_hat := mode.kx / k_len
				var ky_hat := mode.ky / k_len
				mode.a1 = lambda * kx_hat
				mode.a2 = lambda * ky_hat
				mode.b1 = mode.kx
				mode.b2 = mode.ky
				mode.c11 = mode.a1 * mode.b1
				mode.c12 = mode.a1 * mode.b2
				mode.c21 = mode.a2 * mode.b1
				mode.c22 = mode.a2 * mode.b2
			mode.parity = 1.0 if (mx + my) & 1 == 0 else -1.0
			modes[index] = mode
	var result := _CascadeData.new()
	result.inv_n2 = 1.0 / float(n * n)
	result.modes = modes
	return result


func _is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

class_name OceanQueryReference
extends RefCounted
## Referencia CPU matemática del océano FFT GPU (Fase 2A).
##
## Reconstruye la misma superficie que el pipeline GPU a partir de:
## - exactamente el mismo H0 (PackedByteArray RGBA32F) subido a GPU;
## - exactamente las mismas configs LONG/MID/SHORT;
## - el mismo simulation time;
## - la misma dispersión y el mismo signo de choppiness (lambda negativa).
##
## Es intencionadamente lenta: evalúa TODOS los modos espectrales de las tres
## cascadas (3 × N² complejos). No es para physics per-frame; es la verdad
## matemática contra la que se validará la implementación reducida de 2B.
##
## Normalización derivada del pipeline:
##   tessendorf_spectrum.gd construye H0 con discrete_scale = Δk·N²;
##   stockham_ifft.glsl aplica la IFFT sin normalizar;
##   assemble_maps.glsl multiplica por 1/(N·N) y corrige el checkerboard.
## La suma directa con 1/N² sobre índices centrados reproduce exactamente los
## valores de texel del displacement_map (el checkerboard cancela al usar
## k = (c - N/2)·Δk; queda el factor σ = (-1)^(mx+my) de la convención de
## origen del clipmap: el mundo x=0 cae en el texel N/2).

const SampleScript := preload("res://ocean_v3/physics/ocean_query_sample.gd")


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
	# Estado preparado para un tiempo fijo (probes/snapshots).
	var ev_h_re := 0.0
	var ev_h_im := 0.0
	var ev_v_re := 0.0
	var ev_v_im := 0.0


class _CascadeData:
	var inv_n2 := 0.0
	var modes: Array[_ModeData] = []


var _cascades: Array[_CascadeData] = []


func set_spectrum(configs: Array[OpenOceanFFTConfig], h0_datas: Array[PackedByteArray]) -> void:
	assert(configs.size() == h0_datas.size())
	_cascades.clear()
	for index in configs.size():
		_cascades.append(_decode_cascade(configs[index], h0_datas[index]))


func is_ready() -> bool:
	return not _cascades.is_empty()


func sample_water(world_position: Vector3, simulation_time: float):
	return _evaluate(world_position.x, world_position.z, simulation_time, false)


func prepare_time(simulation_time: float) -> void:
	## Precalcula el espectro evolucionado h(j,t) y dh/dt para un tiempo fijo;
	## luego sample_prepared() evalúa posiciones sin recalcular las fases ω·t.
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
	return _evaluate(world_position.x, world_position.z, 0.0, true)


func _decode_cascade(config: OpenOceanFFTConfig, h0_bytes: PackedByteArray) -> _CascadeData:
	var n := config.resolution
	var delta_k := TAU / config.domain_size_m
	var lambda := -config.choppiness
	var floats := h0_bytes.to_float32_array()
	var half := n / 2
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


func _evaluate(wx: float, wz: float, simulation_time: float, use_prepared: bool):
	if _cascades.is_empty():
		return SampleScript.flat()

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
			var phi := mode.kx * wx + mode.ky * wz
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

	var displacement := Vector3(total_dx, total_h, total_dz)
	var tangent_x := Vector3(1.0 + total_dxx, total_dhx, total_dzx)
	var tangent_z := Vector3(total_dxz, total_dhz, 1.0 + total_dzz)
	var normal := tangent_z.cross(tangent_x)
	if normal.length_squared() > 0.0000001:
		normal = normal.normalized()
		if normal.y < 0.0:
			normal = -normal
	else:
		normal = Vector3.UP
	var velocity := Vector3(total_vx, total_vh, total_vz)

	if not _is_finite(displacement) or not _is_finite(normal) or not _is_finite(velocity):
		return SampleScript.invalid()

	var sample := SampleScript.new()
	sample.valid = true
	sample.height = total_h
	sample.displacement = displacement
	sample.normal = normal
	sample.surface_velocity = velocity
	return sample


func _is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

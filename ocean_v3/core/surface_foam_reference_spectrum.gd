class_name SurfaceFoamReferenceSpectrum
extends RefCounted
## H0 reference-compatible de GodotOceanWaves para la máscara Surface Foam.
## Esta ruta no comparte la normalización a Hs ni el band-pass de las cascadas
## físicas LONG/MID/SHORT.

const G := 9.81
const UINT_MASK := 0xffffffff
const UINT_SCALE := 1.0 / 4294967296.0


static func build_h0_rgba32f(config: SurfaceFoamReferenceConfig, simulation_seed: int) -> PackedByteArray:
	assert(config.is_valid())
	var n := config.resolution
	var h0 := PackedVector2Array()
	h0.resize(n * n)
	var dk_out := TAU / config.domain_size_m
	var compression := maxf(config.domain_size_m / maxf(config.feature_domain_m, 0.000001), 1.0)
	var dk_eval := dk_out / compression
	var half := float(n) * 0.5
	var alpha := 0.076 * pow(config.wind_speed_mps * config.wind_speed_mps / (config.fetch_length_m * G), 0.22)
	var omega_p := 22.0 * pow(G * G / (config.wind_speed_mps * config.fetch_length_m), 1.0 / 3.0)
	var wind_angle := config.wind_direction.angle()

	for y in n:
		for x in n:
			var index := y * n + x
			var k_out_vec := Vector2(float(x) - half, float(y) - half) * dk_out
			var k_eval_vec := k_out_vec / compression
			var k_eval := k_eval_vec.length() + 0.000001
			var dispersion := _finite_depth_dispersion(k_eval, config.depth_m)
			var omega := dispersion.x
			var domega_dk := dispersion.y
			var tma := _tma_spectrum(omega, omega_p, alpha, config.depth_m)
			# Direction follows the real output grid; only spectral magnitude is remapped.
			var theta := atan2(k_out_vec.x, k_out_vec.y)
			var hasselmann := _hasselmann_directional(omega, omega_p, config.wind_speed_mps, config.swell, theta - wind_angle)
			var directional := lerpf(0.5 / PI, hasselmann, 1.0 - clampf(config.directional_spread, 0.0, 1.0))
			var detail_damping := exp(-(1.0 - config.detail) * (1.0 - config.detail) * k_eval * k_eval)
			# 2D spectral remap: d²k_out = compression² d²k_eval, so the
			# energy-consistent amplitude uses dk_eval² directly.
			var w_norm := domega_dk / k_eval * dk_eval * dk_eval
			var amplitude := sqrt(maxf(2.0 * tma * directional * detail_damping * w_norm, 0.0))
			h0[index] = _gaussian_pair(simulation_seed, index) * amplitude
	return _pack_h0(h0, n)


static func _finite_depth_dispersion(k: float, depth_m: float) -> Vector2:
	var a := k * depth_m
	var b := tanh(a)
	var omega := sqrt(G * k * b)
	var derivative := 0.5 * G * (b + a * (1.0 - b * b)) / maxf(omega, 0.000001)
	return Vector2(omega, derivative)


static func _tma_spectrum(omega: float, omega_p: float, alpha: float, depth_m: float) -> float:
	var sigma := 0.07 if omega <= omega_p else 0.09
	var r := exp(-(omega - omega_p) * (omega - omega_p) / (2.0 * sigma * sigma * omega_p * omega_p))
	var jonswap := alpha * G * G / pow(omega, 5.0) * exp(-1.25 * pow(omega_p / omega, 4.0)) * pow(3.3, r)
	var omega_h := minf(omega * sqrt(depth_m / G), 2.0)
	var depth_attenuation := 0.5 * omega_h * omega_h if omega_h <= 1.0 else 1.0 - 0.5 * (2.0 - omega_h) * (2.0 - omega_h)
	return jonswap * depth_attenuation


static func _hasselmann_directional(omega: float, omega_p: float, wind_speed_mps: float, swell: float, theta: float) -> float:
	var p := omega / omega_p
	var s := 6.97 * pow(absf(p), 4.06) if omega <= omega_p else 9.77 * pow(absf(p), -2.33 - 1.45 * (wind_speed_mps * omega_p / G - 1.17))
	var s_xi := 16.0 * tanh(omega_p / omega) * swell * swell
	return _longuet_higgins(s + s_xi, theta)


static func _longuet_higgins(s: float, theta: float) -> float:
	var q := _longuet_higgins_normalization(s)
	return q * pow(absf(cos(theta * 0.5)), 2.0 * s)


static func _longuet_higgins_normalization(s: float) -> float:
	if s < 0.4:
		return 0.5 / PI + s * (0.220636 + s * (-0.109 + s * 0.090))
	var a := sqrt(s)
	return (0.5 * a + 0.0625 / a) / sqrt(PI)


static func _pack_h0(h0: PackedVector2Array, n: int) -> PackedByteArray:
	var packed := PackedFloat32Array()
	packed.resize(n * n * 4)
	for y in n:
		for x in n:
			var index := y * n + x
			var negative_index := ((n - y) % n) * n + ((n - x) % n)
			var value := h0[index]
			var opposite := h0[negative_index]
			var base := index * 4
			packed[base] = value.x
			packed[base + 1] = value.y
			packed[base + 2] = opposite.x
			packed[base + 3] = -opposite.y
	return packed.to_byte_array()


static func _gaussian_pair(simulation_seed: int, index: int) -> Vector2:
	var base := (simulation_seed & UINT_MASK) ^ ((index * 0x9e3779b9) & UINT_MASK)
	var u1 := maxf((float(_hash_u32(base ^ 0x68bc21eb)) + 0.5) * UINT_SCALE, 0.0000001)
	var u2 := (float(_hash_u32(base ^ 0x02e5be93)) + 0.5) * UINT_SCALE
	var radius := sqrt(-2.0 * log(u1))
	var angle := TAU * u2
	return Vector2(radius * cos(angle), radius * sin(angle))


static func _hash_u32(value: int) -> int:
	var x := value & UINT_MASK
	x = ((x ^ (x >> 16)) * 0x7feb352d) & UINT_MASK
	x = ((x ^ (x >> 15)) * 0x846ca68b) & UINT_MASK
	return (x ^ (x >> 16)) & UINT_MASK

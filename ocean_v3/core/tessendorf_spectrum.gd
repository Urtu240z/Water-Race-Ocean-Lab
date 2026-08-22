class_name TessendorfSpectrum
extends RefCounted
## Genera H0 determinista y normalizado una vez por cascada, sin RNG global.

const TWO_PI := TAU
const UINT_MASK := 0xffffffff
const UINT_SCALE := 1.0 / 4294967296.0


static func build_h0_rgba32f(config: Resource, simulation_seed: int) -> PackedByteArray:
	var h0 := _build_h0_vector(config, simulation_seed)
	return _pack_h0(h0, config.resolution)


## --- 3B.2B: split direccional de LONG (COASTAL / REMAINDER) -------------------
## Divide H0 LONG en dos componentes lineales:
##   H0_COASTAL   = w(k) * H0[k]        (energía cerca de la dirección del viento)
##   H0_REMAINDER = (1 - w(k)) * H0[k]
## con w(k) máscara angular suave: 1 para |ang(k, viento)| <= inner_deg, falloff
## suave hasta 0 en outer_deg, 0 después.
##
## Hermiticidad: el peso se aplica al valor complejo H0[k] ANTES del empaquetado;
## _pack_h0 genera el conjugado del texel opuesto automáticamente, por lo que
## cada componente es un campo espacial real y la suma reproduce H0_LONG
## EXACTAMENTE (w + (1-w) = 1, lineal). No hay energía nueva ni regeneración.

static func build_h0_split_rgba32f(config: OpenOceanFFTConfig, simulation_seed: int,
		inner_deg: float, outer_deg: float) -> Dictionary:
	var h0 := _build_h0_vector(config, simulation_seed)
	var wind: Vector2 = config.wind_direction.normalized()
	var delta_k: float = TAU / config.domain_size_m
	var half := float(config.resolution) * 0.5
	var coastal := PackedFloat32Array()
	var remainder := PackedFloat32Array()
	var n: int = config.resolution
	coastal.resize(n * n * 4)
	remainder.resize(n * n * 4)
	for y in n:
		for x in n:
			var index := y * n + x
			var k: Vector2 = Vector2(float(x) - half, float(y) - half) * delta_k
			var weight := _angular_weight(k, wind, inner_deg, outer_deg)
			var negative_index := ((n - y) % n) * n + ((n - x) % n)
			var negative_y: int = int(float(negative_index) / float(n))
			var k_neg: Vector2 = Vector2(float(negative_index % n) - half, float(negative_y) - half) * delta_k
			var weight_neg := _angular_weight(k_neg, wind, inner_deg, outer_deg)
			var value := h0[index]
			var negative_conjugate := Vector2(h0[negative_index].x, -h0[negative_index].y)
			var base := index * 4
			# Hermiticidad: el conjugado del texel opuesto (-k) lleva el peso de
			# ese texel (w(-k)), no el del texel actual. Así cada componente es
			# un espectro Hermitiano completo -> campo espacial real.
			coastal[base] = value.x * weight
			coastal[base + 1] = value.y * weight
			coastal[base + 2] = negative_conjugate.x * weight_neg
			coastal[base + 3] = negative_conjugate.y * weight_neg
			remainder[base] = value.x * (1.0 - weight)
			remainder[base + 1] = value.y * (1.0 - weight)
			remainder[base + 2] = negative_conjugate.x * (1.0 - weight_neg)
			remainder[base + 3] = negative_conjugate.y * (1.0 - weight_neg)
	return {
		"coastal": coastal.to_byte_array(),
		"remainder": remainder.to_byte_array(),
		"coastal_energy_metrics": _split_energy_metrics(h0, n, delta_k, wind, inner_deg, outer_deg),
	}


static func _angular_weight(k: Vector2, wind: Vector2, inner_deg: float, outer_deg: float) -> float:
	if k.length() <= 0.000001:
		return 1.0
	var ang := rad_to_deg(absf(k.normalized().angle_to(wind)))
	if ang <= inner_deg:
		return 1.0
	if ang >= outer_deg:
		return 0.0
	var t := (ang - inner_deg) / maxf(outer_deg - inner_deg, 1.0e-6)
	return 1.0 - smoothstep(0.0, 1.0, t)


static func _split_energy_metrics(h0: PackedVector2Array, n: int, delta_k: float,
		wind: Vector2, inner_deg: float, outer_deg: float) -> Dictionary:
	## H0_COASTAL y H0_REMAINDER son componentes correlacionados. Por ello no
	## existe una fracción de energía única y aditiva: se informa potencia H0
	## ponderada y estadística espacial reconstruida con su covarianza.
	var half := float(n) * 0.5
	var total_h0_power := 0.0
	var coastal_weighted_h0_power := 0.0
	var remainder_weighted_h0_power := 0.0
	var coastal_variance_numerator := 0.0
	var remainder_variance_numerator := 0.0
	var covariance_numerator := 0.0
	var original_variance_numerator := 0.0
	for y in n:
		for x in n:
			var index := y * n + x
			var k := Vector2(float(x) - half, float(y) - half) * delta_k
			var weight := _angular_weight(k, wind, inner_deg, outer_deg)
			var negative_index := ((n - y) % n) * n + ((n - x) % n)
			var negative_y: int = int(float(negative_index) / float(n))
			var k_neg := Vector2(float(negative_index % n) - half, float(negative_y) - half) * delta_k
			var weight_neg := _angular_weight(k_neg, wind, inner_deg, outer_deg)
			var value := h0[index]
			var negative_conjugate := Vector2(h0[negative_index].x, -h0[negative_index].y)
			var coastal_height := value * weight + negative_conjugate * weight_neg
			var remainder_height := value * (1.0 - weight) + negative_conjugate * (1.0 - weight_neg)
			total_h0_power += value.length_squared()
			coastal_weighted_h0_power += (value * weight).length_squared()
			remainder_weighted_h0_power += (value * (1.0 - weight)).length_squared()
			coastal_variance_numerator += coastal_height.length_squared()
			remainder_variance_numerator += remainder_height.length_squared()
			covariance_numerator += coastal_height.dot(remainder_height)
			original_variance_numerator += (value + negative_conjugate).length_squared()
	var normalization := pow(float(n), 4.0)
	var coastal_variance := coastal_variance_numerator / normalization
	var remainder_variance := remainder_variance_numerator / normalization
	var covariance := covariance_numerator / normalization
	return {
		"weighted_h0_power_coastal": coastal_weighted_h0_power,
		"weighted_h0_power_remainder": remainder_weighted_h0_power,
		"weighted_h0_power_total": total_h0_power,
		"weighted_h0_power_coastal_fraction": coastal_weighted_h0_power / total_h0_power if total_h0_power > 0.0 else 0.0,
		"weighted_h0_power_remainder_fraction": remainder_weighted_h0_power / total_h0_power if total_h0_power > 0.0 else 0.0,
		"reconstructed_spatial_variance_coastal": coastal_variance,
		"reconstructed_spatial_variance_remainder": remainder_variance,
		"coastal_remainder_covariance": covariance,
		"total_reconstructed_variance": coastal_variance + remainder_variance + 2.0 * covariance,
		"original_reconstructed_variance": original_variance_numerator / normalization,
	}


static func _build_h0_vector(config: OpenOceanFFTConfig, simulation_seed: int) -> PackedVector2Array:
	assert(config.is_valid())
	var n: int = config.resolution
	var h0 := PackedVector2Array()
	h0.resize(n * n)
	var delta_k: float = TWO_PI / config.domain_size_m
	var wind: Vector2 = config.wind_direction.normalized()
	if wind.length_squared() < 0.5:
		wind = Vector2.RIGHT
	var largest_wave: float = config.wind_speed_mps * config.wind_speed_mps / config.gravity_mps2
	var discrete_scale: float = delta_k * float(n * n)
	var total_energy := 0.0
	var outside_energy := 0.0

	for y in n:
		for x in n:
			var index := y * n + x
			var centered_index := float(n) * 0.5
			var k := Vector2(float(x) - centered_index, float(y) - centered_index) * delta_k
			var k_length := k.length()
			if k_length < 0.000001 or config.energy == 0.0 or config.target_hs_m == 0.0:
				h0[index] = Vector2.ZERO
				continue

			var k_dot_w := k.normalized().dot(wind)
			var directional := pow(maxf(k_dot_w, 0.0), config.directional_spread)
			directional += 0.05 * pow(maxf(-k_dot_w, 0.0), config.directional_spread)
			var k2 := k_length * k_length
			var phillips: float = config.energy * exp(-1.0 / maxf(k2 * largest_wave * largest_wave, 0.000001))
			phillips *= directional / maxf(k2 * k2, 0.000001)
			phillips *= exp(-k2 * config.short_wave_damping_m * config.short_wave_damping_m)
			var wavelength := TWO_PI / k_length
			var band_weight := _band_weight(wavelength, config)
			var gaussian := _gaussian_pair(simulation_seed, index)
			var amplitude := sqrt(maxf(phillips, 0.0) * 0.5) * discrete_scale * band_weight
			h0[index] = gaussian * amplitude
			var sample_energy := h0[index].length_squared()
			total_energy += sample_energy
			if wavelength < config.min_wavelength_m or wavelength > config.max_wavelength_m:
				outside_energy += sample_energy

	var measured_hs: float = estimate_hs_from_h0(h0, n)
	var amplitude_scale: float = 0.0 if measured_hs <= 0.0000001 else config.target_hs_m / measured_hs
	if amplitude_scale != 1.0:
		for index in h0.size():
			h0[index] *= amplitude_scale
	config.measured_hs_m = estimate_hs_from_h0(h0, n)
	config.out_of_band_energy_ratio = outside_energy / total_energy if total_energy > 0.0 else 0.0
	return h0


static func derive_cascade_seed(simulation_seed: int, cascade_id: StringName) -> int:
	var value := (simulation_seed & UINT_MASK) ^ 0x811c9dc5
	for byte in String(cascade_id).to_utf8_buffer():
		value = ((value ^ byte) * 0x01000193) & UINT_MASK
	return _hash_u32(value)


static func estimate_hs_from_bytes(h0_bytes: PackedByteArray, resolution: int) -> float:
	var values := h0_bytes.to_float32_array()
	var spectral_energy := 0.0
	for index in resolution * resolution:
		var base := index * 4
		var real: float = values[base] + values[base + 2]
		var imaginary: float = values[base + 1] + values[base + 3]
		spectral_energy += real * real + imaginary * imaginary
	return 4.0 * sqrt(spectral_energy / pow(float(resolution), 4.0))


static func estimate_hs_from_h0(h0: PackedVector2Array, resolution: int) -> float:
	var spectral_energy := 0.0
	for y in resolution:
		for x in resolution:
			var index := y * resolution + x
			var negative_index := ((resolution - y) % resolution) * resolution + ((resolution - x) % resolution)
			var height := h0[index] + Vector2(h0[negative_index].x, -h0[negative_index].y)
			spectral_energy += height.length_squared()
	return 4.0 * sqrt(spectral_energy / pow(float(resolution), 4.0))


static func _band_weight(wavelength: float, config: Resource) -> float:
	var width: float = maxf(config.transition_width_m, 0.0001)
	var lower := smoothstep(config.min_wavelength_m - width, config.min_wavelength_m + width, wavelength)
	var upper := 1.0 - smoothstep(config.max_wavelength_m - width, config.max_wavelength_m + width, wavelength)
	return lower * upper


static func _pack_h0(h0: PackedVector2Array, n: int) -> PackedByteArray:
	var packed := PackedFloat32Array()
	packed.resize(n * n * 4)
	for y in n:
		for x in n:
			var index := y * n + x
			var negative_index := ((n - y) % n) * n + ((n - x) % n)
			var value := h0[index]
			var negative_conjugate := Vector2(h0[negative_index].x, -h0[negative_index].y)
			var base := index * 4
			packed[base] = value.x
			packed[base + 1] = value.y
			packed[base + 2] = negative_conjugate.x
			packed[base + 3] = negative_conjugate.y
	return packed.to_byte_array()


static func _gaussian_pair(simulation_seed: int, index: int) -> Vector2:
	var base := (simulation_seed & UINT_MASK) ^ ((index * 0x9e3779b9) & UINT_MASK)
	var u1 := maxf((float(_hash_u32(base ^ 0x68bc21eb)) + 0.5) * UINT_SCALE, 0.0000001)
	var u2 := (float(_hash_u32(base ^ 0x02e5be93)) + 0.5) * UINT_SCALE
	var radius := sqrt(-2.0 * log(u1))
	var angle := TWO_PI * u2
	return Vector2(radius * cos(angle), radius * sin(angle))


static func _hash_u32(value: int) -> int:
	var x := value & UINT_MASK
	x = ((x ^ (x >> 16)) * 0x7feb352d) & UINT_MASK
	x = ((x ^ (x >> 15)) * 0x846ca68b) & UINT_MASK
	return (x ^ (x >> 16)) & UINT_MASK

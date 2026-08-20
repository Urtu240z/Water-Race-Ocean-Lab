class_name TessendorfSpectrum
extends RefCounted
## Genera H0 determinista y normalizado una vez por cascada, sin RNG global.

const TWO_PI := TAU
const UINT_MASK := 0xffffffff
const UINT_SCALE := 1.0 / 4294967296.0


static func build_h0_rgba32f(config: Resource, seed: int) -> PackedByteArray:
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
			var k := Vector2(float(x - n / 2), float(y - n / 2)) * delta_k
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
			var gaussian := _gaussian_pair(seed, index)
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
	return _pack_h0(h0, n)


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


static func _gaussian_pair(seed: int, index: int) -> Vector2:
	var base := (seed & UINT_MASK) ^ ((index * 0x9e3779b9) & UINT_MASK)
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

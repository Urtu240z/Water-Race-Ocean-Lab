class_name TessendorfSpectrum
extends RefCounted
## Genera H0 una vez en CPU. No usa el RNG global ni estado entre llamadas.

const TWO_PI := TAU
const UINT_MASK := 0xffffffff
const UINT_SCALE := 1.0 / 4294967296.0


static func build_h0_rgba32f(config: Resource, seed: int) -> PackedByteArray:
	assert(config.is_valid())
	var n = config.resolution
	var h0 := PackedVector2Array()
	h0.resize(n * n)
	var delta_k = TWO_PI / config.domain_size_m
	var wind = config.wind_direction.normalized()
	if wind.length_squared() < 0.5:
		wind = Vector2.RIGHT
	var largest_wave = config.wind_speed_mps * config.wind_speed_mps / config.gravity_mps2
	var discrete_scale = delta_k * float(n * n)

	for y in n:
		for x in n:
			var index = y * n + x
			var k = Vector2(float(x - n / 2), float(y - n / 2)) * delta_k
			var k_length = k.length()
			if k_length < 0.000001 or config.energy == 0.0:
				h0[index] = Vector2.ZERO
				continue

			var k_dot_w = k.normalized().dot(wind)
			var forward_energy = pow(maxf(k_dot_w, 0.0), config.directional_spread)
			var backward_energy = 0.05 * pow(maxf(-k_dot_w, 0.0), config.directional_spread)
			var directional = forward_energy + backward_energy
			var k2 = k_length * k_length
			var phillips = config.energy * exp(-1.0 / maxf(k2 * largest_wave * largest_wave, 0.000001))
			phillips *= directional / maxf(k2 * k2, 0.000001)
			phillips *= exp(-k2 * config.short_wave_damping_m * config.short_wave_damping_m)

			var gaussian = _gaussian_pair(seed, index)
			var amplitude = sqrt(maxf(phillips, 0.0) * 0.5) * discrete_scale
			h0[index] = gaussian * amplitude

	var packed := PackedFloat32Array()
	packed.resize(n * n * 4)
	for y in n:
		for x in n:
			var index = y * n + x
			var negative_index = ((n - y) % n) * n + ((n - x) % n)
			var value := h0[index]
			var negative_conjugate := Vector2(h0[negative_index].x, -h0[negative_index].y)
			var base = index * 4
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

extends SceneTree
## Validación CPU sin readback. Ejecutar con Godot --headless --script.

const ConfigScript := preload("res://ocean_v3/core/open_ocean_fft_config.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const ClockScript := preload("res://ocean_v3/core/simulation_clock.gd")

var _failures := 0


func _initialize() -> void:
	var config = ConfigScript.new()
	_validate_default_amplitude(config)
	config.resolution = 32
	var first: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, 12345)
	var repeated: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, 12345)
	var other_seed: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, 12346)
	_check(first == repeated, "H0 es idéntico con misma seed y parámetros")
	_check(first != other_seed, "una seed distinta cambia H0")

	config.energy = 0.0
	var zero: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, 12345)
	var zero_floats := zero.to_float32_array()
	var all_zero := true
	for value in zero_floats:
		if value != 0.0:
			all_zero = false
			break
	_check(all_zero, "energía cero produce H0 exactamente nulo")
	_validate_stockham_indexing()
	_validate_clock()

	if _failures == 0:
		print("PHASE_1A_VALIDATION: PASS")
		quit(0)
	else:
		push_error("PHASE_1A_VALIDATION: %d fallos" % _failures)
		quit(1)


func _validate_default_amplitude(config: Resource) -> void:
	var bytes: PackedByteArray = SpectrumScript.build_h0_rgba32f(config, 20260820)
	var values := bytes.to_float32_array()
	var spectral_energy := 0.0
	for index in config.resolution * config.resolution:
		var base: int = index * 4
		var real: float = values[base] + values[base + 2]
		var imaginary: float = values[base + 1] + values[base + 3]
		spectral_energy += real * real + imaginary * imaginary
	var variance := spectral_energy / pow(float(config.resolution), 4.0)
	var significant_height := 4.0 * sqrt(variance)
	print("INFO: Hs estimada en t=0 para defaults: %.3f m" % significant_height)
	_check(is_finite(significant_height) and significant_height >= 0.4 and significant_height <= 0.8, "Hs por defecto dentro del rango Race Sea de diseño")


func _validate_clock() -> void:
	var clock = ClockScript.new()
	clock.time_scale = 2.0
	clock.reset_simulation()
	clock.advance_deterministic(0.5)
	_check(is_equal_approx(clock.simulation_time, 1.0), "time_scale afecta al tiempo autoritativo")
	clock.pause()
	clock.advance_deterministic(1.0)
	_check(is_equal_approx(clock.simulation_time, 1.0), "pause congela el reloj")
	clock.reset_simulation()
	_check(clock.simulation_time == 0.0 and clock.get_render_time() == 0.0, "reset vuelve exactamente a cero")
	clock.free()


func _validate_stockham_indexing() -> void:
	var input := PackedVector2Array([
		Vector2(0.25, -0.5), Vector2(1.0, 0.25), Vector2(-0.75, 0.1), Vector2(0.4, -0.2),
		Vector2(0.9, 0.7), Vector2(-0.1, 0.3), Vector2(0.6, -0.8), Vector2(-0.2, 0.5),
	])
	var stockham := _stockham_inverse(input)
	var direct := _direct_inverse(input)
	var max_error := 0.0
	for index in input.size():
		max_error = maxf(max_error, stockham[index].distance_to(direct[index]))
	_check(max_error < 0.00001, "el orden Stockham coincide con la IDFT directa (error %.8f)" % max_error)


func _stockham_inverse(input: PackedVector2Array) -> PackedVector2Array:
	var source := input.duplicate()
	var target := PackedVector2Array()
	target.resize(input.size())
	var subtransform := 2
	while subtransform <= input.size():
		for index in input.size():
			var half := subtransform / 2
			var even_index := (index / subtransform) * half + index % half
			var odd_index := even_index + input.size() / 2
			var angle := TAU * float(index) / float(subtransform)
			var twiddle := Vector2(cos(angle), sin(angle))
			target[index] = source[even_index] + _complex_multiply(twiddle, source[odd_index])
		source = target.duplicate()
		subtransform *= 2
	return source


func _direct_inverse(input: PackedVector2Array) -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(input.size())
	for x in input.size():
		var sum := Vector2.ZERO
		for k in input.size():
			var angle := TAU * float(k * x) / float(input.size())
			sum += _complex_multiply(input[k], Vector2(cos(angle), sin(angle)))
		output[x] = sum
	return output


func _complex_multiply(a: Vector2, b: Vector2) -> Vector2:
	return Vector2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

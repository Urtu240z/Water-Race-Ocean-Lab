extends SceneTree
## Fase 3B: dispersión de profundidad finita y transformación rectilínea.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const BakerScript := preload("res://ocean_v3/coastal/coastal_propagation_baker.gd")
const MathScript := preload("res://ocean_v3/coastal/finite_depth_wave_math.gd")
const MonoScript := preload("res://ocean_v3/coastal/coastal_monochromatic_debug.gd")
const SampleScript := preload("res://ocean_v3/coastal/coastal_propagation_sample.gd")

var _failures := 0


func _initialize() -> void:
	_validate_dispersion_math()
	_validate_ramp_response()
	_validate_bank_phase_memory()
	_validate_mapping_and_gpu_payload()
	_validate_determinism()
	if _failures == 0:
		print("PHASE_3B_COASTAL_PROPAGATION: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_COASTAL_PROPAGATION: %d fallos" % _failures)
		quit(1)


func _validate_dispersion_math() -> void:
	var lambda_ref := 16.0
	var omega := MathScript.omega_for_wavelength_deep(lambda_ref)
	var k_deep := MathScript.solve_wavenumber(omega, 100.0)
	var k_shallow := MathScript.solve_wavenumber(omega, 0.5)
	var residual := 9.81 * k_shallow * tanh(k_shallow * 0.5) - omega * omega
	_check(absf(k_deep - TAU / lambda_ref) < 1.0e-5, "math: límite profundo recupera k0")
	_check(absf(residual) < 1.0e-5, "math: Newton satisface omega²=g*k*tanh(kh)")
	_check(k_shallow > k_deep and MathScript.wavelength(k_shallow) < lambda_ref, "math: longitud de onda disminuye en shallow")
	_check(MathScript.phase_speed(omega, k_shallow) < MathScript.phase_speed(omega, k_deep), "math: c disminuye en shallow")


func _validate_ramp_response() -> void:
	var data = _make_bathymetry(81, 5, func(x: int, _z: int) -> float:
		return lerpf(10.0, 0.5, float(x) / 80.0))
	var propagation = _bake(data, Vector2.RIGHT)
	var deep = propagation.sample_propagation(Vector2(0.0, 1.0))
	var shallow = propagation.sample_propagation(Vector2(40.0, 1.0))
	print("3B RAMP deep(k=%.6f lambda=%.4f c=%.4f Cg=%.4f S=%.4f) shallow(k=%.6f lambda=%.4f c=%.4f Cg=%.4f S=%.4f phase=%.4f)" % [deep.local_k, deep.wavelength_m, deep.phase_speed_mps, deep.group_velocity_mps, deep.shoaling_scale, shallow.local_k, shallow.wavelength_m, shallow.phase_speed_mps, shallow.group_velocity_mps, shallow.shoaling_scale, shallow.phase_offset_rad])
	_check(deep.valid and shallow.valid, "ramp: muestras de agua válidas")
	_check(shallow.local_k > deep.local_k and shallow.wavelength_m < deep.wavelength_m, "ramp: lambda cambia al cruzar profundidad")
	_check(shallow.phase_speed_mps < deep.phase_speed_mps, "ramp: c cambia con h")
	_check(shallow.group_velocity_mps < deep.group_velocity_mps, "ramp: Cg menor en shallow efectivo")
	_check(deep.shoaling_scale >= 0.999 and shallow.shoaling_scale > 1.0, "ramp: shoaling deep≈1 y shallow>1")
	_check(shallow.phase_offset_rad > deep.phase_offset_rad, "ramp: offset de fase se acumula aguas abajo")
	var crest_height := MonoScript.height_at(Vector2(40.0, 1.0), 0.0, shallow, Vector2.RIGHT, propagation.k0_rad_m, propagation.omega_ref_rad_s, 0.4)
	_check(absf(crest_height) <= 0.4 * shallow.shoaling_scale + 1.0e-5, "mono: amplitud usa shoaling coherente")


func _validate_bank_phase_memory() -> void:
	var data = _make_bathymetry(121, 5, func(x: int, _z: int) -> float:
		return 0.5 if x >= 40 and x <= 60 else 10.0)
	var propagation = _bake(data, Vector2.RIGHT)
	var before = propagation.sample_propagation(Vector2(15.0, 1.0))
	var on_bank = propagation.sample_propagation(Vector2(25.0, 1.0))
	var after = propagation.sample_propagation(Vector2(50.0, 1.0))
	var farther_after = propagation.sample_propagation(Vector2(55.0, 1.0))
	print("3B BANK before(lambda=%.4f S=%.4f) bank(lambda=%.4f S=%.4f) after(lambda=%.4f S=%.4f phase_lag_rad=%.4f time_lag_s=%.4f)" % [before.wavelength_m, before.shoaling_scale, on_bank.wavelength_m, on_bank.shoaling_scale, after.wavelength_m, after.shoaling_scale, after.phase_offset_rad, after.phase_offset_rad / propagation.omega_ref_rad_s])
	_check(on_bank.shoaling_scale > before.shoaling_scale, "bank: amplitud aumenta sobre el banco somero")
	_check(absf(after.wavelength_m - before.wavelength_m) < 0.01 and absf(after.shoaling_scale - before.shoaling_scale) < 0.001, "bank: recupera wavelength/amplitud deep")
	_check(after.phase_offset_rad > before.phase_offset_rad + 0.1, "bank: mantiene desplazamiento de fase tras el banco")
	_check(absf(farther_after.phase_offset_rad - after.phase_offset_rad) < 0.1, "bank: aguas profundas no reinician la fase")
	var max_step_error := 0.0
	var row := 2
	for x in range(1, propagation.width):
		var previous_index: int = row * propagation.width + x - 1
		var current_index: int = previous_index + 1
		var previous_delta: float = propagation.local_k[previous_index] - propagation.k0_rad_m
		var current_delta: float = propagation.local_k[current_index] - propagation.k0_rad_m
		var expected: float = propagation.phase_offset_rad[previous_index] + 0.5 * (previous_delta + current_delta) * propagation.cell_size_m
		max_step_error = maxf(max_step_error, absf(propagation.phase_offset_rad[current_index] - expected))
	print("3B BANK phase_continuity_max_error_rad=%.8f" % max_step_error)
	_check(max_step_error < 1.0e-6, "bank: continuidad de fase trapezoidal por celda")
	# Dirección no axial: mismo algoritmo de rayo recto, resultado finito y estable.
	var diagonal = _bake(data, Vector2(1.0, 0.35))
	var diagonal_sample = diagonal.sample_propagation(Vector2(50.0, 1.0))
	_check(diagonal_sample.valid and is_finite(diagonal_sample.phase_offset_rad), "phase: entrada diagonal sin discontinuidad numérica")


func _validate_mapping_and_gpu_payload() -> void:
	var data = _make_bathymetry(9, 4, func(x: int, _z: int) -> float: return 0.5 + float(x))
	data.world_origin_xz = Vector2(-13.0, 7.0)
	var propagation = _bake(data, Vector2.RIGHT)
	var sample = propagation.sample_propagation(Vector2(-11.5, 8.0), SampleScript.new())
	_check(sample.in_bounds and sample.valid and sample.depth_m > 3.4 and sample.depth_m < 3.6, "mapping: world-space negativo e interpolación CPU")
	_check(absf(sample.shadow_scale - 1.0) < 1.0e-6, "mapping: Straight Baker deja shadow_scale neutral")
	var authored_shadow := PackedFloat32Array()
	authored_shadow.resize(propagation.width * propagation.height)
	authored_shadow.fill(0.25)
	propagation.shadow_scale = authored_shadow
	var interpolated_shadow = propagation.sample_propagation(Vector2(-11.5, 8.0))
	_check(absf(interpolated_shadow.shadow_scale - 0.25) < 1.0e-6, "mapping: shadow_scale CPU interpola")
	propagation.shadow_scale = PackedFloat32Array()
	var legacy_shadow = propagation.sample_propagation(Vector2(-11.5, 8.0))
	_check(absf(legacy_shadow.shadow_scale - 1.0) < 1.0e-6, "mapping: shadow_scale legacy fallback válido")
	var outside = propagation.sample_propagation(Vector2(-40.0, 8.0))
	_check(not outside.in_bounds, "mapping: bounds explícito")
	var land_data = _make_bathymetry(5, 5, func(_x: int, _z: int) -> float: return 10.0)
	var land_index: int = 2 * land_data.width + 2
	land_data.depth_m[land_index] = -1.0
	land_data.land_water_mask[land_index] = 0
	var land_propagation = _bake(land_data, Vector2.RIGHT)
	_check(land_propagation.shadow_scale[land_index] == 0.0 and land_propagation.shadow_scale[0] == 1.0, "mapping: shadow_scale distingue LAND y agua")
	var textures: Dictionary = propagation.build_gpu_textures()
	_check(textures.has("field") and textures.has("metrics") and textures.has("phase") and textures["field"] != null and textures["phase"] != null, "gpu payload: tres texturas derivadas del mismo dato")
	_check(propagation.approximate_gpu_memory_bytes() == propagation.width * propagation.height * 48, "gpu payload: 48 B/nodo con fase/dirección RGBA32F")
	_check(propagation.approximate_memory_bytes() == propagation.width * propagation.height * 54, "cpu payload: shadow_scale añade 6 B/nodo en Straight legacy")


func _validate_determinism() -> void:
	var data = _make_bathymetry(43, 5, func(x: int, _z: int) -> float: return 0.5 if x > 20 else 10.0)
	var first = _bake(data, Vector2(1.0, 0.2))
	var second = _bake(data, Vector2(1.0, 0.2))
	_check(first.local_k == second.local_k and first.shoaling_scale == second.shoaling_scale and first.phase_offset_rad == second.phase_offset_rad, "determinism: mismo bathy/params produce buffers idénticos")


func _make_bathymetry(width: int, height: int, depth_fn: Callable):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = 0.5
	var count := width * height
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in height:
		for x in width:
			var index := z * width + x
			data.depth_m[index] = depth_fn.call(x, z)
			data.gradient_x[index] = 0.0
			data.gradient_z[index] = 0.0
			data.slope_magnitude[index] = 0.0
			data.land_water_mask[index] = 1
	return data


func _bake(data, direction: Vector2):
	var baker = BakerScript.new()
	baker.bathymetry_data = data
	baker.incoming_direction_xz = direction
	baker.reference_wavelength_m = 16.0
	baker.min_valid_depth_m = 0.25
	return baker.bake()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

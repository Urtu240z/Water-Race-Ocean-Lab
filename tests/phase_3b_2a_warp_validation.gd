extends SceneTree
## Fase 3B.2A: validación del mapping world_xz -> deep_xz (warp).
##
## A. FLAT: identity warp, detJ≈1, phase consistency, r_deep lineal.
## B. OBLIQUE BEACH: warp suave, dirección coherente con Snell.
## C. GAUSSIAN BANK: grid warp suave, phase consistency, jacobian distribution.
## D. ISLAND: tierra y shadow -> warp invalid; NO backtrace a través de tierra.
## Además: re-test del giro de dirección a 1 m vs 0.5 m, synthetic narrow-band
## y energía angular del espectro LONG.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")
const WarpDataScript := preload("res://ocean_v3/coastal/coastal_warp_data.gd")
const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

const SEED := 20260820

var _failures := 0


func _initialize() -> void:
	_validate_flat()
	_validate_oblique_beach()
	_validate_gaussian_bank()
	_validate_island()
	_validate_direction_resolution()
	_validate_synthetic_narrow_band()
	_measure_long_angular_energy()
	if _failures == 0:
		print("PHASE_3B_2A_WARP: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_2A_WARP: %d fallos" % _failures)
		quit(1)


## --- Helpers ------------------------------------------------------------------

func _make_data(width: int, height: int, cell: float, depth_fn: Callable):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = cell
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
			data.land_water_mask[index] = 1 if data.depth_m[index] >= 0.25 else 0
	return data


func _bake_propagation(data, direction: Vector2):
	var baker = EikonalBakerScript.new()
	baker.bathymetry_data = data
	baker.incoming_direction_xz = direction
	baker.reference_wavelength_m = 16.0
	baker.min_valid_depth_m = 0.25
	return baker.bake()


func _bake_warp(propagation):
	var baker = WarpBakerScript.new()
	baker.propagation = propagation
	baker.backtrace_step_cells = 0.5
	return baker.bake()


## --- A. FLAT ------------------------------------------------------------------

func _validate_flat() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var propagation = _bake_propagation(_make_data(81, 81, 1.0, func(_x: int, _z: int) -> float: return 100.0), direction)
	var warp = _bake_warp(propagation)
	var width: int = warp.width
	var height: int = warp.height
	var cell: float = warp.cell_size_m
	var max_pos_error := 0.0
	var max_detj_error := 0.0
	var max_phase_error := 0.0
	var max_r_linear_error := 0.0
	var valid_count := 0
	# n0 = perpendicular(d0) con el MISMO convenio que el baker: (-d.y, d.x).
	var normal := Vector2(-direction.y, direction.x)
	var k0: float = warp.k0_rad_m
	var deep_origin: Vector2 = warp.deep_origin_xz
	# Continuidad del mapping: salto de deep_xz entre celdas adyacentes válidas.
	var max_mapping_jump := 0.0
	for z in range(4, height - 4):
		for x in range(4, width - 4):
			var index := z * width + x
			if warp.valid_mask[index] == 0:
				continue
			valid_count += 1
			var world: Vector2 = warp.world_origin_xz + Vector2(float(x), float(z)) * cell
			var deep := Vector2(warp.deep_x[index], warp.deep_z[index])
			max_pos_error = maxf(max_pos_error, deep.distance_to(world))
			max_detj_error = maxf(max_detj_error, absf(warp.jacobian_det[index] - 1.0))
			var phase_rebuilt: float = k0 * (deep - deep_origin).dot(direction)
			max_phase_error = maxf(max_phase_error, absf(phase_rebuilt - propagation.phase_rad[index]))
			max_r_linear_error = maxf(max_r_linear_error, absf(warp.r_deep[index] - world.dot(normal)))
			if x < width - 5 and warp.valid_mask[z * width + x + 1] != 0:
				var deep_e := Vector2(warp.deep_x[z * width + x + 1], warp.deep_z[z * width + x + 1])
				max_mapping_jump = maxf(max_mapping_jump, deep.distance_to(deep_e))
	print("3B.2A FLAT valid=%d pos_max=%.6f detj_max=%.6f phase_max=%.8f r_linear_max=%.6f mapping_jump_max=%.4f" % [valid_count, max_pos_error, max_detj_error, max_phase_error, max_r_linear_error, max_mapping_jump])
	_check(max_pos_error < cell * 0.01, "flat: warp ~= identidad (pos error << cell)")
	_check(max_detj_error < 0.01, "flat: detJ ~= 1")
	_check(max_phase_error < 1.0e-3, "flat: fase del warp reproduce Eikonal")
	_check(max_r_linear_error < 0.01, "flat: r_deep lineal = dot(world, n0)")
	_check(valid_count > (width - 8) * (height - 8) * 0.9, "flat: interior mayoritariamente válido")
	_check(max_mapping_jump < cell * 1.05, "flat: mapping continuo entre celdas")


## --- B. OBLIQUE BEACH ----------------------------------------------------------

func _validate_oblique_beach() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var data = _make_data(101, 61, 1.0, func(x: int, _z: int) -> float: return lerpf(100.0, 2.0, float(x) / 100.0))
	var propagation = _bake_propagation(data, direction)
	var warp = _bake_warp(propagation)
	var width: int = warp.width
	var height: int = warp.height
	var deep_snell: float = absf(propagation.local_direction_z[30 * propagation.width + 12]) / propagation.phase_speed_mps[30 * propagation.width + 12]
	var shallow_snell: float = absf(propagation.local_direction_z[30 * propagation.width + 82]) / propagation.phase_speed_mps[30 * propagation.width + 82]
	var max_warp_angle := 0.0
	var smooth_max := 0.0
	for z in range(4, height - 4):
		for x in range(4, width - 4):
			var index := z * width + x
			if warp.valid_mask[index] == 0:
				continue
			var deep := Vector2(warp.deep_x[index], warp.deep_z[index])
			var x1 := mini(x + 1, width - 1)
			var z1 := mini(z + 1, height - 1)
			var d_dx: Vector2 = Vector2(warp.deep_x[z * width + x1], warp.deep_z[z * width + x1]) - deep
			var d_dz: Vector2 = Vector2(warp.deep_x[z1 * width + x], warp.deep_z[z1 * width + x]) - deep
			var cell_dir := (d_dx + d_dz).normalized()
			max_warp_angle = maxf(max_warp_angle, rad_to_deg(acos(clampf(cell_dir.dot(direction), -1.0, 1.0))))
			if x > 4 and z > 4 and x < width - 5 and z < height - 5:
				var west := Vector2(warp.deep_x[z * width + x - 1], warp.deep_z[z * width + x - 1])
				var north := Vector2(warp.deep_x[(z - 1) * width + x], warp.deep_z[(z - 1) * width + x])
				smooth_max = maxf(smooth_max, maxf(deep.distance_to(west), deep.distance_to(north)))
	print("3B.2A BEACH snell_deep=%.6f snell_shallow=%.6f snell_error=%.6f warp_max_angle=%.3f smooth_max_cell_shift=%.4f" % [deep_snell, shallow_snell, absf(deep_snell - shallow_snell), max_warp_angle, smooth_max])
	_check(absf(deep_snell - shallow_snell) < 0.025, "beach: Snell conservado")
	_check(max_warp_angle < 30.0, "beach: warp suave, direcciones coherentes")
	_check(smooth_max < warp.cell_size_m * 3.0, "beach: grid warpeado continuo (sin tears)")


## --- C. GAUSSIAN BANK ----------------------------------------------------------

func _validate_gaussian_bank() -> void:
	var data = _make_data(129, 97, 1.0, func(x: int, z: int) -> float:
		var px := float(x - 64)
		var pz := float(z - 48)
		return 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0)))
	var propagation = _bake_propagation(data, Vector2.RIGHT)
	var warp = _bake_warp(propagation)
	var width: int = warp.width
	var height: int = warp.height
	var detj_values: Array[float] = []
	var max_phase_error := 0.0
	var max_dir_change := 0.0
	var valid_count := 0
	var k0: float = warp.k0_rad_m
	var deep_origin: Vector2 = warp.deep_origin_xz
	for index in width * height:
		var x: int = index % width
		var z: int = index / width
		if x == 0 or z == 0 or x == width - 1 or z == height - 1:
			continue
		if warp.valid_mask[index] == 0:
			continue
		valid_count += 1
		detj_values.append(warp.jacobian_det[index])
		var deep := Vector2(warp.deep_x[index], warp.deep_z[index])
		var phase_rebuilt: float = k0 * (deep - deep_origin).dot(Vector2.RIGHT)
		max_phase_error = maxf(max_phase_error, absf(phase_rebuilt - propagation.phase_rad[index]))
		var dir_change := rad_to_deg(acos(clampf(Vector2(propagation.local_direction_x[index], propagation.local_direction_z[index]).dot(Vector2.RIGHT), -1.0, 1.0)))
		max_dir_change = maxf(max_dir_change, dir_change)
	var stats := _stats(detj_values)
	var safe := 0
	var near := 0
	var folded := 0
	for index in width * height:
		match warp.jacobian_class[index]:
			WarpDataScript.JacobianClass.SAFE: safe += 1
			WarpDataScript.JacobianClass.NEAR_CAUSTIC: near += 1
			WarpDataScript.JacobianClass.FOLDED: folded += 1
	var valid_total := width * height
	print("3B.2A BANK valid=%d detJ min=%.4f p5=%.4f median=%.4f max=%.4f | SAFE=%d NEAR=%d FOLDED=%d (de %d) | phase_max=%.6f dir_max=%.3f" % [valid_count, stats[0], stats[1], stats[2], stats[3], safe, near, folded, valid_total, max_phase_error, max_dir_change])
	_check(max_phase_error < 1.0e-3, "bank: fase del warp reproduce Eikonal")
	_check(max_dir_change > 1.0, "bank: refracción real presente")
	_check(safe > 0, "bank: zona SAFE existe")
	_check(folded == 0, "bank: sin folds en geometría gaussiana suave")
	_check(stats[2] > 0.5 and stats[2] < 1.6, "bank: detJ mediana en rango razonable")


## --- D. ISLAND ------------------------------------------------------------------

func _validate_island() -> void:
	var data = _make_data(101, 81, 1.0, func(x: int, z: int) -> float:
		var dx := float(x - 50)
		var dz := float(z - 40)
		return -1.0 if dx * dx + dz * dz < 14.0 * 14.0 else 18.0)
	var propagation = _bake_propagation(data, Vector2.RIGHT)
	var warp = _bake_warp(propagation)
	var width: int = warp.width
	var height: int = warp.height
	var land_index: int = 40 * width + 50
	var shadow_index: int = 40 * width + 76
	var side_index: int = 64 * width + 76
	var land_warp: int = warp.valid_mask[land_index]
	var shadow_warp: int = warp.valid_mask[shadow_index]
	var side_warp: int = warp.valid_mask[side_index]
	var crossed_land := 0
	var valid_total := 0
	for index in width * height:
		if propagation.valid_mask[index] == 0 or propagation.reached_mask[index] == 0:
			continue
		valid_total += 1
		if warp.boundary_hit[index] == WarpDataScript.BoundaryHit.LAND_OR_SHADOW:
			crossed_land += 1
	print("3B.2A ISLAND land_warp=%d shadow_warp=%d side_warp=%d backtrace_blocked=%d/%d" % [land_warp, shadow_warp, side_warp, crossed_land, valid_total])
	_check(land_warp == 0, "island: warp inválido en tierra")
	_check(shadow_warp != 0, "island: warp conserva agua alcanzada detrás")
	_check(side_warp != 0, "island: agua lateral con warp válido")
	_check(crossed_land > 0, "island: el warp reporta el límite de tierra sin usarlo como reached mask")


## --- Giro de dirección 1 m vs 0.5 m (sección 10) --------------------------------

func _validate_direction_resolution() -> void:
	var results := {}
	for resolution: float in [1.0, 0.5]:
		var width := 129 if resolution == 1.0 else 258
		var height := 97 if resolution == 1.0 else 194
		var res: float = resolution
		var data = _make_data(width, height, resolution, func(x: int, z: int) -> float:
			var px := float(x) * res - 64.0
			var pz := float(z) * res - 48.0
			return 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0)))
		var propagation = _bake_propagation(data, Vector2.RIGHT)
		var max_angle := 0.0
		var angles: Array[float] = []
		var max_angle_pos := Vector2.ZERO
		for index in propagation.width * propagation.height:
			var x: int = index % propagation.width
			var z: int = index / propagation.width
			if propagation.reached_mask[index] == 0:
				continue
			var angle := rad_to_deg(acos(clampf(Vector2(propagation.local_direction_x[index], propagation.local_direction_z[index]).dot(Vector2.RIGHT), -1.0, 1.0)))
			angles.append(angle)
			if angle > max_angle:
				max_angle = angle
				max_angle_pos = Vector2(float(x) * resolution - 64.0, float(z) * resolution - 48.0)
		angles.sort()
		var p95 := angles[int(0.95 * float(angles.size() - 1))]
		results[resolution] = {"max": max_angle, "p95": p95, "pos": max_angle_pos}
		print("3B.2A DIR_RES %.1fm max=%.4f p95=%.4f pos=(%.1f,%.1f) n=%d" % [resolution, max_angle, p95, max_angle_pos.x, max_angle_pos.y, angles.size()])
	var max_1m: float = results[1.0]["max"]
	var max_05: float = results[0.5]["max"]
	var p95_1m: float = results[1.0]["p95"]
	var p95_05: float = results[0.5]["p95"]
	_check(absf(max_05 - max_1m) < 15.0, "dir: max change estable al duplicar resolución (diferencia < 15°)")
	_check(absf(p95_05 - p95_1m) < 5.0, "dir: P95 estable al duplicar resolución")
	_check(max_1m > 10.0 and max_05 > 10.0, "dir: refracción fuerte en ambas resoluciones")


## --- Synthetic narrow-band (sección 13) ----------------------------------------

func _validate_synthetic_narrow_band() -> void:
	var data = _make_data(129, 97, 1.0, func(x: int, z: int) -> float:
		var px := float(x - 64)
		var pz := float(z - 48)
		return 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0)))
	var propagation = _bake_propagation(data, Vector2.RIGHT)
	var warp = _bake_warp(propagation)
	var width: int = warp.width
	var height: int = warp.height
	var k0: float = propagation.k0_rad_m
	var omega0: float = propagation.omega_ref_rad_s
	var t := 2.3
	var max_jump := 0.0
	var max_jump_ratio := 0.0
	var max_jump_time := 0.0
	var valid_count := 0
	for z in range(4, height - 4):
		for x in range(4, width - 4):
			var index := z * width + x
			if warp.valid_mask[index] == 0:
				continue
			valid_count += 1
			var deep := Vector2(warp.deep_x[index], warp.deep_z[index])
			var v1 := _narrow_band_value(deep, k0, omega0, t)
			var e: Variant = _sample_east(warp, x, z, k0, omega0, t)
			var n: Variant = _sample_north(warp, x, z, k0, omega0, t)
			if e != null:
				var ddeep: Vector2 = Vector2(warp.deep_x[z * width + x + 1], warp.deep_z[z * width + x + 1]) - deep
				var expected_jump := _narrow_band_max_step(deep, ddeep, k0, omega0, t)
				max_jump = maxf(max_jump, absf(v1 - e))
				if expected_jump > 1.0e-9:
					max_jump_ratio = maxf(max_jump_ratio, absf(v1 - e) / expected_jump)
			if n != null:
				var ddeep: Vector2 = Vector2(warp.deep_x[(z + 1) * width + x], warp.deep_z[(z + 1) * width + x]) - deep
				var expected_jump := _narrow_band_max_step(deep, ddeep, k0, omega0, t)
				max_jump = maxf(max_jump, absf(v1 - n))
				if expected_jump > 1.0e-9:
					max_jump_ratio = maxf(max_jump_ratio, absf(v1 - n) / expected_jump)
			var v2 := _narrow_band_value(deep, k0, omega0, t + 0.1)
			max_jump_time = maxf(max_jump_time, absf(v1 - v2))
	print("3B.2A NARROW_BAND valid=%d max_spatial_jump=%.6f max_jump_ratio=%.3f max_temporal_jump_0.1s=%.6f" % [valid_count, max_jump, max_jump_ratio, max_jump_time])
	# Un tear es un salto incoherente: muy superior a lo que la derivada local
	# del patrón (a lo largo del deep desplazado) predice. ratio > 3 = tear.
	_check(max_jump_ratio < 3.0, "narrow-band: sin tears (salto coherente con el mapping)")
	_check(max_jump_time < 0.5, "narrow-band: continuidad temporal del patrón animado")


func _narrow_band_value(deep: Vector2, k0: float, omega0: float, t: float) -> float:
	var value := 0.0
	for i in 5:
		var angle_offset := lerpf(-0.18, 0.18, float(i) / 4.0)
		var dir := Vector2.RIGHT.rotated(angle_offset)
		var freq_scale := lerpf(0.94, 1.06, float(i) / 4.0)
		var amplitude := 0.75 / 5.0
		value += amplitude * cos(k0 * freq_scale * deep.dot(dir) - omega0 * freq_scale * t + 0.7 * float(i))
	return value


func _narrow_band_max_step(deep: Vector2, ddeep: Vector2, k0: float, omega0: float, t: float) -> float:
	## Cota del salto esperado del patrón al desplazarse ddeep: suma de
	## amplitud_i * k0 * freq_i * |dot(dir_i, ddeep)| (derivada direccional).
	var bound := 0.0
	for i in 5:
		var angle_offset := lerpf(-0.18, 0.18, float(i) / 4.0)
		var dir := Vector2.RIGHT.rotated(angle_offset)
		var freq_scale := lerpf(0.94, 1.06, float(i) / 4.0)
		var amplitude := 0.75 / 5.0
		bound += amplitude * k0 * freq_scale * absf(dir.dot(ddeep))
	return bound


func _sample_east(warp, x: int, z: int, k0: float, omega0: float, t: float) -> Variant:
	var width: int = warp.width
	if x + 1 >= width or warp.valid_mask[z * width + x + 1] == 0:
		return null
	var d2 := Vector2(warp.deep_x[z * width + x + 1], warp.deep_z[z * width + x + 1])
	return _narrow_band_value(d2, k0, omega0, t)


func _sample_north(warp, x: int, z: int, k0: float, omega0: float, t: float) -> Variant:
	var width: int = warp.width
	var height: int = warp.height
	if z + 1 >= height or warp.valid_mask[(z + 1) * width + x] == 0:
		return null
	var d2 := Vector2(warp.deep_x[(z + 1) * width + x], warp.deep_z[(z + 1) * width + x])
	return _narrow_band_value(d2, k0, omega0, t)


## --- Energía angular LONG (sección 17) ------------------------------------------

func _measure_long_angular_energy() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		var configs = SeaStateScript.build_cascades(state)
		var long_config: OpenOceanFFTConfig = configs[0]
		var h0_bytes = SpectrumScript.build_h0_rgba32f(long_config, SpectrumScript.derive_cascade_seed(SEED, long_config.id))
		var floats := h0_bytes.to_float32_array()
		var n: int = long_config.resolution
		var half := float(n) * 0.5
		var delta_k: float = TAU / long_config.domain_size_m
		var wind: Vector2 = long_config.wind_direction.normalized()
		var total := 0.0
		var e10 := 0.0
		var e20 := 0.0
		var e30 := 0.0
		var dominant_dir := Vector2.ZERO
		var dominant_energy := 0.0
		for y in n:
			for x in n:
				var index := y * n + x
				var k: Vector2 = Vector2(float(x) - half, float(y) - half) * delta_k
				if k.length() < 0.000001:
					continue
				var base := index * 4
				var re: float = floats[base]
				var im: float = floats[base + 1]
				var re2: float = floats[base + 2]
				var im2: float = floats[base + 3]
				var energy := re * re + im * im + re2 * re2 + im2 * im2
				total += energy
				var angle_deg := rad_to_deg(k.normalized().angle_to(wind))
				if absf(angle_deg) <= 10.0:
					e10 += energy
				if absf(angle_deg) <= 20.0:
					e20 += energy
				if absf(angle_deg) <= 30.0:
					e30 += energy
				if energy > dominant_energy:
					dominant_energy = energy
					dominant_dir = k.normalized()
		var pct10 := 100.0 * e10 / maxf(total, 1.0e-12)
		var pct20 := 100.0 * e20 / maxf(total, 1.0e-12)
		var pct30 := 100.0 * e30 / maxf(total, 1.0e-12)
		print("3B.2A LONG_ENERGY %s dominant_deg=%.2f energy_10=%.1f%% 20=%.1f%% 30=%.1f%%" % [state_name, rad_to_deg(dominant_dir.angle_to(wind)), pct10, pct20, pct30])


## --- Utilidades -----------------------------------------------------------------

func _stats(values: Array) -> Array:
	if values.is_empty():
		return [0.0, 0.0, 0.0, 0.0]
	var sorted := values.duplicate()
	sorted.sort()
	return [sorted[0], sorted[int(0.05 * float(sorted.size() - 1))], sorted[int(0.5 * float(sorted.size() - 1))], sorted[sorted.size() - 1]]


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

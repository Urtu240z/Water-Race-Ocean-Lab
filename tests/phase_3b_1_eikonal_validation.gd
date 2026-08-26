extends SceneTree
## Fase 3B.1: validación cuantitativa del campo Eikonal bidimensional.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")

var _failures := 0


func _initialize() -> void:
	_validate_flat_plane()
	_validate_oblique_snell()
	_validate_bank_and_determinism()
	_validate_island_shadow()
	_validate_two_island_channel()
	if _failures == 0:
		print("PHASE_3B_1_EIKONAL: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_1_EIKONAL: %d fallos" % _failures)
		quit(1)


func _validate_flat_plane() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var propagation = _bake(_make_data(81, 81, func(_x: int, _z: int) -> float: return 100.0), direction)
	var max_angle_deg := 0.0
	var max_k_error := 0.0
	var max_shadow_error := 0.0
	for z in range(4, propagation.height - 4):
		for x in range(4, propagation.width - 4):
			var index: int = z * propagation.width + x
			var local_direction := Vector2(propagation.local_direction_x[index], propagation.local_direction_z[index])
			max_angle_deg = maxf(max_angle_deg, rad_to_deg(acos(clampf(local_direction.dot(direction), -1.0, 1.0))))
			var gradient_k := Vector2(propagation.phase_gradient_x[index], propagation.phase_gradient_z[index]).length()
			max_k_error = maxf(max_k_error, absf(gradient_k - propagation.local_k[index]))
			max_shadow_error = maxf(max_shadow_error, absf(propagation.shadow_scale[index] - 1.0))
	print("3B.1 FLAT max_angle_deg=%.6f max_k_error=%.8f max_shadow_error=%.8f residual=%.8f sweeps=%d" % [max_angle_deg, max_k_error, max_shadow_error, propagation.eikonal_max_residual_rad_m, propagation.eikonal_sweeps])
	_check(max_angle_deg < 0.25, "flat: dirección local coincide con incoming")
	_check(max_k_error < 1.0e-4, "flat: |grad(phi)| coincide con k")
	_check(max_shadow_error < 1.0e-6, "flat: shadow_scale neutral")


func _validate_oblique_snell() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var data = _make_data(101, 61, func(x: int, _z: int) -> float: return lerpf(100.0, 2.0, float(x) / 100.0))
	var propagation = _bake(data, direction)
	var deep = propagation.sample_propagation(Vector2(12.0, 30.0))
	var shallow = propagation.sample_propagation(Vector2(82.0, 30.0))
	var deep_snell: float = absf(deep.local_direction_xz.y) / deep.phase_speed_mps
	var shallow_snell: float = absf(shallow.local_direction_xz.y) / shallow.phase_speed_mps
	print("3B.1 SNELL deep=%.6f shallow=%.6f error=%.6f" % [deep_snell, shallow_snell, absf(deep_snell - shallow_snell)])
	_check(deep.valid and shallow.valid, "snell: muestras alcanzadas")
	_check(absf(deep_snell - shallow_snell) < 0.025, "snell: sin(theta)/c conservado")


func _validate_bank_and_determinism() -> void:
	var data = _make_data(129, 97, func(x: int, z: int) -> float:
		var px := float(x - 64)
		var pz := float(z - 48)
		return 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0)))
	var direction := Vector2.RIGHT
	var first = _bake(data, direction)
	var second = _bake(data, direction)
	var max_angle_deg := 0.0
	var max_residual := 0.0
	var reached := 0
	for index in first.width * first.height:
		var x: int = index % first.width
		var z: int = index / first.width
		if x == 0 or z == 0 or x == first.width - 1 or z == first.height - 1:
			continue
		if first.reached_mask[index] == 0:
			continue
		reached += 1
		var local_direction := Vector2(first.local_direction_x[index], first.local_direction_z[index])
		max_angle_deg = maxf(max_angle_deg, rad_to_deg(acos(clampf(local_direction.dot(direction), -1.0, 1.0))))
		max_residual = maxf(max_residual, absf(Vector2(first.phase_gradient_x[index], first.phase_gradient_z[index]).length() - first.local_k[index]))
	print("3B.1 BANK max_angle_deg=%.4f max_residual=%.6f reached=%d/%d sweeps=%d" % [max_angle_deg, max_residual, reached, first.width * first.height, first.eikonal_sweeps])
	_check(max_angle_deg > 1.0, "bank: dirección local curva físicamente")
	_check(max_residual < 0.12, "bank: residual Eikonal acotado a resolución de grid")
	_check(first.phase_rad == second.phase_rad and first.local_direction_x == second.local_direction_x and first.reached_mask == second.reached_mask, "bank: solve determinista")


func _validate_island_shadow() -> void:
	var data = _make_data(101, 81, func(x: int, z: int) -> float:
		var dx := float(x - 50)
		var dz := float(z - 40)
		return -1.0 if dx * dx + dz * dz < 14.0 * 14.0 else 18.0)
	var propagation = _bake(data, Vector2.RIGHT)
	var invalid_index: int = 40 * propagation.width + 50
	var shadow_index: int = 40 * propagation.width + 76
	var open_index: int = 20 * propagation.width + 76
	var side_index: int = 64 * propagation.width + 76
	var shadow_direction := Vector2(propagation.local_direction_x[shadow_index], propagation.local_direction_z[shadow_index])
	print("3B.1 ISLAND invalid=%d shadow_reached=%d shadow_scale=%.4f shadow_dir=(%.4f,%.4f) open_scale=%.4f side=%d" % [propagation.valid_mask[invalid_index], propagation.reached_mask[shadow_index], propagation.shadow_scale[shadow_index], shadow_direction.x, shadow_direction.y, propagation.shadow_scale[open_index], propagation.reached_mask[side_index]])
	_check(propagation.valid_mask[invalid_index] == 0, "island: tierra inválida")
	_check(propagation.reached_mask[shadow_index] != 0, "island: agua detrás permanece alcanzada")
	_check(propagation.shadow_scale[shadow_index] >= 0.15 and propagation.shadow_scale[shadow_index] < 0.999, "island: sombra suave detrás")
	_check(propagation.shadow_scale[open_index] > 0.999, "island: agua abierta sin sombra")
	_check(shadow_direction.dot(Vector2.RIGHT) < 0.999, "island: dirección gira alrededor del obstáculo")
	_check(propagation.reached_mask[side_index] != 0, "island: agua lateral alcanzada")


func _validate_two_island_channel() -> void:
	var data = _make_data(121, 81, func(x: int, z: int) -> float:
		var upper_dx := float(x - 50)
		var upper_dz := float(z - 28)
		var lower_dx := float(x - 50)
		var lower_dz := float(z - 52)
		var upper_land := upper_dx * upper_dx + upper_dz * upper_dz < 10.0 * 10.0
		var lower_land := lower_dx * lower_dx + lower_dz * lower_dz < 10.0 * 10.0
		return -1.0 if upper_land or lower_land else 18.0)
	var propagation = _bake(data, Vector2.RIGHT)
	var upper_lee: int = 32 * propagation.width + 78
	var channel: int = 40 * propagation.width + 78
	var lower_lee: int = 48 * propagation.width + 78
	var open: int = 12 * propagation.width + 78
	print("3B.1 CHANNEL upper_reached=%d upper_scale=%.4f channel_reached=%d channel_scale=%.4f lower_reached=%d lower_scale=%.4f open_scale=%.4f" % [propagation.reached_mask[upper_lee], propagation.shadow_scale[upper_lee], propagation.reached_mask[channel], propagation.shadow_scale[channel], propagation.reached_mask[lower_lee], propagation.shadow_scale[lower_lee], propagation.shadow_scale[open]])
	_check(propagation.reached_mask[upper_lee] != 0 and propagation.reached_mask[lower_lee] != 0, "channel: ambos leewards alcanzados")
	_check(propagation.reached_mask[channel] != 0, "channel: paso entre islas alcanzado")
	_check(propagation.shadow_scale[channel] > propagation.shadow_scale[upper_lee] and propagation.shadow_scale[channel] > propagation.shadow_scale[lower_lee], "channel: canal conserva más luz que los leewards")
	_check(propagation.shadow_scale[open] > 0.999, "channel: agua abierta sin sombra")


func _make_data(width: int, height: int, depth_fn: Callable):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
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


func _bake(data, direction: Vector2):
	var baker = EikonalBakerScript.new()
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

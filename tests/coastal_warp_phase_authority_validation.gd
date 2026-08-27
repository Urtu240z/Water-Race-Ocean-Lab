extends SceneTree
## Validación cuantitativa del fix COASTAL WARP PHASE-AUTHORITY.
## Casos sintéticos deterministas: flat, smooth ramp, single island, channel y rocks.

const PropagationScript := preload("res://ocean_v3/coastal/coastal_propagation_data.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")
const WarpDataScript := preload("res://ocean_v3/coastal/coastal_warp_data.gd")

var _failures := 0


func _initialize() -> void:
	_validate_flat_identity_and_units()
	_validate_smooth_ramp_authority()
	_validate_island_cut_locus()
	_validate_channel_and_multiple_rocks()
	if _failures == 0:
		print("COASTAL_WARP_PHASE_AUTHORITY: PASS")
		quit(0)
	else:
		push_error("COASTAL_WARP_PHASE_AUTHORITY: %d fallos" % _failures)
		quit(1)


func _make_propagation(width: int, height: int, cell: float, direction: Vector2,
		phase_fn: Callable, mask_fn := Callable(), direction_fn := Callable()):
	var propagation = PropagationScript.new()
	propagation.world_origin_xz = Vector2(-0.5 * float(width - 1) * cell, -0.5 * float(height - 1) * cell)
	propagation.width = width
	propagation.height = height
	propagation.cell_size_m = cell
	propagation.omega_ref_rad_s = 1.0
	propagation.k0_rad_m = 0.5
	propagation.incoming_direction_xz = direction.normalized()
	propagation.min_valid_depth_m = 0.25
	propagation.propagation_kind = 1
	var count := width * height
	propagation.depth_m.resize(count)
	propagation.local_k.resize(count)
	propagation.wavelength_m.resize(count)
	propagation.phase_speed_mps.resize(count)
	propagation.group_velocity_mps.resize(count)
	propagation.shoaling_scale.resize(count)
	propagation.phase_offset_rad.resize(count)
	propagation.phase_rad.resize(count)
	propagation.phase_gradient_x.resize(count)
	propagation.phase_gradient_z.resize(count)
	propagation.local_direction_x.resize(count)
	propagation.local_direction_z.resize(count)
	propagation.render_phase_rad.resize(count)
	propagation.render_direction_x.resize(count)
	propagation.render_direction_z.resize(count)
	propagation.valid_mask.resize(count)
	propagation.reached_mask.resize(count)
	propagation.shadow_scale.resize(count)
	propagation.cut_locus_mask.resize(count)
	for z in height:
		for x in width:
			var index := z * width + x
			var point: Vector2 = propagation.world_origin_xz + Vector2(float(x), float(z)) * cell
			var valid := true if not mask_fn.is_valid() else bool(mask_fn.call(point))
			var phase_data: Dictionary = phase_fn.call(point)
			var phase: float = phase_data["phase"]
			var gradient: Vector2 = phase_data["gradient"]
			var phase_direction := gradient.normalized() if gradient.length_squared() > 1.0e-12 else direction
			var render_direction: Vector2 = phase_direction
			if direction_fn.is_valid():
				var custom_direction: Vector2 = direction_fn.call(point)
				render_direction = custom_direction.normalized()
			propagation.depth_m[index] = 20.0 if valid else -1.0
			propagation.local_k[index] = propagation.k0_rad_m
			propagation.wavelength_m[index] = TAU / propagation.k0_rad_m
			propagation.phase_speed_mps[index] = 1.0
			propagation.group_velocity_mps[index] = 1.0
			propagation.shoaling_scale[index] = 1.0
			propagation.phase_offset_rad[index] = 0.0
			propagation.phase_rad[index] = phase
			propagation.phase_gradient_x[index] = gradient.x
			propagation.phase_gradient_z[index] = gradient.y
			propagation.local_direction_x[index] = phase_direction.x
			propagation.local_direction_z[index] = phase_direction.y
			propagation.render_phase_rad[index] = phase
			propagation.render_direction_x[index] = render_direction.x
			propagation.render_direction_z[index] = render_direction.y
			propagation.valid_mask[index] = 1 if valid else 0
			propagation.reached_mask[index] = 1 if valid else 0
			propagation.shadow_scale[index] = 1.0 if valid else 0.0
			propagation.cut_locus_mask[index] = 1 if valid and point.length() < 14.0 else 0
	return propagation


func _flat_phase(direction: Vector2, cell: float, width: int, height: int, k0: float) -> Callable:
	var origin := Vector2(-0.5 * float(width - 1) * cell, -0.5 * float(height - 1) * cell)
	var minimum_s := origin.dot(direction)
	return func(point: Vector2) -> Dictionary:
		var gradient := k0 * direction
		return {"phase": k0 * (point.dot(direction) - minimum_s), "gradient": gradient}


func _smooth_phase(direction: Vector2, k0: float) -> Callable:
	var normal := Vector2(-direction.y, direction.x)
	return func(point: Vector2) -> Dictionary:
		var transverse := point.dot(normal)
		var offset := 0.60 * sin(transverse / 12.0)
		var gradient := k0 * (direction + normal * (0.60 / 12.0) * cos(transverse / 12.0))
		return {"phase": k0 * point.dot(direction) + k0 * offset, "gradient": gradient}


func _bake(propagation, mode: int):
	var baker := WarpBakerScript.new()
	baker.propagation = propagation
	baker.mapping_mode = mode
	baker.backtrace_step_cells = 0.5
	return baker.bake()


func _validate_flat_identity_and_units() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var phase := _flat_phase(direction, 1.0, 65, 49, 0.5)
	var propagation = _make_propagation(65, 49, 1.0, direction, phase)
	var warp = _bake(propagation, WarpBakerScript.WarpMappingMode.PHASE_TRANSVERSE_IDENTITY)
	var max_identity := 0.0
	var max_phase := 0.0
	var max_r := 0.0
	for index in warp.width * warp.height:
		if warp.valid_mask[index] == 0:
			continue
		var x: int = index % warp.width
		var z: int = index / warp.width
		var world: Vector2 = warp.world_origin_xz + Vector2(float(x), float(z)) * warp.cell_size_m
		var deep := Vector2(warp.deep_x[index], warp.deep_z[index])
		max_identity = maxf(max_identity, deep.distance_to(world))
		max_phase = maxf(max_phase, absf(warp.k0_rad_m * (deep - warp.deep_origin_xz).dot(direction) - propagation.render_phase_rad[index]))
		max_r = maxf(max_r, absf(warp.r_deep[index] - world.dot(Vector2(-direction.y, direction.x))))
	print("PHASE_AUTH FLAT identity_max=%.9f phase_reconstruction_max=%.9f r_identity_max=%.9f" % [max_identity, max_phase, max_r])
	_check(max_identity < 1.0e-5, "flat: phase-transverse mapping is identity")
	_check(max_phase < 1.0e-5, "flat: phase reconstruction is exact")
	_check(max_r < 1.0e-5, "flat: r_deep follows world transverse coordinate")

	# Unit regression: with cell=2m and h=0.5, integration must advance 0.5
	# grid cells per step, not 1.0 cell due to an accidental metre conversion.
	var unit_propagation = _make_propagation(65, 33, 2.0, Vector2.RIGHT,
		_flat_phase(Vector2.RIGHT, 2.0, 65, 33, 0.5))
	var legacy_baker := WarpBakerScript.new()
	legacy_baker.propagation = unit_propagation
	legacy_baker.mapping_mode = WarpBakerScript.WarpMappingMode.LEGACY_CHARACTERISTIC_BACKTRACE
	legacy_baker.backtrace_step_cells = 0.5
	var legacy = legacy_baker.bake()
	var center: int = 16 * legacy.width + 32
	print("PHASE_AUTH UNITS legacy_center_steps=%d cell=2.0 step_cells=0.5" % legacy.backtrace_steps[center])
	_check(legacy.backtrace_steps[center] > 50, "backtrace: step_h remains in grid-cell units")


func _validate_smooth_ramp_authority() -> void:
	var direction := Vector2(0.8, 0.6).normalized()
	var propagation = _make_propagation(81, 61, 1.0, direction, _smooth_phase(direction, 0.5))
	var warp = _bake(propagation, WarpBakerScript.WarpMappingMode.PHASE_TRANSVERSE_IDENTITY)
	var direction_angles: Array[float] = []
	var max_phase := 0.0
	var max_jacobian_error := 0.0
	for z in range(1, warp.height - 1):
		for x in range(1, warp.width - 1):
			var index: int = z * warp.width + x
			if warp.valid_mask[index] == 0:
				continue
			var phase_rebuilt: float = warp.k0_rad_m * (Vector2(warp.deep_x[index], warp.deep_z[index]) - warp.deep_origin_xz).dot(direction)
			max_phase = maxf(max_phase, absf(phase_rebuilt - propagation.render_phase_rad[index]))
			var gx: float = (propagation.render_phase_rad[index + 1] - propagation.render_phase_rad[index - 1]) / (2.0 * warp.cell_size_m)
			var gz: float = (propagation.render_phase_rad[index + warp.width] - propagation.render_phase_rad[index - warp.width]) / (2.0 * warp.cell_size_m)
			var gradient := Vector2(gx, gz)
			var render_direction := Vector2(propagation.render_direction_x[index], propagation.render_direction_z[index]).normalized()
			if gradient.length_squared() > 1.0e-12:
				direction_angles.append(rad_to_deg(acos(clampf(gradient.normalized().dot(render_direction), -1.0, 1.0))))
			var normal := Vector2(-direction.y, direction.x)
			var expected_j00: float = direction.x * gx / warp.k0_rad_m + normal.x * normal.x
			var expected_j01: float = direction.x * gz / warp.k0_rad_m + normal.x * normal.y
			var expected_j10: float = direction.y * gx / warp.k0_rad_m + normal.y * normal.x
			var expected_j11: float = direction.y * gz / warp.k0_rad_m + normal.y * normal.y
			max_jacobian_error = maxf(max_jacobian_error, absf(warp.jacobian_j00[index] - expected_j00))
			max_jacobian_error = maxf(max_jacobian_error, absf(warp.jacobian_j01[index] - expected_j01))
			max_jacobian_error = maxf(max_jacobian_error, absf(warp.jacobian_j10[index] - expected_j10))
			max_jacobian_error = maxf(max_jacobian_error, absf(warp.jacobian_j11[index] - expected_j11))
	direction_angles.sort()
	var mean_angle := _mean(direction_angles)
	var p95_angle := _percentile(direction_angles, 0.95)
	var max_angle: float = direction_angles.back() if not direction_angles.is_empty() else 180.0
	print("PHASE_AUTH RAMP phase_reconstruction_max=%.9f direction_angle_mean=%.6f p95=%.6f max=%.6f jacobian_analytic_max=%.9f" % [max_phase, mean_angle, p95_angle, max_angle, max_jacobian_error])
	_check(max_phase < 1.0e-5, "ramp: render phase remains longitudinal authority")
	_check(mean_angle < 0.1 and p95_angle < 0.1 and max_angle < 0.2, "ramp: render direction agrees with phase gradient")
	_check(max_jacobian_error < 0.02, "ramp: finite-difference Jacobian matches analytic J")
	_print_jacobian_stats("RAMP new", warp)


func _validate_island_cut_locus() -> void:
	var direction := Vector2.RIGHT
	var phase := _flat_phase(direction, 1.0, 81, 81, 0.5)
	var island_mask := func(point: Vector2) -> bool: return point.length() > 10.0
	var detour_direction := func(point: Vector2) -> Vector2:
		var falloff := exp(-point.length_squared() / (2.0 * 11.0 * 11.0))
		var side := signf(point.y)
		return Vector2(1.0, -0.95 * side * falloff).normalized()
	var propagation = _make_propagation(81, 81, 1.0, direction, phase, island_mask, detour_direction)
	var legacy = _bake(propagation, WarpBakerScript.WarpMappingMode.LEGACY_CHARACTERISTIC_BACKTRACE)
	var current = _bake(propagation, WarpBakerScript.WarpMappingMode.PHASE_TRANSVERSE_IDENTITY)
	var legacy_continuity := _continuity_stats(legacy)
	var current_continuity := _continuity_stats(current)
	var legacy_valid := _valid_count(legacy)
	var current_valid := _valid_count(current)
	var center_z: int = current.height >> 1
	var legacy_line_valid := 0
	var current_line_valid := 0
	var legacy_line_r_jump := 0.0
	var current_line_r_jump := 0.0
	var last_legacy_r := 0.0
	var last_current_r := 0.0
	var have_legacy := false
	var have_current := false
	for x in range((current.width >> 1) + 12, current.width - 2):
		var index: int = center_z * current.width + x
		if legacy.valid_mask[index] != 0:
			legacy_line_valid += 1
			if have_legacy:
				legacy_line_r_jump = maxf(legacy_line_r_jump, absf(legacy.r_deep[index] - last_legacy_r))
			last_legacy_r = legacy.r_deep[index]
			have_legacy = true
		if current.valid_mask[index] != 0:
			current_line_valid += 1
			if have_current:
				current_line_r_jump = maxf(current_line_r_jump, absf(current.r_deep[index] - last_current_r))
			last_current_r = current.r_deep[index]
			have_current = true
	print("PHASE_AUTH ISLAND valid_area legacy=%d/%d new=%d/%d | all_neighbor_delta legacy=(%.4f,%.4f,%.4f) new=(%.4f,%.4f,%.4f) | center_line legacy_valid=%d new_valid=%d r_jump legacy=%.4f new=%.4f" % [legacy_valid, propagation.width * propagation.height, current_valid, propagation.width * propagation.height, legacy_continuity[0], legacy_continuity[1], legacy_continuity[2], current_continuity[0], current_continuity[1], current_continuity[2], legacy_line_valid, current_line_valid, legacy_line_r_jump, current_line_r_jump])
	_check(current_line_valid > 20, "island: phase-transverse mapping stays valid behind recovered water")
	_check(current_line_r_jump <= current.cell_size_m * 1.01, "island: transverse coordinate has no central scar")
	_check(legacy_valid <= current_valid, "island: legacy does not gain valid area over propagation masks")
	_print_jacobian_stats("ISLAND legacy", legacy)
	_print_jacobian_stats("ISLAND new", current)


func _validate_channel_and_multiple_rocks() -> void:
	var direction := Vector2.RIGHT
	var phase := _smooth_phase(direction, 0.5)
	var channel_mask := func(point: Vector2) -> bool: return absf(point.y) < 12.0
	var channel_prop = _make_propagation(97, 65, 1.0, direction, phase, channel_mask)
	var channel_warp = _bake(channel_prop, WarpBakerScript.WarpMappingMode.PHASE_TRANSVERSE_IDENTITY)
	print("PHASE_AUTH CHANNEL valid=%d/%d" % [_valid_count(channel_warp), channel_prop.width * channel_prop.height])
	_check(_valid_count(channel_warp) == _valid_count(channel_prop), "channel: warp validity exactly follows propagation masks")
	_check(_all_finite(channel_warp), "channel: mapping and Jacobian finite")

	var rocks_mask := func(point: Vector2) -> bool:
		return point.distance_to(Vector2(-18.0, 7.0)) > 4.0 and point.distance_to(Vector2(4.0, -8.0)) > 5.0 and point.distance_to(Vector2(22.0, 10.0)) > 3.0
	var rocks_prop = _make_propagation(97, 65, 1.0, direction, phase, rocks_mask)
	var rocks_warp = _bake(rocks_prop, WarpBakerScript.WarpMappingMode.PHASE_TRANSVERSE_IDENTITY)
	print("PHASE_AUTH ROCKS valid=%d/%d" % [_valid_count(rocks_warp), rocks_prop.width * rocks_prop.height])
	_check(_valid_count(rocks_warp) == _valid_count(rocks_prop), "rocks: warp validity exactly follows propagation masks")
	_check(_all_finite(rocks_warp), "rocks: mapping and Jacobian finite")
	_print_jacobian_stats("CHANNEL new", channel_warp)
	_print_jacobian_stats("ROCKS new", rocks_warp)


func _valid_count(warp) -> int:
	var count := 0
	for value in warp.valid_mask:
		count += int(value != 0)
	return count


func _valid_count_propagation(propagation) -> int:
	var count := 0
	for index in propagation.width * propagation.height:
		count += int(propagation.valid_mask[index] != 0 and propagation.reached_mask[index] != 0)
	return count


func _all_finite(warp) -> bool:
	for index in warp.width * warp.height:
		for value in [warp.deep_x[index], warp.deep_z[index], warp.jacobian_det[index], warp.r_deep[index]]:
			if not is_finite(float(value)):
				return false
	return true


func _continuity_stats(warp) -> Array[float]:
	var max_x := 0.0
	var max_z := 0.0
	var max_r := 0.0
	for z in warp.height:
		for x in warp.width:
			var index: int = z * warp.width + x
			if warp.valid_mask[index] == 0:
				continue
			if x + 1 < warp.width and warp.valid_mask[index + 1] != 0:
				max_x = maxf(max_x, absf(warp.deep_x[index + 1] - warp.deep_x[index]))
				max_r = maxf(max_r, absf(warp.r_deep[index + 1] - warp.r_deep[index]))
			if z + 1 < warp.height and warp.valid_mask[index + warp.width] != 0:
				max_z = maxf(max_z, absf(warp.deep_z[index + warp.width] - warp.deep_z[index]))
				max_r = maxf(max_r, absf(warp.r_deep[index + warp.width] - warp.r_deep[index]))
	return [max_x, max_z, max_r]


func _print_jacobian_stats(label: String, warp) -> void:
	var values: Array[float] = []
	var counts := [0, 0, 0, 0]
	for index in warp.width * warp.height:
		var class_id: int = warp.jacobian_class[index]
		counts[class_id] += 1
		if warp.valid_mask[index] != 0:
			values.append(warp.jacobian_det[index])
	var stats := _numeric_stats(values)
	var total := float(warp.width * warp.height)
	print("PHASE_AUTH J %s det[min=%.6f p01=%.6f mean=%.6f p99=%.6f max=%.6f] SAFE=%.2f%% NEAR_CAUSTIC=%.2f%% FOLDED=%.2f%% INVALID=%.2f%%" % [label, stats[0], stats[1], stats[2], stats[3], stats[4], 100.0 * float(counts[0]) / total, 100.0 * float(counts[1]) / total, 100.0 * float(counts[2]) / total, 100.0 * float(counts[3]) / total])


func _numeric_stats(values: Array[float]) -> Array[float]:
	if values.is_empty():
		return [0.0, 0.0, 0.0, 0.0, 0.0]
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	return [sorted[0], sorted[int(0.01 * float(sorted.size() - 1))], total / float(sorted.size()), sorted[int(0.99 * float(sorted.size() - 1))], sorted.back()]


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(floor(float(sorted.size() - 1) * fraction)), 0, sorted.size() - 1)]


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

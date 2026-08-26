extends SceneTree
## Fase 3B.1: validación cuantitativa del campo Eikonal bidimensional.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const DebugScript := preload("res://ocean_v3/coastal/coastal_eikonal_debug.gd")

var _failures := 0


func _initialize() -> void:
	_validate_flat_plane()
	_validate_oblique_snell()
	_validate_bank_and_determinism()
	_validate_island_shadow()
	_validate_small_rock_shadow()
	_validate_two_island_channel()
	_validate_render_field_data()
	_validate_convergence_quality()
	_validate_visibility_sweep()
	_validate_large_grid_scaling()
	_validate_eikonal_path_complexity()
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
	var max_render_angle_deg := 0.0
	var max_k_error := 0.0
	var max_shadow_error := 0.0
	for z in range(4, propagation.height - 4):
		for x in range(4, propagation.width - 4):
			var index: int = z * propagation.width + x
			var local_direction := Vector2(propagation.local_direction_x[index], propagation.local_direction_z[index])
			max_angle_deg = maxf(max_angle_deg, rad_to_deg(acos(clampf(local_direction.dot(direction), -1.0, 1.0))))
			var render_direction := Vector2(propagation.render_direction_x[index], propagation.render_direction_z[index])
			max_render_angle_deg = maxf(max_render_angle_deg, rad_to_deg(acos(clampf(render_direction.dot(direction), -1.0, 1.0))))
			var gradient_k := Vector2(propagation.phase_gradient_x[index], propagation.phase_gradient_z[index]).length()
			max_k_error = maxf(max_k_error, absf(gradient_k - propagation.local_k[index]))
			max_shadow_error = maxf(max_shadow_error, absf(propagation.shadow_scale[index] - 1.0))
	print("3B.1 FLAT max_angle_deg=%.6f max_render_angle_deg=%.6f max_k_error=%.8f max_shadow_error=%.8f residual=%.8f interior_residual=%.8f cycles=%d directional_sweeps=%d final_change=%.8f" % [max_angle_deg, max_render_angle_deg, max_k_error, max_shadow_error, propagation.eikonal_max_residual_rad_m, propagation.eikonal_interior_residual_rad_m, propagation.eikonal_cycles, propagation.eikonal_directional_sweeps, propagation.eikonal_final_max_change_s])
	_check(max_angle_deg < 0.25, "flat: dirección local coincide con incoming")
	_check(max_render_angle_deg < 0.25, "flat: render_direction coincide con incoming")
	_check(max_k_error < 1.0e-4, "flat: |grad(phi)| coincide con k")
	_check(max_shadow_error < 1.0e-6, "flat: shadow_scale neutral")
	for flat_direction in [Vector2.RIGHT, Vector2.LEFT, Vector2(1.0, 1.0).normalized(), Vector2(-1.0, 0.4).normalized()]:
		var flat = _bake(_make_data(37, 29, func(_x: int, _z: int) -> float: return 100.0), flat_direction)
		var flat_max_angle := 0.0
		var flat_shadow_error := 0.0
		for index in flat.width * flat.height:
			if flat.valid_mask[index] == 0 or flat.reached_mask[index] == 0:
				continue
			var local_direction := Vector2(flat.local_direction_x[index], flat.local_direction_z[index])
			flat_max_angle = maxf(flat_max_angle, rad_to_deg(acos(clampf(local_direction.dot(flat_direction), -1.0, 1.0))))
			flat_shadow_error = maxf(flat_shadow_error, absf(flat.shadow_scale[index] - 1.0))
		_check(flat_max_angle < 0.5 and flat_shadow_error < 1.0e-6, "flat: dirección %s conserva reached/dirección/shadow" % flat_direction)


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
	print("3B.1 BANK max_angle_deg=%.4f max_residual=%.6f reached=%d/%d cycles=%d directional_sweeps=%d final_change=%.8f" % [max_angle_deg, max_residual, reached, first.width * first.height, first.eikonal_cycles, first.eikonal_directional_sweeps, first.eikonal_final_max_change_s])
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
	var near_index: int = 40 * propagation.width + 66
	var mid_index: int = 40 * propagation.width + 86
	var far_index: int = 40 * propagation.width + 100
	var open_index: int = 20 * propagation.width + 76
	var side_index: int = 64 * propagation.width + 76
	var shadow_direction := Vector2(propagation.local_direction_x[shadow_index], propagation.local_direction_z[shadow_index])
	var max_raw_jump := _max_neighbor_angle_deg(propagation, false, 60, propagation.width - 1, 0, propagation.height - 1)
	var max_render_jump := _max_neighbor_angle_deg(propagation, true, 60, propagation.width - 1, 0, propagation.height - 1)
	print("3B.1 ISLAND invalid=%d shadow_reached=%d shadow_near=%.4f shadow_mid=%.4f shadow_far=%.4f shadow_dir=(%.4f,%.4f) open_scale=%.4f side=%d raw_jump_deg=%.4f render_jump_deg=%.4f interior_residual=%.8f cycles=%d directional_sweeps=%d final_change=%.8f" % [propagation.valid_mask[invalid_index], propagation.reached_mask[shadow_index], propagation.shadow_scale[near_index], propagation.shadow_scale[mid_index], propagation.shadow_scale[far_index], shadow_direction.x, shadow_direction.y, propagation.shadow_scale[open_index], propagation.reached_mask[side_index], max_raw_jump, max_render_jump, propagation.eikonal_interior_residual_rad_m, propagation.eikonal_cycles, propagation.eikonal_directional_sweeps, propagation.eikonal_final_max_change_s])
	_check(propagation.valid_mask[invalid_index] == 0, "island: tierra inválida")
	_check(propagation.reached_mask[shadow_index] != 0, "island: agua detrás permanece alcanzada")
	_check(propagation.shadow_scale[shadow_index] >= 0.15 and propagation.shadow_scale[shadow_index] < 0.999, "island: sombra suave detrás")
	_check(propagation.shadow_scale[near_index] < propagation.shadow_scale[mid_index] and propagation.shadow_scale[mid_index] < propagation.shadow_scale[far_index], "island: recuperación aumenta downstream")
	_check(propagation.shadow_scale[far_index] > propagation.shadow_scale[near_index] + 0.10, "island: sombra no permanece extruida")
	_check(propagation.shadow_scale[open_index] > 0.999, "island: agua abierta sin sombra")
	_check(shadow_direction.dot(Vector2.RIGHT) < 0.999, "island: dirección gira alrededor del obstáculo")
	_check(propagation.reached_mask[side_index] != 0, "island: agua lateral alcanzada")
	_check(max_render_jump < max_raw_jump * 0.95, "island: render_direction reduce cut locus claramente")
	_check(_raw_direction_matches_gradient(propagation), "island: local_direction raw no se modifica")


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
	var upper_near: int = 32 * propagation.width + 62
	var upper_far: int = 32 * propagation.width + 105
	var lower_near: int = 48 * propagation.width + 62
	var lower_far: int = 48 * propagation.width + 105
	print("3B.1 CHANNEL upper_reached=%d upper_scale=%.4f upper_near=%.4f upper_far=%.4f channel_reached=%d channel_scale=%.4f lower_reached=%d lower_scale=%.4f lower_near=%.4f lower_far=%.4f open_scale=%.4f cycles=%d directional_sweeps=%d final_change=%.8f" % [propagation.reached_mask[upper_lee], propagation.shadow_scale[upper_lee], propagation.shadow_scale[upper_near], propagation.shadow_scale[upper_far], propagation.reached_mask[channel], propagation.shadow_scale[channel], propagation.reached_mask[lower_lee], propagation.shadow_scale[lower_lee], propagation.shadow_scale[lower_near], propagation.shadow_scale[lower_far], propagation.shadow_scale[open], propagation.eikonal_cycles, propagation.eikonal_directional_sweeps, propagation.eikonal_final_max_change_s])
	_check(propagation.reached_mask[upper_lee] != 0 and propagation.reached_mask[lower_lee] != 0, "channel: ambos leewards alcanzados")
	_check(propagation.reached_mask[channel] != 0, "channel: paso entre islas alcanzado")
	_check(propagation.shadow_scale[channel] > propagation.shadow_scale[upper_lee] and propagation.shadow_scale[channel] > propagation.shadow_scale[lower_lee], "channel: canal conserva más luz que los leewards")
	_check(propagation.shadow_scale[open] > 0.999, "channel: agua abierta sin sombra")
	_check(propagation.shadow_scale[upper_near] < propagation.shadow_scale[upper_far] and propagation.shadow_scale[lower_near] < propagation.shadow_scale[lower_far], "channel: ambas sombras recuperan downstream")


func _validate_small_rock_shadow() -> void:
	var data = _make_data(121, 61, func(x: int, z: int) -> float:
		var dx := float(x - 40)
		var dz := float(z - 30)
		return -1.0 if dx * dx + dz * dz < 2.5 * 2.5 else 18.0)
	var propagation = _bake(data, Vector2.RIGHT)
	var near_index: int = 30 * propagation.width + 44
	var mid_index: int = 30 * propagation.width + 58
	var far_index: int = 30 * propagation.width + 100
	print("3B.1 SMALL_ROCK shadow_near=%.4f shadow_mid=%.4f shadow_far=%.4f" % [propagation.shadow_scale[near_index], propagation.shadow_scale[mid_index], propagation.shadow_scale[far_index]])
	_check(propagation.shadow_scale[near_index] < propagation.shadow_scale[mid_index] and propagation.shadow_scale[mid_index] < propagation.shadow_scale[far_index], "small rock: sombra recupera progresivamente")
	_check(propagation.shadow_scale[far_index] > 0.90, "small rock: estela cierra antes del borde")


func _validate_render_field_data() -> void:
	var propagation = _bake(_make_data(37, 29, func(_x: int, _z: int) -> float: return 18.0), Vector2(1.0, 0.4).normalized())
	var sample = propagation.sample_propagation(Vector2(18.0, 14.0))
	var open_water_mean_error := _mean_raw_render_angle_deg(propagation)
	print("3B.1 RENDER_FIELD open_water_mean_error_deg=%.8f" % open_water_mean_error)
	_check(propagation.has_render_direction() and propagation.render_direction_x.size() == propagation.width * propagation.height and propagation.render_direction_z.size() == propagation.width * propagation.height, "render data: arrays derivados asignados")
	_check(open_water_mean_error < 0.001, "render data: agua abierta conserva dirección")
	_check(propagation.approximate_memory_bytes() == propagation.width * propagation.height * 62, "render data: accounting incluye 8 B/nodo adicional")
	_check(sample.render_direction_xz.length_squared() > 0.99, "render data: sample devuelve render_direction")
	var legacy_x: PackedFloat32Array = propagation.render_direction_x
	var legacy_z: PackedFloat32Array = propagation.render_direction_z
	propagation.render_direction_x = PackedFloat32Array()
	propagation.render_direction_z = PackedFloat32Array()
	var legacy_sample = propagation.sample_propagation(Vector2(18.0, 14.0))
	_check(legacy_sample.render_direction_xz == legacy_sample.local_direction_xz, "render data: recurso legacy hace fallback a raw")
	propagation.render_direction_x = legacy_x
	propagation.render_direction_z = legacy_z


func _validate_visibility_sweep() -> void:
	var data = _make_data(61, 41, func(x: int, z: int) -> float:
		var dx := float(x - 30)
		var dz := float(z - 20)
		return -1.0 if dx * dx + dz * dz < 8.0 * 8.0 else 18.0)
	var baker = EikonalBakerScript.new()
	var cardinal_mismatch := _visibility_mismatch(baker, data, Vector2.RIGHT)
	var diagonal_mismatch := _visibility_mismatch(baker, data, Vector2(1.0, 0.65).normalized())
	print("3B.1 VISIBILITY cardinal_mismatch=%d diagonal_mismatch=%d" % [cardinal_mismatch, diagonal_mismatch])
	_check(cardinal_mismatch == 0, "visibility: sweep cardinal equivalente a referencia")
	_check(diagonal_mismatch <= 160, "visibility: sweep diagonal sólo difiere en silueta local")
	var propagation = _bake(data, Vector2.RIGHT)
	var visibility: PackedFloat32Array = baker._build_incident_visibility_field(propagation, Vector2.RIGHT)
	var lee_index: int = 20 * propagation.width + 45
	var open_index: int = 8 * propagation.width + 45
	_check(visibility[lee_index] < 0.01 and visibility[open_index] > 0.99, "visibility: isla bloquea lee pero conserva agua abierta")


func _validate_convergence_quality() -> void:
	var data = _make_data(61, 41, func(x: int, z: int) -> float:
		var dx := float(x - 30)
		var dz := float(z - 20)
		return -1.0 if dx * dx + dz * dz < 7.0 * 7.0 else 18.0)
	var direction := Vector2(1.0, 0.65).normalized()
	var fast = _bake_with_settings(data, direction, 16, 1.0e-4)
	var strict = _bake_with_settings(data, direction, 96, 1.0e-6)
	var max_phase_error := 0.0
	var max_direction_error_deg := 0.0
	var max_shadow_error := 0.0
	var reached_mismatch := 0
	for index in fast.width * fast.height:
		if fast.valid_mask[index] == 0:
			continue
		if fast.reached_mask[index] != strict.reached_mask[index]:
			reached_mismatch += 1
		if fast.reached_mask[index] == 0 or strict.reached_mask[index] == 0:
			continue
		max_phase_error = maxf(max_phase_error, absf(fast.phase_rad[index] - strict.phase_rad[index]))
		var fast_direction := Vector2(fast.local_direction_x[index], fast.local_direction_z[index])
		var strict_direction := Vector2(strict.local_direction_x[index], strict.local_direction_z[index])
		max_direction_error_deg = maxf(max_direction_error_deg, rad_to_deg(acos(clampf(fast_direction.dot(strict_direction), -1.0, 1.0))))
		max_shadow_error = maxf(max_shadow_error, absf(fast.shadow_scale[index] - strict.shadow_scale[index]))
	print("3B.1 STRICT_COMPARE fast_cycles=%d strict_cycles=%d phase_error=%.8f direction_error_deg=%.6f shadow_error=%.8f reached_mismatch=%d" % [fast.eikonal_cycles, strict.eikonal_cycles, max_phase_error, max_direction_error_deg, max_shadow_error, reached_mismatch])
	_check(reached_mismatch == 0, "quality: fast/strict conserva reached")
	_check(max_phase_error < 0.05 and max_direction_error_deg < 2.0 and max_shadow_error < 0.10, "quality: error frente a solve estricto acotado")


func _visibility_mismatch(baker, data, direction: Vector2) -> int:
	var propagation = _bake(data, direction)
	var visibility: PackedFloat32Array = baker._build_incident_visibility_field(propagation, direction)
	var mismatch := 0
	for index in propagation.width * propagation.height:
		if propagation.valid_mask[index] == 0:
			continue
		var x: int = index % propagation.width
		var z: int = index / propagation.width
		var expected := 1.0 if baker._has_incident_line_of_sight_reference(propagation, x, z, direction) else 0.0
		if absf(visibility[index] - expected) > 0.25:
			mismatch += 1
	return mismatch


func _validate_large_grid_scaling() -> void:
	for resolution in [512, 1024]:
		var start := Time.get_ticks_usec()
		var baker = EikonalBakerScript.new()
		baker.bathymetry_data = _make_data(resolution, resolution, func(_x: int, _z: int) -> float: return 18.0)
		baker.incoming_direction_xz = Vector2.RIGHT
		baker.reference_wavelength_m = 16.0
		baker.min_valid_depth_m = 0.25
		var propagation = baker.bake()
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		if propagation == null:
			_check(false, "large: grid %dx%d completa con data válida" % [resolution, resolution])
			continue
		var reached := 0
		for index in propagation.width * propagation.height:
			if propagation.reached_mask[index] != 0:
				reached += 1
		var debug := DebugScript.new()
		get_root().add_child(debug)
		var debug_start := Time.get_ticks_usec()
		debug.data = propagation
		var debug_ms := float(Time.get_ticks_usec() - debug_start) / 1000.0
		var plane := debug.mesh as PlaneMesh
		print("3B.1 LARGE grid=%dx%d elapsed=%.3f ms base=%.3f sweep=%.3f phase=%.3f shadow=%.3f shadow_geometric=%.3f shadow_recovery=%.3f direction_smoothing=%.3f debug_texture=%.3f triangles=%d cycles=%d directional_sweeps=%d final_change=%.8f reached=%d" % [propagation.width, propagation.height, elapsed_ms, baker.last_base_metrics_ms, baker.last_eikonal_sweep_ms, baker.last_phase_populate_ms, baker.last_shadow_ms, baker.last_shadow_geometric_ms, baker.last_shadow_recovery_ms, baker.last_direction_smoothing_ms, debug_ms, debug.last_debug_triangle_count, propagation.eikonal_cycles, propagation.eikonal_directional_sweeps, propagation.eikonal_final_max_change_s, reached])
		_check(propagation.is_valid(), "large: grid %dx%d completa con data válida" % [resolution, resolution])
		_check(reached == resolution * resolution, "large: flat water %dx%d reached completo" % [resolution, resolution])
		_check(plane != null and debug.last_debug_triangle_count == 2 and plane.size == Vector2(resolution - 1, resolution - 1), "large: debug %dx%d es un plano de dos triángulos" % [resolution, resolution])
		debug.free()


func _validate_eikonal_path_complexity() -> void:
	var source := FileAccess.get_file_as_string("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
	_check(not source.contains("Array[Dictionary]") and not source.contains("order.sort_custom") and not source.contains("_has_incident_line_of_sight(output") and source.contains("_recover_shadow_energy") and source.contains("_build_render_direction"), "complexity: campos derivados no conservan sort/raymarch patológicos")


func _max_neighbor_angle_deg(data, use_render: bool, min_x: int, max_x: int, min_z: int, max_z: int) -> float:
	var maximum := 0.0
	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var index: int = z * data.width + x
			if data.valid_mask[index] == 0 or data.reached_mask[index] == 0:
				continue
			var current := Vector2(data.render_direction_x[index], data.render_direction_z[index]) if use_render else Vector2(data.local_direction_x[index], data.local_direction_z[index])
			if x < max_x:
				var right_index: int = index + 1
				if data.valid_mask[right_index] != 0 and data.reached_mask[right_index] != 0:
					var right := Vector2(data.render_direction_x[right_index], data.render_direction_z[right_index]) if use_render else Vector2(data.local_direction_x[right_index], data.local_direction_z[right_index])
					maximum = maxf(maximum, rad_to_deg(acos(clampf(current.dot(right), -1.0, 1.0))))
			if z < max_z:
				var down_index: int = index + data.width
				if data.valid_mask[down_index] != 0 and data.reached_mask[down_index] != 0:
					var down := Vector2(data.render_direction_x[down_index], data.render_direction_z[down_index]) if use_render else Vector2(data.local_direction_x[down_index], data.local_direction_z[down_index])
					maximum = maxf(maximum, rad_to_deg(acos(clampf(current.dot(down), -1.0, 1.0))))
	return maximum


func _raw_direction_matches_gradient(data) -> bool:
	for index in data.width * data.height:
		if data.valid_mask[index] == 0 or data.reached_mask[index] == 0:
			continue
		var gradient := Vector2(data.phase_gradient_x[index], data.phase_gradient_z[index]).normalized()
		var raw := Vector2(data.local_direction_x[index], data.local_direction_z[index])
		if raw.distance_to(gradient) > 1.0e-6:
			return false
	return true


func _mean_raw_render_angle_deg(data) -> float:
	var total := 0.0
	var count := 0
	for index in data.width * data.height:
		if data.valid_mask[index] == 0 or data.reached_mask[index] == 0:
			continue
		var raw := Vector2(data.local_direction_x[index], data.local_direction_z[index])
		var render := Vector2(data.render_direction_x[index], data.render_direction_z[index])
		total += rad_to_deg(acos(clampf(raw.dot(render), -1.0, 1.0)))
		count += 1
	return total / float(count) if count > 0 else 0.0


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
	return _bake_with_settings(data, direction, 16, 1.0e-4)


func _bake_with_settings(data, direction: Vector2, max_cycles: int, tolerance: float):
	var baker = EikonalBakerScript.new()
	baker.bathymetry_data = data
	baker.incoming_direction_xz = direction
	baker.reference_wavelength_m = 16.0
	baker.min_valid_depth_m = 0.25
	baker.max_sweep_cycles = max_cycles
	baker.convergence_tolerance_s = tolerance
	return baker.bake()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

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
	_validate_cut_locus()
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
	_check(propagation.approximate_memory_bytes() == propagation.width * propagation.height * 63, "render data: accounting incluye render_direction y máscara cut locus")
	_check(sample.render_direction_xz.length_squared() > 0.99, "render data: sample devuelve render_direction")
	var legacy_x: PackedFloat32Array = propagation.render_direction_x
	var legacy_z: PackedFloat32Array = propagation.render_direction_z
	propagation.render_direction_x = PackedFloat32Array()
	propagation.render_direction_z = PackedFloat32Array()
	var legacy_sample = propagation.sample_propagation(Vector2(18.0, 14.0))
	_check(legacy_sample.render_direction_xz == legacy_sample.local_direction_xz, "render data: recurso legacy hace fallback a raw")
	propagation.render_direction_x = legacy_x
	propagation.render_direction_z = legacy_z


func _validate_cut_locus() -> void:
	var bridge_baker = EikonalBakerScript.new()
	var symmetric_samples := PackedVector2Array()
	symmetric_samples.append(Vector2(1.0, 1.0).normalized())
	symmetric_samples.append(Vector2(1.0, -1.0).normalized())
	var symmetric_bridge: Vector2 = bridge_baker._resolve_core_bridge_direction(symmetric_samples, Vector2.RIGHT)
	var symmetric_angle := rad_to_deg(atan2(symmetric_bridge.y, symmetric_bridge.x))
	var cancellation_samples := PackedVector2Array()
	cancellation_samples.append(Vector2.UP)
	cancellation_samples.append(Vector2.DOWN)
	var cancellation_bridge: Vector2 = bridge_baker._resolve_core_bridge_direction(cancellation_samples, Vector2.RIGHT)
	var asymmetric_samples := PackedVector2Array()
	asymmetric_samples.append(Vector2(cos(deg_to_rad(20.0)), sin(deg_to_rad(20.0))))
	asymmetric_samples.append(Vector2(cos(deg_to_rad(-50.0)), sin(deg_to_rad(-50.0))))
	var asymmetric_bridge: Vector2 = bridge_baker._resolve_core_bridge_direction(asymmetric_samples, Vector2.RIGHT)
	var asymmetric_angle := rad_to_deg(atan2(asymmetric_bridge.y, asymmetric_bridge.x))
	print("3B.1 CUT_BRIDGE symmetric_angle=%.4f asymmetric_angle=%.4f" % [symmetric_angle, asymmetric_angle])
	_check(absf(symmetric_angle) < 5.0 and symmetric_bridge.dot(Vector2.RIGHT) > -0.25, "cut locus: symmetric branches bridge toward incoming direction")
	_check(cancellation_bridge == Vector2.RIGHT, "cut locus: vector cancellation falls back to incoming direction")
	_check(asymmetric_angle > -50.0 and asymmetric_angle < 20.0 and asymmetric_bridge.dot(Vector2.RIGHT) > -0.25, "cut locus: asymmetric branches bridge to intermediate forward direction")

	var flat = _bake(_make_data(81, 61, func(_x: int, _z: int) -> float: return 18.0), Vector2.RIGHT)
	print("3B.1 CUT_FLAT core=%d band=%d" % [_cut_core_count(flat), _cut_band_count(flat)])
	_check(_cut_core_count(flat) == 0, "cut locus: flat water has no core")
	_check(_cut_band_count(flat) == 0, "cut locus: flat water has no blend band")

	var bank_data = _make_data(129, 97, func(x: int, z: int) -> float:
		return lerpf(18.0, 8.0, float(z) / 96.0)
	)
	var bank = _bake(bank_data, Vector2.RIGHT)
	var bank_water := _water_count(bank)
	var bank_band_percent := 100.0 * float(_cut_band_count(bank)) / float(maxi(bank_water, 1))
	var bank_direction_angle := _max_direction_angle_deg(bank, Vector2.RIGHT)
	print("3B.1 CUT_BANK water=%d core=%d band=%d percent=%.4f direction_angle=%.4f" % [bank_water, _cut_core_count(bank), _cut_band_count(bank), bank_band_percent, bank_direction_angle])
	_check(bank_direction_angle > 0.1 and bank_band_percent < 1.0, "cut locus: smooth refraction remains localized")

	var island_data = _make_data(101, 81, func(x: int, z: int) -> float:
		var dx := float(x - 50)
		var dz := float(z - 40)
		return -1.0 if dx * dx + dz * dz < 14.0 * 14.0 else 18.0)
	var island_pre = _bake_with_cut_locus(island_data, Vector2.RIGHT, false)
	var island_final = _bake(island_data, Vector2.RIGHT)
	var island_bridge_core_mask: PackedByteArray = bridge_baker._detect_cut_locus_core(island_pre)
	var island_bridge_fields: Array = bridge_baker._build_core_bridge_fields(island_pre, island_bridge_core_mask, Vector2.RIGHT)
	var island_bridge_angle := 0.0
	var island_bridge_samples := 0
	var island_core_bridge_error := 0.0
	for index in island_bridge_core_mask.size():
		if island_bridge_core_mask[index] == 0:
			continue
		var bridge_direction := Vector2((island_bridge_fields[0] as PackedFloat32Array)[index], (island_bridge_fields[1] as PackedFloat32Array)[index]).normalized()
		island_bridge_angle = rad_to_deg(atan2(bridge_direction.y, bridge_direction.x))
		var final_core_direction := Vector2(island_final.render_direction_x[index], island_final.render_direction_z[index]).normalized()
		island_core_bridge_error = rad_to_deg(acos(clampf(final_core_direction.dot(bridge_direction), -1.0, 1.0)))
		island_bridge_samples += 1
		break
	var island_raw_jump := _max_neighbor_angle_deg(island_final, false, 60, island_final.width - 1, 0, island_final.height - 1)
	var island_pre_jump := _max_neighbor_angle_deg(island_pre, true, 60, island_pre.width - 1, 0, island_pre.height - 1)
	var island_final_jump := _max_neighbor_angle_deg(island_final, true, 60, island_final.width - 1, 0, island_final.height - 1)
	var island_water := _water_count(island_final)
	var island_modified_percent := 100.0 * float(_cut_band_count(island_final)) / float(maxi(island_water, 1))
	var island_outside_error := _mean_render_delta_outside_cut(island_pre, island_final)
	print("3B.1 CUT_ISLAND raw_jump=%.4f pre_cut=%.4f final=%.4f core=%d band=%d modified_percent=%.4f outside_error_deg=%.8f bridge_angle=%.4f bridge_core=%d core_bridge_error=%.8f" % [island_raw_jump, island_pre_jump, island_final_jump, _cut_core_count(island_final), _cut_band_count(island_final), island_modified_percent, island_outside_error, island_bridge_angle, island_bridge_samples, island_core_bridge_error])
	_check(_cut_core_count(island_final) > 0, "cut locus: single island detects reconvergence")
	_check(island_final_jump < island_pre_jump, "cut locus: localized blend reduces the pre-cut jump")
	_check(island_final_jump < 45.0, "cut locus: single-island final jump is visually continuous")
	_check(island_modified_percent < 25.0, "cut locus: single-island blend remains localized")
	_check(island_outside_error < 0.01, "cut locus: outside band preserves adaptive direction")
	_check(island_final.local_direction_x == island_pre.local_direction_x and island_final.local_direction_z == island_pre.local_direction_z, "cut locus: core bridge leaves RAW direction unchanged")
	_check(island_final.phase_rad == island_pre.phase_rad and island_final.phase_offset_rad == island_pre.phase_offset_rad and island_final.phase_gradient_x == island_pre.phase_gradient_x and island_final.phase_gradient_z == island_pre.phase_gradient_z, "cut locus: core bridge leaves phase fields unchanged")
	_check(island_final.reached_mask == island_pre.reached_mask, "cut locus: core bridge leaves reached unchanged")
	_check(island_final.shadow_scale == island_pre.shadow_scale, "cut locus: core bridge leaves shadow unchanged")
	_check(island_core_bridge_error < 0.001, "cut locus: CORE remains fixed to its component bridge")

	var island_32 = _bake_with_cut_locus_settings(island_data, Vector2.RIGHT, 32.0, 24, 0.65)
	var island_32_jump := _max_neighbor_angle_deg(island_32, true, 60, island_32.width - 1, 0, island_32.height - 1)
	print("3B.1 CUT_ISLAND_32 final=%.4f core=%d band=%d modified_percent=%.4f" % [island_32_jump, _cut_core_count(island_32), _cut_band_count(island_32), 100.0 * float(_cut_band_count(island_32)) / float(maxi(_water_count(island_32), 1))])
	_check(island_32_jump < island_pre_jump, "cut locus: radius 32 also reduces the single-island seam")

	var profile_offsets := [-20, -15, -10, -5, 0, 5, 10, 15, 20]
	var profile_text := ""
	var profile_max_step := 0.0
	var previous_angle := 0.0
	var has_previous := false
	for offset in profile_offsets:
		var profile_index: int = (40 + offset) * island_final.width + 86
		var profile_direction := Vector2(island_final.render_direction_x[profile_index], island_final.render_direction_z[profile_index]).normalized()
		var profile_angle := rad_to_deg(atan2(profile_direction.y, profile_direction.x))
		profile_text += "%d:%.3f " % [offset, profile_angle]
		if has_previous:
			profile_max_step = maxf(profile_max_step, absf(profile_angle - previous_angle))
		previous_angle = profile_angle
		has_previous = true
	print("3B.1 CUT_PROFILE x=86 angles=%s max_step=%.4f" % [profile_text, profile_max_step])
	_check(profile_max_step < 45.0, "cut locus: transverse profile has no brutal direction jump")

	var channel_data = _make_data(121, 81, func(x: int, z: int) -> float:
		var upper_dx := float(x - 50)
		var upper_dz := float(z - 28)
		var lower_dx := float(x - 50)
		var lower_dz := float(z - 52)
		return -1.0 if upper_dx * upper_dx + upper_dz * upper_dz < 10.0 * 10.0 or lower_dx * lower_dx + lower_dz * lower_dz < 10.0 * 10.0 else 18.0)
	var channel_pre = _bake_with_cut_locus(channel_data, Vector2.RIGHT, false)
	var channel_final = _bake(channel_data, Vector2.RIGHT)
	var channel_index: int = 40 * channel_final.width + 78
	var channel_cut_respects_land := true
	for index in channel_final.width * channel_final.height:
		if channel_final.cut_locus_mask[index] != 0 and channel_final.valid_mask[index] == 0:
			channel_cut_respects_land = false
	print("3B.1 CUT_CHANNEL core=%d band=%d channel_reached=%d channel_shadow=%.4f" % [_cut_core_count(channel_final), _cut_band_count(channel_final), channel_final.reached_mask[channel_index], channel_final.shadow_scale[channel_index]])
	_check(channel_final.reached_mask[channel_index] != 0, "cut locus: channel remains reached")
	_check(channel_final.shadow_scale == channel_pre.shadow_scale, "cut locus: channel shadow unchanged")
	_check(channel_final.local_direction_x == channel_pre.local_direction_x and channel_final.local_direction_z == channel_pre.local_direction_z, "cut locus: channel raw direction unchanged")
	_check(channel_final.phase_rad == channel_pre.phase_rad and channel_final.reached_mask == channel_pre.reached_mask, "cut locus: channel solve fields unchanged")
	_check(channel_cut_respects_land, "cut locus: band never crosses LAND")

	var paradise_data = _make_data(161, 121, func(x: int, z: int) -> float:
		var dx := float(x - 80)
		var dz := float(z - 60)
		var body := dx * dx + dz * dz < 22.0 * 22.0
		var notch := dx < -8.0 and absf(dz) < 7.0
		return -1.0 if body and not notch else 18.0)
	var paradise_pre = _bake_with_cut_locus(paradise_data, Vector2.RIGHT, false)
	var paradise_final = _bake(paradise_data, Vector2.RIGHT)
	var paradise_pre_jump := _max_neighbor_angle_deg(paradise_pre, true, 100, 145, 15, paradise_pre.height - 16)
	var paradise_final_jump := _max_neighbor_angle_deg(paradise_final, true, 100, 145, 15, paradise_final.height - 16)
	print("3B.1 CUT_PARADISE_LIKE pre_cut=%.4f final=%.4f core=%d band=%d" % [paradise_pre_jump, paradise_final_jump, _cut_core_count(paradise_final), _cut_band_count(paradise_final)])
	_check(_cut_core_count(paradise_final) > 0 and paradise_final_jump < paradise_pre_jump, "cut locus: paradise-like reconvergence seam reduced")


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
		print("3B.1 LARGE grid=%dx%d elapsed=%.3f ms base=%.3f sweep=%.3f phase=%.3f shadow=%.3f shadow_geometric=%.3f shadow_recovery=%.3f direction_smoothing=%.3f cut_detection=%.3f cut_band=%.3f core_bridge=%.3f cut_blend=%.3f cut_core=%d cut_band_cells=%d debug_texture=%.3f triangles=%d cycles=%d directional_sweeps=%d final_change=%.8f reached=%d" % [propagation.width, propagation.height, elapsed_ms, baker.last_base_metrics_ms, baker.last_eikonal_sweep_ms, baker.last_phase_populate_ms, baker.last_shadow_ms, baker.last_shadow_geometric_ms, baker.last_shadow_recovery_ms, baker.last_direction_smoothing_ms, baker.last_cut_locus_detection_ms, baker.last_cut_locus_band_ms, baker.last_cut_locus_core_bridge_ms, baker.last_cut_locus_blend_ms, baker.last_cut_locus_core_count, baker.last_cut_locus_band_count, debug_ms, debug.last_debug_triangle_count, propagation.eikonal_cycles, propagation.eikonal_directional_sweeps, propagation.eikonal_final_max_change_s, reached])
		_check(propagation.is_valid(), "large: grid %dx%d completa con data válida" % [resolution, resolution])
		_check(reached == resolution * resolution, "large: flat water %dx%d reached completo" % [resolution, resolution])
		_check(plane != null and debug.last_debug_triangle_count == 2 and plane.size == Vector2(resolution - 1, resolution - 1), "large: debug %dx%d es un plano de dos triángulos" % [resolution, resolution])
		debug.free()


func _validate_eikonal_path_complexity() -> void:
	var source := FileAccess.get_file_as_string("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
	_check(not source.contains("Array[Dictionary]") and not source.contains("order.sort_custom") and not source.contains("_has_incident_line_of_sight(output") and source.contains("_recover_shadow_energy") and source.contains("_build_render_direction") and source.contains("_detect_cut_locus_core") and source.contains("_build_core_bridge_fields") and source.contains("_resolve_core_bridge_direction") and source.contains("_apply_cut_locus_blend"), "complexity: campos derivados no conservan sort/raymarch patológicos")


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


func _max_direction_angle_deg(data, incoming: Vector2) -> float:
	var maximum := 0.0
	for index in data.width * data.height:
		if data.valid_mask[index] == 0 or data.reached_mask[index] == 0:
			continue
		var direction := Vector2(data.local_direction_x[index], data.local_direction_z[index])
		maximum = maxf(maximum, rad_to_deg(acos(clampf(direction.dot(incoming), -1.0, 1.0))))
	return maximum


func _cut_core_count(data) -> int:
	var count := 0
	if not data.has_cut_locus_mask():
		return count
	for value in data.cut_locus_mask:
		if value >= 2:
			count += 1
	return count


func _cut_band_count(data) -> int:
	var count := 0
	if not data.has_cut_locus_mask():
		return count
	for value in data.cut_locus_mask:
		if value != 0:
			count += 1
	return count


func _water_count(data) -> int:
	var count := 0
	for index in data.width * data.height:
		if data.valid_mask[index] != 0 and data.reached_mask[index] != 0:
			count += 1
	return count


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


func _mean_render_delta_outside_cut(before, after) -> float:
	var total := 0.0
	var count := 0
	for index in after.width * after.height:
		if after.valid_mask[index] == 0 or after.reached_mask[index] == 0 or after.cut_locus_mask[index] != 0:
			continue
		var first := Vector2(before.render_direction_x[index], before.render_direction_z[index])
		var second := Vector2(after.render_direction_x[index], after.render_direction_z[index])
		total += rad_to_deg(acos(clampf(first.dot(second), -1.0, 1.0)))
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
	return _bake_with_options(data, direction, max_cycles, tolerance, true)


func _bake_with_cut_locus(data, direction: Vector2, enabled: bool):
	return _bake_with_options(data, direction, 16, 1.0e-4, enabled)


func _bake_with_cut_locus_settings(data, direction: Vector2, radius_m: float, passes: int, strength: float):
	var baker = EikonalBakerScript.new()
	baker.bathymetry_data = data
	baker.incoming_direction_xz = direction
	baker.reference_wavelength_m = 16.0
	baker.min_valid_depth_m = 0.25
	baker.max_sweep_cycles = 16
	baker.convergence_tolerance_s = 1.0e-4
	baker.cut_locus_enabled = true
	baker.cut_locus_blend_radius_m = radius_m
	baker.cut_locus_blend_passes = passes
	baker.cut_locus_blend_strength = strength
	return baker.bake()


func _bake_with_options(data, direction: Vector2, max_cycles: int, tolerance: float, cut_enabled: bool):
	var baker = EikonalBakerScript.new()
	baker.bathymetry_data = data
	baker.incoming_direction_xz = direction
	baker.reference_wavelength_m = 16.0
	baker.min_valid_depth_m = 0.25
	baker.max_sweep_cycles = max_cycles
	baker.convergence_tolerance_s = tolerance
	baker.cut_locus_enabled = cut_enabled
	return baker.bake()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

class_name CoastalEikonalBaker
extends RefCounted
## Fase 3B.1: Fast Sweeping offline de T, con |∇T|=1/c_phase(h).
## La fase de diagnóstico es phi=omega*T; no modifica H0 ni el FFT.

const StraightBakerScript := preload("res://ocean_v3/coastal/coastal_propagation_baker.gd")

var bathymetry_data: Resource
var incoming_direction_xz := Vector2.RIGHT
var reference_wavelength_m := 16.0
var gravity_mps2 := 9.81
var min_valid_depth_m := 0.25
var max_sweeps := 96
var convergence_tolerance_s := 1.0e-6
var shadow_min_scale := 0.15
var shadow_occlusion_entry_scale := 0.70
var shadow_detour_length_m := 32.0
var shadow_smoothing_passes := 2


func bake():
	var direction := incoming_direction_xz.normalized()
	if bathymetry_data == null or not bathymetry_data.is_valid() or direction.length_squared() <= 1.0e-8:
		push_error("CoastalEikonalBaker requiere BathymetryData y dirección válidos.")
		return null
	# Reutiliza exactamente la dispersión, Cg y shoaling de 3B. Sólo sustituye
	# el campo de fase longitudinal por un solve eikonal bidimensional.
	var straight = StraightBakerScript.new()
	straight.bathymetry_data = bathymetry_data
	straight.incoming_direction_xz = direction
	straight.reference_wavelength_m = reference_wavelength_m
	straight.gravity_mps2 = gravity_mps2
	straight.min_valid_depth_m = min_valid_depth_m
	var output = straight.bake()
	if output == null:
		return null
	output.propagation_kind = 1
	var travel_time := _initialize_travel_time(output, direction)
	var fixed := _build_upstream_boundary(output, travel_time, direction)
	_sweep_travel_time(output, travel_time, fixed)
	_populate_phase_fields(output, travel_time, direction)
	_build_shadow_scale(output, travel_time, fixed, direction)
	return output


func _initialize_travel_time(output, _direction: Vector2) -> PackedFloat32Array:
	var travel_time := PackedFloat32Array()
	travel_time.resize(output.width * output.height)
	for index in travel_time.size():
		travel_time[index] = INF
	return travel_time


func _build_upstream_boundary(output, travel_time: PackedFloat32Array, direction: Vector2) -> PackedByteArray:
	var fixed := PackedByteArray()
	fixed.resize(output.width * output.height)
	var minimum_s := _minimum_projection(output, direction)
	var deep_phase_speed: float = output.omega_ref_rad_s / output.k0_rad_m
	for z in output.height:
		for x in output.width:
			var index: int = z * output.width + x
			if output.valid_mask[index] == 0 or not _is_upstream_boundary(output, x, z, direction):
				continue
			var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
			travel_time[index] = maxf(0.0, (point.dot(direction) - minimum_s) / deep_phase_speed)
			fixed[index] = 1
	return fixed


func _is_upstream_boundary(output, x: int, z: int, direction: Vector2) -> bool:
	var previous := Vector2(float(x), float(z)) - direction
	return previous.x < 0.0 or previous.y < 0.0 or previous.x > float(output.width - 1) or previous.y > float(output.height - 1)


func _sweep_travel_time(output, travel_time: PackedFloat32Array, fixed: PackedByteArray) -> void:
	var sweep_count := 0
	for _iteration in max_sweeps:
		var max_change := 0.0
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				max_change = maxf(max_change, _sweep_once(output, travel_time, fixed, sx, sz))
		sweep_count += 4
		if max_change <= convergence_tolerance_s:
			break
	output.eikonal_sweeps = sweep_count


func _sweep_once(output, travel_time: PackedFloat32Array, fixed: PackedByteArray, sx: int, sz: int) -> float:
	var maximum_change := 0.0
	var x_start: int = 0 if sx > 0 else output.width - 1
	var z_start: int = 0 if sz > 0 else output.height - 1
	for zi in output.height:
		var z: int = z_start + zi * sz
		for xi in output.width:
			var x: int = x_start + xi * sx
			var index: int = z * output.width + x
			if output.valid_mask[index] == 0 or fixed[index] != 0:
				continue
			var candidate := _godunov_update(output, travel_time, x, z)
			if candidate >= INF * 0.5 or candidate >= travel_time[index]:
				continue
			if travel_time[index] < INF * 0.5:
				maximum_change = maxf(maximum_change, travel_time[index] - candidate)
			travel_time[index] = candidate
	return maximum_change


func _godunov_update(output, travel_time: PackedFloat32Array, x: int, z: int) -> float:
	var a := minf(_travel_at(output, travel_time, x - 1, z), _travel_at(output, travel_time, x + 1, z))
	var b := minf(_travel_at(output, travel_time, x, z - 1), _travel_at(output, travel_time, x, z + 1))
	var slowness: float = 1.0 / maxf(output.phase_speed_mps[z * output.width + x], 1.0e-6)
	var step: float = slowness * output.cell_size_m
	if a >= INF * 0.5:
		return b + step if b < INF * 0.5 else INF
	if b >= INF * 0.5:
		return a + step
	if absf(a - b) >= step:
		return minf(a, b) + step
	return 0.5 * (a + b + sqrt(maxf(0.0, 2.0 * step * step - (a - b) * (a - b))))


func _travel_at(output, travel_time: PackedFloat32Array, x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= output.width or z >= output.height:
		return INF
	var index: int = z * output.width + x
	return travel_time[index] if output.valid_mask[index] != 0 else INF


func _populate_phase_fields(output, travel_time: PackedFloat32Array, direction: Vector2) -> void:
	var minimum_s := _minimum_projection(output, direction)
	var max_residual := 0.0
	for z in output.height:
		for x in output.width:
			var index: int = z * output.width + x
			if output.valid_mask[index] == 0 or travel_time[index] >= INF * 0.5:
				output.reached_mask[index] = 0
				continue
			var gradient_t := _upwind_gradient_at(output, travel_time, x, z)
			var gradient_phase: Vector2 = gradient_t * output.omega_ref_rad_s
			var length_phase: float = gradient_phase.length()
			var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
			output.phase_rad[index] = travel_time[index] * output.omega_ref_rad_s
			output.phase_offset_rad[index] = output.phase_rad[index] - output.k0_rad_m * (point.dot(direction) - minimum_s)
			output.phase_gradient_x[index] = gradient_phase.x
			output.phase_gradient_z[index] = gradient_phase.y
			var local_direction: Vector2 = gradient_phase.normalized() if length_phase > 1.0e-8 else direction
			output.local_direction_x[index] = local_direction.x
			output.local_direction_z[index] = local_direction.y
			output.reached_mask[index] = 1
			# Sólo gradiente central interior: las fronteras de entrada y costas usan
			# diferencias one-sided, que no miden el residual espacial del solver.
			if x > 0 and z > 0 and x < output.width - 1 and z < output.height - 1:
				max_residual = maxf(max_residual, absf(length_phase - output.local_k[index]))
	output.eikonal_max_residual_rad_m = max_residual


func _upwind_gradient_at(output, values: PackedFloat32Array, x: int, z: int) -> Vector2:
	## Gradiente Godunov coherente con la actualización eikonal discreta. A
	## diferencia del central, conserva |grad(T)|=1/c incluso junto a una zona
	## de fuerte curvatura; no suaviza ni altera el campo de travel time.
	var center := values[z * output.width + x]
	var left := _travel_at(output, values, x - 1, z)
	var right := _travel_at(output, values, x + 1, z)
	var down := _travel_at(output, values, x, z - 1)
	var up := _travel_at(output, values, x, z + 1)
	var gx := 0.0
	var gz := 0.0
	var best_x := minf(left, right)
	var best_z := minf(down, up)
	if best_x < INF * 0.5:
		gx = (center - best_x) / output.cell_size_m
		if right < left:
			gx = -gx
	if best_z < INF * 0.5:
		gz = (center - best_z) / output.cell_size_m
		if up < down:
			gz = -gz
	return Vector2(gx, gz)


func _minimum_projection(output, direction: Vector2) -> float:
	var minimum_s := INF
	for z in output.height:
		for x in output.width:
			var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
			minimum_s = minf(minimum_s, point.dot(direction))
	return minimum_s


func _build_shadow_scale(output, travel_time: PackedFloat32Array, fixed: PackedByteArray, direction: Vector2) -> void:
	var count: int = output.width * output.height
	var route_distance := PackedFloat32Array()
	route_distance.resize(count)
	route_distance.fill(INF)
	var raw_shadow := PackedFloat32Array()
	raw_shadow.resize(count)
	var order := []
	for index in count:
		if output.valid_mask[index] != 0 and output.reached_mask[index] != 0 and travel_time[index] < INF * 0.5:
			order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
			if not is_equal_approx(travel_time[a], travel_time[b]):
				return travel_time[a] < travel_time[b]
			return a < b
	)
	var minimum_s := _minimum_projection(output, direction)
	for current in order:
		var x: int = current % output.width
		var z: int = current / output.width
		var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
		var direct_distance: float = maxf(0.0, point.dot(direction) - minimum_s)
		if fixed[current] != 0:
			route_distance[current] = direct_distance
		else:
			var parent := _best_route_parent(output, travel_time, route_distance, x, z)
			if parent >= 0 and route_distance[parent] < INF * 0.5:
				route_distance[current] = route_distance[parent] + output.cell_size_m
			else:
				route_distance[current] = direct_distance
		if _has_incident_line_of_sight(output, x, z, direction):
			raw_shadow[current] = 1.0
		else:
			var detour: float = maxf(0.0, route_distance[current] - direct_distance)
			var decay_length: float = maxf(shadow_detour_length_m, 1.0e-6)
			raw_shadow[current] = clampf(shadow_occlusion_entry_scale * exp(-detour / decay_length), shadow_min_scale, 1.0)
	_smooth_shadow_scale(output, raw_shadow, fixed)


func _best_route_parent(output, travel_time: PackedFloat32Array, route_distance: PackedFloat32Array, x: int, z: int) -> int:
	var current: int = z * output.width + x
	var current_time: float = travel_time[current]
	var best_index := -1
	var best_time := INF
	for neighbor in [Vector2i(x - 1, z), Vector2i(x + 1, z), Vector2i(x, z - 1), Vector2i(x, z + 1)]:
		if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= output.width or neighbor.y >= output.height:
			continue
		var candidate: int = neighbor.y * output.width + neighbor.x
		if output.valid_mask[candidate] == 0 or output.reached_mask[candidate] == 0 or route_distance[candidate] >= INF * 0.5:
			continue
		if travel_time[candidate] >= current_time - 1.0e-7:
			continue
		if travel_time[candidate] < best_time or (is_equal_approx(travel_time[candidate], best_time) and candidate < best_index):
			best_time = travel_time[candidate]
			best_index = candidate
	return best_index


func _smooth_shadow_scale(output, raw_shadow: PackedFloat32Array, fixed: PackedByteArray) -> void:
	output.shadow_scale.resize(output.width * output.height)
	output.shadow_scale.fill(0.0)
	var current := raw_shadow
	for _pass in shadow_smoothing_passes:
		var next := PackedFloat32Array()
		next.resize(output.width * output.height)
		for z in output.height:
			for x in output.width:
				var index: int = z * output.width + x
				if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
					next[index] = 0.0
					continue
				if fixed[index] != 0:
					next[index] = 1.0
					continue
				var sum: float = current[index]
				var samples := 1
				for neighbor in [Vector2i(x - 1, z), Vector2i(x + 1, z), Vector2i(x, z - 1), Vector2i(x, z + 1)]:
					if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= output.width or neighbor.y >= output.height:
						continue
					var candidate: int = neighbor.y * output.width + neighbor.x
					if output.valid_mask[candidate] == 0 or output.reached_mask[candidate] == 0:
						continue
					sum += current[candidate]
					samples += 1
				next[index] = clampf(sum / float(samples), 0.0, 1.0)
		current = next
	output.shadow_scale = current


func _has_incident_line_of_sight(output, x: int, z: int, direction: Vector2) -> bool:
	var position := Vector2(float(x), float(z))
	var step := direction * 0.5
	var maximum_steps := 4 * maxi(output.width, output.height)
	for _step_index in maximum_steps:
		position -= step
		if position.x < 0.0 or position.y < 0.0 or position.x > float(output.width - 1) or position.y > float(output.height - 1):
			return true
		var ix := clampi(int(round(position.x)), 0, output.width - 1)
		var iz := clampi(int(round(position.y)), 0, output.height - 1)
		if output.valid_mask[iz * output.width + ix] == 0:
			return false
	return false

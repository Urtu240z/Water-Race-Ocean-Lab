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
var max_sweep_cycles := 16
var convergence_tolerance_s := 1.0e-4
var shadow_min_scale := 0.15
var shadow_occlusion_entry_scale := 0.70
var shadow_detour_length_m := 32.0
var shadow_smoothing_passes := 2
var shadow_recovery_enabled := true
var shadow_diffraction_angle_deg := 12.0
var shadow_recovery_strength := 1.0
var direction_smoothing_passes := 3
var direction_smoothing_strength := 0.35
var direction_smoothing_threshold_deg := 6.0
var last_base_metrics_ms := 0.0
var last_eikonal_sweep_ms := 0.0
var last_phase_populate_ms := 0.0
var last_shadow_ms := 0.0
var last_shadow_geometric_ms := 0.0
var last_shadow_recovery_ms := 0.0
var last_direction_smoothing_ms := 0.0
var last_cycles_used := 0
var last_directional_sweeps_used := 0
var last_final_max_change := 0.0


func bake():
	var direction := incoming_direction_xz.normalized()
	if bathymetry_data == null or not bathymetry_data.is_valid() or direction.length_squared() <= 1.0e-8:
		push_error("CoastalEikonalBaker requiere BathymetryData y dirección válidos.")
		return null
	# Reutiliza exactamente la dispersión, Cg y shoaling de 3B, pero no paga la
	# integración de fase rectilínea que el solve Eikonal sustituirá.
	var straight = StraightBakerScript.new()
	straight.bathymetry_data = bathymetry_data
	straight.incoming_direction_xz = direction
	straight.reference_wavelength_m = reference_wavelength_m
	straight.gravity_mps2 = gravity_mps2
	straight.min_valid_depth_m = min_valid_depth_m
	print("COASTAL PREVIEW: computing base metrics...")
	var base_start := Time.get_ticks_usec()
	var output = straight.bake_base_fields()
	last_base_metrics_ms = float(Time.get_ticks_usec() - base_start) / 1000.0
	if output == null:
		return null
	output.propagation_kind = 1
	var travel_time := _initialize_travel_time(output, direction)
	var fixed := _build_upstream_boundary(output, travel_time, direction)
	print("COASTAL PREVIEW: solving eikonal...")
	var sweep_start := Time.get_ticks_usec()
	_sweep_travel_time(output, travel_time, fixed)
	last_eikonal_sweep_ms = float(Time.get_ticks_usec() - sweep_start) / 1000.0
	var phase_start := Time.get_ticks_usec()
	_populate_phase_fields(output, travel_time, direction)
	last_phase_populate_ms = float(Time.get_ticks_usec() - phase_start) / 1000.0
	var direction_start := Time.get_ticks_usec()
	_build_render_direction(output)
	last_direction_smoothing_ms = float(Time.get_ticks_usec() - direction_start) / 1000.0
	print("COASTAL PREVIEW: building shadow...")
	var shadow_start := Time.get_ticks_usec()
	_build_shadow_scale(output, fixed, direction)
	last_shadow_ms = float(Time.get_ticks_usec() - shadow_start) / 1000.0
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
	var cycle_count := 0
	var directional_sweep_count := 0
	var final_max_change := INF
	for _iteration in max_sweep_cycles:
		var max_change := 0.0
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				max_change = maxf(max_change, _sweep_once(output, travel_time, fixed, sx, sz))
		directional_sweep_count += 4
		cycle_count += 1
		final_max_change = max_change
		if max_change <= convergence_tolerance_s:
			break
	output.eikonal_sweeps = directional_sweep_count
	output.eikonal_cycles = cycle_count
	output.eikonal_directional_sweeps = directional_sweep_count
	output.eikonal_final_max_change_s = final_max_change
	last_cycles_used = cycle_count
	last_directional_sweeps_used = directional_sweep_count
	last_final_max_change = final_max_change


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
	var interior_residual := 0.0
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
	for z in output.height:
		for x in output.width:
			var index: int = z * output.width + x
			if output.valid_mask[index] == 0 or output.reached_mask[index] == 0 or not _has_reached_water_neighbors(output, x, z):
				continue
			var gradient_phase: Vector2 = _upwind_gradient_at(output, travel_time, x, z) * output.omega_ref_rad_s
			interior_residual = maxf(interior_residual, absf(gradient_phase.length() - output.local_k[index]))
	output.eikonal_interior_residual_rad_m = interior_residual


func _has_reached_water_neighbors(output, x: int, z: int) -> bool:
	if x <= 0 or z <= 0 or x >= output.width - 1 or z >= output.height - 1:
		return false
	for neighbor in [Vector2i(x - 1, z), Vector2i(x + 1, z), Vector2i(x, z - 1), Vector2i(x, z + 1)]:
		var index: int = neighbor.y * output.width + neighbor.x
		if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
			return false
	return true


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


func _build_shadow_scale(output, fixed: PackedByteArray, direction: Vector2) -> void:
	var geometric_start := Time.get_ticks_usec()
	var visibility := _build_incident_visibility_field(output, direction)
	var occluded_distance := _build_occluded_distance_field(output, visibility, direction)
	var raw_shadow := PackedFloat32Array()
	raw_shadow.resize(output.width * output.height)
	var decay_length: float = maxf(shadow_detour_length_m, 1.0e-6)
	for index in raw_shadow.size():
		if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
			raw_shadow[index] = 0.0
			continue
		if fixed[index] != 0 or visibility[index] >= 0.999:
			raw_shadow[index] = 1.0
			continue
		var occluded_shadow: float = clampf(shadow_occlusion_entry_scale * exp(-occluded_distance[index] / decay_length), shadow_min_scale, 1.0)
		raw_shadow[index] = clampf(lerpf(occluded_shadow, 1.0, visibility[index]), shadow_min_scale, 1.0)
	last_shadow_geometric_ms = float(Time.get_ticks_usec() - geometric_start) / 1000.0
	var recovery_start := Time.get_ticks_usec()
	var energetic_shadow := raw_shadow
	if shadow_recovery_enabled and shadow_recovery_strength > 0.0 and shadow_diffraction_angle_deg > 0.0:
		energetic_shadow = _recover_shadow_energy(output, fixed, visibility, occluded_distance, raw_shadow, direction)
	last_shadow_recovery_ms = float(Time.get_ticks_usec() - recovery_start) / 1000.0
	_smooth_shadow_scale(output, energetic_shadow, fixed)


func _recover_shadow_energy(output, fixed: PackedByteArray, visibility: PackedFloat32Array, occluded_distance: PackedFloat32Array, geometric_shadow: PackedFloat32Array, direction: Vector2) -> PackedFloat32Array:
	## Advection/diffusion direccional barata: cada celda sólo recibe del slice
	## inmediatamente upstream y de dos donantes laterales de esa misma slice.
	## LAND y agua no alcanzada tienen energía cero y nunca son donantes.
	var energy := PackedFloat32Array()
	energy.resize(output.width * output.height)
	energy.fill(0.0)
	var axis_x := absf(direction.x) >= absf(direction.y)
	var step_x: int = 0
	var step_z: int = 0
	var dominant_abs: float
	if axis_x:
		step_x = 1 if direction.x > 0.0 else -1
		dominant_abs = absf(direction.x)
	else:
		step_z = 1 if direction.y > 0.0 else -1
		dominant_abs = absf(direction.y)
	var slice_step: float = 1.0 / maxf(dominant_abs, 1.0e-6)
	var slice_length: int = output.width if axis_x else output.height
	var slice_direction: int = step_x if axis_x else step_z
	var slice_start: int = 0 if slice_direction > 0 else slice_length - 1
	var slice_end: int = slice_length if slice_direction > 0 else -1
	var perpendicular := Vector2(-direction.y, direction.x)
	var diffraction_slope := tan(deg_to_rad(shadow_diffraction_angle_deg))
	var lateral_mix := clampf(shadow_recovery_strength * diffraction_slope, 0.0, 1.0)
	for slice_index in range(slice_start, slice_end, slice_direction):
		if axis_x:
			for z in output.height:
				var index: int = z * output.width + slice_index
				if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
					energy[index] = 0.0
					continue
				if fixed[index] != 0 or visibility[index] >= 0.999:
					energy[index] = 1.0
					continue
				var upstream := Vector2(float(slice_index), float(z)) - direction * slice_step
				var upstream_energy := _sample_scalar_slice(energy, output, upstream, true)
				var lateral_offset := perpendicular * (diffraction_slope * maxf(occluded_distance[index] / maxf(output.cell_size_m, 1.0e-6), 1.0))
				var lateral_left := _sample_scalar_slice(energy, output, upstream - lateral_offset, true)
				var lateral_right := _sample_scalar_slice(energy, output, upstream + lateral_offset, true)
				var recovered_energy := lerpf(upstream_energy, 0.5 * (lateral_left + lateral_right), lateral_mix)
				energy[index] = maxf(geometric_shadow[index], clampf(recovered_energy, 0.0, 1.0))
		else:
			for x in output.width:
				var index: int = slice_index * output.width + x
				if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
					energy[index] = 0.0
					continue
				if fixed[index] != 0 or visibility[index] >= 0.999:
					energy[index] = 1.0
					continue
				var upstream := Vector2(float(x), float(slice_index)) - direction * slice_step
				var upstream_energy := _sample_scalar_slice(energy, output, upstream, false)
				var lateral_offset := perpendicular * (diffraction_slope * maxf(occluded_distance[index] / maxf(output.cell_size_m, 1.0e-6), 1.0))
				var lateral_left := _sample_scalar_slice(energy, output, upstream - lateral_offset, false)
				var lateral_right := _sample_scalar_slice(energy, output, upstream + lateral_offset, false)
				var recovered_energy := lerpf(upstream_energy, 0.5 * (lateral_left + lateral_right), lateral_mix)
				energy[index] = maxf(geometric_shadow[index], clampf(recovered_energy, 0.0, 1.0))
	return energy


func _build_render_direction(output) -> void:
	## Campo derivado para visualización/render futuro. local_direction permanece
	## como la dirección raw de ∇T y nunca se sobrescribe.
	var current_x: PackedFloat32Array = output.local_direction_x
	var current_z: PackedFloat32Array = output.local_direction_z
	var threshold_rad := deg_to_rad(direction_smoothing_threshold_deg)
	var transition_rad := deg_to_rad(24.0)
	for _pass in direction_smoothing_passes:
		var next_x := PackedFloat32Array()
		var next_z := PackedFloat32Array()
		next_x.resize(output.width * output.height)
		next_z.resize(output.width * output.height)
		for z in output.height:
			for x in output.width:
				var index: int = z * output.width + x
				var current := Vector2(current_x[index], current_z[index]).normalized()
				if output.valid_mask[index] == 0 or output.reached_mask[index] == 0:
					next_x[index] = current.x
					next_z[index] = current.y
					continue
				var sum := Vector2.ZERO
				var samples := 0
				if x > 0:
					var neighbor: int = index - 1
					if output.valid_mask[neighbor] != 0 and output.reached_mask[neighbor] != 0:
						sum += Vector2(current_x[neighbor], current_z[neighbor]).normalized()
						samples += 1
				if x + 1 < output.width:
					var neighbor: int = index + 1
					if output.valid_mask[neighbor] != 0 and output.reached_mask[neighbor] != 0:
						sum += Vector2(current_x[neighbor], current_z[neighbor]).normalized()
						samples += 1
				if z > 0:
					var neighbor: int = index - output.width
					if output.valid_mask[neighbor] != 0 and output.reached_mask[neighbor] != 0:
						sum += Vector2(current_x[neighbor], current_z[neighbor]).normalized()
						samples += 1
				if z + 1 < output.height:
					var neighbor: int = index + output.width
					if output.valid_mask[neighbor] != 0 and output.reached_mask[neighbor] != 0:
						sum += Vector2(current_x[neighbor], current_z[neighbor]).normalized()
						samples += 1
				if samples == 0 or sum.length_squared() <= 1.0e-8:
					next_x[index] = current.x
					next_z[index] = current.y
					continue
				var average := sum.normalized()
				var angle := acos(clampf(current.dot(average), -1.0, 1.0))
				var transition := clampf((angle - threshold_rad) / maxf(transition_rad, 1.0e-6), 0.0, 1.0)
				transition = transition * transition * (3.0 - 2.0 * transition)
				var weight := transition * clampf(direction_smoothing_strength, 0.0, 1.0)
				var blended := current.lerp(average, weight).normalized()
				next_x[index] = blended.x
				next_z[index] = blended.y
		current_x = next_x
		current_z = next_z
	output.render_direction_x = current_x
	output.render_direction_z = current_z


func _build_incident_visibility_field(output, direction: Vector2) -> PackedFloat32Array:
	## O(N) semi-Lagrangian directional sweep. Cada celda consulta sólo la
	## slice inmediatamente upstream; no ray-marcha ni ordena el grid.
	var visibility := PackedFloat32Array()
	visibility.resize(output.width * output.height)
	var axis_x := absf(direction.x) >= absf(direction.y)
	var step_x: int = 0
	var step_z: int = 0
	var dominant_abs: float
	if axis_x:
		step_x = 1 if direction.x > 0.0 else -1
		dominant_abs = absf(direction.x)
	else:
		step_z = 1 if direction.y > 0.0 else -1
		dominant_abs = absf(direction.y)
	var slice_step: float = 1.0 / maxf(dominant_abs, 1.0e-6)
	var slice_length: int = output.width if axis_x else output.height
	var slice_direction: int = step_x if axis_x else step_z
	var slice_start: int = 0 if slice_direction > 0 else slice_length - 1
	var slice_end: int = slice_length if slice_direction > 0 else -1
	for slice_index in range(slice_start, slice_end, slice_direction):
		if axis_x:
			for z in output.height:
				var index: int = z * output.width + slice_index
				if output.valid_mask[index] == 0:
					visibility[index] = 0.0
					continue
				var upstream := Vector2(float(slice_index), float(z)) - direction * slice_step
				visibility[index] = _sample_visibility_slice(visibility, output, upstream, true)
		else:
			for x in output.width:
				var index: int = slice_index * output.width + x
				if output.valid_mask[index] == 0:
					visibility[index] = 0.0
					continue
				var upstream := Vector2(float(x), float(slice_index)) - direction * slice_step
				visibility[index] = _sample_visibility_slice(visibility, output, upstream, false)
	return visibility


func _build_occluded_distance_field(output, visibility: PackedFloat32Array, direction: Vector2) -> PackedFloat32Array:
	var distance := PackedFloat32Array()
	distance.resize(output.width * output.height)
	distance.fill(0.0)
	var axis_x := absf(direction.x) >= absf(direction.y)
	var step_x: int = 0
	var step_z: int = 0
	var dominant_abs: float
	if axis_x:
		step_x = 1 if direction.x > 0.0 else -1
		dominant_abs = absf(direction.x)
	else:
		step_z = 1 if direction.y > 0.0 else -1
		dominant_abs = absf(direction.y)
	var slice_step: float = 1.0 / maxf(dominant_abs, 1.0e-6)
	var step_distance_m: float = output.cell_size_m * slice_step
	var slice_length: int = output.width if axis_x else output.height
	var slice_direction: int = step_x if axis_x else step_z
	var slice_start: int = 0 if slice_direction > 0 else slice_length - 1
	var slice_end: int = slice_length if slice_direction > 0 else -1
	for slice_index in range(slice_start, slice_end, slice_direction):
		if axis_x:
			for z in output.height:
				var index: int = z * output.width + slice_index
				if output.valid_mask[index] == 0:
					distance[index] = 0.0
					continue
				var upstream := Vector2(float(slice_index), float(z)) - direction * slice_step
				var upstream_distance := _sample_scalar_slice(distance, output, upstream, true)
				var upstream_visibility := _sample_visibility_slice(visibility, output, upstream, true)
				distance[index] = 0.0 if upstream_visibility >= 0.999 else upstream_distance + step_distance_m
		else:
			for x in output.width:
				var index: int = slice_index * output.width + x
				if output.valid_mask[index] == 0:
					distance[index] = 0.0
					continue
				var upstream := Vector2(float(x), float(slice_index)) - direction * slice_step
				var upstream_distance := _sample_scalar_slice(distance, output, upstream, false)
				var upstream_visibility := _sample_visibility_slice(visibility, output, upstream, false)
				distance[index] = 0.0 if upstream_visibility >= 0.999 else upstream_distance + step_distance_m
	return distance


func _sample_visibility_slice(values: PackedFloat32Array, output, grid: Vector2, axis_x: bool) -> float:
	if grid.x < 0.0 or grid.y < 0.0 or grid.x > float(output.width - 1) or grid.y > float(output.height - 1):
		return 1.0
	if axis_x:
		var x: int = clampi(int(round(grid.x)), 0, output.width - 1)
		var z0: int = clampi(int(floor(grid.y)), 0, output.height - 1)
		var z1: int = mini(z0 + 1, output.height - 1)
		var tz: float = grid.y - float(z0)
		return lerpf(values[z0 * output.width + x], values[z1 * output.width + x], tz)
	var z: int = clampi(int(round(grid.y)), 0, output.height - 1)
	var x0: int = clampi(int(floor(grid.x)), 0, output.width - 1)
	var x1: int = mini(x0 + 1, output.width - 1)
	var tx: float = grid.x - float(x0)
	return lerpf(values[z * output.width + x0], values[z * output.width + x1], tx)


func _sample_scalar_slice(values: PackedFloat32Array, output, grid: Vector2, axis_x: bool) -> float:
	return _sample_visibility_slice(values, output, grid, axis_x)


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


func _has_incident_line_of_sight_reference(output, x: int, z: int, direction: Vector2) -> bool:
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

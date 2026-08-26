class_name CoastalPropagationBaker
extends RefCounted
## Bake offline/dev-time de propagación rectilínea. No modifica BathymetryData.

const DataScript := preload("res://ocean_v3/coastal/coastal_propagation_data.gd")
const MathScript := preload("res://ocean_v3/coastal/finite_depth_wave_math.gd")

var bathymetry_data: Resource
var incoming_direction_xz := Vector2.RIGHT
var reference_wavelength_m := 16.0 # Banda LONG representativa, no altera H0.
var gravity_mps2 := 9.81
var min_valid_depth_m := 0.25


func bake_base_fields():
	if bathymetry_data == null or not bathymetry_data.is_valid():
		push_error("CoastalPropagationBaker requiere BathymetryData válido.")
		return null
	var direction := incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8 or reference_wavelength_m <= 0.0 or gravity_mps2 <= 0.0:
		push_error("CoastalPropagationBaker tiene dirección, lambda o gravedad inválida.")
		return null
	var output = DataScript.new()
	output.world_origin_xz = bathymetry_data.world_origin_xz
	output.width = bathymetry_data.width
	output.height = bathymetry_data.height
	output.cell_size_m = bathymetry_data.cell_size_m
	output.incoming_direction_xz = direction
	output.min_valid_depth_m = min_valid_depth_m
	output.omega_ref_rad_s = MathScript.omega_for_wavelength_deep(reference_wavelength_m, gravity_mps2)
	output.k0_rad_m = output.omega_ref_rad_s * output.omega_ref_rad_s / gravity_mps2
	var count: int = output.width * output.height
	output.depth_m.resize(count)
	output.local_k.resize(count)
	output.wavelength_m.resize(count)
	output.phase_speed_mps.resize(count)
	output.group_velocity_mps.resize(count)
	output.shoaling_scale.resize(count)
	output.phase_offset_rad.resize(count)
	output.valid_mask.resize(count)
	output.phase_rad.resize(count)
	output.phase_gradient_x.resize(count)
	output.phase_gradient_z.resize(count)
	output.local_direction_x.resize(count)
	output.local_direction_z.resize(count)
	output.reached_mask.resize(count)
	output.shadow_scale.resize(count)
	var cg_deep: float = 0.5 * output.omega_ref_rad_s / output.k0_rad_m
	for index in count:
		var depth: float = bathymetry_data.depth_m[index]
		var is_valid: bool = bathymetry_data.land_water_mask[index] != 0 and depth >= min_valid_depth_m
		output.depth_m[index] = depth
		output.valid_mask[index] = 1 if is_valid else 0
		output.shadow_scale[index] = 1.0 if is_valid else 0.0
		if not is_valid:
			output.local_k[index] = output.k0_rad_m
			output.wavelength_m[index] = reference_wavelength_m
			output.phase_speed_mps[index] = output.omega_ref_rad_s / output.k0_rad_m
			output.group_velocity_mps[index] = cg_deep
			output.shoaling_scale[index] = 1.0
			continue
		# Igual matemática que solve_properties(), sin crear un Dictionary por
		# nodo durante grids grandes. La única implementación numérica sigue en
		# FiniteDepthWaveMath.
		var local_k: float = MathScript.solve_wavenumber(output.omega_ref_rad_s, depth, gravity_mps2)
		output.local_k[index] = local_k
		output.wavelength_m[index] = MathScript.wavelength(local_k)
		output.phase_speed_mps[index] = MathScript.phase_speed(output.omega_ref_rad_s, local_k)
		output.group_velocity_mps[index] = MathScript.group_velocity(output.omega_ref_rad_s, local_k, depth)
		# Conservación de flujo de energía lineal. El clamp evita una reducción
		# visual marginal en profundidades intermedias y conserva deep≈1.
		output.shoaling_scale[index] = maxf(1.0, sqrt(cg_deep / maxf(output.group_velocity_mps[index], 1.0e-6)))
	return output


func bake():
	var output = bake_base_fields()
	if output == null:
		return null
	var direction: Vector2 = output.incoming_direction_xz
	_integrate_straight_ray_phase(output, direction)
	_populate_straight_phase_fields(output, direction)
	return output


func _populate_straight_phase_fields(output, direction: Vector2) -> void:
	## Compatibilidad 3B: un frente estrictamente longitudinal conserva k local
	## paralelo a la dirección incidente y todos los nodos válidos son reached.
	for z in output.height:
		for x in output.width:
			var index: int = z * output.width + x
			var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
			output.phase_rad[index] = output.k0_rad_m * point.dot(direction) + output.phase_offset_rad[index]
			output.phase_gradient_x[index] = output.local_k[index] * direction.x
			output.phase_gradient_z[index] = output.local_k[index] * direction.y
			output.local_direction_x[index] = direction.x
			output.local_direction_z[index] = direction.y
			output.reached_mask[index] = output.valid_mask[index]


func _integrate_straight_ray_phase(output, direction: Vector2) -> void:
	## Sweep por s=dot(x,d). Cada celda interpola sólo vecinos ya procesados
	## aguas arriba; evita O(n³), funciona en cualquier dirección y conserva el
	## offset al salir de un banco. La distancia de integración por paso es una
	## celda sobre el rayo de entrada fijo.
	var order: Array[Dictionary] = []
	for z in output.height:
		for x in output.width:
			var index: int = z * output.width + x
			var point: Vector2 = output.world_origin_xz + Vector2(float(x), float(z)) * output.cell_size_m
			order.append({"index": index, "x": x, "z": z, "s": point.dot(direction)})
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a["s"], b["s"]):
			return a["s"] < b["s"]
		if a["z"] != b["z"]:
			return a["z"] < b["z"]
		return a["x"] < b["x"]
	)
	var processed := PackedByteArray()
	processed.resize(output.width * output.height)
	for item in order:
		var index: int = item["index"]
		var point: Vector2 = output.world_origin_xz + Vector2(float(item["x"]), float(item["z"])) * output.cell_size_m
		var upstream_grid: Vector2 = ((point - direction * output.cell_size_m) - output.world_origin_xz) / output.cell_size_m
		var interpolation := _interpolate_upstream(output, processed, upstream_grid)
		if interpolation["weight"] <= 1.0e-6:
			output.phase_offset_rad[index] = 0.0
		else:
			var delta_current: float = output.local_k[index] - output.k0_rad_m if output.valid_mask[index] != 0 else 0.0
			output.phase_offset_rad[index] = interpolation["phase"] + 0.5 * (interpolation["delta_k"] + delta_current) * output.cell_size_m
		processed[index] = 1


func _interpolate_upstream(output, processed: PackedByteArray, grid: Vector2) -> Dictionary:
	if grid.x < 0.0 or grid.y < 0.0 or grid.x > float(output.width - 1) or grid.y > float(output.height - 1):
		return {"phase": 0.0, "delta_k": 0.0, "weight": 0.0}
	var x0 := mini(int(floor(grid.x)), output.width - 2)
	var z0 := mini(int(floor(grid.y)), output.height - 2)
	var tx := grid.x - float(x0)
	var tz := grid.y - float(z0)
	var indices := [z0 * output.width + x0, z0 * output.width + x0 + 1, (z0 + 1) * output.width + x0, (z0 + 1) * output.width + x0 + 1]
	var weights := [(1.0 - tx) * (1.0 - tz), tx * (1.0 - tz), (1.0 - tx) * tz, tx * tz]
	var total_weight := 0.0
	var phase := 0.0
	var delta_k := 0.0
	for candidate in indices.size():
		var candidate_index: int = indices[candidate]
		if processed[candidate_index] == 0:
			continue
		var weight: float = weights[candidate]
		total_weight += weight
		phase += output.phase_offset_rad[candidate_index] * weight
		var local_delta: float = output.local_k[candidate_index] - output.k0_rad_m if output.valid_mask[candidate_index] != 0 else 0.0
		delta_k += local_delta * weight
	if total_weight <= 1.0e-6:
		return {"phase": 0.0, "delta_k": 0.0, "weight": 0.0}
	return {"phase": phase / total_weight, "delta_k": delta_k / total_weight, "weight": total_weight}

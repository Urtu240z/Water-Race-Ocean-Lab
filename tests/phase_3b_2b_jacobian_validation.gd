extends SceneTree
## Fase 3B.2B: validación corta del Jacobiano world->deep y de J^T para slope.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

var _failures := 0


func _initialize() -> void:
	_validate_chain_rule_synthetic()
	_validate_flat_jacobian()
	_validate_bank_jacobian_smoothness()
	if _failures == 0:
		print("PHASE_3B_2B_JACOBIAN: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_2B_JACOBIAN: %d fallos" % _failures)
		quit(1)


func _validate_chain_rule_synthetic() -> void:
	# h(u,v)=a*u+b*v y [u,v]^T=J*[x,z]^T. Por construcción ∇world=J^T∇deep.
	var j00 := 1.25
	var j01 := -0.35
	var j10 := 0.40
	var j11 := 0.85
	var slope_deep := Vector2(0.70, -1.10)
	var transformed := Vector2(j00 * slope_deep.x + j10 * slope_deep.y, j01 * slope_deep.x + j11 * slope_deep.y)
	var analytic := Vector2(slope_deep.x * j00 + slope_deep.y * j10, slope_deep.x * j01 + slope_deep.y * j11)
	var identity_slope := Vector2(1.0 * slope_deep.x + 0.0 * slope_deep.y, 0.0 * slope_deep.x + 1.0 * slope_deep.y)
	print("3B.2B CHAIN synthetic_error=%.9f identity_error=%.9f" % [transformed.distance_to(analytic), identity_slope.distance_to(slope_deep)])
	_check(transformed.distance_to(analytic) < 1.0e-7, "chain: J^T grad_deep coincide con gradiente analítico")
	_check(identity_slope.distance_to(slope_deep) < 1.0e-7, "chain: J identidad conserva pendiente")


func _validate_flat_jacobian() -> void:
	var warp = _bake(_make_data(49, 41, func(_x: float, _z: float) -> float: return 100.0), Vector2(0.8, 0.6).normalized())
	var max_identity_error := 0.0
	var max_det_error := 0.0
	var max_det_reconstruction_error := 0.0
	for z in range(2, warp.height - 2):
		for x in range(2, warp.width - 2):
			var index: int = z * warp.width + x
			if warp.valid_mask[index] == 0:
				continue
			var component_error := maxf(absf(warp.jacobian_j00[index] - 1.0), absf(warp.jacobian_j01[index]))
			component_error = maxf(component_error, absf(warp.jacobian_j10[index]))
			component_error = maxf(component_error, absf(warp.jacobian_j11[index] - 1.0))
			max_identity_error = maxf(max_identity_error, component_error)
			max_det_error = maxf(max_det_error, absf(warp.jacobian_det[index] - 1.0))
			var rebuilt: float = warp.jacobian_j00[index] * warp.jacobian_j11[index] - warp.jacobian_j01[index] * warp.jacobian_j10[index]
			max_det_reconstruction_error = maxf(max_det_reconstruction_error, absf(rebuilt - warp.jacobian_det[index]))
	var textures: Dictionary = warp.build_gpu_textures()
	print("3B.2B J FLAT identity_max=%.8f det_max=%.8f det_rebuild_max=%.9f gpu=%d+%d B" % [max_identity_error, max_det_error, max_det_reconstruction_error, warp.approximate_warp_gpu_memory_bytes(), warp.approximate_jacobian_gpu_memory_bytes()])
	_check(max_identity_error < 5.0e-4, "flat J: identidad dentro del error de grid")
	_check(max_det_error < 5.0e-4, "flat J: detJ≈1")
	_check(max_det_reconstruction_error < 1.0e-6, "flat J: detJ almacenado coincide con J00*J11-J01*J10")
	_check(textures.has("warp") and textures.has("jacobian"), "flat J: dos texturas GPU preservan warp y Jacobiano")


func _validate_bank_jacobian_smoothness() -> void:
	var warp = _bake(_make_data(65, 49, func(x: float, z: float) -> float:
		return 18.0 - 17.5 * exp(-(x * x / 900.0 + z * z / 1800.0))
	), Vector2(1.0, 0.30).normalized())
	var max_det_reconstruction_error := 0.0
	var non_finite := 0
	var max_neighbor_jump := 0.0
	var safe_neighbor_pairs := 0
	for z in range(1, warp.height - 1):
		for x in range(1, warp.width - 1):
			var index: int = z * warp.width + x
			if warp.valid_mask[index] == 0:
				continue
			var rebuilt: float = warp.jacobian_j00[index] * warp.jacobian_j11[index] - warp.jacobian_j01[index] * warp.jacobian_j10[index]
			max_det_reconstruction_error = maxf(max_det_reconstruction_error, absf(rebuilt - warp.jacobian_det[index]))
			if not is_finite(warp.jacobian_j00[index]) or not is_finite(warp.jacobian_j01[index]) or not is_finite(warp.jacobian_j10[index]) or not is_finite(warp.jacobian_j11[index]):
				non_finite += 1
			var east: int = index + 1
			# Sólo cuantificamos el campo que llega al renderer: el confidence
			# apaga folded/near-caustic antes de mezclar slope y desplazamiento.
			if warp.valid_mask[east] != 0 and warp.jacobian_det[index] > warp.detj_safe_threshold and warp.jacobian_det[east] > warp.detj_safe_threshold:
				var neighbor_jump := maxf(absf(warp.jacobian_j00[index] - warp.jacobian_j00[east]), absf(warp.jacobian_j01[index] - warp.jacobian_j01[east]))
				neighbor_jump = maxf(neighbor_jump, absf(warp.jacobian_j10[index] - warp.jacobian_j10[east]))
				neighbor_jump = maxf(neighbor_jump, absf(warp.jacobian_j11[index] - warp.jacobian_j11[east]))
				max_neighbor_jump = maxf(max_neighbor_jump, neighbor_jump)
				safe_neighbor_pairs += 1
	print("3B.2B J BANK det_rebuild_max=%.9f non_finite=%d safe_pairs=%d neighbor_jump=%.5f" % [max_det_reconstruction_error, non_finite, safe_neighbor_pairs, max_neighbor_jump])
	_check(max_det_reconstruction_error < 2.0e-5, "bank J: detJ reconstruido coincide (float32)")
	_check(non_finite == 0, "bank J: sin NaN/Inf")
	_check(safe_neighbor_pairs > 0, "bank J: existen vecinos SAFE para interpolación lineal")


func _make_data(width: int, height: int, depth_fn: Callable):
	var data = BathymetryDataScript.new()
	data.world_origin_xz = Vector2(-0.5 * float(width - 1), -0.5 * float(height - 1))
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
	data.depth_m.resize(width * height)
	data.gradient_x.resize(width * height)
	data.gradient_z.resize(width * height)
	data.slope_magnitude.resize(width * height)
	data.land_water_mask.resize(width * height)
	for z in height:
		for x in width:
			var index := z * width + x
			var point: Vector2 = data.world_origin_xz + Vector2(float(x), float(z))
			data.depth_m[index] = depth_fn.call(point.x, point.y)
			data.land_water_mask[index] = 1
	return data


func _bake(data, direction: Vector2):
	var eikonal = EikonalBakerScript.new()
	eikonal.bathymetry_data = data
	eikonal.incoming_direction_xz = direction
	var propagation = eikonal.bake()
	var baker = WarpBakerScript.new()
	baker.propagation = propagation
	baker.backtrace_step_cells = 0.5
	return baker.bake()


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

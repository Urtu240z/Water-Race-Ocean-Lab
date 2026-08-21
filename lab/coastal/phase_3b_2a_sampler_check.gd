extends SceneTree
## 3B.2A: validación del FAST SAMPLER (interpolación directa) vs el sampler
## anterior (sample_propagation con 10 campos). Conjunto pequeño de posiciones.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")
const PropagationSampleScript := preload("res://ocean_v3/coastal/coastal_propagation_sample.gd")


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


func _initialize() -> void:
	# Banck gaussiano (misma geometría que la validación).
	var data = _make_data(129, 97, 1.0, func(x: int, z: int) -> float:
		var px := float(x - 64)
		var pz := float(z - 48)
		return 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0)))
	var eikonal = EikonalBakerScript.new()
	eikonal.bathymetry_data = data
	eikonal.incoming_direction_xz = Vector2.RIGHT
	eikonal.reference_wavelength_m = 16.0
	eikonal.min_valid_depth_m = 0.25
	var propagation = eikonal.bake()
	var warp_baker = WarpBakerScript.new()
	var sample: CoastalPropagationSample = PropagationSampleScript.new()
	var origin: Vector2 = propagation.world_origin_xz
	var cell: float = propagation.cell_size_m
	var width: int = propagation.width
	var height: int = propagation.height

	var max_angle_deg := 0.0
	var mask_mismatch := 0
	var valid_old := 0
	var valid_new := 0
	var tested := 0
	var worst_info := ""
	for z in range(8, height - 8, 4):
		for x in range(8, width - 8, 4):
			tested += 1
			var grid_local := Vector2(float(x) + 0.3, float(z) + 0.7)
			var world := origin + grid_local * cell
			var s = propagation.sample_propagation(world, sample)
			var sd: Dictionary = warp_baker.debug_sample_direction(propagation, origin, cell, width, height, grid_local, sample)
			if s.valid:
				valid_old += 1
			if sd["valid"]:
				valid_new += 1
			if s.valid != bool(sd["valid"]):
				mask_mismatch += 1
				continue
			if not s.valid:
				continue
			var old_dir: Vector2 = s.local_direction_xz
			var new_dir: Vector2 = sd["dir"]
			# IMPORTANTE: Vector2.normalized() en float32 no da longitud exacta 1
			# (|v|~0.99999994); acos(dot) con esa longitud produce un ángulo
			# espurio ~0.028°. Renormalizar ambos antes de medir el ángulo real.
			var old_n := old_dir.normalized()
			var new_n := new_dir.normalized()
			var ang := rad_to_deg(acos(clampf(old_n.dot(new_n), -1.0, 1.0)))
			if ang > max_angle_deg:
				max_angle_deg = ang
				# Reproducir el bilinear EXACTO del sampler viejo (lerpf anidado).
				var gx := grid_local.x
				var gz := grid_local.y
				var x0n := mini(int(floor(gx)), width - 2)
				var z0n := mini(int(floor(gz)), height - 2)
				var txn := gx - float(x0n)
				var tzn := gz - float(z0n)
				var i00n := z0n * width + x0n
				var i10n := i00n + 1
				var i01n := i00n + width
				var i11n := i01n + 1
				var old_x: float = lerpf(lerpf(propagation.local_direction_x[i00n], propagation.local_direction_x[i10n], txn), lerpf(propagation.local_direction_x[i01n], propagation.local_direction_x[i11n], txn), tzn)
				var old_z: float = lerpf(lerpf(propagation.local_direction_z[i00n], propagation.local_direction_z[i10n], txn), lerpf(propagation.local_direction_z[i01n], propagation.local_direction_z[i11n], txn), tzn)
				var w00 := (1.0 - txn) * (1.0 - tzn)
				var w10 := txn * (1.0 - tzn)
				var w01 := (1.0 - txn) * tzn
				var w11 := txn * tzn
				var new_x: float = propagation.local_direction_x[i00n] * w00 + propagation.local_direction_x[i10n] * w10 + propagation.local_direction_x[i01n] * w01 + propagation.local_direction_x[i11n] * w11
				var new_z: float = propagation.local_direction_z[i00n] * w00 + propagation.local_direction_z[i10n] * w10 + propagation.local_direction_z[i01n] * w01 + propagation.local_direction_z[i11n] * w11
				worst_info = "g=" + str(grid_local) + " |od|=" + str(old_dir.length()) + " |nd|=" + str(new_dir.length()) + " dot=" + str(old_dir.dot(new_dir)) + " lx=" + str(old_x) + " lz=" + str(old_z) + " nx=" + str(new_x) + " nz=" + str(new_z) + " dx=" + str(old_x - new_x) + " dz=" + str(old_z - new_z)
	print("3B.2A SAMPLER tested=%d valid_old=%d valid_new=%d mask_mismatch=%d max_angle_deg=%.8f\n  worst: %s" % [tested, valid_old, valid_new, mask_mismatch, max_angle_deg, worst_info])
	var failures := 0
	if mask_mismatch != 0:
		failures += 1
		push_error("SAMPLER FAIL: mask mismatches")
	if max_angle_deg > 1.0e-4:
		failures += 1
		push_error("SAMPLER FAIL: angle error > 1e-4 deg")
	if failures == 0:
		print("PHASE_3B_2A_SAMPLER: PASS")
		quit(0)
	else:
		quit(1)

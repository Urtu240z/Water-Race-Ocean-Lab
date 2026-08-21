extends SceneTree
## Medición offline de 3B.2A: bake Eikonal + bake warp/backtrace + memoria.
## Grids: 129x97 @1m y región equivalente @0.5m (258x194).

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")

const REPS := 1


func _initialize() -> void:
	for res in [1.0]:
		var width := 129 if res == 1.0 else 258
		var height := 97 if res == 1.0 else 194
		var data = _make_gaussian_bank(width, height, res)
		var eikonal_times: Array[float] = []
		var warp_times: Array[float] = []
		var propagation = null
		var warp = null
		var warp_baker = null
		for _rep in REPS:
			var eikonal_baker = EikonalBakerScript.new()
			eikonal_baker.bathymetry_data = data
			eikonal_baker.incoming_direction_xz = Vector2.RIGHT
			eikonal_baker.reference_wavelength_m = 16.0
			var t0 := Time.get_ticks_usec()
			propagation = eikonal_baker.bake()
			eikonal_times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			warp_baker = WarpBakerScript.new()
			warp_baker.propagation = propagation
			warp_baker.backtrace_step_cells = 0.5
			t0 = Time.get_ticks_usec()
			warp = warp_baker.bake()
			warp_times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		eikonal_times.sort()
		warp_times.sort()
		var total := eikonal_times[REPS / 2] + warp_times[REPS / 2]
		print("3B.2A COST %dx%d@%.1fm eikonal_ms=%.3f warp_ms=%.3f total_ms=%.3f sweeps=%d prop_cpu=%d warp_cpu=%d valid=%d/%d" % [width, height, res, eikonal_times[REPS / 2], warp_times[REPS / 2], total, propagation.eikonal_sweeps, propagation.approximate_memory_bytes(), warp.approximate_memory_bytes(), warp.valid_mask.count(1), width * height])
		print("3B.2A PROFILE steps=%d sample_dir_us=%d (%.1f%%) integration_us=%d (%.1f%%) jacobian_us=%d (%.1f%%) total_us=%d | us_per_step=%.3f" % [warp_baker.diag_total_steps, warp_baker.diag_time_sample_direction_us, 100.0 * float(warp_baker.diag_time_sample_direction_us) / maxf(float(warp_baker.diag_time_total_us), 1.0), warp_baker.diag_time_integration_us, 100.0 * float(warp_baker.diag_time_integration_us) / maxf(float(warp_baker.diag_time_total_us), 1.0), warp_baker.diag_time_jacobian_us, 100.0 * float(warp_baker.diag_time_jacobian_us) / maxf(float(warp_baker.diag_time_total_us), 1.0), warp_baker.diag_time_total_us, float(warp_baker.diag_time_total_us) / maxf(float(warp_baker.diag_total_steps), 1.0)])
	quit(0)


func _make_gaussian_bank(width: int, height: int, cell: float):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = cell
	var count := width * height
	data.depth_m.resize(count); data.gradient_x.resize(count); data.gradient_z.resize(count); data.slope_magnitude.resize(count); data.land_water_mask.resize(count)
	for z in height:
		for x in width:
			var px := float(x) * cell - 64.0
			var pz := float(z) * cell - 48.0
			var index := z * width + x
			data.depth_m[index] = 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0))
			data.land_water_mask[index] = 1
	return data

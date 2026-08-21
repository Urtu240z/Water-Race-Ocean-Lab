extends SceneTree
## Medición offline del Fast Sweeping 3B.1: mismo grid 1 m que la validación.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")

const REPS := 3


func _initialize() -> void:
	var data = _make_gaussian_bank(129, 97)
	var times: Array[float] = []
	var propagation = null
	for _rep in REPS:
		var baker = EikonalBakerScript.new()
		baker.bathymetry_data = data
		baker.incoming_direction_xz = Vector2.RIGHT
		baker.reference_wavelength_m = 16.0
		var start := Time.get_ticks_usec()
		propagation = baker.bake()
		times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	times.sort()
	print("3B.1 EIKONAL_BUILD grid=%dx%d median_ms=%.3f sweeps=%d residual=%.8f cpu_bytes=%d gpu_bytes=%d" % [propagation.width, propagation.height, times[REPS / 2], propagation.eikonal_sweeps, propagation.eikonal_max_residual_rad_m, propagation.approximate_memory_bytes(), propagation.approximate_gpu_memory_bytes()])
	quit(0)


func _make_gaussian_bank(width: int, height: int):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
	var count := width * height
	data.depth_m.resize(count); data.gradient_x.resize(count); data.gradient_z.resize(count); data.slope_magnitude.resize(count); data.land_water_mask.resize(count)
	for z in height:
		for x in width:
			var px := float(x - width / 2)
			var pz := float(z - height / 2)
			var index := z * width + x
			data.depth_m[index] = 18.0 - 17.5 * exp(-(px * px / 900.0 + pz * pz / 1800.0))
			data.land_water_mask[index] = 1
	return data

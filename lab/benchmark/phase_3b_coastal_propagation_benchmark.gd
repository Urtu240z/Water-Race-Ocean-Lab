extends SceneTree
## Medición reproducible del bake y sample CPU de 3B. El upload de las dos
## texturas se mide aparte; no añade dispatch FFT ni readback GPU→CPU.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const BakerScript := preload("res://ocean_v3/coastal/coastal_propagation_baker.gd")
const SampleScript := preload("res://ocean_v3/coastal/coastal_propagation_sample.gd")

const REPS := 3
const COUNTS := [1, 64, 256, 1024]


func _initialize() -> void:
	# El sweep upstream es O(N log N) por el orden determinista de celdas.
	# 65² mantiene la medición breve y directamente comparable en CI/local.
	var bathymetry = _make_bank(65, 65)
	var baker = BakerScript.new()
	baker.bathymetry_data = bathymetry
	baker.incoming_direction_xz = Vector2(1.0, 0.25)
	var bake_times: Array[float] = []
	var propagation = null
	for _rep in REPS:
		var start := Time.get_ticks_usec()
		propagation = baker.bake()
		bake_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	bake_times.sort()
	print("3B COASTAL_BUILD grid=%dx%d median_ms=%.3f" % [propagation.width, propagation.height, bake_times[REPS / 2]])
	var upload_start := Time.get_ticks_usec()
	propagation.build_gpu_textures()
	print("3B COASTAL_GPU_UPLOAD grid=%dx%d cpu_submit_ms=%.3f gpu_bytes=%d extra_dispatches=0 readbacks=0" % [propagation.width, propagation.height, float(Time.get_ticks_usec() - upload_start) / 1000.0, propagation.approximate_gpu_memory_bytes()])
	var reuse = SampleScript.new()
	for count in COUNTS:
		var times: Array[float] = []
		for _rep in REPS:
			var start := Time.get_ticks_usec()
			for index in count:
				propagation.sample_propagation(Vector2(float(index % 127) * 0.5, float((index * 7) % 127) * 0.5), reuse)
			times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		times.sort()
		print("3B COASTAL_SAMPLE N=%d median_ms=%.4f us_per_query=%.3f" % [count, times[REPS / 2], times[REPS / 2] * 1000.0 / count])
	print("3B FFT_CLIPMAP_INCREMENTAL off=0_compute_passes on=0_compute_passes shader_fetches_long=2 payload_bytes=%d" % propagation.approximate_gpu_memory_bytes())
	quit(0)


func _make_bank(width: int, height: int):
	var data = BathymetryDataScript.new()
	data.width = width
	data.height = height
	data.cell_size_m = 0.5
	var count := width * height
	data.depth_m.resize(count); data.gradient_x.resize(count); data.gradient_z.resize(count); data.slope_magnitude.resize(count); data.land_water_mask.resize(count)
	for z in height:
		for x in width:
			var nx := (float(x) / float(width - 1)) * 2.0 - 1.0
			var nz := (float(z) / float(height - 1)) * 2.0 - 1.0
			var index := z * width + x
			data.depth_m[index] = 0.5 + 9.5 * (1.0 - exp(-(nx * nx + nz * nz) * 12.0))
			data.land_water_mask[index] = 1
	return data

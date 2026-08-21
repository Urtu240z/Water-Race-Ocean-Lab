extends SceneTree
## Coste de consulta BathymetryData sin geometría ni raycasts.

const Factory := preload("res://lab/bathymetry/bathymetry_case_factory.gd")
const BakerScript := preload("res://ocean_v3/bathymetry/bathymetry_baker.gd")
const SampleScript := preload("res://ocean_v3/bathymetry/bathymetry_sample.gd")
const COUNTS := [1, 16, 64, 256, 1024, 10000]
const REPS := 9
const BAKE_REPS := 1 # offline O(celdas×triángulos); una medición basta en 3A.


func _initialize() -> void:
	var source := Factory.make_submerged_bank()
	var baker = BakerScript.new()
	baker.source = source
	baker.cell_size_m = 1.0
	var bake_times: Array[float] = []
	var data = null
	for rep in BAKE_REPS:
		var start := Time.get_ticks_usec()
		data = baker.bake()
		bake_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	bake_times.sort()
	print("3A BATHY_BAKE BANK grid=%dx%d faces=%d median_ms=%.3f" % [data.width, data.height, source.mesh.get_faces().size() / 3, bake_times[BAKE_REPS / 2]])
	var reuse = SampleScript.new()
	for count in COUNTS:
		var times: Array[float] = []
		for rep in REPS:
			var start := Time.get_ticks_usec()
			for i in count:
				data.sample_bathymetry(Vector2(8.0 + float(i % 97) * 0.31, -12.0 + float(i % 53) * 0.27), reuse)
			times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		times.sort()
		print("3A BATHY_QUERY N=%d median_ms=%.4f us_per_query=%.3f" % [count, times[REPS / 2], times[REPS / 2] * 1000.0 / count])
	for size in [256, 512, 1024]:
		var bytes = size * size * 18
		print("3A BATHY_MEMORY %dx%d bytes=%d MiB=%.2f" % [size, size, bytes, float(bytes) / (1024.0 * 1024.0)])
	source.free()
	baker.free()
	quit(0)

extends SceneTree
## Diagnóstico: cuánto tarda rebuild_coastal_propagation con warp en 257x129.

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")
const EikonalBakerScript := preload("res://ocean_v3/coastal/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://ocean_v3/coastal/coastal_warp_baker.gd")


func _initialize() -> void:
	var data = BathymetryDataScript.new()
	data.world_origin_xz = Vector2(-128.0, -64.0)
	data.width = 257
	data.height = 129
	data.cell_size_m = 1.0
	var count := 257 * 129
	data.depth_m.resize(count); data.gradient_x.resize(count); data.gradient_z.resize(count); data.slope_magnitude.resize(count); data.land_water_mask.resize(count)
	for z in 129:
		for x in 257:
			var index := z * 257 + x
			var wx := -128.0 + float(x)
			var wz := -64.0 + float(z)
			data.depth_m[index] = 18.0 - 17.5 * exp(-(wx * wx / 900.0 + wz * wz / 1800.0))
			data.land_water_mask[index] = 1
	var t0 := Time.get_ticks_usec()
	var eb = EikonalBakerScript.new()
	eb.bathymetry_data = data
	eb.incoming_direction_xz = Vector2.RIGHT
	eb.reference_wavelength_m = 16.0
	var prop = eb.bake()
	print("257x129 eikonal_ms=", (Time.get_ticks_usec() - t0) / 1000.0)
	t0 = Time.get_ticks_usec()
	var wb = WarpBakerScript.new()
	wb.propagation = prop
	wb.backtrace_step_cells = 0.5
	var warp = wb.bake()
	print("257x129 warp_ms=", (Time.get_ticks_usec() - t0) / 1000.0, " valid=", warp.valid_mask.count(1))
	quit(0)

extends Node
## VerificaciÃ³n de render 3B.2B como ESCENA (el renderer D3D12 no se inicializa
## bien con SceneTree --script). Ejecutar: godot --path . --scene res://lab/coastal/phase_3b_2b_pixel_scene.tscn

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

var _ocean = null
var _demo = null
var _phase := 0
var _frames := 0
var _results: Dictionary = {}
var _log_path := "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/pixel_scene_abs_log.txt"
var _log_lines: Array[String] = []


func _ready() -> void:
	var scene: PackedScene = load("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
	_demo = scene.instantiate()
	add_child(_demo)
	_ocean = _demo.get_node("OceanV3/OpenOceanFFT")
	var grazing: Camera3D = _demo.get_node("GrazingCamera")
	grazing.make_current()
	# NO pausar aquí: el FFT debe despachar al menos una vez para que las
	# texturas de desplazamiento existan. Se pausa tras el warmup (fase 0).
	_log("inicio: demo instanciada (tiempo corriendo hasta primer dispatch)")


func _process(_delta: float) -> void:
	_frames += 1
	match _phase:
		0:
			if _frames > 90:
				# Warmup con tiempo corriendo: el FFT ya despachó y las texturas
				# LONG/MID/SHORT tienen datos. Congelar AHORA para que OFF/ON se
				# comparen en el mismo instante de simulación.
				SimulationClock.set_paused(true)
				_phase = 1
				_frames = 0
				_log("tiempo congelado tras warmup; capturando BANCO OFF...")
		1:
			if _frames == 30:
				_results["bank_off"] = _grab()
				_phase = 2
				_frames = 0
				_log("horneando warp (banco)...")
				_ocean.coastal_propagation_enabled = true
				_ocean.coastal_eikonal_refraction_debug = true
				_ocean.coastal_warp_enabled = true
				_ocean.rebuild_coastal_propagation()
		2:
			if _ocean.coastal_warp_data() != null and _frames > 90:
				# Diagnóstico de uniforms y fade.
				var surface = _demo.get_node("OceanV3/OpenOceanFFT/OceanClipmapSurface")
				var mat: ShaderMaterial = surface.get("_surface_material")
				_log("uniforms warp_enabled=" + str(mat.get_shader_parameter("coastal_warp_enabled")) + " transform=" + str(mat.get_shader_parameter("coastal_transform_enabled")) + " prop=" + str(mat.get_shader_parameter("coastal_propagation_enabled")) + " long_fade=" + str(mat.get_shader_parameter("long_fade_range_m")))
				var warp = _ocean.coastal_warp_data()
				var s = warp.sample_warp(Vector2(10.0, 0.0))
				_log("warp_sample(10,0) deep=" + str(s.deep_xz) + " detJ=" + str(s.jacobian_det) + " valid=" + str(s.valid))
				_phase = 3
				_frames = 0
				_log("capturando BANCO ON...")
		3:
			if _frames == 30:
				_results["bank_on"] = _grab()
				_ocean.coastal_bathymetry_data = _make_flat()
				_ocean.coastal_propagation_enabled = false
				_ocean.rebuild_coastal_propagation()
				_phase = 4
				_frames = 0
				_log("capturando FLAT OFF...")
		4:
			if _frames == 30:
				_results["flat_off"] = _grab()
				_phase = 5
				_frames = 0
				_log("horneando warp flat...")
				_ocean.coastal_propagation_enabled = true
				_ocean.rebuild_coastal_propagation()
		5:
			if _ocean.coastal_warp_data() != null and _frames > 90:
				_phase = 6
				_frames = 0
				_log("capturando FLAT ON...")
		6:
			if _frames == 30:
				_results["flat_on"] = _grab()
				_report()
				get_tree().quit(0)


func _make_flat():
	var data = BathymetryDataScript.new()
	data.world_origin_xz = Vector2(-64.0, -48.0)
	data.width = 129
	data.height = 97
	data.cell_size_m = 1.0
	data.sea_level_y = 0.0
	var count := 129 * 97
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for i in count:
		data.depth_m[i] = 100.0
		data.land_water_mask[i] = 1
	return data


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _log(msg: String) -> void:
	_log_lines.append(msg)
	print(msg)


func _flush_log() -> void:
	var f := FileAccess.open(_log_path, FileAccess.WRITE)
	if f != null:
		for line in _log_lines:
			f.store_line(line)
		f.close()


func _report() -> void:
	var bank_diff := _diff(_results["bank_off"], _results["bank_on"])
	var flat_diff := _diff(_results["flat_off"], _results["flat_on"])
	_results["bank_off"].save_png("res://lab/coastal/cap_bank_off.png")
	_results["bank_on"].save_png("res://lab/coastal/cap_bank_on.png")
	_results["flat_off"].save_png("res://lab/coastal/cap_flat_off.png")
	_results["flat_on"].save_png("res://lab/coastal/cap_flat_on.png")
	var variance := _spatial_variance(_results["bank_off"])
	var variance_flat := _spatial_variance(_results["flat_off"])
	_log("bank_off_vs_on mean_abs=" + str(bank_diff[0]) + " max_abs=" + str(bank_diff[1]) + " pct_changed=" + str(bank_diff[2]) + "%")
	_log("flat_off_vs_on mean_abs=" + str(flat_diff[0]) + " max_abs=" + str(flat_diff[1]) + " pct_changed=" + str(flat_diff[2]) + "%")
	_log("sanity: varianza_banco=" + str(variance) + " varianza_flat=" + str(variance_flat))
	var failures := 0
	if variance < 0.001:
		failures += 1
		_log("FAIL: el ocÃ©ano parece plano (sin ondas; FFT no renderiza)")
	if bank_diff[2] < 0.05:
		failures += 1
		_log("FAIL: el banco no cambia con Coastal ON (<0.05% pÃ­xeles)")
	if flat_diff[2] > 0.5 or flat_diff[0] > 0.02:
		failures += 1
		_log("FAIL: flat cambia artificialmente con Coastal ON")
	if failures == 0:
		_log("PIXEL_SCENE: PASS")
	else:
		_log("PIXEL_SCENE: %d FAIL" % failures)
	_flush_log()


func _diff(a: Image, b: Image) -> Array:
	var w := mini(a.get_width(), b.get_width())
	var h := mini(a.get_height(), b.get_height())
	var sum := 0.0
	var maxv := 0.0
	var changed := 0
	var total := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			sum += d
			maxv = maxf(maxv, d)
			if d > 0.02:
				changed += 1
			total += 1
	return [sum / float(total), maxv, 100.0 * float(changed) / float(total)]


func _spatial_variance(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var sum := 0.0
	var sum2 := 0.0
	var n := 0
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c := img.get_pixel(x, y)
			var lum := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			sum += lum
			sum2 += lum * lum
			n += 1
	var mean := sum / float(n)
	return maxf(sum2 / float(n) - mean * mean, 0.0)





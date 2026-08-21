extends SceneTree
## VerificaciÃ³n cuantitativa del render 3B.2B (sin inspecciÃ³n visual manual):
## captura frames con Coastal OFF/ON sobre BANCO y sobre FLAT, y compara
## pÃ­xeles. Esperado:
##  - BANCO: OFF vs ON difieren (el warp modifica LONG_COASTAL sobre el banco).
##  - FLAT: OFF vs ON prÃ¡cticamente iguales (warp identidad; errores de muestreo
##    de textura de una cascada extra ~0, acotados).

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

var _ocean = null
var _demo = null
var _phase := 0
var _frames := 0
var _results: Dictionary = {}


func _initialize() -> void:
	root.size = Vector2i(960, 540)
	DisplayServer.window_set_size(Vector2i(960, 540))
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Cargar la demo como ESCENA PRINCIPAL: solo asÃ­ el SceneTree renderiza de
	# verdad (en --script puro el viewport no dibuja el ocÃ©ano).
	var scene: PackedScene = load("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
	change_scene_to_file("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
	_log("3B.2B PIXEL: escena cambiada...")
	_frames = 0


var _wait_scene := 0


func _process(_delta: float) -> bool:
	if _demo == null and current_scene != null:
		_demo = current_scene
		_ocean = _demo.get_node("OceanV3/OpenOceanFFT")
		var grazing: Camera3D = _demo.get_node("GrazingCamera")
		grazing.make_current()
		# Congelar el tiempo de simulaciÃ³n: OFF y ON deben compararse en el MISMO
		# instante para aislar el efecto del warp (si no, la animaciÃ³n contamina).
		var clock = root.get_node_or_null("/root/SimulationClock")
		if clock != null:
			clock.call("set_paused", true)
		_log("3B.2B PIXEL: demo lista, cÃ¡mara GRAZING, tiempo congelado")
		return false
	if _ocean == null:
		_frames += 1
		return false
	_frames += 1
	match _phase:
		0: # esperar cascades + warmup, luego capturar BANCO OFF
			if _frames > 90:
				_phase = 1
				_frames = 0
				_log("3B.2B PIXEL: capturando BANCO OFF...")
		1:
			if _frames == 30:
				_results["bank_off"] = _grab()
				_phase = 2
				_frames = 0
				_log("3B.2B PIXEL: horneando warp (banco)...")
				_ocean.coastal_propagation_enabled = true
				_ocean.coastal_eikonal_refraction_debug = true
				_ocean.coastal_warp_enabled = true
				_ocean.rebuild_coastal_propagation()
		2: # capturar BANCO ON tras bake + warmup
			if _ocean.coastal_warp_data() != null and _frames > 90:
				var surface = _demo.get_node("OceanV3/OpenOceanFFT/OceanClipmapSurface")
				var mat: ShaderMaterial = surface.get("_surface_material")
				print("3B.2B PIXEL uniforms warp_enabled=", mat.get_shader_parameter("coastal_warp_enabled"), " transform=", mat.get_shader_parameter("coastal_transform_enabled"), " prop=", mat.get_shader_parameter("coastal_propagation_enabled"), " warp_tex=", mat.get_shader_parameter("coastal_warp_texture") != null)
				var warp = _ocean.coastal_warp_data()
				var s = warp.sample_warp(Vector2(10.0, 0.0))
				print("3B.2B PIXEL warp_sample(10,0) deep=", s.deep_xz, " detJ=", s.jacobian_det, " valid=", s.valid)
				# Verificar que el render RESPONDE al tiempo: capturar dos frames
				# con tiempo simulado distinto (el FFT debe animar).
				_phase = 3
				_frames = 0
				_log("3B.2B PIXEL: capturando BANCO ON (t0)...")
		3:
			if _frames == 30:
				_results["bank_on"] = _grab()
				# Tiempo congelado: sin avance; pasar a flat OFF.
				_ocean.coastal_bathymetry_data = _make_flat()
				_ocean.coastal_propagation_enabled = false
				_ocean.rebuild_coastal_propagation()
				_phase = 4
				_frames = 0
				_log("3B.2B PIXEL: capturando FLAT OFF...")
		4:
			if _frames == 30:
				_results["flat_off"] = _grab()
				_phase = 5
				_frames = 0
				_log("3B.2B PIXEL: horneando warp flat...")
				_ocean.coastal_propagation_enabled = true
				_ocean.rebuild_coastal_propagation()
		5:
			if _ocean.coastal_warp_data() != null and _frames > 90:
				_phase = 6
				_frames = 0
				_log("3B.2B PIXEL: capturando FLAT ON...")
		6:
			if _frames == 30:
				_results["flat_on"] = _grab()
				_report()
				quit(0)
	return false


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
	return root.get_texture().get_image()


func _log(msg: String) -> void:
	var f := FileAccess.open("res://lab/coastal/pixel_check_log.txt", FileAccess.WRITE)
	if f != null:
		f.store_line(msg)
		f.close()
	print(msg)
	var bank_diff := _diff(_results["bank_off"], _results["bank_on"])
	var flat_diff := _diff(_results["flat_off"], _results["flat_on"])
	# Guardar capturas para inspecciÃ³n y verificar que el render cambia con el tiempo.
	_results["bank_off"].save_png("res://lab/coastal/cap_bank_off.png")
	_results["bank_on"].save_png("res://lab/coastal/cap_bank_on.png")
	_results["flat_off"].save_png("res://lab/coastal/cap_flat_off.png")
	_results["flat_on"].save_png("res://lab/coastal/cap_flat_on.png")
	# Sanity: Â¿el ocÃ©ano tiene ondas? Varianza espacial de la captura OFF.
	var variance := _spatial_variance(_results["bank_off"])
	var variance_flat := _spatial_variance(_results["flat_off"])
	print("3B.2B PIXEL bank_off_vs_on mean_abs=" + str(bank_diff[0]) + " max_abs=" + str(bank_diff[1]) + " pct_changed=" + str(bank_diff[2]) + "%")
	print("3B.2B PIXEL flat_off_vs_on mean_abs=" + str(flat_diff[0]) + " max_abs=" + str(flat_diff[1]) + " pct_changed=" + str(flat_diff[2]) + "%")
	print("3B.2B PIXEL sanity: varianza_banco=" + str(variance) + " varianza_flat=" + str(variance_flat))
	var failures := 0
	if variance < 0.001:
		failures += 1
		push_error("PIXEL FAIL: el ocÃ©ano parece plano (sin ondas; FFT no renderiza)")
	# Con tiempo congelado, el banco DEBE cambiar con Coastal ON (warp activo) y
	# el flat NO debe cambiar (warp identidad). Umbral generoso: el banco mueve
	# olas de 16 m en crestas -> cientos de pÃ­xeles; el flat solo ruido de
	# muestreo de la cascada extra.
	if bank_diff[2] < 0.05:
		failures += 1
		push_error("PIXEL FAIL: el banco no cambia con Coastal ON (<0.05% pÃ­xeles)")
	if flat_diff[2] > 0.5 or flat_diff[0] > 0.02:
		failures += 1
		push_error("PIXEL FAIL: flat cambia artificialmente con Coastal ON (mean_abs=" + str(flat_diff[0]) + " pct=" + str(flat_diff[2]) + "%)")
	quit(0 if failures == 0 else 1)


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


func _diff(a: Image, b: Image) -> Array:
	var wa := a.get_width()
	var ha := a.get_height()
	var wb := b.get_width()
	var hb := b.get_height()
	var w := mini(wa, wb)
	var h := mini(ha, hb)
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


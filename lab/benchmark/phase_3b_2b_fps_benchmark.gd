extends SceneTree
## Benchmark de Fase 3B.2B: FPS en RACE 1080p comparando:
##   B. split LONG COASTAL/REMAINDER + MID + SHORT, Coastal OFF.
##   C. split, Coastal ON (warp activo).
## Ejecutar CON ventana (no --headless): mide el render real.
## El bake del warp usa un subgrid 129x97 (~8 s) para no penalizar la medición
## de FPS (el bake es offline y no depende del grid de la demo 257x129).
## Uso: godot --path . --script res://lab/benchmark/phase_3b_2b_fps_benchmark.gd

const BathymetryDataScript := preload("res://ocean_v3/bathymetry/bathymetry_data.gd")

const WARMUP_FRAMES := 120
const MEASURE_FRAMES := 240

var _ocean = null
var _demo = null
var _frames := 0
var _phase := 0 # 0=warmup OFF, 1=measure OFF, 2=warmup ON, 3=measure ON
var _offs: Array = []
var _ons: Array = []


func _initialize() -> void:
	# Resolución 1080p sin VSync.
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Cargar la demo 3B.2B.
	var scene: PackedScene = load("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
	_demo = scene.instantiate()
	root.add_child(_demo)
	_ocean = _demo.get_node("OceanV3/OpenOceanFFT")
	# Sustituir la bathymetry de la demo por un subgrid 129x97 (bake ~8 s).
	var sub: Variant = _make_bank(129, 97, Vector2(-64.0, -48.0))
	_ocean.coastal_bathymetry_data = sub
	print("3B.2B FPS_BENCH: esperando cascade ready...")


func _make_bank(width: int, height: int, origin: Vector2):
	var data = BathymetryDataScript.new()
	data.world_origin_xz = origin
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
	data.sea_level_y = 0.0
	var count := width * height
	data.depth_m.resize(count)
	data.gradient_x.resize(count)
	data.gradient_z.resize(count)
	data.slope_magnitude.resize(count)
	data.land_water_mask.resize(count)
	for z in height:
		for x in width:
			var index := z * width + x
			var wx := origin.x + float(x)
			var wz := origin.y + float(z)
			data.depth_m[index] = 18.0 - 17.5 * exp(-(wx * wx / 900.0 + wz * wz / 1800.0))
			data.land_water_mask[index] = 1
	return data


func _process(delta: float) -> bool:
	if _ocean == null:
		return false
	if _frames == 0:
		# Primer frame: Coastal OFF para la primera medición (split sin warp).
		if not _ocean.coastal_propagation_enabled:
			_ocean.coastal_propagation_enabled = false
			_ocean.rebuild_coastal_propagation()
	_frames += 1
	match _phase:
		0:
			var ready := true
			for cascade in _ocean.get("_cascades"):
				if not cascade["solver"].ready:
					ready = false
					break
			if ready and _frames > WARMUP_FRAMES:
				_phase = 1
				_frames = 0
				print("3B.2B FPS_BENCH: midiendo COASTAL OFF...")
		1:
			_measure(delta)
			if _frames >= MEASURE_FRAMES:
				_offs = _stats("COASTAL OFF (split, sin warp)")
				print("3B.2B FPS_BENCH: horneando warp (Coastal ON)...")
				var t_bake := Time.get_ticks_usec()
				_ocean.coastal_propagation_enabled = true
				_ocean.coastal_eikonal_refraction_debug = true
				_ocean.coastal_warp_enabled = true
				_ocean.rebuild_coastal_propagation()
				print("3B.2B FPS_BENCH: bake done en %.1f s, warp=" % ((Time.get_ticks_usec() - t_bake) / 1000.0 / 1000.0), _ocean.coastal_warp_data() != null)
				_phase = 2
				_frames = 0
		2:
			if _ocean.coastal_warp_data() != null and _frames > WARMUP_FRAMES:
				_phase = 3
				_frames = 0
				print("3B.2B FPS_BENCH: midiendo COASTAL ON...")
		3:
			_measure(delta)
			if _frames >= MEASURE_FRAMES:
				_ons = _stats("COASTAL ON (warp activo)")
				_report()
				quit(0)
	return false


var _frame_times: Array = []


func _measure(delta: float) -> void:
	_frame_times.append(delta)


func _stats(label: String) -> Array:
	var sorted := _frame_times.duplicate()
	sorted.sort()
	var median_ms: float = sorted[int(sorted.size() / 2)] * 1000.0
	var p95_ms: float = sorted[int(0.95 * float(sorted.size() - 1))] * 1000.0
	print("3B.2B FPS_BENCH %s: frame_median=%.2f ms FPS=%.1f | P95=%.2f ms" % [label, median_ms, 1000.0 / maxf(median_ms, 0.001), p95_ms])
	_frame_times.clear()
	return [median_ms, p95_ms]


func _report() -> void:
	print("=== 3B.2B FPS RESULT ===")
	print("COASTAL OFF: %.2f ms (%.1f FPS)" % [_offs[0], 1000.0 / maxf(_offs[0], 0.001)])
	print("COASTAL ON : %.2f ms (%.1f FPS)" % [_ons[0], 1000.0 / maxf(_ons[0], 0.001)])
	print("overhead ON vs OFF: %.2f ms" % (_ons[0] - _offs[0]))

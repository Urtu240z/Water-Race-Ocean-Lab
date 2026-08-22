extends Node
## Phase 4A: comparación renderizada 1080p RACE, sin readbacks.
## Mide frame time presentado (CPU+GPU), porque Godot no expone un GPU timer
## portable aquí. No se usa para atribuir exclusivamente GPU sin profiler externo.

const DEMO_SCENE := preload("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 300

var _demo: Node
var _state := 0
var _frames := 0
var _samples: PackedFloat32Array = PackedFloat32Array()
var _off: Dictionary = {}


func _ready() -> void:
	get_window().title = "Phase 4A Pre-break Frame Benchmark"
	# El proyecto usa 0.7 global para desarrollo; este benchmark fuerza el buffer
	# 3D nativo de la ventana 1920x1080 para que la comparación sea 1080p real.
	get_viewport().scaling_3d_scale = 1.0
	_demo = DEMO_SCENE.instantiate()
	add_child(_demo)


func _process(delta: float) -> void:
	if _demo == null:
		return
	var ocean = _demo.get_node_or_null("OceanV3/OpenOceanFFT")
	if ocean == null or ocean.coastal_warp_data() == null:
		return # espera sólo al bake estático; nunca sincroniza GPU->CPU.
	_frames += 1
	if _state == 0:
		if _frames >= WARMUP_FRAMES:
			_begin_sample(0)
			_state = 1
		return
	_samples.append(delta * 1000.0)
	if _samples.size() < SAMPLE_FRAMES:
		return
	var result := _stats(_samples)
	if _state == 1:
		_off = result
		ocean.set_breaking_debug(4) # PREBREAK, ruta extra de fetches activa.
		_begin_sample(0)
		_state = 2
		return
	var difference: float = result["median_ms"] - _off["median_ms"]
	print("PHASE_4A_RENDER_FRAME_BENCH 1080p RACE: OFF median=%.3f p95=%.3f | PREBREAK median=%.3f p95=%.3f | delta=%.3f ms" % [_off["median_ms"], _off["p95_ms"], result["median_ms"], result["p95_ms"], difference])
	print("PHASE_4A_RENDER_FRAME_BENCH: frame-time proxy only; verify isolated GPU cost in GPU profiler before accepting >0.5 ms threshold.")
	get_tree().quit(0)


func _begin_sample(_unused: int) -> void:
	_frames = 0
	_samples.clear()


func _stats(samples: PackedFloat32Array) -> Dictionary:
	var sorted: Array[float] = []
	for sample in samples:
		sorted.append(sample)
	sorted.sort()
	return {
		"median_ms": sorted[sorted.size() / 2],
		"p95_ms": sorted[int(floor(float(sorted.size() - 1) * 0.95))],
	}

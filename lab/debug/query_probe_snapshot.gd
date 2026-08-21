extends Node3D
## Tool de laboratorio: snapshot de probes cuya Y proviene de la query CPU
## reference, para comparar visualmente con la superficie GPU.
##
## Uso: tecla Y -> coloca 9 probes en una cuadrícula alrededor de la cámara
## usando el tiempo de render actual (pausa con P para comparación exacta).
## Otra Y -> limpia los probes. No forma parte de ocean_v3 core.

const PROBE_OFFSETS: Array[Vector2] = [
	Vector2(0, 0),
	Vector2(-8, 0), Vector2(8, 0),
	Vector2(0, -8), Vector2(0, 8),
	Vector2(-8, -8), Vector2(8, -8),
	Vector2(-8, 8), Vector2(8, 8),
]
const GOLDEN_OFFSETS: Array[Vector2] = [
	Vector2(0, 0),
	Vector2(-4, 4),
	Vector2(4, -4),
]

var _probes: Array[MeshInstance3D] = []
var _golden_probes: Array[MeshInstance3D] = []
var _enabled := false


func _ready() -> void:
	add_to_group(&"query_probes")


func toggle_snapshot() -> void:
	if _enabled:
		_clear()
	else:
		_snapshot()


func is_enabled() -> bool:
	return _enabled


func _snapshot() -> void:
	var module := get_tree().get_first_node_in_group(&"ocean_fft")
	if module == null or not module.has_method(&"sample_water"):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	# Tiempo de render para coincidir con la superficie mostrada en pantalla;
	# con la simulación pausada la comparación es exacta.
	var time: float = SimulationClock.get_render_time()
	var center := Vector2(camera.global_position.x, camera.global_position.z)
	module.prepare_query_time(time)
	_clear()
	# Probes REDUCED (cyan): query de producción world-space.
	for offset in PROBE_OFFSETS:
		var world := Vector3(center.x + offset.x, 0.0, center.y + offset.y)
		var sample = module.sample_water_prepared(world)
		# La query es WORLD-SPACE: la esfera se coloca en el XZ pedido con la
		# altura absoluta de la superficie en ese punto. Los probes se mantienen
		# dentro del radio donde LONG/MID/SHORT tienen peso visual 1.0 (<= 8 m)
		# y donde la malla L0 es densa.
		if sample.valid:
			_spawn_probe(Vector3(world.x, sample.height, world.z), Color(0.2, 0.9, 1.0), false)
	# Probes GOLDEN (naranja) sólo en 3 puntos, cuando el debug está activo.
	if module.has_method(&"has_golden_reference") and module.has_golden_reference():
		module.prepare_golden_time(time)
		for offset in GOLDEN_OFFSETS:
			var world := Vector3(center.x + offset.x, 0.0, center.y + offset.y)
			var sample = module.sample_water_golden_prepared(world)
			if sample.valid:
				_spawn_probe(Vector3(world.x, sample.height, world.z), Color(1.0, 0.35, 0.08), true)
	_enabled = true


func _spawn_probe(position: Vector3, color: Color, is_golden: bool) -> void:
	var probe := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.18
	mesh.height = 0.36
	probe.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	probe.material_override = material
	probe.position = position
	add_child(probe)
	if is_golden:
		_golden_probes.append(probe)
	else:
		_probes.append(probe)


func _clear() -> void:
	for probe in _probes:
		probe.queue_free()
	_probes.clear()
	for probe in _golden_probes:
		probe.queue_free()
	_golden_probes.clear()
	_enabled = false

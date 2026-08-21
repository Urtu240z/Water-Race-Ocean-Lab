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

var _probes: Array[MeshInstance3D] = []
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
	for offset in PROBE_OFFSETS:
		var world := Vector3(center.x + offset.x, 0.0, center.y + offset.y)
		var sample = module.sample_water_prepared(world)
		_spawn_probe(Vector3(world.x, sample.height, world.z))
	_enabled = true


func _spawn_probe(position: Vector3) -> void:
	var probe := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.18
	mesh.height = 0.36
	probe.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.35, 0.08)
	probe.material_override = material
	probe.position = position
	add_child(probe)
	_probes.append(probe)


func _clear() -> void:
	for probe in _probes:
		probe.queue_free()
	_probes.clear()
	_enabled = false

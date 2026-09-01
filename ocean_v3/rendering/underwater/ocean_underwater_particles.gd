@tool
class_name OceanUnderwaterParticles
extends Node3D

## Camera-local suspended particles for the underwater medium. This component
## owns only presentation; AIR/UNDERWATER activation is supplied by OceanV3.

const PROCESS_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_underwater_particles_process.gdshader"
const RENDER_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_underwater_particles.gdshader"
const VOLUME_EXTENTS := Vector3(12.0, 6.0, 12.0)
const VISIBILITY_AABB := AABB(Vector3(-18.0, -10.0, -18.0), Vector3(36.0, 20.0, 36.0))
const PARTICLE_LIFETIME_S := 22.0
const MAX_CAMERA_SPEED_MPS := 35.0

@export_group("Underwater / Suspended Particles")
@export var underwater_particles_enabled := true
@export_range(800, 1200, 10) var underwater_particles_fine_amount := 1000:
	set(value):
		underwater_particles_fine_amount = clampi(value, 800, 1200)
		_queue_rebuild()
@export_range(80, 200, 10) var underwater_particles_near_amount := 140:
	set(value):
		underwater_particles_near_amount = clampi(value, 80, 200)
		_queue_rebuild()
@export_range(0.0, 2.0, 0.05) var underwater_particles_fine_strength := 1.0
@export_range(0.0, 2.0, 0.05) var underwater_particles_near_strength := 1.0
@export_range(0.0, 0.25, 0.005, "suffix: m/s") var underwater_particles_drift_speed := 0.05
@export_range(0.0, 0.5, 0.01) var underwater_particles_velocity_influence := 0.15
@export_range(8.0, 24.0, 0.5, "suffix: m") var underwater_particles_far_distance_m := 18.0
@export var particles_debug := false

var _fine_particles: GPUParticles3D
var _near_particles: GPUParticles3D
var _fine_process_material: ShaderMaterial
var _near_process_material: ShaderMaterial
var _fine_render_material: ShaderMaterial
var _near_render_material: ShaderMaterial
var _process_shader: Shader
var _render_shader: Shader
var _underwater := false
var _camera: Camera3D
var _last_camera_position := Vector3.ZERO
var _camera_velocity := Vector3.ZERO
var _has_camera_sample := false
var _rebuild_pending := false
var _applied_fine_amount := -1
var _applied_near_amount := -1
var _benchmark_fine_enabled := true
var _benchmark_near_enabled := true
var _last_fine_enabled := false
var _last_near_enabled := false
var _last_debug := false


func _ready() -> void:
	# Only translation follows the active camera. Rotation is intentionally not
	# inherited so the layer cannot look like a HUD glued to the lens.
	top_level = true
	if not Engine.is_editor_hint():
		_ensure_particles()
		_apply_state(false)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var active_camera := get_viewport().get_camera_3d()
	if active_camera == null:
		_apply_state(false)
		return
	if active_camera != _camera:
		_camera = active_camera
		_last_camera_position = active_camera.global_position
		_camera_velocity = Vector3.ZERO
		_has_camera_sample = true
	else:
		var delta := get_process_delta_time()
		if _has_camera_sample and delta > 0.00001:
			_camera_velocity = (active_camera.global_position - _last_camera_position) / delta
			if _camera_velocity.length() > MAX_CAMERA_SPEED_MPS:
				_camera_velocity = _camera_velocity.normalized() * MAX_CAMERA_SPEED_MPS
		_last_camera_position = active_camera.global_position
		_has_camera_sample = true

	# Moving the emitter does not restart or reseed either GPUParticles3D layer.
	# local_coords=false keeps already-emitted particles in world space while the
	# emission volume advances with the camera, preserving believable parallax.
	global_position = active_camera.global_position
	if _rebuild_pending:
		_rebuild_pending = false
		_last_debug = not particles_debug
		_configure_particles()
	_update_process_uniforms()
	_apply_state(_underwater)


func set_underwater_state(camera_underwater: bool) -> void:
	_underwater = camera_underwater
	if not Engine.is_editor_hint():
		_apply_state(_underwater)


func set_benchmark_layers(fine_enabled: bool, near_enabled: bool) -> void:
	## Benchmark-only gate. It does not alter authored counts or materials.
	_benchmark_fine_enabled = fine_enabled
	_benchmark_near_enabled = near_enabled
	if not Engine.is_editor_hint():
		_apply_state(_underwater)


func _queue_rebuild() -> void:
	_rebuild_pending = true


func _ensure_particles() -> void:
	if _fine_particles != null and is_instance_valid(_fine_particles):
		return
	_process_shader = load(PROCESS_SHADER_PATH) as Shader
	_render_shader = load(RENDER_SHADER_PATH) as Shader
	if _process_shader == null or _render_shader == null:
		push_error("OceanUnderwaterParticles: particle shaders could not be loaded.")
		return

	_fine_particles = _create_layer("FineParticles")
	_near_particles = _create_layer("NearParticles")
	add_child(_fine_particles)
	add_child(_near_particles)
	_fine_particles.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
	_near_particles.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
	_configure_particles()


func _create_layer(layer_name: String) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.lifetime = PARTICLE_LIFETIME_S
	particles.randomness = 0.35
	particles.local_coords = false
	particles.visibility_aabb = VISIBILITY_AABB
	particles.emitting = false
	particles.visible = false
	particles.draw_pass_1 = _create_quad()
	return particles


func _create_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	return quad


func _configure_particles() -> void:
	if _fine_particles == null or _near_particles == null:
		return
	_fine_particles.amount = underwater_particles_fine_amount
	_near_particles.amount = underwater_particles_near_amount
	_applied_fine_amount = underwater_particles_fine_amount
	_applied_near_amount = underwater_particles_near_amount

	_fine_process_material = _make_process_material(1.0, 0.005, 0.025, Vector3(0.008, 0.001, -0.006))
	_near_process_material = _make_process_material(17.0, 0.02, 0.07, Vector3(0.014, 0.003, -0.010))
	_fine_render_material = _make_render_material(Color(0.37, 0.58, 0.59, 0.032), underwater_particles_fine_strength)
	_near_render_material = _make_render_material(Color(0.40, 0.63, 0.62, 0.060), underwater_particles_near_strength)
	_fine_particles.process_material = _fine_process_material
	_near_particles.process_material = _near_process_material
	(_fine_particles.draw_pass_1 as QuadMesh).material = _fine_render_material
	(_near_particles.draw_pass_1 as QuadMesh).material = _near_render_material


func _make_process_material(layer_seed: float, size_min: float, size_max: float, current: Vector3) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _process_shader
	material.set_shader_parameter(&"emission_extents", VOLUME_EXTENTS)
	material.set_shader_parameter(&"layer_seed", layer_seed)
	material.set_shader_parameter(&"drift_speed", underwater_particles_drift_speed)
	material.set_shader_parameter(&"velocity_influence", underwater_particles_velocity_influence)
	material.set_shader_parameter(&"max_flow_speed", 0.45 if layer_seed < 10.0 else 0.80)
	material.set_shader_parameter(&"current_velocity", current)
	material.set_shader_parameter(&"camera_velocity", Vector3.ZERO)
	material.set_shader_parameter(&"size_min", size_min)
	material.set_shader_parameter(&"size_max", size_max)
	return material


func _make_render_material(color: Color, layer_strength: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _render_shader
	material.set_shader_parameter(&"particle_color", color)
	material.set_shader_parameter(&"strength", layer_strength)
	material.set_shader_parameter(&"near_fade_start_m", 0.15)
	material.set_shader_parameter(&"near_fully_visible_m", 0.70)
	material.set_shader_parameter(&"far_fade_start_m", maxf(8.0, underwater_particles_far_distance_m * 0.56))
	material.set_shader_parameter(&"far_fade_end_m", maxf(15.0, underwater_particles_far_distance_m * 1.22))
	return material


func _update_process_uniforms() -> void:
	if _fine_process_material == null or _near_process_material == null:
		return
	for material in [_fine_process_material, _near_process_material]:
		material.set_shader_parameter(&"camera_velocity", _camera_velocity)
		material.set_shader_parameter(&"drift_speed", underwater_particles_drift_speed)
		material.set_shader_parameter(&"velocity_influence", underwater_particles_velocity_influence)
	if _fine_render_material != null:
		_fine_render_material.set_shader_parameter(&"strength", underwater_particles_fine_strength)
		_fine_render_material.set_shader_parameter(&"far_fade_start_m", maxf(8.0, underwater_particles_far_distance_m * 0.56))
		_fine_render_material.set_shader_parameter(&"far_fade_end_m", maxf(15.0, underwater_particles_far_distance_m * 1.22))
	if _near_render_material != null:
		_near_render_material.set_shader_parameter(&"strength", underwater_particles_near_strength)
		_near_render_material.set_shader_parameter(&"far_fade_start_m", maxf(8.0, underwater_particles_far_distance_m * 0.56))
		_near_render_material.set_shader_parameter(&"far_fade_end_m", maxf(15.0, underwater_particles_far_distance_m * 1.22))


func _apply_state(camera_underwater: bool) -> void:
	if _fine_particles == null or _near_particles == null:
		return
	var should_emit := underwater_particles_enabled and camera_underwater
	var fine_should_emit := should_emit and _benchmark_fine_enabled
	var near_should_emit := should_emit and _benchmark_near_enabled
	var debug_changed := particles_debug != _last_debug
	if fine_should_emit == _last_fine_enabled and near_should_emit == _last_near_enabled and not debug_changed:
		return
	_last_fine_enabled = fine_should_emit
	_last_near_enabled = near_should_emit
	_last_debug = particles_debug
	# No node recreation and no restart on AIR <-> UNDERWATER transitions. The
	# disabled path is both invisible and non-emitting; the existing GPU state is
	# retained for a clean, allocation-free transition back underwater.
	_fine_particles.emitting = fine_should_emit
	_near_particles.emitting = near_should_emit
	_fine_particles.visible = fine_should_emit
	_near_particles.visible = near_should_emit
	if particles_debug:
		_fine_render_material.set_shader_parameter(&"strength", 8.0 if should_emit else 0.0)
		_near_render_material.set_shader_parameter(&"strength", 8.0 if should_emit else 0.0)
	else:
		_fine_render_material.set_shader_parameter(&"strength", underwater_particles_fine_strength)
		_near_render_material.set_shader_parameter(&"strength", underwater_particles_near_strength)

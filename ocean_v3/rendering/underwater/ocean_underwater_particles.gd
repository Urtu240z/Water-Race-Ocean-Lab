@tool
class_name OceanUnderwaterParticles
extends Node3D

## Camera-local suspended particles for the underwater medium. This component
## owns only presentation; AIR/UNDERWATER activation is supplied by OceanV3.

const PROCESS_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_underwater_particles_process.gdshader"
const RENDER_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_underwater_particles.gdshader"
const PARTICLE_LIFETIME_S := 22.0
const PARTICLE_PREPROCESS_S := PARTICLE_LIFETIME_S
const MAX_CAMERA_SPEED_MPS := 35.0
const PARTICLES_POSITION_DEBUG := "PARTICLES_POSITION_DEBUG"
const DEFAULT_SPAWN_NEAR_DISTANCE_M := 4.0
const DEFAULT_SPAWN_FAR_DISTANCE_M := 50.0
const DEFAULT_SPAWN_NEAR_WIDTH_M := 12.0
const DEFAULT_SPAWN_FAR_WIDTH_M := 60.0
const DEFAULT_SPAWN_NEAR_HEIGHT_M := 8.0
const DEFAULT_SPAWN_FAR_HEIGHT_M := 30.0
const DEFAULT_PARTICLE_CULL_DISTANCE_M := 72.0

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
@export_range(0.0, 8.0, 0.05) var underwater_particles_fine_strength := 1.0
@export_range(0.0, 8.0, 0.05) var underwater_particles_near_strength := 1.0
@export_range(0.0, 0.25, 0.005, "suffix: m/s") var underwater_particles_drift_speed := 0.05
@export_range(0.0, 0.5, 0.01) var underwater_particles_velocity_influence := 0.15
@export_range(8.0, 24.0, 0.5, "suffix: m") var underwater_particles_far_distance_m := 18.0

@export_group("Underwater / Suspended Particles / Spawn")
@export_range(1.0, 20.0, 0.5, "suffix: m") var underwater_particles_spawn_near_distance_m := DEFAULT_SPAWN_NEAR_DISTANCE_M
@export_range(20.0, 80.0, 1.0, "suffix: m") var underwater_particles_spawn_far_distance_m := DEFAULT_SPAWN_FAR_DISTANCE_M
@export_range(4.0, 80.0, 1.0, "suffix: m") var underwater_particles_spawn_near_width_m := DEFAULT_SPAWN_NEAR_WIDTH_M
@export_range(8.0, 120.0, 1.0, "suffix: m") var underwater_particles_spawn_far_width_m := DEFAULT_SPAWN_FAR_WIDTH_M
@export_range(4.0, 50.0, 1.0, "suffix: m") var underwater_particles_spawn_near_height_m := DEFAULT_SPAWN_NEAR_HEIGHT_M
@export_range(8.0, 80.0, 1.0, "suffix: m") var underwater_particles_spawn_far_height_m := DEFAULT_SPAWN_FAR_HEIGHT_M
@export_range(20.0, 120.0, 1.0, "suffix: m") var underwater_particles_cull_distance_m := DEFAULT_PARTICLE_CULL_DISTANCE_M

@export_group("Underwater / Suspended Particles / Appearance")
@export_color_no_alpha var underwater_particles_fine_color := Color(0.37, 0.58, 0.59, 1.0)
@export_color_no_alpha var underwater_particles_near_color := Color(0.40, 0.63, 0.62, 1.0)
@export_range(0.25, 10.0, 0.05) var underwater_particles_fine_size_scale := 1.0
@export_range(0.25, 8.0, 0.05) var underwater_particles_near_size_scale := 1.0

@export var particles_position_debug := false

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
var _last_position_diagnostic: Dictionary = {}


func _ready() -> void:
	# Only translation follows the active camera. Rotation is intentionally not
	# inherited so the layer cannot look like a HUD glued to the lens.
	top_level = true
	if not Engine.is_editor_hint():
		var initial_camera := get_viewport().get_camera_3d()
		if initial_camera != null:
			_camera = initial_camera
			_align_emission_to_camera(initial_camera)
			_last_camera_position = initial_camera.global_position
			_has_camera_sample = true
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
		_align_emission_to_camera(active_camera)
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

	# The emitter transform follows the camera so new particles use its forward
	# direction. Moving or rotating it does not restart or reseed either layer:
	# local_coords=false keeps already-emitted particles in world space.
	_align_emission_to_camera(active_camera)
	if _rebuild_pending:
		_rebuild_pending = false
		_last_debug = not particles_position_debug
		_configure_particles()
	_update_process_uniforms()
	_apply_state(_underwater)


func set_underwater_state(camera_underwater: bool) -> void:
	var entered_underwater := camera_underwater and not _underwater
	_underwater = camera_underwater
	if not Engine.is_editor_hint():
		# The parent OceanV3 calls this from its state-sync path. Snap only the
		# emitter translation before the diagnostic/state write so the reported
		# activation range always belongs to the current active camera.
		var active_camera := get_viewport().get_camera_3d()
		if active_camera != null:
			_camera = active_camera
			_align_emission_to_camera(active_camera)
		if entered_underwater:
			_record_position_diagnostic()
		_apply_state(_underwater)


func get_position_diagnostic() -> Dictionary:
	return _last_position_diagnostic.duplicate(true)


func get_particle_debug_state() -> Dictionary:
	return {
		"underwater": _underwater,
		"emitter_world_position": global_position,
		"fine_emitting": _fine_particles.emitting if _fine_particles != null else false,
		"fine_visible": _fine_particles.visible if _fine_particles != null else false,
		"near_emitting": _near_particles.emitting if _near_particles != null else false,
		"near_visible": _near_particles.visible if _near_particles != null else false,
	}


func set_benchmark_layers(fine_enabled: bool, near_enabled: bool) -> void:
	## Benchmark-only gate. It does not alter authored counts or materials.
	_benchmark_fine_enabled = fine_enabled
	_benchmark_near_enabled = near_enabled
	if not Engine.is_editor_hint():
		_apply_state(_underwater)


func _queue_rebuild() -> void:
	_rebuild_pending = true


func _align_emission_to_camera(camera: Camera3D) -> void:
	global_position = camera.global_position
	global_basis = camera.global_basis


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
	particles.preprocess = PARTICLE_PREPROCESS_S
	particles.randomness = 0.35
	particles.local_coords = false
	particles.visibility_aabb = _get_visibility_aabb()
	particles.emitting = false
	particles.visible = false
	particles.draw_pass_1 = _create_quad()
	return particles


func _create_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	return quad


func _get_visibility_aabb() -> AABB:
	# Particles are world-space and can remain anywhere within the GPU cull
	# radius around the moving emitter. Keep the system's own visibility bounds
	# large enough that Godot does not hide valid particles before the process
	# shader can retire them.
	var half_extent := underwater_particles_cull_distance_m + 2.0
	return AABB(Vector3.ONE * -half_extent, Vector3.ONE * (half_extent * 2.0))


func _configure_particles() -> void:
	if _fine_particles == null or _near_particles == null:
		return
	_fine_particles.amount = underwater_particles_fine_amount
	_near_particles.amount = underwater_particles_near_amount
	_applied_fine_amount = underwater_particles_fine_amount
	_applied_near_amount = underwater_particles_near_amount

	_fine_process_material = _make_process_material(1.0, 0.005, 0.025, Vector3(0.008, 0.001, -0.006), underwater_particles_fine_size_scale)
	_near_process_material = _make_process_material(17.0, 0.02, 0.07, Vector3(0.014, 0.003, -0.010), underwater_particles_near_size_scale)
	_fine_render_material = _make_render_material(_with_alpha(underwater_particles_fine_color, 0.032), underwater_particles_fine_strength)
	_near_render_material = _make_render_material(_with_alpha(underwater_particles_near_color, 0.060), underwater_particles_near_strength)
	_fine_particles.process_material = _fine_process_material
	_near_particles.process_material = _near_process_material
	(_fine_particles.draw_pass_1 as QuadMesh).material = _fine_render_material
	(_near_particles.draw_pass_1 as QuadMesh).material = _near_render_material


func _make_process_material(layer_seed: float, size_min: float, size_max: float, current: Vector3, size_scale: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _process_shader
	material.set_shader_parameter(&"emission_depth_min_m", underwater_particles_spawn_near_distance_m)
	material.set_shader_parameter(&"emission_depth_max_m", underwater_particles_spawn_far_distance_m)
	material.set_shader_parameter(&"emission_width_near_m", underwater_particles_spawn_near_width_m)
	material.set_shader_parameter(&"emission_width_far_m", underwater_particles_spawn_far_width_m)
	material.set_shader_parameter(&"emission_height_near_m", underwater_particles_spawn_near_height_m)
	material.set_shader_parameter(&"emission_height_far_m", underwater_particles_spawn_far_height_m)
	material.set_shader_parameter(&"camera_position_world", global_position)
	material.set_shader_parameter(&"max_particle_distance_m", underwater_particles_cull_distance_m)
	material.set_shader_parameter(&"layer_seed", layer_seed)
	material.set_shader_parameter(&"drift_speed", underwater_particles_drift_speed)
	material.set_shader_parameter(&"velocity_influence", underwater_particles_velocity_influence)
	material.set_shader_parameter(&"max_flow_speed", 0.45 if layer_seed < 10.0 else 0.80)
	material.set_shader_parameter(&"current_velocity", current)
	material.set_shader_parameter(&"camera_velocity", Vector3.ZERO)
	material.set_shader_parameter(&"size_min", size_min * size_scale)
	material.set_shader_parameter(&"size_max", size_max * size_scale)
	material.set_shader_parameter(&"debug_size_multiplier", 8.0 if particles_position_debug and layer_seed < 10.0 else (4.0 if particles_position_debug else 1.0))
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


func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


func _update_process_uniforms() -> void:
	if _fine_process_material == null or _near_process_material == null:
		return
	for material in [_fine_process_material, _near_process_material]:
		material.set_shader_parameter(&"camera_velocity", _camera_velocity)
		material.set_shader_parameter(&"camera_position_world", global_position)
		material.set_shader_parameter(&"drift_speed", underwater_particles_drift_speed)
		material.set_shader_parameter(&"velocity_influence", underwater_particles_velocity_influence)
		material.set_shader_parameter(&"emission_depth_min_m", underwater_particles_spawn_near_distance_m)
		material.set_shader_parameter(&"emission_depth_max_m", underwater_particles_spawn_far_distance_m)
		material.set_shader_parameter(&"emission_width_near_m", underwater_particles_spawn_near_width_m)
		material.set_shader_parameter(&"emission_width_far_m", underwater_particles_spawn_far_width_m)
		material.set_shader_parameter(&"emission_height_near_m", underwater_particles_spawn_near_height_m)
		material.set_shader_parameter(&"emission_height_far_m", underwater_particles_spawn_far_height_m)
		material.set_shader_parameter(&"max_particle_distance_m", underwater_particles_cull_distance_m)
	if _fine_particles != null:
		_fine_particles.visibility_aabb = _get_visibility_aabb()
	if _near_particles != null:
		_near_particles.visibility_aabb = _get_visibility_aabb()
	_fine_process_material.set_shader_parameter(&"debug_size_multiplier", 8.0 if particles_position_debug else 1.0)
	_near_process_material.set_shader_parameter(&"debug_size_multiplier", 4.0 if particles_position_debug else 1.0)
	_fine_process_material.set_shader_parameter(&"size_min", 0.005 * underwater_particles_fine_size_scale)
	_fine_process_material.set_shader_parameter(&"size_max", 0.025 * underwater_particles_fine_size_scale)
	_near_process_material.set_shader_parameter(&"size_min", 0.02 * underwater_particles_near_size_scale)
	_near_process_material.set_shader_parameter(&"size_max", 0.07 * underwater_particles_near_size_scale)
	if _fine_render_material != null:
		_fine_render_material.set_shader_parameter(&"strength", underwater_particles_fine_strength)
		_fine_render_material.set_shader_parameter(&"particle_color", _with_alpha(underwater_particles_fine_color, 0.032))
		_fine_render_material.set_shader_parameter(&"far_fade_start_m", maxf(8.0, underwater_particles_far_distance_m * 0.56))
		_fine_render_material.set_shader_parameter(&"far_fade_end_m", maxf(15.0, underwater_particles_far_distance_m * 1.22))
	if _near_render_material != null:
		_near_render_material.set_shader_parameter(&"strength", underwater_particles_near_strength)
		_near_render_material.set_shader_parameter(&"particle_color", _with_alpha(underwater_particles_near_color, 0.060))
		_near_render_material.set_shader_parameter(&"far_fade_start_m", maxf(8.0, underwater_particles_far_distance_m * 0.56))
		_near_render_material.set_shader_parameter(&"far_fade_end_m", maxf(15.0, underwater_particles_far_distance_m * 1.22))


func _apply_state(camera_underwater: bool) -> void:
	if _fine_particles == null or _near_particles == null:
		return
	var should_emit := underwater_particles_enabled and camera_underwater
	var fine_should_emit := should_emit and _benchmark_fine_enabled
	var near_should_emit := should_emit and _benchmark_near_enabled
	var debug_changed := particles_position_debug != _last_debug
	if fine_should_emit == _last_fine_enabled and near_should_emit == _last_near_enabled and not debug_changed:
		return
	_last_fine_enabled = fine_should_emit
	_last_near_enabled = near_should_emit
	_last_debug = particles_position_debug
	# No node recreation and no restart on AIR <-> UNDERWATER transitions. The
	# disabled path is both invisible and non-emitting; the existing GPU state is
	# retained for a clean, allocation-free transition back underwater.
	_fine_particles.emitting = fine_should_emit
	_near_particles.emitting = near_should_emit
	_fine_particles.visible = fine_should_emit
	_near_particles.visible = near_should_emit
	if particles_position_debug:
		_fine_render_material.set_shader_parameter(&"strength", 8.0 if should_emit else 0.0)
		_near_render_material.set_shader_parameter(&"strength", 8.0 if should_emit else 0.0)
	else:
		_fine_render_material.set_shader_parameter(&"strength", underwater_particles_fine_strength)
		_near_render_material.set_shader_parameter(&"strength", underwater_particles_near_strength)
	if particles_position_debug and should_emit:
		var state_valid := _fine_particles.emitting and _fine_particles.visible \
			and _near_particles.emitting and _near_particles.visible
		if not state_valid:
			push_error("%s: underwater state did not enable both particle layers." % PARTICLES_POSITION_DEBUG)


func _record_position_diagnostic() -> void:
	var camera_position := _camera.global_position if _camera != null else global_position
	var spawn_radius := maxf(
		underwater_particles_spawn_far_distance_m,
		maxf(underwater_particles_spawn_far_width_m, underwater_particles_spawn_far_height_m) * 0.5
	)
	var minimum := global_position - Vector3.ONE * spawn_radius
	var maximum := global_position + Vector3.ONE * spawn_radius
	_last_position_diagnostic = {
		"camera_world_position": camera_position,
		"emitter_world_position": global_position,
		"spawn_world_min": minimum,
		"spawn_world_max": maximum,
		"spawn_depth_min_m": underwater_particles_spawn_near_distance_m,
		"spawn_depth_max_m": underwater_particles_spawn_far_distance_m,
		"cull_distance_m": underwater_particles_cull_distance_m,
	}
	if particles_position_debug:
		print("PARTICLES_POSITION_DEBUG camera=%s emitter=%s spawn_world=%s..%s" % [
			camera_position, global_position, minimum, maximum
		])

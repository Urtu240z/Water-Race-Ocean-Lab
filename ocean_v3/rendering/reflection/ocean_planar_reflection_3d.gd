extends Node
class_name OceanPlanarReflection3D
## Runtime-only planar reflection pass owned by one OceanV3 instance.
##
## The pass shares the main viewport's World3D and renders through one mirrored
## Camera3D. Ocean visuals are moved to layer 2 locally so the reflection camera
## can exclude them without hiding or toggling the ocean in the main viewport.

const OCEAN_RENDER_LAYER := 2
const USER_RENDER_LAYER_MASK := (1 << 20) - 1
const MIN_VIEWPORT_SIZE := Vector2i(2, 2)

var _ocean_root: Node3D
var _surface_material: ShaderMaterial
var _surface_node: Node3D
var _main_viewport: Viewport
var _reflection_viewport: SubViewport
var _reflection_camera: Camera3D
var _resolution_scale := 0.25
var _update_hz := 30
var _max_distance_m := 500.0
var _max_camera_height_m := 75.0
var _reflection_strength := 0.55
var _distortion_strength := 0.035
var _edge_fade := 0.08
var _cull_mask := USER_RENDER_LAYER_MASK & ~(1 << (OCEAN_RENDER_LAYER - 1))
var _enabled := true
var _initialized := false
var _last_main_size := Vector2i.ZERO
var _scheduler_elapsed_s := 0.0
var _capture_rate_elapsed_s := 0.0
var _capture_count_window := 0
var _capture_rate_hz := 0.0
var _has_capture := false
var _was_active := false
var _capture_view_projection: Projection
var _pending_capture_view_projection: Projection
var _capture_matrix_pending := false


func initialize(ocean_root: Node3D, surface_material: ShaderMaterial) -> void:
	if _initialized:
		return
	_ocean_root = ocean_root
	_surface_material = surface_material
	_surface_node = _ocean_root.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as Node3D
	_main_viewport = _ocean_root.get_viewport()
	if _main_viewport == null or _surface_material == null:
		return

	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_render_target()
	_apply_ocean_render_layer()
	_initialized = _reflection_viewport != null and _reflection_camera != null
	_sync_material_state(false)


func set_settings(enabled: bool, resolution_scale: float, update_hz: int, max_distance_m: float, max_camera_height_m: float, reflection_strength: float, distortion_strength: float, cull_mask: int, edge_fade: float) -> void:
	_enabled = enabled
	_resolution_scale = clampf(resolution_scale, 0.10, 1.0)
	var previous_update_hz := _update_hz
	_update_hz = 0 if update_hz <= 0 else 15 if update_hz <= 15 else 30 if update_hz <= 30 else 60
	_max_distance_m = clampf(max_distance_m, 50.0, 5000.0)
	_max_camera_height_m = clampf(max_camera_height_m, 1.0, 500.0)
	_reflection_strength = clampf(reflection_strength, 0.0, 1.0)
	_distortion_strength = maxf(distortion_strength, 0.0)
	_edge_fade = clampf(edge_fade, 0.001, 0.5)
	# Ocean layer exclusion is enforced even when a level supplies a broad mask.
	_cull_mask = cull_mask & USER_RENDER_LAYER_MASK & ~(1 << (OCEAN_RENDER_LAYER - 1))
	if previous_update_hz != _update_hz:
		_scheduler_elapsed_s = 0.0
	if _initialized:
		_reflection_camera.cull_mask = _cull_mask
		_resize_to_main_viewport()
		_sync_material_state(_enabled)


func _create_render_target() -> void:
	_reflection_viewport = SubViewport.new()
	_reflection_viewport.name = "PlanarReflectionViewport"
	_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_reflection_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_reflection_viewport.transparent_bg = false
	_reflection_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_reflection_viewport.own_world_3d = false
	_reflection_viewport.world_3d = _main_viewport.find_world_3d()
	_ocean_root.add_child(_reflection_viewport)

	_reflection_camera = Camera3D.new()
	_reflection_camera.name = "PlanarReflectionCamera"
	_reflection_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_reflection_camera.cull_mask = _cull_mask
	_reflection_camera.current = true
	_reflection_viewport.add_child(_reflection_camera)
	_resize_to_main_viewport()


func _process(delta: float) -> void:
	if not _initialized:
		return
	_capture_rate_elapsed_s += maxf(delta, 0.0)
	if _capture_rate_elapsed_s >= 1.0:
		_capture_rate_hz = float(_capture_count_window) / _capture_rate_elapsed_s
		_capture_count_window = 0
		_capture_rate_elapsed_s = 0.0
	_resize_to_main_viewport()
	var main_camera := _main_viewport.get_camera_3d()
	var active := _enabled and main_camera != null and is_instance_valid(main_camera)
	if active:
		var plane_y := _sea_plane_world_y()
		active = absf(main_camera.global_position.y - plane_y) <= _max_camera_height_m
	if not active:
		_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_sync_material_state(false)
		_capture_rate_hz = 0.0
		_capture_count_window = 0
		_capture_rate_elapsed_s = 0.0
		_was_active = false
		return

	var shared_world := _main_viewport.find_world_3d()
	if shared_world != null and _reflection_viewport.world_3d != shared_world:
		_reflection_viewport.world_3d = shared_world
	_sync_reflection_camera(main_camera, _sea_plane_world_y())
	if _capture_matrix_pending:
		# The SubViewport has rendered the request from the previous frame. Apply
		# that capture's matrix together with the texture that is now current.
		_capture_view_projection = _pending_capture_view_projection
		_capture_matrix_pending = false
		_surface_material.set_shader_parameter(&"planar_reflection_view_projection", _capture_view_projection)
	_scheduler_elapsed_s += maxf(delta, 0.0)
	var capture_interval_s := 1.0 / float(_update_hz) if _update_hz > 0 else 0.0
	var capture_due := not _was_active or not _has_capture or _update_hz <= 0 or _scheduler_elapsed_s >= capture_interval_s
	if capture_due:
		_scheduler_elapsed_s = 0.0
		_has_capture = true
		_capture_count_window += 1
		# UPDATE_ONCE keeps the last texture resident and renders this viewport
		# exactly once; the next frame returns it to UPDATE_DISABLED.
		_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		_pending_capture_view_projection = _reflection_camera.get_camera_projection() * Projection(_reflection_camera.get_camera_transform().affine_inverse())
		_capture_matrix_pending = true
		_sync_material_state(true)
	else:
		_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_sync_material_state(true)
	_was_active = true


func _resize_to_main_viewport() -> void:
	if _reflection_viewport == null or _main_viewport == null:
		return
	var main_size := _main_viewport.get_visible_rect().size
	var target_size := Vector2i(
		maxi(roundi(main_size.x * _resolution_scale), MIN_VIEWPORT_SIZE.x),
		maxi(roundi(main_size.y * _resolution_scale), MIN_VIEWPORT_SIZE.y)
	)
	if target_size == _last_main_size:
		return
	_last_main_size = target_size
	_reflection_viewport.size = target_size


func _sync_reflection_camera(main_camera: Camera3D, plane_y: float) -> void:
	# Godot 4.7 exposes no clean Camera3D oblique-frustum clipping API for this
	# pass. Keep the mirror mathematically correct and avoid an unsafe projection
	# hack; scenes should keep below-datum geometry out of the planar pass through
	# the public cull mask when that distinction matters.
	# Reflect forward/up over the horizontal sea datum, then reconstruct right so
	# the camera basis stays orthonormal and keeps Godot's +X/+Y/-Z convention.
	var main_transform := main_camera.global_transform
	var reflected_origin := main_transform.origin
	reflected_origin.y = 2.0 * plane_y - reflected_origin.y
	var reflected_forward := -main_transform.basis.z
	var reflected_up := main_transform.basis.y
	reflected_forward.y = -reflected_forward.y
	reflected_up.y = -reflected_up.y
	reflected_forward = reflected_forward.normalized()
	reflected_up = (reflected_up - reflected_forward * reflected_forward.dot(reflected_up)).normalized()
	var reflected_right := reflected_forward.cross(reflected_up).normalized()
	reflected_up = reflected_right.cross(reflected_forward).normalized()
	var reflected_basis := Basis(reflected_right, reflected_up, -reflected_forward).orthonormalized()
	_reflection_camera.global_transform = Transform3D(reflected_basis, reflected_origin)

	_reflection_camera.projection = main_camera.projection
	_reflection_camera.fov = main_camera.fov
	_reflection_camera.size = main_camera.size
	_reflection_camera.keep_aspect = main_camera.keep_aspect
	_reflection_camera.near = main_camera.near
	_reflection_camera.far = maxf(main_camera.near + 0.001, minf(main_camera.far, _max_distance_m))
	_reflection_camera.frustum_offset = main_camera.frustum_offset
	_reflection_camera.h_offset = main_camera.h_offset
	_reflection_camera.v_offset = main_camera.v_offset
	_reflection_camera.environment = main_camera.environment
	_reflection_camera.cull_mask = _cull_mask


func _sync_material_state(active: bool) -> void:
	if _surface_material == null or not is_instance_valid(_surface_material):
		return
	_surface_material.set_shader_parameter(&"planar_reflection_enabled", active)
	_surface_material.set_shader_parameter(&"planar_reflection_strength", _reflection_strength)
	_surface_material.set_shader_parameter(&"planar_reflection_distortion_strength", _distortion_strength)
	_surface_material.set_shader_parameter(&"planar_reflection_edge_fade", _edge_fade)
	if _reflection_viewport != null:
		_surface_material.set_shader_parameter(&"planar_reflection_texture", _reflection_viewport.get_texture())


func capture_rate_hz() -> float:
	return _capture_rate_hz


func _apply_ocean_render_layer() -> void:
	if _ocean_root == null:
		return
	var ocean_layer_mask := 1 << (OCEAN_RENDER_LAYER - 1)
	# Keep this mask scene-owned: production levels should additionally exclude
	# particles, VFX, helpers, underwater objects, tiny props, and secondary
	# vegetation when those objects do not contribute to the reflection.
	for node in _ocean_root.find_children("*", "VisualInstance3D", true, false):
		var visual := node as VisualInstance3D
		if visual != null:
			visual.layers = ocean_layer_mask


func _sea_plane_world_y() -> float:
	if _surface_node != null and is_instance_valid(_surface_node):
		# This is the datum actually used by the clipmap renderer, not an assumed Y=0.
		return _surface_node.global_position.y
	return _ocean_root.global_position.y

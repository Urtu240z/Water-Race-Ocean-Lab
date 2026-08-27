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
const PROJECTION_MODE_MIRRORED_PERSPECTIVE := 0
const PROJECTION_MODE_OFF_AXIS_FRUSTUM := 1
const PROJECTION_MODE_TRUE_OBLIQUE := 2
const SAFE_CAMERA_EPSILON_M := 0.001
const MAX_FRUSTUM_OFFSET_RATIO := 8.0

var _ocean_root: Node3D
var _surface_material: ShaderMaterial
var _surface_node: Node3D
var _main_viewport: Viewport
var _reflection_viewport: SubViewport
var _reflection_camera: Camera3D
var _resolution_scale := 0.25
var _overscan := 1.15
var _projection_mode := PROJECTION_MODE_MIRRORED_PERSPECTIVE
var _clip_bias_m := 0.10
var _update_hz := 30
var _max_distance_m := 500.0
var _max_camera_height_m := 75.0
var _reflection_strength := 0.55
var _distortion_strength := 0.035
var _edge_fade := 0.08
var _sampling_anchor_mode := 0
var _cull_mask := USER_RENDER_LAYER_MASK & ~(1 << (OCEAN_RENDER_LAYER - 1))
var _enabled := true
var _initialized := false
var _last_main_size := Vector2i.ZERO
var _scheduler_elapsed_s := 0.0
var _capture_rate_elapsed_s := 0.0
var _capture_count_window := 0
var _capture_rate_hz := 0.0
var _has_capture := false
var _capture_ready := false
var _was_active := false
var _capture_view_projection: Projection
var _pending_capture_view_projection: Projection
# True Oblique owns the render projection; sampling can A/B against the
# mirrored perspective projection captured before oblique clipping is enabled.
var _base_sampling_projection: Projection
var _base_sampling_projection_valid := false
var _use_base_sampling_projection := false
var _sampling_xyw_max_delta := 0.0
var _sampling_z_max_delta := 0.0
var _capture_matrix_pending := false
var _capture_sequence := 0
var _pending_capture_sequence := 0
var _last_active_camera_id := 0
var _active_projection_label := "PERSPECTIVE"


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)


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
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	_create_render_target()
	_apply_ocean_render_layer()
	_initialized = _reflection_viewport != null and _reflection_camera != null
	_sync_material_state(false)



func set_settings(enabled: bool, resolution_scale: float, overscan: float, projection_mode: int, clip_bias_m: float, update_hz: int, max_distance_m: float, max_camera_height_m: float, reflection_strength: float, distortion_strength: float, cull_mask: int, edge_fade: float) -> void:
	var previous_enabled := _enabled
	var previous_overscan := _overscan
	var previous_projection_mode := _projection_mode
	var previous_clip_bias_m := _clip_bias_m
	var previous_max_distance_m := _max_distance_m
	_enabled = enabled
	_resolution_scale = clampf(resolution_scale, 0.10, 1.0)
	_overscan = clampf(overscan, 1.0, 2.0)
	_projection_mode = clampi(projection_mode, PROJECTION_MODE_MIRRORED_PERSPECTIVE, PROJECTION_MODE_TRUE_OBLIQUE)
	_clip_bias_m = clampf(clip_bias_m, 0.0, 1.0)
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
		if previous_projection_mode != _projection_mode:
			_disable_oblique_camera()
		if previous_enabled != _enabled or not is_equal_approx(previous_overscan, _overscan) or previous_projection_mode != _projection_mode or not is_equal_approx(previous_clip_bias_m, _clip_bias_m) or not is_equal_approx(previous_max_distance_m, _max_distance_m):
			_invalidate_capture_state()
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
		_invalidate_capture_state()
		_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_sync_material_state(false)
		_capture_rate_hz = 0.0
		_capture_count_window = 0
		_capture_rate_elapsed_s = 0.0
		_was_active = false
		_last_active_camera_id = 0
		return

	var camera_id := main_camera.get_instance_id()
	if _last_active_camera_id != 0 and _last_active_camera_id != camera_id:
		_invalidate_capture_state()
	_last_active_camera_id = camera_id

	var shared_world := _main_viewport.find_world_3d()
	if shared_world != null and _reflection_viewport.world_3d != shared_world:
		_reflection_viewport.world_3d = shared_world
	_sync_reflection_camera(main_camera, _sea_plane_world_y())
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
		# Keep the actual camera projection for capture, except for the LAB-only
		# A/B that tests the pre-oblique perspective matrix for reprojection.
		_pending_capture_view_projection = _sampling_projection_for_capture() * Projection(_reflection_camera.get_camera_transform().affine_inverse())
		_capture_sequence += 1
		_pending_capture_sequence = _capture_sequence
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
	if _initialized:
		_invalidate_capture_state()


func _sync_reflection_camera(main_camera: Camera3D, plane_y: float) -> void:
	if _projection_mode == PROJECTION_MODE_TRUE_OBLIQUE:
		var oblique_available := _oblique_engine_supported()
		if _sync_true_oblique(main_camera, plane_y):
			_active_projection_label = "TRUE OBLIQUE"
			return
		_disable_oblique_camera()
		_sync_mirrored_perspective(main_camera, plane_y)
		_update_sampling_projection_diagnostic()
		_active_projection_label = "TRUE OBLIQUE (%s -> PERSPECTIVE)" % ("UNAVAILABLE" if not oblique_available else "GUARDED")
		return

	_disable_oblique_camera()
	if _projection_mode == PROJECTION_MODE_OFF_AXIS_FRUSTUM and main_camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		if _sync_off_axis_frustum(main_camera, plane_y):
			_active_projection_label = "OFF-AXIS FRUSTUM"
			return

	_sync_mirrored_perspective(main_camera, plane_y)
	if _projection_mode == PROJECTION_MODE_MIRRORED_PERSPECTIVE:
		_active_projection_label = "PERSPECTIVE"
	elif main_camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		_active_projection_label = "PERSPECTIVE (FALLBACK)"
	else:
		_active_projection_label = "MIRRORED (FALLBACK)"


func _sync_true_oblique(main_camera: Camera3D, plane_y: float) -> bool:
	if not _oblique_engine_supported() or main_camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return false
	var main_position := main_camera.global_position
	if not main_position.is_finite() or not is_finite(plane_y):
		return false
	if main_position.y - plane_y <= SAFE_CAMERA_EPSILON_M:
		return false
	_disable_oblique_camera()
	_sync_mirrored_perspective(main_camera, plane_y)
	_reflection_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var plane_position := Vector3(main_position.x, plane_y, main_position.z)
	# The custom engine clips the camera side and keeps the opposite half-space.
	# A positive offset moves the boundary slightly below the datum, preventing
	# below-water geometry leakage without clipping the water surface itself.
	_reflection_camera.call(&"set_oblique_plane_normal", Vector3.UP)
	_reflection_camera.call(&"set_oblique_plane_position", plane_position)
	_reflection_camera.call(&"set_oblique_plane_offset", _clip_bias_m)
	_reflection_camera.call(&"set_use_oblique_near_plane", true)
	_update_sampling_projection_diagnostic()
	return bool(_reflection_camera.call(&"get_use_oblique_near_plane"))


func _oblique_engine_supported() -> bool:
	if _reflection_camera == null or not is_instance_valid(_reflection_camera):
		return false
	return _reflection_camera.has_method(&"set_use_oblique_near_plane") \
			and _reflection_camera.has_method(&"set_oblique_plane_normal") \
			and _reflection_camera.has_method(&"set_oblique_plane_position") \
			and _reflection_camera.has_method(&"set_oblique_plane_offset") \
			and _reflection_camera.has_method(&"get_use_oblique_near_plane")


func oblique_engine_available() -> bool:
	return _oblique_engine_supported()


func _disable_oblique_camera() -> void:
	if _reflection_camera == null or not is_instance_valid(_reflection_camera):
		return
	if _reflection_camera.has_method(&"set_use_oblique_near_plane"):
		_reflection_camera.call(&"set_use_oblique_near_plane", false)


func _sync_mirrored_perspective(main_camera: Camera3D, plane_y: float) -> void:
	# Safe fallback for non-perspective cameras, near-water cameras, and any
	# invalid off-axis footprint. Keep the original mirrored-camera behavior.
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
	_reflection_camera.keep_aspect = main_camera.keep_aspect
	if main_camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		_reflection_camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(main_camera.fov) * 0.5) * _overscan))
		_reflection_camera.size = main_camera.size
	elif main_camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_reflection_camera.fov = main_camera.fov
		_reflection_camera.size = main_camera.size * _overscan
	else:
		_reflection_camera.fov = main_camera.fov
		_reflection_camera.size = main_camera.size * _overscan
	_reflection_camera.near = main_camera.near
	_reflection_camera.far = maxf(main_camera.near + SAFE_CAMERA_EPSILON_M, minf(main_camera.far, _max_distance_m))
	_reflection_camera.frustum_offset = main_camera.frustum_offset
	_reflection_camera.h_offset = main_camera.h_offset
	_reflection_camera.v_offset = main_camera.v_offset
	_reflection_camera.environment = main_camera.environment
	_reflection_camera.cull_mask = _cull_mask
	# This is sampled immediately before _sync_true_oblique enables the custom
	# clip plane, so the base matrix remains the true mirrored perspective one.
	_base_sampling_projection = _reflection_camera.get_camera_projection()
	_base_sampling_projection_valid = true


func _sync_off_axis_frustum(main_camera: Camera3D, plane_y: float) -> bool:
	var main_position := main_camera.global_position
	var height_m := main_position.y - plane_y
	if height_m <= SAFE_CAMERA_EPSILON_M:
		return false

	var z_near := maxf(height_m - _clip_bias_m, SAFE_CAMERA_EPSILON_M)
	var z_far := minf(main_camera.far, _max_distance_m)
	if z_far <= z_near + SAFE_CAMERA_EPSILON_M:
		return false

	var tangent_right := _stable_tangent_right(main_camera)
	var forward := Vector3.UP
	var tangent_up := tangent_right.cross(forward).normalized()
	if tangent_up.length_squared() <= SAFE_CAMERA_EPSILON_M:
		return false
	var reflected_origin := main_position
	reflected_origin.y = 2.0 * plane_y - main_position.y
	var reflected_basis := Basis(tangent_right, tangent_up, -forward).orthonormalized()
	_reflection_camera.global_transform = Transform3D(reflected_basis, reflected_origin)

	var water_plane_rect := _calculate_sea_plane_footprint(main_camera, plane_y, tangent_right, tangent_up)
	if water_plane_rect.size.x <= SAFE_CAMERA_EPSILON_M or water_plane_rect.size.y <= SAFE_CAMERA_EPSILON_M:
		return false

	var reflection_aspect := float(_reflection_viewport.size.x) / maxf(float(_reflection_viewport.size.y), 1.0)
	if reflection_aspect <= SAFE_CAMERA_EPSILON_M:
		return false
	water_plane_rect = _fit_footprint_aspect(water_plane_rect, reflection_aspect)
	water_plane_rect = _scale_footprint(water_plane_rect, _overscan)
	water_plane_rect = _clamp_rect_corners_radius(water_plane_rect, _max_distance_m)

	# Convert the complete water-plane rectangle into the near-plane rectangle.
	# Scaling the center as well as the extents keeps the optical-axis offset
	# consistent when clip bias moves the near plane toward the reflected eye.
	var near_scale := z_near / height_m
	var near_center := (water_plane_rect.position + water_plane_rect.size * 0.5) * near_scale
	var near_size := water_plane_rect.size * near_scale
	var near_plane_rect := Rect2(near_center - near_size * 0.5, near_size)
	near_plane_rect = _clamp_rect_corners_radius(near_plane_rect, _max_distance_m * near_scale)
	near_center = near_plane_rect.position + near_plane_rect.size * 0.5
	near_size = near_plane_rect.size
	if near_size.x <= SAFE_CAMERA_EPSILON_M or near_size.y <= SAFE_CAMERA_EPSILON_M:
		return false
	if not _is_valid_frustum_values(near_size.y, near_center, z_near, z_far):
		return false

	_reflection_camera.set_frustum(
		near_size.y,
		near_center,
		z_near,
		z_far
	)
	_reflection_camera.h_offset = 0.0
	_reflection_camera.v_offset = 0.0
	_reflection_camera.environment = main_camera.environment
	_reflection_camera.cull_mask = _cull_mask
	return _frustum_center_maps_to_viewport_center(near_center, z_near)


func _stable_tangent_right(main_camera: Camera3D) -> Vector3:
	var candidate := main_camera.global_transform.basis.x
	candidate.y = 0.0
	if candidate.length_squared() <= SAFE_CAMERA_EPSILON_M:
		candidate = Vector3.RIGHT
	return candidate.normalized()


func _calculate_sea_plane_footprint(main_camera: Camera3D, plane_y: float, tangent_right: Vector3, tangent_up: Vector3) -> Rect2:
	var viewport_size := _main_viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Rect2()
	var plane_projection := main_camera.global_position
	plane_projection.y = plane_y
	var corners := [
		Vector2(0.0, 0.0),
		Vector2(viewport_size.x, 0.0),
		Vector2(0.0, viewport_size.y),
		Vector2(viewport_size.x, viewport_size.y),
	]
	var footprint := Rect2()
	var has_point := false
	for corner in corners:
		var ray_origin := main_camera.project_ray_origin(corner)
		var ray_direction := main_camera.project_ray_normal(corner).normalized()
		var point := _ray_to_finite_sea_plane(ray_origin, ray_direction, plane_y)
		var horizontal_offset := point - plane_projection
		horizontal_offset.y = 0.0
		if horizontal_offset.length() > _max_distance_m:
			horizontal_offset = horizontal_offset.normalized() * _max_distance_m
		point = plane_projection + horizontal_offset
		var local_offset := point - plane_projection
		var planar_point := Vector2(local_offset.dot(tangent_right), local_offset.dot(tangent_up))
		if not has_point:
			footprint = Rect2(planar_point, Vector2.ZERO)
			has_point = true
		else:
			footprint = footprint.expand(planar_point)
	return footprint


func _ray_to_finite_sea_plane(ray_origin: Vector3, ray_direction: Vector3, plane_y: float) -> Vector3:
	if absf(ray_direction.y) > SAFE_CAMERA_EPSILON_M:
		var distance := (plane_y - ray_origin.y) / ray_direction.y
		if is_finite(distance) and distance > 0.0 and distance <= _max_distance_m:
			var intersection := ray_origin + ray_direction * distance
			intersection.y = plane_y
			return intersection
	var fallback := ray_origin + ray_direction * _max_distance_m
	fallback.y = plane_y
	return fallback


func _fit_footprint_aspect(footprint: Rect2, aspect: float) -> Rect2:
	var center := footprint.position + footprint.size * 0.5
	var half_size := footprint.size * 0.5
	if footprint.size.x / maxf(footprint.size.y, SAFE_CAMERA_EPSILON_M) > aspect:
		half_size.y = half_size.x / aspect
	else:
		half_size.x = half_size.y * aspect
	return Rect2(center - half_size, half_size * 2.0)


func _scale_footprint(footprint: Rect2, scale: float) -> Rect2:
	var center := footprint.position + footprint.size * 0.5
	var size := footprint.size * maxf(scale, SAFE_CAMERA_EPSILON_M)
	return Rect2(center - size * 0.5, size)


func _clamp_rect_corners_radius(rect: Rect2, max_radius: float) -> Rect2:
	var corners := [
		rect.position,
		rect.position + Vector2(rect.size.x, 0.0),
		rect.position + Vector2(0.0, rect.size.y),
		rect.position + rect.size,
	]
	var corner_radius := 0.0
	for corner in corners:
		corner_radius = maxf(corner_radius, corner.length())
	if corner_radius > max_radius and corner_radius > SAFE_CAMERA_EPSILON_M:
		var scale := max_radius / corner_radius
		return Rect2(rect.position * scale, rect.size * scale)
	return rect


func _is_valid_frustum_values(size: float, offset: Vector2, z_near: float, z_far: float) -> bool:
	if not is_finite(size) or not is_finite(offset.x) or not is_finite(offset.y):
		return false
	if not is_finite(z_near) or not is_finite(z_far):
		return false
	if size <= SAFE_CAMERA_EPSILON_M or z_near <= SAFE_CAMERA_EPSILON_M or z_far <= z_near + SAFE_CAMERA_EPSILON_M:
		return false
	return absf(offset.x) / size <= MAX_FRUSTUM_OFFSET_RATIO and absf(offset.y) / size <= MAX_FRUSTUM_OFFSET_RATIO


func _frustum_center_maps_to_viewport_center(near_center: Vector2, z_near: float) -> bool:
	var local_near_point := Vector4(near_center.x, near_center.y, -z_near, 1.0)
	var clip_point := _reflection_camera.get_camera_projection() * local_near_point
	if not is_finite(clip_point.x) or not is_finite(clip_point.y) or not is_finite(clip_point.w) or absf(clip_point.w) <= SAFE_CAMERA_EPSILON_M:
		return false
	var ndc_center := Vector2(clip_point.x, clip_point.y) / clip_point.w
	return ndc_center.length() <= 0.001


func _sync_material_state(active: bool) -> void:
	if _surface_material == null or not is_instance_valid(_surface_material):
		return
	_surface_material.set_shader_parameter(&"planar_reflection_enabled", active and _capture_ready)
	_surface_material.set_shader_parameter(&"planar_reflection_strength", _reflection_strength)
	_surface_material.set_shader_parameter(&"planar_reflection_distortion_strength", _distortion_strength)
	_surface_material.set_shader_parameter(&"planar_reflection_edge_fade", _edge_fade)
	_surface_material.set_shader_parameter(&"planar_reflection_plane_y", _sea_plane_world_y())
	_surface_material.set_shader_parameter(&"planar_reflection_anchor_mode", _sampling_anchor_mode)
	if _reflection_viewport != null:
		_surface_material.set_shader_parameter(&"planar_reflection_texture", _reflection_viewport.get_texture())


func _on_frame_post_draw() -> void:
	if not _capture_matrix_pending or _pending_capture_sequence <= 0:
		return
	# frame_post_draw is emitted after RenderingServer has updated all Viewports,
	# including the SubViewport UPDATE_ONCE requested for this sequence. Publish
	# the matching matrix only now; the next main frame sees a coherent pair.
	_capture_view_projection = _pending_capture_view_projection
	_capture_matrix_pending = false
	_pending_capture_sequence = 0
	_capture_ready = true
	_surface_material.set_shader_parameter(&"planar_reflection_view_projection", _capture_view_projection)
	if _enabled and _was_active:
		_sync_material_state(true)


func _invalidate_capture_state() -> void:
	_has_capture = false
	_capture_ready = false
	_capture_matrix_pending = false
	_pending_capture_sequence = 0
	_scheduler_elapsed_s = 0.0
	if _reflection_viewport != null:
		_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sync_material_state(false)


func capture_rate_hz() -> float:
	return _capture_rate_hz


func projection_mode_label() -> String:
	return _active_projection_label


func toggle_sampling_projection_debug() -> void:
	_use_base_sampling_projection = not _use_base_sampling_projection
	_invalidate_capture_state()


func sampling_projection_label() -> String:
	if _projection_mode != PROJECTION_MODE_TRUE_OBLIQUE:
		return "N/A (TRUE OBLIQUE ONLY)"
	return "BASE PERSPECTIVE" if _use_base_sampling_projection else "OBLIQUE"


func sampling_projection_diagnostic() -> Dictionary:
	return {
		"xyw_max_delta": _sampling_xyw_max_delta,
		"z_max_delta": _sampling_z_max_delta,
	}


func cycle_sampling_anchor_mode() -> void:
	_sampling_anchor_mode = (_sampling_anchor_mode + 1) % 3
	if _surface_material == null or not is_instance_valid(_surface_material):
		return
	_surface_material.set_shader_parameter(&"planar_reflection_plane_y", _sea_plane_world_y())
	_surface_material.set_shader_parameter(&"planar_reflection_anchor_mode", _sampling_anchor_mode)


func sampling_anchor_label() -> String:
	match _sampling_anchor_mode:
		1:
			return "FLAT WORLD XZ"
		2:
			return "FLAT BASE XZ"
		_:
			return "DISPLACED WORLD"


func _sampling_projection_for_capture() -> Projection:
	if _projection_mode == PROJECTION_MODE_TRUE_OBLIQUE and _use_base_sampling_projection and _base_sampling_projection_valid:
		return _base_sampling_projection
	return _reflection_camera.get_camera_projection()


func _update_sampling_projection_diagnostic() -> void:
	if not _base_sampling_projection_valid or _projection_mode != PROJECTION_MODE_TRUE_OBLIQUE:
		_sampling_xyw_max_delta = 0.0
		_sampling_z_max_delta = 0.0
		return
	var oblique_projection := _reflection_camera.get_camera_projection()
	var basis_vectors := [
		Vector4(1.0, 0.0, 0.0, 0.0),
		Vector4(0.0, 1.0, 0.0, 0.0),
		Vector4(0.0, 0.0, 1.0, 0.0),
		Vector4(0.0, 0.0, 0.0, 1.0),
	]
	var xyw_delta := 0.0
	var z_delta := 0.0
	for basis_vector in basis_vectors:
		var base_clip: Vector4 = _base_sampling_projection * basis_vector
		var oblique_clip: Vector4 = oblique_projection * basis_vector
		xyw_delta = maxf(xyw_delta, absf(base_clip.x - oblique_clip.x))
		xyw_delta = maxf(xyw_delta, absf(base_clip.y - oblique_clip.y))
		xyw_delta = maxf(xyw_delta, absf(base_clip.w - oblique_clip.w))
		z_delta = maxf(z_delta, absf(base_clip.z - oblique_clip.z))
	_sampling_xyw_max_delta = xyw_delta
	_sampling_z_max_delta = z_delta


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

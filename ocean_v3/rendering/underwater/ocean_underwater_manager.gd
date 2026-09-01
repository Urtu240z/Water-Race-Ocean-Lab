@tool
class_name OceanUnderwaterManager
extends Node

## Owns the single auxiliary WaterInterface render. It shares the main World3D,
## renders only OceanClipmapSurface's proxy layer, and never renders an air or
## water copy of the scene.

const EFFECT_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_underwater_effect.gd")
const DEPTH_CAPTURE_SCRIPT := preload("res://ocean_v3/rendering/underwater/underwater_opaque_depth_capture.gd")

var _effect: OceanUnderwaterEffect
var _depth_capture: OceanUnderwaterOpaqueDepthCapture
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _ocean: Node
var _interface_viewport: SubViewport
var _interface_camera: Camera3D
var _interface_layer := 0
var _main_camera: Camera3D
var _main_camera_cull_mask := 0
var _attached := false
var _settings: Dictionary = {}


func configure(ocean: Node) -> void:
	_ocean = ocean
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	call_deferred(&"_initialize")


func set_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_push_settings()


func _ready() -> void:
	if not Engine.is_editor_hint():
		call_deferred(&"_initialize")


func _process(_delta: float) -> void:
	if _attached:
		_sync_water_interface_view()
		_push_settings()


func _push_settings() -> void:
	if _effect == null:
		return
	var absorption: Vector3 = _settings.get("absorption", Vector3(0.35, 0.14, 0.10))
	var scattering_color: Color = _settings.get("scattering_color", Color(0.02, 0.32, 0.42, 1.0))
	_effect.set_settings(
		bool(_settings.get("enabled", true)),
		_interface_viewport.get_texture() if _interface_viewport != null else null,
		int(_settings.get("viewer_medium", 0)),
		float(_settings.get("camera_factor", 0.0)),
		float(_settings.get("waterline_feather", 0.03)),
		absorption,
		float(_settings.get("absorption_scale", 1.0)),
		scattering_color,
		float(_settings.get("scattering_strength", 1.0)),
		float(_settings.get("scattering_density", 0.15)),
		float(_settings.get("max_distance", 120.0)),
		int(_settings.get("debug_mode", 0))
	)
	if _depth_capture != null:
		_effect.set_opaque_depth_rid(_depth_capture.get_snapshot())


func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree():
		return
	if not _create_water_interface_view():
		push_warning("OceanUnderwater: WaterInterface buffer could not be initialized.")
		return
	_effect = EFFECT_SCRIPT.new()
	_depth_capture = DEPTH_CAPTURE_SCRIPT.new()
	_push_settings()
	var scene := get_tree().current_scene
	var target := scene.find_child("WorldEnvironment", true, false) if scene != null else null
	if target is WorldEnvironment:
		_world_environment = target
		_compositor = _world_environment.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_world_environment.compositor = _compositor
	else:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			push_warning("OceanUnderwater: no WorldEnvironment or active Camera3D found.")
			return
		_compositor = _camera.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_camera.compositor = _compositor
	var effects := _compositor.compositor_effects.duplicate()
	effects.append(_depth_capture)
	effects.append(_effect)
	_compositor.compositor_effects = effects
	_attached = true


func _create_water_interface_view() -> bool:
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if _ocean != null else null
	var main_viewport := get_viewport()
	if surface == null or main_viewport == null or main_viewport.world_3d == null:
		return false
	_interface_layer = surface.ensure_water_interface_proxy()
	if _interface_layer == 0:
		return false
	_interface_viewport = SubViewport.new()
	_interface_viewport.name = &"WaterInterfaceBuffer"
	_interface_viewport.transparent_bg = true
	_interface_viewport.use_hdr_2d = true
	_interface_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_interface_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_interface_viewport.handle_input_locally = false
	_interface_viewport.world_3d = main_viewport.world_3d
	_interface_viewport.size = _main_render_size(main_viewport)
	add_child(_interface_viewport)
	_interface_camera = Camera3D.new()
	_interface_camera.name = &"WaterInterfaceCamera"
	_interface_camera.current = true
	_interface_camera.cull_mask = _interface_layer
	_interface_viewport.add_child(_interface_camera)
	var neutral_env := Environment.new()
	neutral_env.background_mode = Environment.BG_CLEAR_COLOR
	neutral_env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	neutral_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	if _has_property(_interface_camera, &"environment"):
		_interface_camera.set(&"environment", neutral_env)
	if _has_property(_interface_camera, &"attributes"):
		var neutral_attributes := CameraAttributesPractical.new()
		neutral_attributes.auto_exposure_enabled = false
		neutral_attributes.dof_blur_far_enabled = false
		neutral_attributes.dof_blur_near_enabled = false
		_interface_camera.set(&"attributes", neutral_attributes)
	surface.set_water_interface_depth_max(_interface_camera.far)
	_sync_water_interface_view()
	return true


func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false


func _main_render_size(main_viewport: Viewport) -> Vector2i:
	if main_viewport.has_method(&"get_render_target_size"):
		var render_size := Vector2i(main_viewport.call(&"get_render_target_size"))
		if render_size.x > 0 and render_size.y > 0:
			return render_size
	var visible_size := Vector2i(main_viewport.get_visible_rect().size)
	return Vector2i(maxi(visible_size.x, 1), maxi(visible_size.y, 1))


func _sync_water_interface_view() -> void:
	if _interface_viewport == null or _interface_camera == null or _interface_layer == 0:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if _main_camera != camera:
		_restore_main_camera_layer()
		_main_camera = camera
		_main_camera_cull_mask = camera.cull_mask
	# The visible view can never draw the interface-only mesh copies.
	camera.cull_mask &= ~_interface_layer
	_interface_camera.global_transform = camera.global_transform
	_interface_camera.projection = camera.projection
	_interface_camera.fov = camera.fov
	_interface_camera.size = camera.size
	_interface_camera.near = camera.near
	_interface_camera.far = camera.far
	_interface_camera.keep_aspect = camera.keep_aspect
	_interface_camera.frustum_offset = camera.frustum_offset
	_interface_camera.h_offset = camera.h_offset
	_interface_camera.v_offset = camera.v_offset
	_interface_camera.cull_mask = _interface_layer
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if _ocean != null else null
	if surface != null:
		surface.set_water_interface_depth_max(_interface_camera.far)
	var desired_size := _main_render_size(get_viewport())
	if _interface_viewport.size != desired_size:
		_interface_viewport.size = desired_size


func _restore_main_camera_layer() -> void:
	if _main_camera != null and is_instance_valid(_main_camera):
		_main_camera.cull_mask = _main_camera_cull_mask
	_main_camera = null
	_main_camera_cull_mask = 0


func _exit_tree() -> void:
	_restore_main_camera_layer()
	if _effect != null:
		if _compositor != null:
			var effects := _compositor.compositor_effects.duplicate()
			effects.erase(_depth_capture)
			effects.erase(_effect)
			_compositor.compositor_effects = effects
		_effect.enabled = false
		_effect.set_settings(false, null, 0, 0.0, 0.03, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0, 0)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	if _depth_capture != null:
		RenderingServer.call_on_render_thread(_depth_capture.free_resources)
	if _ocean != null:
		var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
		if surface != null:
			surface.release_water_interface_proxy()
	if _interface_viewport != null:
		_interface_viewport.queue_free()
	_effect = null
	_depth_capture = null
	_interface_viewport = null
	_interface_camera = null
	_attached = false

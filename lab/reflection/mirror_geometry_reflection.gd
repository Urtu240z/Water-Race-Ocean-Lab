extends Node3D
class_name LabMirrorGeometryReflection
## LAB-only first prototype: reflect selected static meshes, not the camera.
##
## The viewport owns an independent World3D and receives only MeshInstance3D
## descendants of the Paradise Island GLB. It intentionally does not clone
## scripts, physics, navigation, particles, actors, or the Ocean V3 itself.

const MIRROR_SHADER := preload("res://lab/reflection/mirror_geometry_reflection.gdshader")
const MIRROR_LAYER := 1
const MIRROR_LAYER_MASK := 1 << (MIRROR_LAYER - 1)
const MIN_VIEWPORT_SIZE := Vector2i(2, 2)
const REFLECTION_SCALE := 0.25
const SAFE_EPSILON_M := 0.001
# This source is captured by a normal main-camera perspective, so its texture
# is already in main-screen coordinates. Keep the first comparison undistorted.
const MIRROR_SCREEN_SPACE_SAMPLING := true
const MIRROR_SCREEN_SPACE_DISTORTION := false

var _lab_root: Node3D
var _ocean_root: Node3D
var _source_root: Node3D
var _main_viewport: Viewport
var _reflection_viewport: SubViewport
var _reflection_camera: Camera3D
var _mirror_geometry_root: Node3D
var _planar_reflection: Node
var _sea_level_y := 0.0
var _capture_view_projection := Projection()
var _pending_view_projection := Projection()
var _capture_pending := false
var _initialized := false
var _source_mesh_count := 0


func _ready() -> void:
	_lab_root = get_parent() as Node3D
	if _lab_root == null:
		return
	_ocean_root = _lab_root.get_node_or_null(^"OceanV3Mount/OceanV3") as Node3D
	_source_root = _lab_root.get_node_or_null(^"paradise_island") as Node3D
	_main_viewport = get_viewport()
	_planar_reflection = _ocean_root.get_node_or_null(^"OceanPlanarReflection3D") as Node if _ocean_root != null else null
	if _main_viewport == null or _ocean_root == null or _source_root == null:
		push_error("LabMirrorGeometryReflection: missing Lab camera, OceanV3, or paradise_island source.")
		return

	_sea_level_y = _find_sea_level_y()
	_create_reflection_world()
	_clone_static_geometry()
	_sync_reflection_camera()
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	_initialized = true
	# This Lab experiment is visible by default. F6 still provides the existing
	# planar on/off control, and the old planar implementation remains intact.
	if _ocean_root.get("planar_reflection_enabled") == false:
		_ocean_root.set("planar_reflection_enabled", true)
	_publish_external_source()


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	if _planar_reflection != null and is_instance_valid(_planar_reflection):
		if _planar_reflection.has_method(&"set_external_reflection_source"):
			_planar_reflection.call(&"set_external_reflection_source", false, null, Projection(), false, false)


func _process(_delta: float) -> void:
	if not _initialized:
		return
	_resize_to_main_viewport()
	if _reflection_viewport == null or _reflection_camera == null:
		return
	_sync_reflection_camera()
	_pending_view_projection = _reflection_camera.get_camera_projection() * Projection(_reflection_camera.get_camera_transform().affine_inverse())
	_capture_pending = true
	_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _create_reflection_world() -> void:
	_reflection_viewport = SubViewport.new()
	_reflection_viewport.name = "MirrorGeometryReflectionViewport"
	_reflection_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_reflection_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_reflection_viewport.transparent_bg = false
	_reflection_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_reflection_viewport.own_world_3d = true
	_reflection_viewport.world_3d = World3D.new()
	add_child(_reflection_viewport)

	var environment_node := WorldEnvironment.new()
	environment_node.name = "MirrorGeometryEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.018, 0.028, 0.034, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.82, 0.86, 1.0)
	environment.ambient_light_energy = 0.8
	environment_node.environment = environment
	_reflection_viewport.add_child(environment_node)

	_reflection_camera = Camera3D.new()
	_reflection_camera.name = "ReflectionCamera"
	_reflection_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_reflection_camera.cull_mask = MIRROR_LAYER_MASK
	_reflection_camera.current = true
	_reflection_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_reflection_viewport.add_child(_reflection_camera)

	_mirror_geometry_root = Node3D.new()
	_mirror_geometry_root.name = "MirrorGeometryRoot"
	_reflection_viewport.add_child(_mirror_geometry_root)


func _clone_static_geometry() -> void:
	_source_mesh_count = 0
	if _source_root == null or _mirror_geometry_root == null:
		return
	var source_meshes := _source_root.find_children("*", "MeshInstance3D", true, false)
	for source_node in source_meshes:
		var source_mesh := source_node as MeshInstance3D
		if source_mesh == null or source_mesh.mesh == null:
			continue
		var reflection_mesh := MeshInstance3D.new()
		reflection_mesh.name = "%s_Mirror" % source_mesh.name
		reflection_mesh.mesh = source_mesh.mesh
		reflection_mesh.transform = _mirrored_transform(source_mesh.global_transform)
		reflection_mesh.layers = MIRROR_LAYER_MASK
		reflection_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		reflection_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		reflection_mesh.set_meta("source_path", str(_source_root.get_path_to(source_mesh)))
		for surface_index in range(source_mesh.mesh.get_surface_count()):
			var source_material := source_mesh.get_active_material(surface_index)
			reflection_mesh.set_surface_override_material(surface_index, _create_reflection_material(source_material))
		_mirror_geometry_root.add_child(reflection_mesh)
		_source_mesh_count += 1


func _create_reflection_material(source_material: Material) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = MIRROR_SHADER
	if source_material is BaseMaterial3D:
		var base_material := source_material as BaseMaterial3D
		material.set_shader_parameter(&"albedo_color", base_material.albedo_color)
		if base_material.albedo_texture != null:
			material.set_shader_parameter(&"albedo_texture", base_material.albedo_texture)
			material.set_shader_parameter(&"use_albedo_texture", true)
	material.set_shader_parameter(&"sea_level_y", _sea_level_y)
	return material


func _mirrored_transform(source_transform: Transform3D) -> Transform3D:
	var source_basis := source_transform.basis
	var mirrored_basis := Basis(
		Vector3(source_basis.x.x, -source_basis.x.y, source_basis.x.z),
		Vector3(source_basis.y.x, -source_basis.y.y, source_basis.y.z),
		Vector3(source_basis.z.x, -source_basis.z.y, source_basis.z.z)
	)
	var mirrored_origin := source_transform.origin
	mirrored_origin.y = 2.0 * _sea_level_y - mirrored_origin.y
	return Transform3D(mirrored_basis, mirrored_origin)


func _sync_reflection_camera() -> void:
	var main_camera := _main_viewport.get_camera_3d()
	if main_camera == null or not is_instance_valid(main_camera):
		return
	# Deliberately keep a conventional perspective camera. Only the geometry is
	# mirrored; no reflected transform, off-axis frustum, or oblique projection.
	_reflection_camera.transform = main_camera.global_transform
	_reflection_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_reflection_camera.fov = main_camera.fov
	_reflection_camera.near = main_camera.near
	_reflection_camera.far = main_camera.far
	_reflection_camera.keep_aspect = main_camera.keep_aspect
	_reflection_camera.cull_mask = MIRROR_LAYER_MASK


func _resize_to_main_viewport() -> void:
	if _main_viewport == null or _reflection_viewport == null:
		return
	var main_size := _main_viewport.get_visible_rect().size
	var target_size := Vector2i(
		maxi(roundi(main_size.x * REFLECTION_SCALE), MIN_VIEWPORT_SIZE.x),
		maxi(roundi(main_size.y * REFLECTION_SCALE), MIN_VIEWPORT_SIZE.y)
	)
	if _reflection_viewport.size != target_size:
		_reflection_viewport.size = target_size


func _on_frame_post_draw() -> void:
	if not _capture_pending:
		return
	_capture_view_projection = _pending_view_projection
	_capture_pending = false
	_publish_external_source()


func _publish_external_source() -> void:
	if _planar_reflection == null or not is_instance_valid(_planar_reflection):
		return
	if _planar_reflection.has_method(&"set_external_reflection_source"):
		_planar_reflection.call(
			&"set_external_reflection_source",
			true,
			_reflection_viewport.get_texture(),
			_capture_view_projection,
			MIRROR_SCREEN_SPACE_SAMPLING,
			MIRROR_SCREEN_SPACE_DISTORTION
		)


func _find_sea_level_y() -> float:
	var surface := _ocean_root.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as Node3D
	if surface != null and is_instance_valid(surface):
		return surface.global_position.y
	return _ocean_root.global_position.y


func get_reflection_texture() -> Texture2D:
	return _reflection_viewport.get_texture() if _reflection_viewport != null else null


func reflection_projection_label() -> String:
	return "MIRROR GEOMETRY / SCREEN UV"


func source_mesh_count() -> int:
	return _source_mesh_count


func sea_level_y() -> float:
	return _sea_level_y

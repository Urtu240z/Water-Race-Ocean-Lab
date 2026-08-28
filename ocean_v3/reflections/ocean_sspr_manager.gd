@tool
class_name OceanSSPRManager
extends Node
## Main-thread owner for the OceanSSPR CompositorEffect and its published RID.

const EFFECT_SCRIPT := preload("res://ocean_v3/reflections/ocean_sspr_effect.gd")

var _ocean: Node
var _effect: OceanSSPREffect
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _texture := Texture2DRD.new()
var _raw_texture := Texture2DRD.new()
var _published_rid := RID()
var _published_raw_rid := RID()
var _attached := false
var _enabled := true
var _ocean_level := 0.0


func configure(ocean: Node, ocean_level: float, enabled: bool) -> void:
	_ocean = ocean
	_ocean_level = ocean_level
	_enabled = enabled
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	call_deferred(&"_initialize")


func set_enabled(value: bool) -> void:
	_enabled = value
	if _effect != null:
		_effect.enabled = value
		_effect.set_active(value)


func set_ocean_level(value: float) -> void:
	_ocean_level = value
	if _effect != null:
		_effect.set_ocean_level(value)


func set_temporal_settings(enabled: bool, weight: float, depth_threshold: float) -> void:
	if _effect != null:
		_effect.set_temporal_settings(enabled, weight, depth_threshold)


func set_kawase_enabled(value: bool) -> void:
	if _effect != null:
		_effect.set_kawase_enabled(value)


func _ready() -> void:
	if not Engine.is_editor_hint() and _ocean == null:
		_ocean = get_parent()
		call_deferred(&"_initialize")


func _process(_delta: float) -> void:
	if _effect == null:
		return
	var current_rid := _effect.get_output_texture_rid()
	var current_raw_rid := _effect.get_raw_texture_rid()
	if current_rid == _published_rid and current_raw_rid == _published_raw_rid:
		return
	if current_rid != _published_rid and _published_rid.is_valid():
		_texture.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(_effect.release_texture.bind(_published_rid))
	if current_raw_rid != _published_raw_rid and _published_raw_rid.is_valid() \
			and _published_raw_rid != _published_rid:
		_raw_texture.texture_rd_rid = RID()
		RenderingServer.call_on_render_thread(_effect.release_texture.bind(_published_raw_rid))
	if current_rid != _published_rid:
		_published_rid = current_rid
	if current_raw_rid != _published_raw_rid:
		_published_raw_rid = current_raw_rid
	if _published_rid.is_valid():
		_texture.texture_rd_rid = _published_rid
	if _published_raw_rid.is_valid():
		_raw_texture.texture_rd_rid = _published_raw_rid
	if _ocean != null and is_instance_valid(_ocean) and _ocean.has_method(&"set_reflection_sspr_texture"):
		_ocean.set_reflection_sspr_texture(_texture, _published_rid.is_valid())
	if _ocean != null and is_instance_valid(_ocean) and _ocean.has_method(&"set_reflection_sspr_raw_texture"):
		_ocean.set_reflection_sspr_raw_texture(_raw_texture, _published_raw_rid.is_valid())


func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree():
		return
	_effect = EFFECT_SCRIPT.new()
	_effect.enabled = _enabled
	_effect.set_active(_enabled)
	_effect.set_ocean_level(_ocean_level)
	if _ocean != null and _ocean.has_method(&"get_reflection_sspr_temporal_settings"):
		var temporal_settings: Dictionary = _ocean.get_reflection_sspr_temporal_settings()
		_effect.set_temporal_settings(
			temporal_settings.get("enabled", true),
			temporal_settings.get("weight", 0.12),
			temporal_settings.get("depth_threshold", 0.035))
	if _ocean != null and _ocean.has_method(&"get_reflection_sspr_kawase_enabled"):
		_effect.set_kawase_enabled(_ocean.get_reflection_sspr_kawase_enabled())
	var target := get_tree().current_scene.find_child("WorldEnvironment", true, false) if get_tree().current_scene != null else null
	if target is WorldEnvironment:
		_world_environment = target
		_compositor = _world_environment.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_world_environment.compositor = _compositor
	else:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			push_warning("OceanSSPR: no WorldEnvironment or active Camera3D found; effect remains disabled.")
			return
		_compositor = _camera.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_camera.compositor = _compositor
	var effects := _compositor.compositor_effects.duplicate()
	effects.append(_effect)
	_compositor.compositor_effects = effects
	_attached = true


func _exit_tree() -> void:
	if _published_rid.is_valid():
		_texture.texture_rd_rid = RID()
		_published_rid = RID()
	if _published_raw_rid.is_valid():
		_raw_texture.texture_rd_rid = RID()
		_published_raw_rid = RID()
	if _effect != null:
		if _compositor != null:
			var effects := _compositor.compositor_effects.duplicate()
			effects.erase(_effect)
			_compositor.compositor_effects = effects
		_effect.enabled = false
		_effect.set_active(false)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

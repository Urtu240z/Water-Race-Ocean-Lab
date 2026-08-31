@tool
class_name OceanCausticsManager
extends Node

const EFFECT_SCRIPT := preload("res://ocean_v3/rendering/caustics/ocean_caustics_effect.gd")

var _ocean: Node
var _effect: OceanCausticsEffect
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _enabled := false
var _sea_level := 0.0
var _texture: Texture2D
var _texture_scale := 0.105
var _strength := 0.65
var _power := 1.0
var _fade_start := 4.0
var _max_depth := 6.0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _debug_mode := 0
var _time := 0.0
var _attached := false


func configure(ocean: Node, sea_level: float, enabled: bool, texture: Texture2D,
		texture_scale: float, strength: float, power: float, fade_start: float,
		max_depth: float, sun_direction: Vector3, debug_mode: int) -> void:
	_ocean = ocean
	_sea_level = sea_level
	_enabled = enabled
	_texture = texture
	_texture_scale = texture_scale
	_strength = strength
	_power = power
	_fade_start = fade_start
	_max_depth = max_depth
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	call_deferred(&"_initialize")


func set_settings(enabled: bool, sea_level: float, texture: Texture2D, texture_scale: float,
		strength: float, power: float, fade_start: float, max_depth: float,
		sun_direction: Vector3, debug_mode: int) -> void:
	_enabled = enabled
	_sea_level = sea_level
	_texture = texture
	_texture_scale = texture_scale
	_strength = strength
	_power = power
	_fade_start = fade_start
	_max_depth = max_depth
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	_push_settings()


func set_time(value: float) -> void:
	_time = value
	if _effect != null:
		_effect.set_time(value)


func _ready() -> void:
	if not Engine.is_editor_hint() and _ocean == null:
		_ocean = get_parent()
		call_deferred(&"_initialize")


func _process(_delta: float) -> void:
	if _effect == null:
		return
	_push_settings()
	_effect.set_time(_time)


func _push_settings() -> void:
	if _effect != null:
		_effect.set_settings(_enabled, _sea_level, _texture, _texture_scale, _strength,
			_power, _fade_start, _max_depth, _sun_direction, _debug_mode)


func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree():

		return
	_effect = EFFECT_SCRIPT.new()
	_effect.set_time(_time)
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
			push_warning("OceanCaustics: no WorldEnvironment or active Camera3D found.")
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
	if _effect != null:
		if _compositor != null:
			var effects := _compositor.compositor_effects.duplicate()
			effects.erase(_effect)
			_compositor.compositor_effects = effects
		_effect.enabled = false
		_effect.set_settings(false, _sea_level, null, _texture_scale, 0.0, _power,
			_fade_start, _max_depth, _sun_direction, 0)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

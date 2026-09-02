@tool
class_name OceanUnderwaterManager
extends Node

const EFFECT_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_underwater_effect.gd")

var _effect: OceanUnderwaterEffect
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _attached := false
var _settings: Dictionary = {}

func configure(_ocean: Node) -> void:
	if not is_inside_tree() or Engine.is_editor_hint(): return
	call_deferred(&"_initialize")

func set_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_push_settings()

func reset_dispatch_count() -> void:
	if _effect != null:
		_effect.reset_dispatch_count()

func get_dispatch_count() -> int:
	return _effect.get_dispatch_count() if _effect != null else 0

func _ready() -> void:
	if not Engine.is_editor_hint(): call_deferred(&"_initialize")

func _push_settings() -> void:
	if _effect == null: return
	var enabled := bool(_settings.get("enabled", true))
	var camera_underwater := bool(_settings.get("camera_underwater", false))
	var debug_mode := int(_settings.get("debug_mode", 0))
	# Keep the effect attached for its whole lifetime, but use the inherited
	# CompositorEffect gate so ordinary AIR frames never enter the resolver or
	# allocate/dispatch a compute list. CAMERA_STATE is the one intentional AIR
	# diagnostic exception.
	_effect.enabled = enabled and (camera_underwater or debug_mode == 4 or debug_mode == 45)
	var absorption: Vector3 = _settings.get("absorption", Vector3(0.35, 0.14, 0.10))
	var scattering_color: Color = _settings.get("scattering_color", Color(0.02, 0.32, 0.42, 1.0))
	var light_into_water: Vector3 = _settings.get("light_into_water", Vector3(0.0, -1.0, 0.0))
	var sun_color: Color = _settings.get("sun_color", Color.WHITE)
	_effect.set_settings(
		enabled, float(_settings.get("sea_level", 0.0)),
		camera_underwater, float(_settings.get("camera_factor", 0.0)),
		float(_settings.get("transition_width", 0.12)), absorption,
		float(_settings.get("absorption_scale", 1.0)), scattering_color,
		float(_settings.get("scattering_strength", 1.0)), float(_settings.get("scattering_density", 0.15)),
		float(_settings.get("max_distance", 120.0)), debug_mode, light_into_water, sun_color,
		float(_settings.get("sun_energy", 0.0)), bool(_settings.get("sunrays_enabled", true)),
		float(_settings.get("sunrays_strength", 0.35)), float(_settings.get("sunrays_anisotropy", 0.72)),
		float(_settings.get("sunrays_density", 0.08)), float(_settings.get("sunrays_max_distance", 30.0)),
		float(_settings.get("sunrays_length_variation", 0.70)),
		float(_settings.get("sunrays_pattern_scale", 1.0)), float(_settings.get("sunrays_pattern_contrast", 1.4)),
		float(_settings.get("sunrays_animation_speed", 0.12)),
		bool(_settings.get("sunrays_wave_modulation_enabled", true)),
		float(_settings.get("sunrays_wave_animation_speed", 1.50)),
		bool(_settings.get("sunrays_wave_freeze", false)),
		float(_settings.get("sunrays_wave_intensity_strength", 0.35)),
		float(_settings.get("sunrays_wave_width_strength", 0.10)),
		float(_settings.get("sunrays_wave_depth_fade_m", 15.0)),
		bool(_settings.get("sunrays_phase_debug_constant", false)),
		float(_settings.get("sunrays_time", 0.0)), int(_settings.get("sunrays_tap_count", 4)),
		int(_settings.get("sunrays_segment_mode", 1)))

func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree(): return
	_effect = EFFECT_SCRIPT.new()
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
		_effect.set_settings(false, 0.0, false, 0.0, 0.12, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0, 0,
			Vector3(0.0, -1.0, 0.0), Color.WHITE, 0.0, false, 0.0, 0.45, 0.08, 30.0, 0.70, 1.0, 1.4,
			0.0, false, 1.0, false, 0.0, 0.0, 15.0, false, 0.0, 4)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

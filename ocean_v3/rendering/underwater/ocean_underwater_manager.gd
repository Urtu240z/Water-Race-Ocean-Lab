@tool
class_name OceanUnderwaterManager
extends Node

const EFFECT_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_underwater_effect.gd")

var _effect: OceanUnderwaterEffect
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _ocean: Node
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


func refresh_surface_probe_sources() -> void:
	_refresh_surface_probe_sources()


func _refresh_surface_probe_sources() -> void:
	if _effect == null or _ocean == null:
		return
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface")
	if surface == null or not surface.has_method(&"get_surface_material"):
		return
	var material := surface.call(&"get_surface_material") as ShaderMaterial
	if material == null:
		return
	_effect.set_surface_probe_sources(
		_rd_texture(material, &"displacement_long_coastal"),
		_rd_texture(material, &"displacement_long_remainder"),
		_rd_texture(material, &"displacement_mid"),
		_rd_texture(material, &"normal_long_coastal"),
		_rd_texture(material, &"normal_long_remainder"),
		_rd_texture(material, &"normal_mid"),
		Vector3(
			float(material.get_shader_parameter(&"domain_long_coastal_m")),
			float(material.get_shader_parameter(&"domain_long_remainder_m")),
			float(material.get_shader_parameter(&"domain_mid_m"))
		)
	)


func _rd_texture(material: ShaderMaterial, parameter: StringName) -> RID:
	var texture := material.get_shader_parameter(parameter) as Texture2D
	if texture == null or not texture.get_rid().is_valid():
		return RID()
	return RenderingServer.texture_get_rd_texture(texture.get_rid(), true)


func _ready() -> void:
	if not Engine.is_editor_hint():
		call_deferred(&"_initialize")


func _push_settings() -> void:
	if _effect == null:
		return
	var absorption: Vector3 = _settings.get("absorption", Vector3(0.35, 0.14, 0.10))
	var scattering_color: Color = _settings.get("scattering_color", Color(0.02, 0.32, 0.42, 1.0))
	_effect.set_settings(
		bool(_settings.get("enabled", true)),
		float(_settings.get("sea_level", 0.0)),
		bool(_settings.get("camera_underwater", false)),
		float(_settings.get("camera_factor", 0.0)),
		float(_settings.get("transition_width", 0.12)),
		float(_settings.get("waterline_feather", 0.03)),
		absorption,
		float(_settings.get("absorption_scale", 1.0)),
		scattering_color,
		float(_settings.get("scattering_strength", 1.0)),
		float(_settings.get("scattering_density", 0.15)),
		float(_settings.get("max_distance", 120.0)),
		int(_settings.get("debug_mode", 0))
	)


func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree():
		return
	_effect = EFFECT_SCRIPT.new()
	_push_settings()
	_refresh_surface_probe_sources()
	call_deferred(&"_refresh_surface_probe_sources")
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
		_effect.set_settings(false, 0.0, false, 0.0, 0.12, 0.03, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0, 0)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

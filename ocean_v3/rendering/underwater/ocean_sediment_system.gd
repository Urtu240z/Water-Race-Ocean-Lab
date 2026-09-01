@tool
class_name OceanSedimentSystem
extends Node3D
## V1 sediment presentation and scheduling. The simulation is the single
## world-anchored OceanSedimentField; particles only populate its local view.

const FIELD_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_sediment_field.gd")
const PARTICLE_PROCESS_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles_process.gdshader"
const PARTICLE_RENDER_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles.gdshader"
const MAX_INJECTIONS := 16

enum DebugMode { OFF, FIELD, SOURCE, CLOUDS, WISPS }

@export_group("Underwater / Sediment")
@export var sediment_enabled := true
@export_range(64, 512, 64) var sediment_field_resolution := 256
@export_range(1.0, 60.0, 1.0, "suffix: Hz") var sediment_update_hz := 20.0
@export_range(1.0, 20.0, 1.0, "suffix: Hz") var sediment_air_update_hz := 5.0
@export_range(0.0, 4.0, 0.01) var sediment_strength := 1.0
@export_range(0.0, 20.0, 0.1, "suffix: m") var sediment_shallow_start_m := 1.0
@export_range(0.1, 30.0, 0.1, "suffix: m") var sediment_shallow_end_m := 5.0
@export_range(0.0, 4.0, 0.01) var sediment_wave_resuspension_strength := 0.65
@export var sediment_current_direction := Vector2(1.0, 0.0)
@export_range(0.0, 4.0, 0.01, "suffix: m/s") var sediment_current_speed := 0.20
@export_range(0.0, 2.0, 0.01, "suffix: m/s") var sediment_orbital_strength := 0.08
@export_range(0.0, 1.0, 0.01) var sediment_diffusion := 0.10
@export_range(0.0, 1.0, 0.005, "suffix: 1/s") var sediment_settling_rate := 0.08
@export_range(0.0, 4.0, 0.01) var sediment_cloud_strength := 1.0
@export_range(0.0, 4.0, 0.01) var sediment_wisp_strength := 1.0
@export_range(8.0, 80.0, 1.0, "suffix: m") var sediment_render_distance_m := 36.0
@export_range(0.0, 2.0, 0.01) var sediment_above_water_optics_strength := 1.0
@export_enum("OFF", "FIELD", "SOURCE", "CLOUDS", "WISPS") var sediment_debug_mode: int = DebugMode.OFF
@export_tool_button("Inject Test Sediment", "Burst") var inject_test_sediment_button = inject_test_sediment

var _field: OceanSedimentField
var _field_texture := Texture2DRD.new()
var _process_shader: Shader
var _render_shader: Shader
var _cloud_particles: GPUParticles3D
var _wisp_particles: GPUParticles3D
var _cloud_material: ShaderMaterial
var _wisp_material: ShaderMaterial
var _cloud_process_material: ShaderMaterial
var _wisp_process_material: ShaderMaterial
var _surface: OceanClipmapSurface
var _bathymetry: BathymetryData
var _configured := false
var _field_published := false
var _camera_underwater := false
var _update_accumulator := 0.0
var _published_read_index := 0
var _last_render_time := 0.0
var _pending_injections: Array[Vector4] = []
var _last_dispatch_usec := 0
var _dispatch_count := 0
var _last_dispatch_period_s := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	top_level = true


func configure(_ocean: Node, bathymetry: BathymetryData, surface: OceanClipmapSurface) -> void:
	if Engine.is_editor_hint() or _configured:
		return
	_surface = surface
	_bathymetry = bathymetry
	_field = FIELD_SCRIPT.new()
	_process_shader = load(PARTICLE_PROCESS_SHADER_PATH) as Shader
	_render_shader = load(PARTICLE_RENDER_SHADER_PATH) as Shader
	var source_bytes := _build_bathymetry_source_bytes(bathymetry)
	var width := bathymetry.width if bathymetry != null and bathymetry.is_valid() else 1
	var height := bathymetry.height if bathymetry != null and bathymetry.is_valid() else 1
	var origin := bathymetry.world_origin_xz if bathymetry != null and bathymetry.is_valid() else Vector2.ZERO
	var extent := bathymetry.world_max_xz() - origin if bathymetry != null and bathymetry.is_valid() else Vector2.ONE
	RenderingServer.call_on_render_thread(_field.initialize.bind(
		sediment_field_resolution,
		origin,
		extent,
		width,
		height,
		source_bytes,
		"OceanV3.Sediment"))
	_configured = true
	_set_emitter_from_camera()
	_ensure_particles()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _configured or _field == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	_set_emitter_from_camera()
	if _field.ready:
		_publish_field_binding()
		_update_particles()
	var hz := sediment_update_hz if _camera_underwater else sediment_air_update_hz
	if not sediment_enabled:
		return
	_update_accumulator += maxf(delta, 0.0)
	var period := 1.0 / maxf(hz, 1.0)
	if _update_accumulator < period:
		return
	var step_delta := minf(_update_accumulator, 0.25)
	_update_accumulator = fmod(_update_accumulator, period)
	_dispatch_field(step_delta)


func set_camera_underwater(camera_underwater: bool) -> void:
	_camera_underwater = camera_underwater
	_apply_particle_visibility()


func inject_sediment(world_position: Vector3, radius_m: float, strength: float) -> void:
	var injection := Vector4(world_position.x, world_position.z, maxf(radius_m, 0.05), clampf(strength, 0.0, 1.0))
	if _pending_injections.size() >= MAX_INJECTIONS:
		_pending_injections.pop_front()
	_pending_injections.append(injection)


func inject_test_sediment() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var sample_position := camera.global_position
	if _bathymetry != null and _bathymetry.is_valid():
		var sample: BathymetrySample = _bathymetry.sample_bathymetry(Vector2(sample_position.x, sample_position.z))
		if sample.in_bounds and sample.is_water:
			sample_position.y = _bathymetry.sea_level_y - sample.depth_m + 0.45
	inject_sediment(sample_position, 5.0, 1.0)


func get_debug_state() -> Dictionary:
	return {
		"enabled": sediment_enabled,
		"camera_underwater": _camera_underwater,
		"configured": _configured,
		"field_published": _field_published,
		"field": _field.diagnostic_state() if _field != null else {},
		"field_origin_xz": _field_origin(),
		"field_extent_m": _field_extent(),
		"update_hz_underwater": sediment_update_hz,
		"update_hz_air": sediment_air_update_hz,
		"dispatch_count": _dispatch_count,
		"last_dispatch_period_s": _last_dispatch_period_s,
		"pending_injections": _pending_injections.size(),
		"cloud_amount": _cloud_particles.amount if _cloud_particles != null else 0,
		"wisp_amount": _wisp_particles.amount if _wisp_particles != null else 0,
	}


func _dispatch_field(step_delta: float) -> void:
	var next_index := 1 - _published_read_index
	var injection_floats := PackedFloat32Array()
	injection_floats.resize(MAX_INJECTIONS * 4)
	for index in mini(_pending_injections.size(), MAX_INJECTIONS):
		var injection := _pending_injections[index]
		injection_floats[index * 4] = injection.x
		injection_floats[index * 4 + 1] = injection.y
		injection_floats[index * 4 + 2] = injection.z
		injection_floats[index * 4 + 3] = injection.w
	var injection_bytes := injection_floats.to_byte_array()
	_pending_injections.clear()
	_published_read_index = next_index
	_field_texture.texture_rd_rid = _field.get_texture_rid(next_index)
	_last_render_time += step_delta
	_last_dispatch_period_s = step_delta
	_dispatch_count += 1
	_last_dispatch_usec = Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(_field.advance.bind(
		1 - next_index,
		next_index,
		_field_origin(),
		_field_extent(),
		step_delta,
		_last_render_time,
		sediment_current_direction,
		sediment_current_speed,
		sediment_orbital_strength,
		Vector2(0.87, 0.50),
		0.22,
		0.72,
		sediment_diffusion,
		sediment_settling_rate,
		sediment_shallow_start_m,
		sediment_shallow_end_m,
		sediment_wave_resuspension_strength * sediment_strength,
		_bathymetry != null and _bathymetry.is_valid(),
		injection_bytes))


func _publish_field_binding() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var material := _surface.get_surface_material()
	if material == null or material.shader == null:
		return
	_field_texture.texture_rd_rid = _field.get_texture_rid(_published_read_index)
	_surface.set_sediment_field(
		_field_texture,
		true,
		_field_origin(),
		_field_extent(),
		sediment_above_water_optics_strength,
		sediment_debug_mode)
	_field_published = true


func _ensure_particles() -> void:
	if _cloud_particles != null and is_instance_valid(_cloud_particles):
		return
	if _process_shader == null or _render_shader == null:
		return
	_cloud_particles = _create_particle_layer("SedimentClouds")
	_wisp_particles = _create_particle_layer("SedimentWisps")
	_cloud_particles.amount = 520
	_wisp_particles.amount = 160
	_cloud_particles.draw_pass_1 = _create_quad()
	_wisp_particles.draw_pass_1 = _create_quad()
	add_child(_cloud_particles)
	add_child(_wisp_particles)
	_cloud_particles.owner = null
	_wisp_particles.owner = null
	_cloud_process_material = _create_process_material(1.0, 0.05, 1.5, 0.15)
	_wisp_process_material = _create_process_material(19.0, 0.5, 2.5, 0.08)
	_cloud_material = _create_render_material(false)
	_wisp_material = _create_render_material(true)
	_cloud_particles.process_material = _cloud_process_material
	_wisp_particles.process_material = _wisp_process_material
	(_cloud_particles.draw_pass_1 as QuadMesh).material = _cloud_material
	(_wisp_particles.draw_pass_1 as QuadMesh).material = _wisp_material
	_apply_particle_visibility()


func _create_particle_layer(layer_name: String) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.lifetime = 26.0
	particles.preprocess = 20.0
	particles.randomness = 0.25
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-42.0, -42.0, -42.0), Vector3(84.0, 84.0, 84.0))
	particles.emitting = false
	particles.visible = false
	return particles


func _create_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	return quad


func _create_process_material(layer_seed: float, height_min: float, height_max: float, threshold: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _process_shader
	material.set_shader_parameter(&"sediment_field_texture", _field_texture)
	material.set_shader_parameter(&"bathymetry_texture", _build_bathymetry_preview_texture())
	material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	material.set_shader_parameter(&"bathymetry_origin_xz", _field_origin())
	material.set_shader_parameter(&"bathymetry_extent_m", _field_extent())
	material.set_shader_parameter(&"bathymetry_depth_scale_m", 32.0)
	material.set_shader_parameter(&"sea_level_y", _bathymetry.sea_level_y if _bathymetry != null else 0.0)
	material.set_shader_parameter(&"spawn_radius_m", sediment_render_distance_m)
	material.set_shader_parameter(&"layer_seed", layer_seed)
	material.set_shader_parameter(&"height_min_m", height_min)
	material.set_shader_parameter(&"height_max_m", height_max)
	material.set_shader_parameter(&"field_threshold", threshold)
	material.set_shader_parameter(&"current_direction_xz", sediment_current_direction.normalized())
	material.set_shader_parameter(&"current_speed_mps", sediment_current_speed)
	material.set_shader_parameter(&"orbital_strength_mps", sediment_orbital_strength)
	material.set_shader_parameter(&"wave_k_rad_m", 0.22)
	material.set_shader_parameter(&"wave_omega_rad_s", 0.72)
	material.set_shader_parameter(&"vertical_wander_m", 0.08 if layer_seed < 10.0 else 0.14)
	return material


func _create_render_material(is_wisps: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _render_shader
	material.set_shader_parameter(&"sediment_field_texture", _field_texture)
	material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	material.set_shader_parameter(&"particle_color", Color(0.34, 0.29, 0.19, 0.065 if not is_wisps else 0.035))
	material.set_shader_parameter(&"strength", sediment_wisp_strength if is_wisps else sediment_cloud_strength)
	material.set_shader_parameter(&"field_threshold", 0.10 if is_wisps else 0.15)
	material.set_shader_parameter(&"field_contrast", 0.80 if is_wisps else 0.68)
	material.set_shader_parameter(&"wisps", is_wisps)
	return material


func _update_particles() -> void:
	if _cloud_process_material == null or _wisp_process_material == null:
		return
	for material in [_cloud_process_material, _wisp_process_material]:
		material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
		material.set_shader_parameter(&"bathymetry_origin_xz", _field_origin())
		material.set_shader_parameter(&"bathymetry_extent_m", _field_extent())
		material.set_shader_parameter(&"bathymetry_depth_scale_m", 32.0)
		material.set_shader_parameter(&"current_direction_xz", sediment_current_direction.normalized())
		material.set_shader_parameter(&"current_speed_mps", sediment_current_speed)
		material.set_shader_parameter(&"orbital_strength_mps", sediment_orbital_strength)
		material.set_shader_parameter(&"spawn_radius_m", sediment_render_distance_m)
	if _cloud_material != null:
		_cloud_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_cloud_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_cloud_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	if _wisp_material != null:
		_wisp_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_wisp_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_wisp_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	_apply_particle_visibility()


func _apply_particle_visibility() -> void:
	var particles_visible := sediment_enabled and _camera_underwater and _field_published
	if _cloud_particles != null:
		_cloud_particles.emitting = particles_visible
		_cloud_particles.visible = particles_visible
	if _wisp_particles != null:
		_wisp_particles.emitting = particles_visible
		_wisp_particles.visible = particles_visible
	if _cloud_material != null:
		_cloud_material.set_shader_parameter(&"strength", sediment_cloud_strength * (8.0 if sediment_debug_mode == DebugMode.CLOUDS else 1.0))
	if _wisp_material != null:
		_wisp_material.set_shader_parameter(&"strength", sediment_wisp_strength * (8.0 if sediment_debug_mode == DebugMode.WISPS else 1.0))


func _set_emitter_from_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	global_position = Vector3(camera.global_position.x, _bathymetry.sea_level_y if _bathymetry != null else 0.0, camera.global_position.z)
	global_basis = Basis.IDENTITY


func _field_origin() -> Vector2:
	return _bathymetry.world_origin_xz if _bathymetry != null and _bathymetry.is_valid() else Vector2.ZERO


func _field_extent() -> Vector2:
	return _bathymetry.world_max_xz() - _field_origin() if _bathymetry != null and _bathymetry.is_valid() else Vector2.ONE


func _build_bathymetry_source_bytes(data: BathymetryData) -> PackedByteArray:
	if data == null or not data.is_valid():
		return PackedFloat32Array([0.0, 0.0]).to_byte_array()
	var values := PackedFloat32Array()
	values.resize(data.cell_count() * 2)
	for index in data.cell_count():
		values[index * 2] = maxf(data.depth_m[index], 0.0)
		values[index * 2 + 1] = 1.0 if data.land_water_mask[index] != 0 else 0.0
	return values.to_byte_array()


func _build_bathymetry_preview_texture() -> Texture2D:
	# Particle shaders need a Texture2D sampler. This is one immutable upload of the
	# existing bake; the simulation itself samples its RD copy and never reads back.
	if _bathymetry == null or not _bathymetry.is_valid():
		var neutral := Image.create(1, 1, false, Image.FORMAT_RG8)
		neutral.fill(Color(0.0, 0.0, 0.0, 1.0))
		return ImageTexture.create_from_image(neutral)
	var packed := PackedByteArray()
	packed.resize(_bathymetry.cell_count() * 2)
	for index in _bathymetry.cell_count():
		packed[index * 2] = clampi(int(round(clampf(_bathymetry.depth_m[index] / 32.0, 0.0, 1.0) * 255.0)), 0, 255)
		packed[index * 2 + 1] = 255 if _bathymetry.land_water_mask[index] != 0 else 0
	var image := Image.create_from_data(_bathymetry.width, _bathymetry.height, false, Image.FORMAT_RG8, packed)
	return ImageTexture.create_from_image(image)


func _exit_tree() -> void:
	if _field == null:
		return
	_field_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_field.free_resources)

@tool
class_name OceanUnderwaterEffect
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/underwater/underwater_medium.glsl"
const PARAMS_BYTES := 240
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params_buffer := RID()
var _mutex := Mutex.new()
var _enabled := true
var _sea_level := 0.0
var _camera_underwater := false
var _camera_factor := 0.0
var _transition_width := 0.12
var _absorption := Vector3(0.35, 0.14, 0.10)
var _absorption_scale := 1.0
var _scattering_color := Color(0.02, 0.32, 0.42, 1.0)
var _scattering_strength := 1.0
var _scattering_density := 0.15
var _max_distance := 120.0
var _debug_mode := 0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _sun_color := Color.WHITE
var _sun_energy := 0.0
var _sunrays_enabled := true
var _sunrays_strength := 0.35
var _sunrays_anisotropy := 0.72
var _sunrays_density := 0.08
var _sunrays_max_distance := 30.0
var _sunrays_pattern_scale := 1.0
var _sunrays_pattern_contrast := 1.4
var _sunrays_animation_speed := 0.12
var _sunrays_pattern_texture: Texture2D
var _sunrays_time := 0.0
var _dispatch_count := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()

func set_settings(is_enabled: bool, sea_level: float, camera_underwater: bool, camera_factor: float,
		transition_width: float, absorption: Vector3, absorption_scale: float,
		scattering_color: Color, scattering_strength: float, scattering_density: float,
		max_distance: float, debug_mode: int, sun_direction: Vector3, sun_color: Color,
		sun_energy: float, sunrays_enabled: bool, sunrays_strength: float,
		sunrays_anisotropy: float, sunrays_density: float, sunrays_max_distance: float,
		sunrays_pattern_scale: float, sunrays_pattern_contrast: float,
		sunrays_animation_speed: float, sunrays_pattern_texture: Texture2D,
		sunrays_time: float) -> void:
	_mutex.lock()
	_enabled = is_enabled
	_sea_level = sea_level
	_camera_underwater = camera_underwater
	_camera_factor = clampf(camera_factor, 0.0, 1.0)
	_transition_width = maxf(transition_width, 0.01)
	_absorption = Vector3(maxf(absorption.x, 0.0), maxf(absorption.y, 0.0), maxf(absorption.z, 0.0))
	_absorption_scale = clampf(absorption_scale, 0.0, 4.0)
	_scattering_color = scattering_color
	_scattering_strength = clampf(scattering_strength, 0.0, 4.0)
	_scattering_density = clampf(scattering_density, 0.0, 2.0)
	_max_distance = clampf(max_distance, 1.0, 500.0)
	_sun_direction = sun_direction.normalized() if sun_direction.length_squared() > 0.000001 else Vector3(0.0, 1.0, 0.0)
	_sun_color = sun_color
	_sun_energy = maxf(sun_energy, 0.0)
	_sunrays_enabled = sunrays_enabled
	_sunrays_strength = clampf(sunrays_strength, 0.0, 1.0)
	_sunrays_anisotropy = clampf(sunrays_anisotropy, 0.0, 0.95)
	_sunrays_density = clampf(sunrays_density, 0.0, 2.0)
	_sunrays_max_distance = clampf(sunrays_max_distance, 1.0, 100.0)
	_sunrays_pattern_scale = clampf(sunrays_pattern_scale, 0.05, 10.0)
	_sunrays_pattern_contrast = clampf(sunrays_pattern_contrast, 0.0, 4.0)
	_sunrays_animation_speed = clampf(sunrays_animation_speed, 0.0, 2.0)
	_sunrays_pattern_texture = sunrays_pattern_texture
	_sunrays_time = sunrays_time
	# Medium and sunray diagnostics belong to this compositor. Snell diagnostics
	# are rendered by the surface material and must not turn this pass into a
	# conflicting compositor visualization.
	_debug_mode = debug_mode if debug_mode <= 4 or (debug_mode >= 13 and debug_mode <= 16) else 0
	_mutex.unlock()

func reset_dispatch_count() -> void:
	_mutex.lock()
	_dispatch_count = 0
	_mutex.unlock()

func get_dispatch_count() -> int:
	_mutex.lock()
	var count := _dispatch_count
	_mutex.unlock()
	return count

func free_resources() -> void:
	if _rd == null: return
	if _pipeline.is_valid(): _rd.free_rid(_pipeline)
	_pipeline = RID()
	if _shader.is_valid(): _rd.free_rid(_shader)
	_shader = RID()
	if _sampler.is_valid(): _rd.free_rid(_sampler)
	_sampler = RID()
	if _params_buffer.is_valid(): _rd.free_rid(_params_buffer)
	_params_buffer = RID()

func _ensure_pipeline() -> bool:
	if _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid(): return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null: return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanUnderwater.Medium")
	if not _shader.is_valid(): return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	return _shader.is_valid() and _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid()

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null: return
	_mutex.lock()
	var is_enabled := _enabled
	var sea_level := _sea_level
	var camera_underwater := _camera_underwater
	var camera_factor := _camera_factor
	var transition_width := _transition_width
	var absorption := _absorption
	var absorption_scale := _absorption_scale
	var scattering_color := _scattering_color
	var scattering_strength := _scattering_strength
	var scattering_density := _scattering_density
	var max_distance := _max_distance
	var debug_mode := _debug_mode
	var sun_direction := _sun_direction
	var sun_color := _sun_color
	var sun_energy := _sun_energy
	var sunrays_enabled := _sunrays_enabled
	var sunrays_strength := _sunrays_strength
	var sunrays_anisotropy := _sunrays_anisotropy
	var sunrays_density := _sunrays_density
	var sunrays_max_distance := _sunrays_max_distance
	var sunrays_pattern_scale := _sunrays_pattern_scale
	var sunrays_pattern_contrast := _sunrays_pattern_contrast
	var sunrays_animation_speed := _sunrays_animation_speed
	var sunrays_pattern_texture := _sunrays_pattern_texture
	var sunrays_time := _sunrays_time
	_mutex.unlock()
	# In normal AIR mode this compositor remains attached but does no GPU work;
	# debug modes intentionally keep the pass alive so CAMERA_STATE can be seen.
	if not is_enabled or (not camera_underwater and debug_mode == 0) or not _ensure_pipeline(): return
	# A pipeline can only be bound with all of its backing RIDs alive. Keep this
	# explicit guard next to the render callback so a teardown/rebuild race cannot
	# reach uniform creation or dispatch with a stale shader resource.
	if not _shader.is_valid() or not _pipeline.is_valid() or not _sampler.is_valid() or not _params_buffer.is_valid(): return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null or buffers.get_view_count() != 1: return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0: return
	var color_image := buffers.get_color_layer(0)
	var depth_texture := buffers.get_depth_layer(0)
	if not color_image.is_valid() or not depth_texture.is_valid(): return
	var projection: Projection = scene_data.get_view_projection(0)
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var inverse_view_projection := (projection * Projection(camera_transform.affine_inverse())).inverse()
	var params := PackedFloat32Array()
	_append_projection(params, inverse_view_projection)
	params.append(float(size.x)); params.append(float(size.y)); params.append(0.0); params.append(0.0)
	params.append(camera_transform.origin.x); params.append(camera_transform.origin.y); params.append(camera_transform.origin.z); params.append(1.0 if camera_underwater else 0.0)
	params.append(sea_level); params.append(transition_width); params.append(max_distance); params.append(absorption_scale)
	params.append(absorption.x); params.append(absorption.y); params.append(absorption.z); params.append(scattering_strength)
	params.append(scattering_color.r); params.append(scattering_color.g); params.append(scattering_color.b); params.append(scattering_density)
	params.append(camera_factor); params.append(float(debug_mode)); params.append(1.0 if is_enabled else 0.0)
	params.append(1.0 if sunrays_pattern_texture != null and sunrays_pattern_texture.get_rid().is_valid() else 0.0)
	params.append(sun_direction.x); params.append(sun_direction.y); params.append(sun_direction.z); params.append(sun_energy)
	params.append(sun_color.r); params.append(sun_color.g); params.append(sun_color.b); params.append(0.0)
	params.append(1.0 if sunrays_enabled and sunrays_strength > 0.0 else 0.0)
	params.append(sunrays_strength); params.append(sunrays_anisotropy); params.append(sunrays_density)
	params.append(sunrays_pattern_scale); params.append(sunrays_pattern_contrast)
	params.append(sunrays_animation_speed); params.append(sunrays_time)
	params.append(sunrays_max_distance); params.append(0.0); params.append(0.0); params.append(0.0)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, params.to_byte_array())
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(color_image)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler)
	depth_uniform.add_id(depth_texture)
	var pattern_uniform := RDUniform.new()
	pattern_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	pattern_uniform.binding = 2
	pattern_uniform.add_id(_sampler)
	var pattern_texture_rid := depth_texture
	if sunrays_pattern_texture != null and sunrays_pattern_texture.get_rid().is_valid():
		var candidate_rid := RenderingServer.texture_get_rd_texture(sunrays_pattern_texture.get_rid(), true)
		if candidate_rid.is_valid(): pattern_texture_rid = candidate_rid
	pattern_uniform.add_id(pattern_texture_rid)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(_params_buffer)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, depth_uniform, pattern_uniform, params_uniform])
	if not uniform_set.is_valid(): return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()
	_mutex.lock()
	_dispatch_count += 1
	_mutex.unlock()

func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x); values.append(column.y); values.append(column.z); values.append(column.w)

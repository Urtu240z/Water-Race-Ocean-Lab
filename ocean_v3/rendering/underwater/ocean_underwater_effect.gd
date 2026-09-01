@tool
class_name OceanUnderwaterEffect
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/underwater/underwater_medium.glsl"
const SURFACE_PROBE_SHADER_PATH := "res://ocean_v3/rendering/underwater/underwater_surface_probe.glsl"
const PARAMS_BYTES := 160
const PROBE_PARAMS_BYTES := 32
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params_buffer := RID()
var _probe_shader := RID()
var _probe_pipeline := RID()
var _probe_sampler := RID()
var _probe_params_buffer := RID()
var _probe_image := RID()
var _probe_long_coastal := RID()
var _probe_long_remainder := RID()
var _probe_mid := RID()
var _probe_normal_long_coastal := RID()
var _probe_normal_long_remainder := RID()
var _probe_normal_mid := RID()
var _probe_domains := Vector3(512.0, 512.0, 137.0)
var _mutex := Mutex.new()
var _enabled := true
var _sea_level := 0.0
var _camera_underwater := false
var _camera_factor := 0.0
var _transition_width := 0.12
var _waterline_feather := 0.03
var _absorption := Vector3(0.35, 0.14, 0.10)
var _absorption_scale := 1.0
var _scattering_color := Color(0.02, 0.32, 0.42, 1.0)
var _scattering_strength := 1.0
var _scattering_density := 0.15
var _max_distance := 120.0
var _debug_mode := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func set_settings(enabled: bool, sea_level: float, camera_underwater: bool, camera_factor: float,
		transition_width: float, waterline_feather: float, absorption: Vector3, absorption_scale: float,
		scattering_color: Color, scattering_strength: float, scattering_density: float,
		max_distance: float, debug_mode: int) -> void:
	_mutex.lock()
	_enabled = enabled
	_sea_level = sea_level
	_camera_underwater = camera_underwater
	_camera_factor = clampf(camera_factor, 0.0, 1.0)
	_transition_width = maxf(transition_width, 0.01)
	_waterline_feather = clampf(waterline_feather, 0.0, 0.2)
	_absorption = Vector3(
		maxf(absorption.x, 0.0),
		maxf(absorption.y, 0.0),
		maxf(absorption.z, 0.0)
	)
	_absorption_scale = clampf(absorption_scale, 0.0, 4.0)
	_scattering_color = scattering_color
	_scattering_strength = clampf(scattering_strength, 0.0, 4.0)
	_scattering_density = clampf(scattering_density, 0.0, 2.0)
	_max_distance = clampf(max_distance, 1.0, 500.0)
	_debug_mode = clampi(debug_mode, 0, 10)
	_mutex.unlock()


func set_surface_probe_sources(long_coastal: RID, long_remainder: RID, mid: RID,
		normal_long_coastal: RID, normal_long_remainder: RID, normal_mid: RID,
		domains: Vector3) -> void:
	_mutex.lock()
	_probe_long_coastal = long_coastal
	_probe_long_remainder = long_remainder
	_probe_mid = mid
	_probe_normal_long_coastal = normal_long_coastal
	_probe_normal_long_remainder = normal_long_remainder
	_probe_normal_mid = normal_mid
	_probe_domains = Vector3(maxf(domains.x, 0.001), maxf(domains.y, 0.001), maxf(domains.z, 0.001))
	_mutex.unlock()


func free_resources() -> void:
	if _rd == null:
		return
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_shader = RID()
	_pipeline = RID()
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	_sampler = RID()
	if _params_buffer.is_valid():
		_rd.free_rid(_params_buffer)
	_params_buffer = RID()
	if _probe_shader.is_valid():
		_rd.free_rid(_probe_shader)
	_probe_shader = RID()
	_probe_pipeline = RID()
	if _probe_sampler.is_valid():
		_rd.free_rid(_probe_sampler)
	_probe_sampler = RID()
	if _probe_params_buffer.is_valid():
		_rd.free_rid(_probe_params_buffer)
	_probe_params_buffer = RID()
	if _probe_image.is_valid():
		_rd.free_rid(_probe_image)
	_probe_image = RID()


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid() \
			and _probe_pipeline.is_valid() and _probe_sampler.is_valid() \
			and _probe_params_buffer.is_valid() and _probe_image.is_valid():
		return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanUnderwater.Medium")
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	var probe_shader_file := load(SURFACE_PROBE_SHADER_PATH) as RDShaderFile
	if probe_shader_file == null:
		return false
	_probe_shader = _rd.shader_create_from_spirv(probe_shader_file.get_spirv(), "OceanUnderwater.SurfaceProbe")
	if not _probe_shader.is_valid():
		return false
	_probe_pipeline = _rd.compute_pipeline_create(_probe_shader)
	var probe_sampler_state := RDSamplerState.new()
	probe_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	probe_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	probe_sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	probe_sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_probe_sampler = _rd.sampler_create(probe_sampler_state)
	_probe_params_buffer = _rd.uniform_buffer_create(PROBE_PARAMS_BYTES)
	var probe_format := RDTextureFormat.new()
	probe_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	probe_format.width = 1
	probe_format.height = 1
	probe_format.depth = 1
	probe_format.array_layers = 1
	probe_format.mipmaps = 1
	probe_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	probe_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_probe_image = _rd.texture_create(probe_format, RDTextureView.new())
	return _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid() \
		and _probe_pipeline.is_valid() and _probe_sampler.is_valid() \
		and _probe_params_buffer.is_valid() and _probe_image.is_valid()


func _run_surface_probe(camera_transform: Transform3D, sea_level: float,
		long_coastal: RID, long_remainder: RID, mid: RID, normal_long_coastal: RID,
		normal_long_remainder: RID, normal_mid: RID, domains: Vector3) -> bool:
	if not long_coastal.is_valid() or not long_remainder.is_valid() or not mid.is_valid() \
			or not normal_long_coastal.is_valid() or not normal_long_remainder.is_valid() \
			or not normal_mid.is_valid():
		return false
	var values := PackedFloat32Array()
	values.append(camera_transform.origin.x); values.append(camera_transform.origin.z); values.append(sea_level); values.append(1.0)
	values.append(domains.x); values.append(domains.y); values.append(domains.z); values.append(0.0)
	_rd.buffer_update(_probe_params_buffer, 0, PROBE_PARAMS_BYTES, values.to_byte_array())
	var source_textures: Array[RID] = [long_coastal, long_remainder, mid,
		normal_long_coastal, normal_long_remainder, normal_mid]
	var uniforms: Array[RDUniform] = []
	for index in source_textures.size():
		var source := source_textures[index]
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = index
		uniform.add_id(_probe_sampler)
		uniform.add_id(source)
		uniforms.append(uniform)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 6
	output_uniform.add_id(_probe_image)
	uniforms.append(output_uniform)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 7
	params_uniform.add_id(_probe_params_buffer)
	uniforms.append(params_uniform)
	var uniform_set := UniformSetCacheRD.get_cache(_probe_shader, 0, uniforms)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _probe_pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	return true


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var enabled := _enabled
	var sea_level := _sea_level
	var camera_factor := _camera_factor
	var transition_width := _transition_width
	var waterline_feather := _waterline_feather
	var absorption := _absorption
	var absorption_scale := _absorption_scale
	var scattering_color := _scattering_color
	var scattering_strength := _scattering_strength
	var scattering_density := _scattering_density
	var max_distance := _max_distance
	var debug_mode := _debug_mode
	var probe_long_coastal := _probe_long_coastal
	var probe_long_remainder := _probe_long_remainder
	var probe_mid := _probe_mid
	var probe_normal_long_coastal := _probe_normal_long_coastal
	var probe_normal_long_remainder := _probe_normal_long_remainder
	var probe_normal_mid := _probe_normal_mid
	var probe_domains := _probe_domains
	_mutex.unlock()
	if not enabled or not _ensure_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color_image := buffers.get_color_layer(0)
	var depth_texture := buffers.get_depth_layer(0)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return
	var projection: Projection = scene_data.get_view_projection(0)
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var inverse_view_projection := (projection * Projection(camera_transform.affine_inverse())).inverse()
	var probe_dispatched := _run_surface_probe(camera_transform, sea_level,
		probe_long_coastal, probe_long_remainder, probe_mid, probe_normal_long_coastal,
		probe_normal_long_remainder, probe_normal_mid, probe_domains)
	var params := PackedFloat32Array()
	_append_projection(params, inverse_view_projection)
	params.append(float(size.x)); params.append(float(size.y)); params.append(0.0); params.append(0.0)
	params.append(camera_transform.origin.x); params.append(camera_transform.origin.y); params.append(camera_transform.origin.z); params.append(1.0 if probe_dispatched else 0.0)
	params.append(sea_level); params.append(transition_width); params.append(max_distance); params.append(absorption_scale)
	params.append(absorption.x); params.append(absorption.y); params.append(absorption.z); params.append(scattering_strength)
	params.append(scattering_color.r); params.append(scattering_color.g); params.append(scattering_color.b); params.append(scattering_density)
	params.append(camera_factor); params.append(float(debug_mode)); params.append(1.0 if enabled else 0.0); params.append(waterline_feather)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, params.to_byte_array())
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(color_image)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler); depth_uniform.add_id(depth_texture)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(_params_buffer)
	var probe_uniform := RDUniform.new()
	probe_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	probe_uniform.binding = 3
	probe_uniform.add_id(_sampler)
	probe_uniform.add_id(_probe_image)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, depth_uniform, params_uniform, probe_uniform])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x); values.append(column.y); values.append(column.z); values.append(column.w)

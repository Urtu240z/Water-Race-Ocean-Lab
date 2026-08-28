@tool
class_name OceanSSPREffect
extends CompositorEffect
## Rendering-thread SSPR Core MVP.
##
## The callback is deliberately PRE_TRANSPARENT: OceanV3 is transparent, so
## the resolved color/depth inputs contain opaque geometry and sky before the
## water pass is drawn. The effect never edits scene/material resources from
## the rendering thread; it only publishes an RD texture RID to its manager.

const PROJECT_SHADER_PATH := "res://ocean_v3/reflections/ocean_sspr_project.glsl"
const RESOLVE_SHADER_PATH := "res://ocean_v3/reflections/ocean_sspr_resolve.glsl"
const DOWNSAMPLE_SHADER_PATH := "res://ocean_v3/reflections/ocean_sspr_downsample.glsl"
const THREAD_X := 8
const THREAD_Y := 8
const PARAMS_BYTES := 240

var _rd: RenderingDevice
var _project_shader := RID()
var _resolve_shader := RID()
var _downsample_shader := RID()
var _project_pipeline := RID()
var _resolve_pipeline := RID()
var _downsample_pipeline := RID()
var _sampler := RID()
var _params_buffer := RID()
var _candidate_buffer := RID()
var _reflection_texture := RID()
var _mip_views: Array[RID] = []
var _source_size := Vector2i.ZERO
var _destination_size := Vector2i.ZERO
var _candidate_clear_bytes := PackedByteArray()
var _retired_texture_rids: Array[RID] = []
var _active := true
var _ocean_level := 0.0
var _output_texture_rid := RID()
var _mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func set_active(value: bool) -> void:
	_mutex.lock()
	_active = value
	_mutex.unlock()


func set_ocean_level(value: float) -> void:
	_mutex.lock()
	_ocean_level = value
	_mutex.unlock()


func get_output_texture_rid() -> RID:
	_mutex.lock()
	var result := _output_texture_rid
	_mutex.unlock()
	return result


func release_texture(texture_rid: RID) -> void:
	if _rd == null or not texture_rid.is_valid():
		return
	_mutex.lock()
	var is_current := texture_rid == _output_texture_rid
	_mutex.unlock()
	if not is_current:
		_retired_texture_rids.erase(texture_rid)
		_rd.free_rid(texture_rid)


func free_resources() -> void:
	if _rd == null:
		return
	_mutex.lock()
	_output_texture_rid = RID()
	_mutex.unlock()
	for rid in [_candidate_buffer, _params_buffer, _sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_free_mip_views()
	if _reflection_texture.is_valid():
		_rd.free_rid(_reflection_texture)
	for rid in [_project_shader, _resolve_shader, _downsample_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	for rid in _retired_texture_rids:
		if rid.is_valid():
			_rd.free_rid(rid)
	_retired_texture_rids.clear()
	_candidate_buffer = RID()
	_params_buffer = RID()
	_sampler = RID()
	_reflection_texture = RID()
	_project_shader = RID()
	_resolve_shader = RID()
	_downsample_shader = RID()
	_project_pipeline = RID()
	_resolve_pipeline = RID()
	_source_size = Vector2i.ZERO
	_destination_size = Vector2i.ZERO
	_candidate_clear_bytes = PackedByteArray()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var active := _active
	var sea_level := _ocean_level
	_mutex.unlock()
	if not active or not _ensure_pipelines():
		return

	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var render_scene_data := render_data.get_render_scene_data()
	if render_scene_buffers == null or render_scene_data == null:
		return
	var source_size := render_scene_buffers.get_internal_size()
	if source_size.x <= 0 or source_size.y <= 0 or render_scene_buffers.get_view_count() != 1:
		return
	# The payload reserves 26 bits for source_id. This covers normal Forward+
	# resolutions and avoids truncating an address on unusually large targets.
	if source_size.x * source_size.y > (1 << 26):
		return
	var destination_size := Vector2i(
		ceili(float(source_size.x + 3) / 4.0),
		ceili(float(source_size.y + 3) / 4.0)
	)
	if not _ensure_resources(source_size, destination_size):
		return

	var scene_color := render_scene_buffers.get_color_layer(0)
	var scene_depth := render_scene_buffers.get_depth_layer(0)
	if not scene_color.is_valid() or not scene_depth.is_valid():
		return

	var projection: Projection = render_scene_data.get_view_projection(0)
	var inverse_projection := projection.inverse()
	var camera_transform: Transform3D = render_scene_data.get_cam_transform()
	var view_transform := camera_transform.affine_inverse()
	var inverse_view: Projection = Projection(camera_transform)
	var view: Projection = Projection(view_transform)
	var view_projection: Projection = projection * view
	var params_data := _pack_params(
		inverse_projection,
		inverse_view,
		view_projection,
		source_size,
		destination_size,
		sea_level
	)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, params_data.to_byte_array())
	_rd.buffer_update(_candidate_buffer, 0, _candidate_clear_bytes.size(), _candidate_clear_bytes)

	var project_uniforms: Array[RDUniform] = []
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 0
	depth_uniform.add_id(_sampler)
	depth_uniform.add_id(scene_depth)
	project_uniforms.append(depth_uniform)
	var candidate_uniform := RDUniform.new()
	candidate_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	candidate_uniform.binding = 1
	candidate_uniform.add_id(_candidate_buffer)
	project_uniforms.append(candidate_uniform)
	var project_params := RDUniform.new()
	project_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	project_params.binding = 2
	project_params.add_id(_params_buffer)
	project_uniforms.append(project_params)
	var project_set := UniformSetCacheRD.get_cache(_project_shader, 0, project_uniforms)

	var resolve_uniforms: Array[RDUniform] = []
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	color_uniform.binding = 0
	color_uniform.add_id(_sampler)
	color_uniform.add_id(scene_color)
	resolve_uniforms.append(color_uniform)
	var resolve_candidates := RDUniform.new()
	resolve_candidates.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	resolve_candidates.binding = 1
	resolve_candidates.add_id(_candidate_buffer)
	resolve_uniforms.append(resolve_candidates)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 2
	output_uniform.add_id(_mip_views[0])
	resolve_uniforms.append(output_uniform)
	var resolve_params := RDUniform.new()
	resolve_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	resolve_params.binding = 3
	resolve_params.add_id(_params_buffer)
	resolve_uniforms.append(resolve_params)
	var resolve_set := UniformSetCacheRD.get_cache(_resolve_shader, 0, resolve_uniforms)

	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _project_pipeline)
	_rd.compute_list_bind_uniform_set(list, project_set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(source_size.x + THREAD_X - 1) / float(THREAD_X)),
		ceili(float(source_size.y + THREAD_Y - 1) / float(THREAD_Y)), 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _resolve_pipeline)
	_rd.compute_list_bind_uniform_set(list, resolve_set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(destination_size.x + THREAD_X - 1) / float(THREAD_X)),
		ceili(float(destination_size.y + THREAD_Y - 1) / float(THREAD_Y)), 1)
	_rd.compute_list_add_barrier(list)
	for mip in range(1, _mip_views.size()):
		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source_uniform.binding = 0
		source_uniform.add_id(_sampler)
		source_uniform.add_id(_mip_views[mip - 1])
		var destination_uniform := RDUniform.new()
		destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		destination_uniform.binding = 1
		destination_uniform.add_id(_mip_views[mip])
		var mip_set := UniformSetCacheRD.get_cache(
			_downsample_shader, 0, [source_uniform, destination_uniform])
		var mip_size := Vector2i(
			maxi(destination_size.x >> mip, 1),
			maxi(destination_size.y >> mip, 1)
		)
		_rd.compute_list_bind_compute_pipeline(list, _downsample_pipeline)
		_rd.compute_list_bind_uniform_set(list, mip_set, 0)
		_rd.compute_list_dispatch(list,
			ceili(float(mip_size.x + THREAD_X - 1) / float(THREAD_X)),
			ceili(float(mip_size.y + THREAD_Y - 1) / float(THREAD_Y)), 1)
		if mip + 1 < _mip_views.size():
			_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()


func _ensure_pipelines() -> bool:
	if _project_pipeline.is_valid() and _resolve_pipeline.is_valid():
		return true
	var project_file: RDShaderFile = load(PROJECT_SHADER_PATH)
	var resolve_file: RDShaderFile = load(RESOLVE_SHADER_PATH)
	if project_file == null or resolve_file == null:
		return false
	_project_shader = _rd.shader_create_from_spirv(project_file.get_spirv(), "OceanSSPR.Project")
	_resolve_shader = _rd.shader_create_from_spirv(resolve_file.get_spirv(), "OceanSSPR.Resolve")
	_downsample_shader = _compile_compute_shader_source(DOWNSAMPLE_SHADER_PATH, "OceanSSPR.Downsample")
	if not _project_shader.is_valid() or not _resolve_shader.is_valid() or not _downsample_shader.is_valid():
		return false
	_project_pipeline = _rd.compute_pipeline_create(_project_shader)
	_resolve_pipeline = _rd.compute_pipeline_create(_resolve_shader)
	_downsample_pipeline = _rd.compute_pipeline_create(_downsample_shader)
	return _project_pipeline.is_valid() and _resolve_pipeline.is_valid() and _downsample_pipeline.is_valid()


func _compile_compute_shader_source(path: String, shader_name: String) -> RID:
	var source_code := FileAccess.get_file_as_string(path)
	if source_code.is_empty():
		push_error("OceanSSPR: unable to read compute shader source: %s" % path)
		return RID()
	# #[compute] is the editor importer directive, not GLSL source. The
	# imported Phase 2 shaders use RDShaderFile; this small Phase 3 shader is
	# compiled directly so a stale/missing .import cannot disable SSPR.
	if source_code.begins_with("#[compute]"):
		var first_newline := source_code.find("\n")
		if first_newline >= 0:
			source_code = source_code.substr(first_newline + 1)
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = source_code
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if spirv.bytecode_compute.is_empty():
		push_error("OceanSSPR: compute shader compilation failed for %s: %s" % [
			path, spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)])
		return RID()
	return _rd.shader_create_from_spirv(spirv, shader_name)


func _ensure_resources(source_size: Vector2i, destination_size: Vector2i) -> bool:
	if source_size == _source_size and destination_size == _destination_size and _reflection_texture.is_valid():
		return true
	if _candidate_buffer.is_valid():
		_rd.free_rid(_candidate_buffer)
	_candidate_buffer = RID()
	if _params_buffer.is_valid():
		_rd.free_rid(_params_buffer)
	_params_buffer = RID()
	_free_mip_views()
	if _reflection_texture.is_valid():
		_mutex.lock()
		var old_output := _output_texture_rid
		_mutex.unlock()
		# Keep the old output alive until the manager detaches its Texture2DRD
		# view. The manager releases it explicitly on the render thread.
		if old_output.is_valid():
			# The old RID is no longer current once the new texture is published.
			_mutex.lock()
			_output_texture_rid = RID()
			_mutex.unlock()
			_retired_texture_rids.append(old_output)
		_reflection_texture = RID()

	_source_size = source_size
	_destination_size = destination_size
	var candidate_count := destination_size.x * destination_size.y
	var clear_values := PackedInt32Array()
	clear_values.resize(candidate_count)
	for index in candidate_count:
		clear_values[index] = -1
	_candidate_clear_bytes = clear_values.to_byte_array()
	_candidate_buffer = _rd.storage_buffer_create(_candidate_clear_bytes.size(), _candidate_clear_bytes)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	if not _candidate_buffer.is_valid() or not _params_buffer.is_valid():
		return false

	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = destination_size.x
	format.height = destination_size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = _mip_count(destination_size)
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_reflection_texture = _rd.texture_create(format, RDTextureView.new())
	if not _reflection_texture.is_valid():
		return false
	for mip in format.mipmaps:
		var mip_view := _rd.texture_create_shared_from_slice(
			RDTextureView.new(), _reflection_texture, 0, mip, 1)
		if not mip_view.is_valid():
			_free_mip_views()
			_rd.free_rid(_reflection_texture)
			_reflection_texture = RID()
			return false
		_mip_views.append(mip_view)
	_rd.set_resource_name(_candidate_buffer, "OceanSSPR.Candidates")
	_rd.set_resource_name(_params_buffer, "OceanSSPR.Params")
	_rd.set_resource_name(_reflection_texture, "OceanSSPR.ReflectionRGBA16F")
	_mutex.lock()
	_output_texture_rid = _reflection_texture
	_mutex.unlock()
	if not _sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_sampler = _rd.sampler_create(sampler_state)
	return _sampler.is_valid()


func _mip_count(size: Vector2i) -> int:
	return floori(log(float(maxi(size.x, size.y))) / log(2.0)) + 1


func _free_mip_views() -> void:
	for view in _mip_views:
		if view.is_valid():
			_rd.free_rid(view)
	_mip_views.clear()


func _pack_params(inverse_projection: Projection, inverse_view: Projection,
		view_projection: Projection, source_size: Vector2i,
		destination_size: Vector2i, sea_level: float) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	_append_projection(values, inverse_projection)
	_append_projection(values, inverse_view)
	_append_projection(values, view_projection)
	values.append(float(source_size.x))
	values.append(float(source_size.y))
	values.append(0.0)
	values.append(0.0)
	values.append(float(destination_size.x))
	values.append(float(destination_size.y))
	values.append(0.0)
	values.append(0.0)
	values.append(sea_level)
	values.append(0.0)
	values.append(0.0)
	values.append(0.0)
	return values


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x)
		values.append(column.y)
		values.append(column.z)
		values.append(column.w)

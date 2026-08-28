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
const TEMPORAL_SHADER_PATH := "res://ocean_v3/reflections/ocean_sspr_temporal.glsl"
const THREAD_X := 8
const THREAD_Y := 8
const PARAMS_BYTES := 240
const TEMPORAL_PARAMS_BYTES := 176

var _rd: RenderingDevice
var _project_shader := RID()
var _resolve_shader := RID()
var _downsample_shader := RID()
var _temporal_shader := RID()
var _project_pipeline := RID()
var _resolve_pipeline := RID()
var _downsample_pipeline := RID()
var _temporal_pipeline := RID()
var _sampler := RID()
var _params_buffer := RID()
var _temporal_params_buffer := RID()
var _candidate_buffer := RID()
var _reflection_texture := RID()
var _current_texture := RID()
var _current_depth_texture := RID()
var _history_color_read := RID()
var _history_color_write := RID()
var _history_depth_read := RID()
var _history_depth_write := RID()
var _mip_views: Array[RID] = []
var _source_size := Vector2i.ZERO
var _destination_size := Vector2i.ZERO
var _candidate_clear_bytes := PackedByteArray()
var _retired_texture_rids: Array[RID] = []
var _active := true
var _ocean_level := 0.0
var _temporal_enabled := true
var _temporal_weight := 0.12
var _temporal_depth_threshold := 0.035
var _conservative_coverage_enabled := true
var _history_valid := false
var _has_previous_frame := false
var _previous_view_projection := Projection()
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


func set_temporal_settings(effect_enabled: bool, weight: float, depth_threshold: float) -> void:
	_mutex.lock()
	_temporal_enabled = effect_enabled
	_temporal_weight = clampf(weight, 0.0, 0.5)
	_temporal_depth_threshold = clampf(depth_threshold, 0.001, 0.25)
	_mutex.unlock()


func set_conservative_coverage_enabled(value: bool) -> void:
	_mutex.lock()
	_conservative_coverage_enabled = value
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
	for rid in [_candidate_buffer, _params_buffer, _temporal_params_buffer, _sampler,
			_current_texture, _current_depth_texture, _history_color_read, _history_color_write,
			_history_depth_read, _history_depth_write]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_free_mip_views()
	if _reflection_texture.is_valid():
		_rd.free_rid(_reflection_texture)
	for rid in [_project_shader, _resolve_shader, _downsample_shader, _temporal_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	for rid in _retired_texture_rids:
		if rid.is_valid():
			_rd.free_rid(rid)
	_retired_texture_rids.clear()
	_candidate_buffer = RID()
	_params_buffer = RID()
	_temporal_params_buffer = RID()
	_sampler = RID()
	_reflection_texture = RID()
	_current_texture = RID()
	_current_depth_texture = RID()
	_history_color_read = RID()
	_history_color_write = RID()
	_history_depth_read = RID()
	_history_depth_write = RID()
	_project_shader = RID()
	_resolve_shader = RID()
	_downsample_shader = RID()
	_temporal_shader = RID()
	_project_pipeline = RID()
	_resolve_pipeline = RID()
	_source_size = Vector2i.ZERO
	_destination_size = Vector2i.ZERO
	_candidate_clear_bytes = PackedByteArray()
	_history_valid = false
	_has_previous_frame = false


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var active := _active
	var sea_level := _ocean_level
	var temporal_enabled := _temporal_enabled
	var temporal_weight := _temporal_weight
	var temporal_depth_threshold := _temporal_depth_threshold
	var conservative_coverage_enabled := _conservative_coverage_enabled
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
	# The projection hash stores each source coordinate in 16 bits.
	if source_size.x > 65535 or source_size.y > 65535:
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
		sea_level,
		conservative_coverage_enabled
	)
	var temporal_params_data := _pack_temporal_params(
		view_projection.inverse(),
		view_projection,
		destination_size,
		sea_level,
		temporal_enabled,
		temporal_weight,
		temporal_depth_threshold,
		_history_valid and _has_previous_frame
	)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, params_data.to_byte_array())
	_rd.buffer_update(_temporal_params_buffer, 0, TEMPORAL_PARAMS_BYTES,
		temporal_params_data.to_byte_array())
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
	output_uniform.add_id(_current_texture)
	resolve_uniforms.append(output_uniform)
	var resolve_params := RDUniform.new()
	resolve_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	resolve_params.binding = 3
	resolve_params.add_id(_params_buffer)
	resolve_uniforms.append(resolve_params)
	var resolve_depth_input := RDUniform.new()
	resolve_depth_input.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	resolve_depth_input.binding = 5
	resolve_depth_input.add_id(_sampler)
	resolve_depth_input.add_id(scene_depth)
	resolve_uniforms.append(resolve_depth_input)
	var resolve_depth_output := RDUniform.new()
	resolve_depth_output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	resolve_depth_output.binding = 4
	resolve_depth_output.add_id(_current_depth_texture)
	resolve_uniforms.append(resolve_depth_output)
	var resolve_set := UniformSetCacheRD.get_cache(_resolve_shader, 0, resolve_uniforms)

	var temporal_current_color := RDUniform.new()
	temporal_current_color.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	temporal_current_color.binding = 0
	temporal_current_color.add_id(_sampler)
	temporal_current_color.add_id(_current_texture)
	var temporal_current_depth := RDUniform.new()
	temporal_current_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	temporal_current_depth.binding = 1
	temporal_current_depth.add_id(_sampler)
	temporal_current_depth.add_id(_current_depth_texture)
	var temporal_history_color := RDUniform.new()
	temporal_history_color.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	temporal_history_color.binding = 2
	temporal_history_color.add_id(_sampler)
	temporal_history_color.add_id(_history_color_read)
	var temporal_history_depth := RDUniform.new()
	temporal_history_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	temporal_history_depth.binding = 3
	temporal_history_depth.add_id(_sampler)
	temporal_history_depth.add_id(_history_depth_read)
	var temporal_output := RDUniform.new()
	temporal_output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	temporal_output.binding = 4
	temporal_output.add_id(_mip_views[0])
	var temporal_history_output := RDUniform.new()
	temporal_history_output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	temporal_history_output.binding = 5
	temporal_history_output.add_id(_history_color_write)
	var temporal_depth_output := RDUniform.new()
	temporal_depth_output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	temporal_depth_output.binding = 6
	temporal_depth_output.add_id(_history_depth_write)
	var temporal_params := RDUniform.new()
	temporal_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	temporal_params.binding = 7
	temporal_params.add_id(_temporal_params_buffer)
	var temporal_set := UniformSetCacheRD.get_cache(_temporal_shader, 0, [
		temporal_current_color, temporal_current_depth, temporal_history_color,
		temporal_history_depth, temporal_output, temporal_history_output,
		temporal_depth_output, temporal_params])

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
	_rd.compute_list_bind_compute_pipeline(list, _temporal_pipeline)
	_rd.compute_list_bind_uniform_set(list, temporal_set, 0)
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
	_previous_view_projection = view_projection
	_has_previous_frame = true
	_history_valid = true
	_swap_history_buffers()


func _ensure_pipelines() -> bool:
	if _project_pipeline.is_valid() and _resolve_pipeline.is_valid() and \
			_downsample_pipeline.is_valid() and _temporal_pipeline.is_valid():
		return true
	var project_file: RDShaderFile = load(PROJECT_SHADER_PATH)
	var resolve_file: RDShaderFile = load(RESOLVE_SHADER_PATH)
	if project_file == null or resolve_file == null:
		return false
	_project_shader = _rd.shader_create_from_spirv(project_file.get_spirv(), "OceanSSPR.Project")
	_resolve_shader = _rd.shader_create_from_spirv(resolve_file.get_spirv(), "OceanSSPR.Resolve")
	_downsample_shader = _compile_compute_shader_source(DOWNSAMPLE_SHADER_PATH, "OceanSSPR.Downsample")
	_temporal_shader = _compile_compute_shader_source(TEMPORAL_SHADER_PATH, "OceanSSPR.Temporal")
	if not _project_shader.is_valid() or not _resolve_shader.is_valid() or \
			not _downsample_shader.is_valid() or not _temporal_shader.is_valid():
		return false
	_project_pipeline = _rd.compute_pipeline_create(_project_shader)
	_resolve_pipeline = _rd.compute_pipeline_create(_resolve_shader)
	_downsample_pipeline = _rd.compute_pipeline_create(_downsample_shader)
	_temporal_pipeline = _rd.compute_pipeline_create(_temporal_shader)
	return _project_pipeline.is_valid() and _resolve_pipeline.is_valid() and \
			_downsample_pipeline.is_valid() and _temporal_pipeline.is_valid()


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
	if source_size == _source_size and destination_size == _destination_size and \
			_reflection_texture.is_valid() and _current_texture.is_valid() and \
			_history_color_read.is_valid() and _history_color_write.is_valid():
		return true
	if _candidate_buffer.is_valid():
		_rd.free_rid(_candidate_buffer)
	_candidate_buffer = RID()
	if _params_buffer.is_valid():
		_rd.free_rid(_params_buffer)
	_params_buffer = RID()
	if _temporal_params_buffer.is_valid():
		_rd.free_rid(_temporal_params_buffer)
	_temporal_params_buffer = RID()
	_free_mip_views()
	for rid in [_current_texture, _current_depth_texture, _history_color_read,
			_history_color_write, _history_depth_read, _history_depth_write]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_current_texture = RID()
	_current_depth_texture = RID()
	_history_color_read = RID()
	_history_color_write = RID()
	_history_depth_read = RID()
	_history_depth_write = RID()
	_history_valid = false
	_has_previous_frame = false
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
		clear_values[index] = 0
	_candidate_clear_bytes = clear_values.to_byte_array()
	_candidate_buffer = _rd.storage_buffer_create(_candidate_clear_bytes.size(), _candidate_clear_bytes)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	_temporal_params_buffer = _rd.uniform_buffer_create(TEMPORAL_PARAMS_BYTES)
	if not _candidate_buffer.is_valid() or not _params_buffer.is_valid() or \
			not _temporal_params_buffer.is_valid():
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
	var working_color_format := RDTextureFormat.new()
	working_color_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	working_color_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	working_color_format.width = destination_size.x
	working_color_format.height = destination_size.y
	working_color_format.depth = 1
	working_color_format.array_layers = 1
	working_color_format.mipmaps = 1
	working_color_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | \
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_current_texture = _rd.texture_create(working_color_format, RDTextureView.new())
	_history_color_read = _rd.texture_create(working_color_format, RDTextureView.new())
	_history_color_write = _rd.texture_create(working_color_format, RDTextureView.new())
	var working_depth_format := RDTextureFormat.new()
	working_depth_format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	working_depth_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	working_depth_format.width = destination_size.x
	working_depth_format.height = destination_size.y
	working_depth_format.depth = 1
	working_depth_format.array_layers = 1
	working_depth_format.mipmaps = 1
	working_depth_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | \
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_current_depth_texture = _rd.texture_create(working_depth_format, RDTextureView.new())
	_history_depth_read = _rd.texture_create(working_depth_format, RDTextureView.new())
	_history_depth_write = _rd.texture_create(working_depth_format, RDTextureView.new())
	if not _current_texture.is_valid() or not _current_depth_texture.is_valid() or \
			not _history_color_read.is_valid() or not _history_color_write.is_valid() or \
			not _history_depth_read.is_valid() or not _history_depth_write.is_valid():
		return false
	_rd.set_resource_name(_candidate_buffer, "OceanSSPR.Candidates")
	_rd.set_resource_name(_params_buffer, "OceanSSPR.Params")
	_rd.set_resource_name(_temporal_params_buffer, "OceanSSPR.TemporalParams")
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


func _pack_temporal_params(current_inverse_view_projection: Projection,
		previous_view_projection: Projection, destination_size: Vector2i,
		sea_level: float, temporal_enabled: bool, temporal_weight: float,
		depth_threshold: float, history_valid: bool) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	_append_projection(values, current_inverse_view_projection)
	_append_projection(values, previous_view_projection)
	values.append(float(destination_size.x))
	values.append(float(destination_size.y))
	values.append(0.0)
	values.append(0.0)
	values.append(1.0 if temporal_enabled else 0.0)
	values.append(temporal_weight)
	values.append(depth_threshold)
	values.append(1.0 if history_valid else 0.0)
	values.append(sea_level)
	values.append(0.0)
	values.append(0.0)
	values.append(0.0)
	return values


func _swap_history_buffers() -> void:
	var color_buffer := _history_color_read
	_history_color_read = _history_color_write
	_history_color_write = color_buffer
	var depth_buffer := _history_depth_read
	_history_depth_read = _history_depth_write
	_history_depth_write = depth_buffer


func _free_mip_views() -> void:
	for view in _mip_views:
		if view.is_valid():
			_rd.free_rid(view)
	_mip_views.clear()


func _pack_params(inverse_projection: Projection, inverse_view: Projection,
		view_projection: Projection, source_size: Vector2i,
		destination_size: Vector2i, sea_level: float,
		conservative_coverage_enabled: bool) -> PackedFloat32Array:
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
	values.append(1.0 if conservative_coverage_enabled else 0.0)
	values.append(0.0)
	values.append(0.0)
	return values


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x)
		values.append(column.y)
		values.append(column.z)
		values.append(column.w)

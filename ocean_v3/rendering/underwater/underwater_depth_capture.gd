@tool
class_name OceanUnderwaterDepthCaptureEffect
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/underwater/underwater_depth_capture.glsl"
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _depth_snapshot := RID()
var _snapshot_size := Vector2i.ZERO


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func get_depth_snapshot(expected_size: Vector2i) -> RID:
	return _depth_snapshot if _snapshot_size == expected_size and _depth_snapshot.is_valid() else RID()


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
	if _depth_snapshot.is_valid():
		_rd.free_rid(_depth_snapshot)
	_depth_snapshot = RID()
	_snapshot_size = Vector2i.ZERO


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid() and _sampler.is_valid():
		return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanUnderwater.DepthCapture")
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	return _pipeline.is_valid() and _sampler.is_valid()


func _ensure_snapshot(size: Vector2i) -> bool:
	if _snapshot_size == size and _depth_snapshot.is_valid():
		return true
	if _depth_snapshot.is_valid():
		_rd.free_rid(_depth_snapshot)
	_depth_snapshot = RID()
	_snapshot_size = Vector2i.ZERO
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_depth_snapshot = _rd.texture_create(format, RDTextureView.new())
	_snapshot_size = size if _depth_snapshot.is_valid() else Vector2i.ZERO
	return _depth_snapshot.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null or not _ensure_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _ensure_snapshot(size):
		return
	var source_depth := buffers.get_depth_layer(0)
	if not source_depth.is_valid() or not _depth_snapshot.is_valid():
		return
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_sampler)
	source_uniform.add_id(source_depth)
	var destination_uniform := RDUniform.new()
	destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	destination_uniform.binding = 1
	destination_uniform.add_id(_depth_snapshot)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [source_uniform, destination_uniform])
	if not uniform_set.is_valid():
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()

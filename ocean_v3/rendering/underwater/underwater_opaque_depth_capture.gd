@tool
class_name OceanUnderwaterOpaqueDepthCapture
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/underwater/underwater_opaque_depth_capture.glsl"
const PARAMS_BYTES := 16
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params := RID()
var _snapshot := RID()
var _snapshot_size := Vector2i.ZERO
var _retired_snapshots: Array[RID] = []

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()

func get_snapshot() -> RID:
	return _snapshot

func free_resources() -> void:
	if _rd == null: return
	# The render server may already reclaim the storage texture during viewport
	# teardown; only release the pipeline-owned handles here, in dependency order.
	if _pipeline.is_valid(): _rd.free_rid(_pipeline)
	if _shader.is_valid(): _rd.free_rid(_shader)
	if _sampler.is_valid(): _rd.free_rid(_sampler)
	if _params.is_valid(): _rd.free_rid(_params)
	_shader = RID(); _pipeline = RID(); _sampler = RID(); _params = RID(); _snapshot = RID()
	_retired_snapshots.clear()
	_snapshot_size = Vector2i.ZERO

func _ensure(size: Vector2i) -> bool:
	if _pipeline.is_valid() and _sampler.is_valid() and _params.is_valid() and _snapshot.is_valid() and _snapshot_size == size:
		return true
	var file := load(SHADER_PATH) as RDShaderFile
	if file == null: return false
	if not _shader.is_valid(): _shader = _rd.shader_create_from_spirv(file.get_spirv(), "OceanUnderwater.OpaqueDepth")
	if not _shader.is_valid(): return false
	if not _pipeline.is_valid(): _pipeline = _rd.compute_pipeline_create(_shader)
	if not _sampler.is_valid():
		var state := RDSamplerState.new()
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_sampler = _rd.sampler_create(state)
	if not _params.is_valid(): _params = _rd.uniform_buffer_create(PARAMS_BYTES)
	if not _snapshot.is_valid() or _snapshot_size != size:
		# Keep the previous texture alive for the in-flight POST effect. The
		# manager publishes the replacement on the next main-thread tick; freeing
		# it here would leave one frame with a stale RID.
		if _snapshot.is_valid(): _retired_snapshots.append(_snapshot)
		var fmt := RDTextureFormat.new()
		fmt.width = size.x; fmt.height = size.y; fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		_snapshot = _rd.texture_create(fmt, RDTextureView.new())
		_snapshot_size = size
	return _pipeline.is_valid() and _sampler.is_valid() and _params.is_valid() and _snapshot.is_valid()

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null: return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1: return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _ensure(size): return
	var source := buffers.get_depth_layer(0)
	if not source.is_valid() or not _snapshot.is_valid() or not _params.is_valid(): return
	var values := PackedFloat32Array([float(size.x), float(size.y), 0.0, 0.0])
	_rd.buffer_update(_params, 0, PARAMS_BYTES, values.to_byte_array())
	var source_u := RDUniform.new(); source_u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; source_u.binding = 0; source_u.add_id(_sampler); source_u.add_id(source)
	var image_u := RDUniform.new(); image_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; image_u.binding = 1; image_u.add_id(_snapshot)
	var params_u := RDUniform.new(); params_u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params_u.binding = 2; params_u.add_id(_params)
	var set := UniformSetCacheRD.get_cache(_shader, 0, [source_u, image_u, params_u])
	if not set.is_valid(): return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()

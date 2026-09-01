@tool
class_name WaterLensEffect
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/underwater/water_lens.glsl"
const PARAMS_BYTES := 3136 # 16 header floats + 64 droplets * 12 floats.
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _params_buffer := RID()
var _mutex := Mutex.new()
var _frame_data := PackedFloat32Array()
var _active := false
var _dispatch_count := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()
	_frame_data.resize(PARAMS_BYTES >> 2)

func set_frame_data(data: PackedFloat32Array, active: bool) -> void:
	_mutex.lock()
	_frame_data = data.duplicate()
	_active = active
	_mutex.unlock()

func reset_dispatch_count() -> void:
	_mutex.lock()
	_dispatch_count = 0
	_mutex.unlock()

func get_dispatch_count() -> int:
	_mutex.lock()
	var value := _dispatch_count
	_mutex.unlock()
	return value

func free_resources() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	_pipeline = RID()
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_shader = RID()
	if _params_buffer.is_valid():
		_rd.free_rid(_params_buffer)
	_params_buffer = RID()

func _ensure_pipeline() -> bool:
	if _shader.is_valid() and _pipeline.is_valid() and _params_buffer.is_valid():
		return true
	if _rd == null:
		return false
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "WaterLens.Shader")
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	return _shader.is_valid() and _pipeline.is_valid() and _params_buffer.is_valid()

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var active := _active
	var data := _frame_data.duplicate()
	_mutex.unlock()
	if not active or not _ensure_pipeline():
		return
	if not _shader.is_valid() or not _pipeline.is_valid() or not _params_buffer.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color_image := buffers.get_color_layer(0)
	if not color_image.is_valid() or data.size() * 4 != PARAMS_BYTES:
		return
	data[0] = float(size.x)
	data[1] = float(size.y)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, data.to_byte_array())
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(color_image)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(_params_buffer)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, params_uniform])
	if not uniform_set.is_valid():
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()
	_mutex.lock()
	_dispatch_count += 1
	_mutex.unlock()

@tool
class_name OceanCausticsEffect
extends CompositorEffect

const SHADER_PATH := "res://ocean_v3/rendering/caustics/project_reference_caustics.glsl"
const PARAMS_BYTES := 128
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _texture_rid := RID()
var _active := false
var _debug_mode := 0
var _sea_level := 0.0
var _texture_scale := 0.105
var _strength := 0.65
var _power := 1.0
var _fade_start := 4.0
var _max_depth := 6.0
var _time := 0.0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func set_settings(active: bool, sea_level: float, texture: Texture2D, texture_scale: float,
		strength: float, power: float, fade_start: float, max_depth: float,
		sun_direction: Vector3, debug_mode: int) -> void:
	var texture_rid := RID()
	if texture != null and texture.get_rid().is_valid():
		texture_rid = RenderingServer.texture_get_rd_texture(texture.get_rid(), true)
	_mutex.lock()
	_active = active
	_sea_level = sea_level
	_texture_rid = texture_rid
	_texture_scale = maxf(texture_scale, 0.0001)
	_strength = maxf(strength, 0.0)
	_power = maxf(power, 0.01)
	_fade_start = maxf(fade_start, 0.0)
	_max_depth = maxf(max_depth, _fade_start + 0.001)
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	_mutex.unlock()


func set_time(value: float) -> void:
	_mutex.lock()
	_time = value
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


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid() and _sampler.is_valid():
		return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanCaustics.Project")
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(sampler_state)
	return _pipeline.is_valid() and _sampler.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var active := _active
	var sea_level := _sea_level
	var texture_rid := _texture_rid
	var texture_scale := _texture_scale
	var strength := _strength
	var power := _power
	var fade_start := _fade_start
	var max_depth := _max_depth
	var time := _time
	var sun_direction := _sun_direction
	var debug_mode := _debug_mode
	_mutex.unlock()
	if not active or not texture_rid.is_valid() or not _ensure_pipeline():
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
	var view_transform := camera_transform.affine_inverse()
	var inverse_view_projection := (projection * Projection(view_transform)).inverse()
	var push := PackedFloat32Array()
	_append_projection(push, inverse_view_projection)
	push.append(float(size.x)); push.append(float(size.y)); push.append(0.0); push.append(0.0)
	push.append(sea_level); push.append(texture_scale); push.append(strength); push.append(power)
	push.append(fade_start); push.append(max_depth); push.append(time)
	push.append(0.0 if not active else 2.0 if debug_mode >= 2 else 1.0)
	push.append(sun_direction.x); push.append(sun_direction.y); push.append(sun_direction.z); push.append(0.0)
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(color_image)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler); depth_uniform.add_id(depth_texture)
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	texture_uniform.binding = 2
	texture_uniform.add_id(_sampler); texture_uniform.add_id(texture_rid)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, depth_uniform, texture_uniform])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, push.to_byte_array(), PARAMS_BYTES)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x); values.append(column.y); values.append(column.z); values.append(column.w)

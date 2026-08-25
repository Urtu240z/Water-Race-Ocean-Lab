class_name SurfaceFoamMidHistorySolver
extends RefCounted
## Persistent MID-fold eligibility driven only by the exact MID Jacobian.

const UPDATE_SHADER := "res://ocean_v3/rendering/fft/shaders/update_surface_foam_mid_history.glsl"

var ready := false
var last_error := ""
var history_rid := RID()

var _rd: RenderingDevice
var _history: Array[RID] = [RID(), RID()]
var _sampler := RID()
var _shader := RID()
var _pipeline := RID()
var _sets: Array[RID] = []
var _read_index := 0
var _resolution := 0
var _accumulator := 0.0
var _enabled := true
var _update_hz := 30.0
var _birth_attack_s := 0.16
var _lifetime_s := 1.10
var _fold_start := 0.10
var _fold_end := 0.24


func initialize(displacement_mid: RID, resolution: int, resource_prefix := "Ocean2B.SurfaceFoamMidHistory") -> void:
	free_resources()
	_resolution = max(resolution, 1)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not displacement_mid.is_valid():
		last_error = "No se pudo inicializar MID Fold History."
		return
	var shader_file: RDShaderFile = load(UPDATE_SHADER)
	if shader_file == null:
		last_error = "No se pudo cargar %s" % UPDATE_SHADER
		return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), resource_prefix + ".Shader")
	if not _shader.is_valid():
		last_error = "No se pudo compilar %s" % UPDATE_SHADER
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	_sampler = _create_nearest_repeat_sampler()
	var initial_data := PackedByteArray()
	initial_data.resize(_resolution * _resolution * 2)
	for index in 2:
		_history[index] = _create_history_texture(resource_prefix + ".History%d" % index, initial_data)
	for previous_index in 2:
		_sets.append(_create_set(displacement_mid, _history[previous_index], _history[1 - previous_index]))
	ready = _pipeline.is_valid() and _sets.size() == 2 and _sets[0].is_valid() and _sets[1].is_valid()
	if ready:
		history_rid = _history[0]
	else:
		last_error = "No se pudieron crear los recursos de MID Fold History."


func set_settings(enabled: bool, update_hz: float, birth_attack_s: float, lifetime_s: float, fold_start: float, fold_end: float) -> void:
	_enabled = enabled
	_update_hz = clampf(update_hz, 30.0, 60.0)
	_birth_attack_s = clampf(birth_attack_s, 0.02, 1.0)
	_lifetime_s = clampf(lifetime_s, 0.1, 5.0)
	_fold_start = clampf(fold_start, 0.0, 1.0)
	_fold_end = maxf(fold_end, _fold_start + 0.01)


func advance(frame_delta: float) -> void:
	if not ready or not _enabled:
		return
	_accumulator += maxf(frame_delta, 0.0)
	var period := 1.0 / _update_hz
	if _accumulator < period:
		return
	var delta_s := _accumulator
	_accumulator = 0.0
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_read_index], 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([
		delta_s, _birth_attack_s, _lifetime_s, 0.0,
		_fold_start, _fold_end, 0.0, 0.0
	]).to_byte_array(), 32)
	var groups := ceili(float(_resolution) / 8.0)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()
	_read_index = 1 - _read_index
	history_rid = _history[_read_index]


func free_resources() -> void:
	ready = false
	if _rd != null:
		for set_rid in _sets:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
		for texture in _history:
			if texture.is_valid():
				_rd.free_rid(texture)
		if _sampler.is_valid():
			_rd.free_rid(_sampler)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_sets.clear()
	_history = [RID(), RID()]
	_sampler = RID()
	_shader = RID()
	_pipeline = RID()
	history_rid = RID()
	_read_index = 0
	_accumulator = 0.0


func _create_history_texture(resource_name: String, initial_data: PackedByteArray) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = _resolution
	texture_format.height = _resolution
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var data: Array[PackedByteArray] = [initial_data]
	var texture := _rd.texture_create(texture_format, RDTextureView.new(), data)
	_rd.set_resource_name(texture, resource_name)
	return texture


func _create_nearest_repeat_sampler() -> RID:
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	return _rd.sampler_create(state)


func _create_set(displacement_mid: RID, previous: RID, next: RID) -> RID:
	var displacement_uniform := RDUniform.new()
	displacement_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	displacement_uniform.binding = 0
	displacement_uniform.add_id(_sampler)
	displacement_uniform.add_id(displacement_mid)
	var previous_uniform := RDUniform.new()
	previous_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	previous_uniform.binding = 1
	previous_uniform.add_id(_sampler)
	previous_uniform.add_id(previous)
	var next_uniform := RDUniform.new()
	next_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	next_uniform.binding = 2
	next_uniform.add_id(next)
	return _rd.uniform_set_create([displacement_uniform, previous_uniform, next_uniform], _shader, 0)

class_name GPUStockhamFFT
extends RefCounted
## Unidad GPU persistente: evolución, IFFT Stockham 2D y ensamblado final.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl"
const UPDATE_FOAM_SHADER := "res://ocean_v3/rendering/fft/shaders/update_foam.glsl"
const DEFAULT_FOAM_RESOLUTION := 1024

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var foam_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _foam_ping: Array[RID] = [RID(), RID()]
var _foam_read_index := 0
var _foam_resolution := DEFAULT_FOAM_RESOLUTION
var _foam_sampler := RID()
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()
var _foam_sets: Array[RID] = [RID(), RID()]


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix := "Ocean1B", foam_resolution := DEFAULT_FOAM_RESOLUTION) -> void:
	free_resources()
	_config = config
	_foam_resolution = _validated_foam_resolution(foam_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return

	var evolve_pipeline := _create_pipeline(EVOLVE_SHADER, resource_prefix + ".Evolve")
	var fft_pipeline := _create_pipeline(STOCKHAM_SHADER, resource_prefix + ".StockhamIFFT")
	var assemble_pipeline := _create_pipeline(ASSEMBLE_SHADER, resource_prefix + ".Assemble")
	var foam_pipeline := _create_pipeline(UPDATE_FOAM_SHADER, resource_prefix + ".UpdateFoam")
	if not evolve_pipeline.is_valid() or not fft_pipeline.is_valid() or not assemble_pipeline.is_valid() or not foam_pipeline.is_valid():
		free_resources()
		return

	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	h0_upload_byte_count = h0_data.size()
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
		_ping_c[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingC%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement")
	# Legacy 256² alpha retained exclusively for OLD_RAW_FOAM_256 diagnostics.
	var normal_initial_data := PackedByteArray()
	normal_initial_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_initial_data)

	_evolve_set = _create_image_set(_shaders[0], [_h0, _ping_a[0], _ping_b[0], _ping_c[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_c[0], _ping_a[1], _ping_b[1], _ping_c[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_c[1], _ping_a[0], _ping_b[0], _ping_c[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _ping_c[0], displacement_rid, normal_rid])
	_create_foam_resources(resource_prefix)
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_sets[0].is_valid() and _foam_sets[1].is_valid()
	if not ready:
		last_error = "No se pudieron crear los uniform sets de %s." % resource_prefix


func upload_h0(h0_data: PackedByteArray) -> void:
	if ready and _h0.is_valid():
		_rd.texture_update(_h0, 0, h0_data)
		h0_upload_byte_count = h0_data.size()


func diagnostic_state() -> Dictionary:
	## Sólo inspección: expone el estado que llega al renderer, sin readback.
	return {
		"ready": ready,
		"h0_rid": _h0.get_id() if _h0.is_valid() else -1,
		"h0_upload_bytes": h0_upload_byte_count,
		"displacement_rid": displacement_rid.get_id() if displacement_rid.is_valid() else -1,
		"normal_rid": normal_rid.get_id() if normal_rid.is_valid() else -1,
		"foam_rid": foam_rid.get_id() if foam_rid.is_valid() else -1,
		"foam_resolution": _foam_resolution,
		"foam_gpu_bytes": _foam_resolution * _foam_resolution * 2 * 2,
	}


func update_config(config: Resource) -> void:
	## Cambiar de sea state sólo muta parámetros físicos macro (choppiness,
	## dirección, dispersión, viento, Hs). Resolución y dominio son invariantes,
	## por lo que las texturas y pipelines existentes siguen siendo válidos.
	_config = config


func set_foam_resolution(foam_resolution: int) -> void:
	var validated := _validated_foam_resolution(foam_resolution)
	if validated == _foam_resolution:
		return
	_foam_resolution = validated
	if _rd == null or _shaders.size() < 4:
		return
	_free_foam_resources()
	_create_foam_resources("OceanFoam")
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_sets[0].is_valid() and _foam_sets[1].is_valid()


func dispatch(render_time: float, delta_s: float = 0.0) -> void:
	if not ready:
		return
	var groups = ceili(float(_config.resolution) / 8.0)
	var compute_list := _rd.compute_list_begin()

	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(compute_list, _evolve_set, 0)
	var evolve_push := PackedFloat32Array([render_time, _config.gravity_mps2, _config.choppiness, _config.domain_size_m])
	_rd.compute_list_set_push_constant(compute_list, evolve_push.to_byte_array(), 16)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	_rd.compute_list_add_barrier(compute_list)

	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[1])
	var pass_index := 0
	for axis in 2:
		var stage_size := 2
		for _stage in _config.fft_stage_count():
			_rd.compute_list_bind_uniform_set(compute_list, _fft_sets[pass_index % 2], 0)
			var fft_push := PackedInt32Array([stage_size, axis, _config.resolution, 1])
			_rd.compute_list_set_push_constant(compute_list, fft_push.to_byte_array(), 16)
			_rd.compute_list_dispatch(compute_list, groups, groups, 1)
			_rd.compute_list_add_barrier(compute_list)
			stage_size *= 2
			pass_index += 1

	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[2])
	_rd.compute_list_bind_uniform_set(compute_list, _assemble_set, 0)
	var assemble_push = PackedFloat32Array([
		_config.domain_size_m,
		1.0 / float(_config.resolution * _config.resolution),
		_config.domain_size_m / float(_config.resolution),
		7.5,
		_config.foam_whitecap,
		maxf(delta_s, 0.0) * _config.foam_amount * 7.5,
		maxf(delta_s, 0.0) * maxf(_config.foam_decay, 0.5) * 1.15,
		_config.foam_cascade_weight if _config.foam_enabled else 0.0,
	])
	_rd.compute_list_set_push_constant(compute_list, assemble_push.to_byte_array(), 32)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	_rd.compute_list_add_barrier(compute_list)

	# The persistent foam field has its own high-resolution ping-pong pair. It
	# samples the freshly assembled spectral J with hardware bilinear filtering;
	# no dispatch reads and writes the same foam image.
	var foam_groups = ceili(float(_foam_resolution) / 8.0)
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[3])
	_rd.compute_list_bind_uniform_set(compute_list, _foam_sets[_foam_read_index], 0)
	var foam_push := PackedFloat32Array([
		_config.foam_whitecap,
		maxf(delta_s, 0.0) * _config.foam_amount * 7.5,
		maxf(delta_s, 0.0) * maxf(_config.foam_decay, 0.5) * 1.15,
		_config.foam_cascade_weight if _config.foam_enabled else 0.0,
	])
	_rd.compute_list_set_push_constant(compute_list, foam_push.to_byte_array(), 16)
	_rd.compute_list_dispatch(compute_list, foam_groups, foam_groups, 1)
	_foam_read_index = 1 - _foam_read_index
	foam_rid = _foam_ping[_foam_read_index]
	_rd.compute_list_end()


func free_resources() -> void:
	ready = false
	h0_upload_byte_count = 0
	if _rd == null:
		return
	_free_foam_resources()
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _ping_c[0], _ping_c[1], displacement_rid, normal_rid]:
		if texture.is_valid():
			_rd.free_rid(texture)
	for pipeline in _pipelines:
		if pipeline.is_valid():
			_rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid():
			_rd.free_rid(shader)
	_pipelines.clear()
	_shaders.clear()
	_h0 = RID()
	displacement_rid = RID()
	normal_rid = RID()
	foam_rid = RID()
	_ping_a = [RID(), RID()]
	_ping_b = [RID(), RID()]
	_ping_c = [RID(), RID()]


func _create_pipeline(path: String, resource_name: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	if shader_file == null:
		last_error = "No se pudo cargar %s" % path
		return RID()
	var shader := _rd.shader_create_from_spirv(shader_file.get_spirv(), resource_name)
	if not shader.is_valid():
		last_error = "No se pudo compilar %s" % path
		return RID()
	var pipeline := _rd.compute_pipeline_create(shader)
	_rd.set_resource_name(shader, resource_name + ".Shader")
	_rd.set_resource_name(pipeline, resource_name + ".Pipeline")
	_shaders.append(shader)
	_pipelines.append(pipeline)
	return pipeline


func _create_texture(format: int, resource_name: String, data := PackedByteArray(), allow_update := false, resolution_override := 0) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	var resolution: int = resolution_override
	if resolution <= 0:
		resolution = int(_config.resolution)
	texture_format.width = resolution
	texture_format.height = resolution
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if allow_update:
		texture_format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial_data: Array[PackedByteArray] = []
	if not data.is_empty():
		initial_data.append(data)
	var texture := _rd.texture_create(texture_format, RDTextureView.new(), initial_data)
	_rd.set_resource_name(texture, resource_name)
	return texture


func _create_image_set(shader: RID, textures: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = binding
		uniform.add_id(textures[binding])
		uniforms.append(uniform)
	var uniform_set := _rd.uniform_set_create(uniforms, shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _create_foam_resources(resource_prefix: String) -> void:
	var initial_data := PackedByteArray()
	initial_data.resize(_foam_resolution * _foam_resolution * 2)
	_foam_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".FoamA", initial_data, false, _foam_resolution)
	_foam_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".FoamB", initial_data, false, _foam_resolution)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_foam_sampler = _rd.sampler_create(sampler_state)
	_foam_sets[0] = _create_foam_set(_shaders[3], displacement_rid, _foam_ping[0], _foam_ping[1])
	_foam_sets[1] = _create_foam_set(_shaders[3], displacement_rid, _foam_ping[1], _foam_ping[0])
	_foam_read_index = 0
	foam_rid = _foam_ping[0]


func _create_foam_set(shader: RID, displacement: RID, previous: RID, next: RID) -> RID:
	var sampler_uniform := RDUniform.new()
	sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	sampler_uniform.binding = 0
	sampler_uniform.add_id(_foam_sampler)
	sampler_uniform.add_id(displacement)
	var previous_uniform := RDUniform.new()
	previous_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	previous_uniform.binding = 1
	previous_uniform.add_id(previous)
	var next_uniform := RDUniform.new()
	next_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	next_uniform.binding = 2
	next_uniform.add_id(next)
	var uniform_set := _rd.uniform_set_create([sampler_uniform, previous_uniform, next_uniform], shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _free_foam_resources() -> void:
	if _rd == null:
		return
	for uniform_set in _foam_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for texture in _foam_ping:
		if texture.is_valid():
			_rd.free_rid(texture)
	if _foam_sampler.is_valid():
		_rd.free_rid(_foam_sampler)
	_foam_sets = [RID(), RID()]
	_foam_ping = [RID(), RID()]
	_foam_sampler = RID()
	foam_rid = RID()


func _validated_foam_resolution(value: int) -> int:
	if value <= 256:
		return 256
	if value <= 512:
		return 512
	return 1024

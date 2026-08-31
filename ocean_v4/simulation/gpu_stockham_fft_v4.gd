class_name GPUStockhamFFTV4
extends RefCounted
## V4 GPU orchestration: evolve H0, inverse Stockham FFT, assemble maps.

const EVOLVE_SHADER := "res://ocean_v4/simulation/shaders/evolve_spectrum_v4.glsl"
const STOCKHAM_SHADER := "res://ocean_v4/simulation/shaders/stockham_ifft_v4.glsl"
const ASSEMBLE_SHADER := "res://ocean_v4/simulation/shaders/assemble_maps_v4.glsl"

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()

var _rd: RenderingDevice
var _config: OpenOceanFFTConfigV4
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()
var _dispatch_count := 0
var _diagnostic_samples := 0


func initialize(config: OpenOceanFFTConfigV4, h0_data: PackedByteArray, resource_prefix: String) -> void:
	free_resources()
	_config = config
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice unavailable."
		return
	for item in [[EVOLVE_SHADER, ".Evolve"], [STOCKHAM_SHADER, ".Stockham"], [ASSEMBLE_SHADER, ".Assemble"]]:
		if not _create_pipeline(item[0], resource_prefix + item[1]).is_valid():
			free_resources()
			return
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
		_ping_c[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingC%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement", PackedByteArray(), false, true)
	var normal_data := PackedByteArray()
	normal_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_data)
	_evolve_set = _create_image_set(_shaders[0], [_h0, _h0, _ping_a[0], _ping_b[0], _ping_c[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_c[0], _ping_a[1], _ping_b[1], _ping_c[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_c[1], _ping_a[0], _ping_b[0], _ping_c[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _ping_c[0], displacement_rid, normal_rid])
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid()
	if not ready:
		last_error = "Could not create V4 uniform sets."
	print("OceanV4 FFT %s initialize ready=%s error=%s" % [_config.id, ready, last_error])
	_dispatch_count = 0
	_diagnostic_samples = 0


func dispatch(simulation_time_s: float) -> void:
	if not ready:
		return
	_dispatch_count += 1
	if (_diagnostic_samples == 0 and _dispatch_count >= 2) or (_diagnostic_samples == 1 and _dispatch_count >= 120):
		_print_displacement_diagnostic(simulation_time_s)
		_diagnostic_samples += 1
	var groups := ceili(float(_config.resolution) / 8.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _evolve_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([simulation_time_s, _config.gravity_mps2, _config.choppiness, _config.domain_size_m, 0.0]).to_byte_array(), 20)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
	var pass_index := 0
	for axis in 2:
		var stage_size := 2
		for _stage in _config.fft_stage_count():
			_rd.compute_list_bind_uniform_set(list, _fft_sets[pass_index % 2], 0)
			_rd.compute_list_set_push_constant(list, PackedInt32Array([stage_size, axis, _config.resolution, 1]).to_byte_array(), 16)
			_rd.compute_list_dispatch(list, groups, groups, 1)
			_rd.compute_list_add_barrier(list)
			stage_size *= 2
			pass_index += 1
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[2])
	_rd.compute_list_bind_uniform_set(list, _assemble_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([_config.domain_size_m, 1.0 / float(_config.resolution * _config.resolution), _config.domain_size_m / float(_config.resolution), 0.0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()


func free_resources() -> void:
	ready = false
	if _rd == null:
		return
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid(): _rd.free_rid(uniform_set)
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _ping_c[0], _ping_c[1], displacement_rid, normal_rid]:
		if texture.is_valid(): _rd.free_rid(texture)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_uniform_sets.clear(); _pipelines.clear(); _shaders.clear()
	_h0 = RID(); _ping_a = [RID(), RID()]; _ping_b = [RID(), RID()]; _ping_c = [RID(), RID()]
	displacement_rid = RID(); normal_rid = RID(); _evolve_set = RID(); _fft_sets = [RID(), RID()]; _assemble_set = RID()


func _create_pipeline(path: String, name: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null:
		last_error = "Cannot load %s" % path
		return RID()
	var shader := _rd.shader_create_from_spirv(file.get_spirv(), name)
	if not shader.is_valid():
		last_error = "Cannot compile %s" % path
		return RID()
	var pipeline := _rd.compute_pipeline_create(shader)
	_shaders.append(shader); _pipelines.append(pipeline)
	return pipeline


func _create_texture(format: int, name: String, data := PackedByteArray(), allow_update := false, allow_readback := false) -> RID:
	var format_info := RDTextureFormat.new()
	format_info.format = format as RenderingDevice.DataFormat
	format_info.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format_info.width = _config.resolution; format_info.height = _config.resolution
	format_info.depth = 1; format_info.array_layers = 1; format_info.mipmaps = 1
	format_info.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if allow_update: format_info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	if allow_readback: format_info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var initial: Array[PackedByteArray] = []
	if not data.is_empty(): initial.append(data)
	var texture := _rd.texture_create(format_info, RDTextureView.new(), initial)
	_rd.set_resource_name(texture, name)
	return texture


func _create_image_set(shader: RID, textures: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = binding; uniform.add_id(textures[binding]); uniforms.append(uniform)
	var uniform_set := _rd.uniform_set_create(uniforms, shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _print_displacement_diagnostic(simulation_time_s: float) -> void:
	var data := _rd.texture_get_data(displacement_rid, 0)
	var pixel_count := _config.resolution * _config.resolution
	var stride := maxi(pixel_count / 128, 1)
	var peak := 0.0
	var finite := true
	for pixel in range(0, pixel_count, stride):
		var byte_offset := pixel * 16
		for component_index in 3:
			var component := data.decode_float(byte_offset + component_index * 4)
			finite = finite and is_finite(component)
			peak = maxf(peak, absf(component))
	print("OceanV4 FFT %s output sample %d: t=%.3f s peak=%.5f m finite=%s" % [_config.id, _diagnostic_samples + 1, simulation_time_s, peak, finite])

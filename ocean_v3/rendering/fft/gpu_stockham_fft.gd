class_name GPUStockhamFFT
extends RefCounted
## Unidad GPU persistente: evolución, IFFT Stockham 2D y ensamblado final.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl"

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix := "Ocean1B") -> void:
	free_resources()
	_config = config
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return

	var evolve_pipeline := _create_pipeline(EVOLVE_SHADER, resource_prefix + ".Evolve")
	var fft_pipeline := _create_pipeline(STOCKHAM_SHADER, resource_prefix + ".StockhamIFFT")
	var assemble_pipeline := _create_pipeline(ASSEMBLE_SHADER, resource_prefix + ".Assemble")
	if not evolve_pipeline.is_valid() or not fft_pipeline.is_valid() or not assemble_pipeline.is_valid():
		free_resources()
		return

	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	h0_upload_byte_count = h0_data.size()
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement")
	# Alpha is persistent foam state. Initialize it once so the first assemble
	# dispatch cannot consume undefined contents; subsequent frames read/write
	# the same GPU image without a readback.
	var normal_initial_data := PackedByteArray()
	normal_initial_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_initial_data)

	_evolve_set = _create_image_set(_shaders[0], [_h0, _ping_a[0], _ping_b[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_a[1], _ping_b[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_a[0], _ping_b[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], displacement_rid, normal_rid])
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid()
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
	}


func update_config(config: Resource) -> void:
	## Cambiar de sea state sólo muta parámetros físicos macro (choppiness,
	## dirección, dispersión, viento, Hs). Resolución y dominio son invariantes,
	## por lo que las texturas y pipelines existentes siguen siendo válidos.
	_config = config


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
		0.0,
		_config.foam_whitecap,
		maxf(delta_s, 0.0) * _config.foam_amount,
		maxf(delta_s, 0.0) * _config.foam_decay,
		_config.foam_cascade_weight if _config.foam_enabled else 0.0,
	])
	_rd.compute_list_set_push_constant(compute_list, assemble_push.to_byte_array(), 32)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	_rd.compute_list_end()


func free_resources() -> void:
	ready = false
	h0_upload_byte_count = 0
	if _rd == null:
		return
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], displacement_rid, normal_rid]:
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
	_ping_a = [RID(), RID()]
	_ping_b = [RID(), RID()]


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


func _create_texture(format: int, resource_name: String, data := PackedByteArray(), allow_update := false) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = _config.resolution
	texture_format.height = _config.resolution
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

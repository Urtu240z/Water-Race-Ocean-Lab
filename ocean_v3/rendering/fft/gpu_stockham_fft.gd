class_name GPUStockhamFFT
extends RefCounted
## Unidad GPU persistente: evolución, IFFT Stockham 2D y ensamblado final.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl"
const SURFACE_FOAM_EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl"
const UPDATE_FOAM_SHADER := "res://ocean_v3/rendering/fft/shaders/update_foam.glsl"
const STORE_DISPLACEMENT_SHADER := "res://ocean_v3/rendering/fft/shaders/store_previous_displacement.glsl"
const UPDATE_SURFACE_FOAM_SHADER := "res://ocean_v3/rendering/fft/shaders/update_surface_foam.glsl"
const DEFAULT_FOAM_RESOLUTION := 1024

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var foam_rid := RID()
var surface_foam_rid := RID()
var previous_displacement_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _foam_ping: Array[RID] = [RID(), RID()]
var _surface_foam_ping: Array[RID] = [RID(), RID()]
var _previous_displacement_ping: Array[RID] = [RID(), RID(), RID()]
var _foam_read_index := 0
var _surface_foam_read_index := 0
var _previous_displacement_read_index := 0
var _foam_resolution := DEFAULT_FOAM_RESOLUTION
var _linear_repeat_sampler := RID()
var _foam_residual_decay_multiplier := 1.0
var _foam_deposit_strength := 0.72
var _foam_advection_enabled := true
var _foam_advection_strength := 1.0
var _surface_foam_enabled := true
var _surface_foam_whitecap := 0.05
var _surface_foam_amount := 8.0
var _surface_foam_advection_strength := 0.0
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()
var _foam_sets: Array[RID] = []
var _surface_foam_sets: Array[RID] = []
var _store_displacement_sets: Array[RID] = []


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix := "Ocean1B", foam_resolution := DEFAULT_FOAM_RESOLUTION) -> void:
	free_resources()
	_config = config
	_foam_resolution = _validated_foam_resolution(foam_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return

	var evolve_shader := SURFACE_FOAM_EVOLVE_SHADER if _is_surface_foam_source() else EVOLVE_SHADER
	var evolve_pipeline := _create_pipeline(evolve_shader, resource_prefix + ".Evolve")
	var fft_pipeline := _create_pipeline(STOCKHAM_SHADER, resource_prefix + ".StockhamIFFT")
	var assemble_pipeline := _create_pipeline(ASSEMBLE_SHADER, resource_prefix + ".Assemble")
	var foam_pipeline := _create_pipeline(UPDATE_FOAM_SHADER, resource_prefix + ".UpdateFoam")
	var store_displacement_pipeline := _create_pipeline(STORE_DISPLACEMENT_SHADER, resource_prefix + ".StorePreviousDisplacement")
	var surface_foam_pipeline := _create_pipeline(UPDATE_SURFACE_FOAM_SHADER, resource_prefix + ".UpdateSurfaceFoam")
	if not evolve_pipeline.is_valid() or not fft_pipeline.is_valid() or not assemble_pipeline.is_valid() or not foam_pipeline.is_valid() or not store_displacement_pipeline.is_valid() or not surface_foam_pipeline.is_valid():
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
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_resources_ready()
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
		"surface_foam_rid": surface_foam_rid.get_id() if surface_foam_rid.is_valid() else -1,
		"previous_displacement_rid": previous_displacement_rid.get_id() if previous_displacement_rid.is_valid() else -1,
		"foam_resolution": _foam_resolution,
		"foam_gpu_bytes": _foam_resolution * _foam_resolution * 4 * 2 if _has_crest_foam() else 0,
		"surface_foam_gpu_bytes": _foam_resolution * _foam_resolution * 2 * 2 if _is_surface_foam_source() else 0,
		"previous_displacement_gpu_bytes": _config.resolution * _config.resolution * 4 * 3,
	}


func update_config(config: Resource) -> void:
	## Cambiar de sea state sólo muta parámetros físicos macro (choppiness,
	## dirección, dispersión, viento, Hs). Resolución y dominio son invariantes,
	## por lo que las texturas y pipelines existentes siguen siendo válidos.
	_config = config


func set_foam_transport_settings(residual_decay_multiplier: float, deposit_strength: float, advection_enabled: bool, advection_strength: float) -> void:
	_foam_residual_decay_multiplier = maxf(residual_decay_multiplier, 0.0)
	_foam_deposit_strength = clampf(deposit_strength, 0.0, 2.0)
	_foam_advection_enabled = advection_enabled
	_foam_advection_strength = clampf(advection_strength, 0.0, 2.0)


func set_surface_foam_settings(enabled: bool, whitecap: float, amount: float, advection_strength: float) -> void:
	_surface_foam_enabled = enabled
	_surface_foam_whitecap = clampf(whitecap, 0.0, 1.5)
	_surface_foam_amount = clampf(amount, 0.0, 10.0)
	_surface_foam_advection_strength = clampf(advection_strength, 0.0, 2.0)


func set_foam_resolution(foam_resolution: int) -> void:
	var validated := _validated_foam_resolution(foam_resolution)
	if validated == _foam_resolution:
		return
	_foam_resolution = validated
	if _rd == null or _shaders.size() < 6:
		return
	_free_foam_resources()
	_create_foam_resources("OceanFoam")
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_resources_ready()


func dispatch(render_time: float, delta_s: float = 0.0) -> void:
	if not ready:
		return
	var groups = ceili(float(_config.resolution) / 8.0)
	var compute_list := _rd.compute_list_begin()

	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(compute_list, _evolve_set, 0)
	var evolution_depth_or_choppiness := 0.0
	if _is_surface_foam_source():
		var surface_foam_config := _config as SurfaceFoamReferenceConfig
		evolution_depth_or_choppiness = surface_foam_config.depth_m
	else:
		evolution_depth_or_choppiness = _config.choppiness
	var evolve_push := PackedFloat32Array([render_time, _config.gravity_mps2, evolution_depth_or_choppiness, _config.domain_size_m])
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
	# GodotOceanWaves' inverse Stockham route leaves its spatial result
	# unnormalised.  Surface Foam follows that convention exactly; production
	# cascades retain their existing 1 / N² conversion.
	var spatial_normalization := 1.0 if _is_surface_foam_source() else 1.0 / float(_config.resolution * _config.resolution)
	var assemble_push = PackedFloat32Array([
		_config.domain_size_m,
		spatial_normalization,
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

	var foam_groups = ceili(float(_foam_resolution) / 8.0)
	if _has_crest_foam():
		# Fresh whitecaps are born from current J; only residual history is advected.
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[3])
		_rd.compute_list_bind_uniform_set(compute_list, _foam_sets[_previous_displacement_read_index * 2 + _foam_read_index], 0)
		# update_foam receives rates per second and the real frame delta; the shader
		# applies the exponential attack/release and residual decay internally.
		var foam_push := PackedFloat32Array([
			_config.foam_whitecap,
			maxf(_config.foam_amount, 0.0) * 7.5,
			_config.foam_cascade_weight if _config.foam_enabled else 0.0,
			_foam_deposit_strength,
			maxf(_config.foam_decay, 0.5) * 1.15 * _foam_residual_decay_multiplier,
			maxf(delta_s, 0.0),
			1.0 if _foam_advection_enabled else 0.0,
			_foam_advection_strength,
			_config.domain_size_m,
			0.0,
			0.0,
			0.0,
		])
		_rd.compute_list_set_push_constant(compute_list, foam_push.to_byte_array(), 48)
		_rd.compute_list_dispatch(compute_list, foam_groups, foam_groups, 1)
		_foam_read_index = 1 - _foam_read_index
		foam_rid = _foam_ping[_foam_read_index]
		_rd.compute_list_add_barrier(compute_list)

	if _is_surface_foam_source():
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[5])
		_rd.compute_list_bind_uniform_set(compute_list, _surface_foam_sets[_previous_displacement_read_index * 2 + _surface_foam_read_index], 0)
		var surface_foam_push := PackedFloat32Array([
			_surface_foam_whitecap,
			_surface_foam_amount * 7.5,
			maxf(0.5, 10.0 - _surface_foam_amount) * 1.15,
			1.0 if _surface_foam_enabled else 0.0,
			maxf(delta_s, 0.0),
			_surface_foam_advection_strength,
			_config.domain_size_m,
			0.0,
		])
		_rd.compute_list_set_push_constant(compute_list, surface_foam_push.to_byte_array(), 32)
		_rd.compute_list_dispatch(compute_list, foam_groups, foam_groups, 1)
		_surface_foam_read_index = 1 - _surface_foam_read_index
		surface_foam_rid = _surface_foam_ping[_surface_foam_read_index]
		_rd.compute_list_add_barrier(compute_list)

	# Capture current horizontal displacement after foam consumed the prior pair.
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[4])
	var previous_snapshot_index := _previous_displacement_read_index
	_rd.compute_list_bind_uniform_set(compute_list, _store_displacement_sets[previous_snapshot_index], 0)
	_rd.compute_list_set_push_constant(compute_list, PackedByteArray(), 0)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	# Publish the exact old snapshot consumed by this foam update. Current
	# displacement is already published separately, so the material can show the
	# same motion vector without retaining another texture.
	previous_displacement_rid = _previous_displacement_ping[previous_snapshot_index]
	_previous_displacement_read_index = (previous_snapshot_index + 1) % 3
	_rd.compute_list_add_barrier(compute_list)
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
	surface_foam_rid = RID()
	previous_displacement_rid = RID()
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
	if _has_crest_foam():
		var initial_data := PackedByteArray()
		initial_data.resize(_foam_resolution * _foam_resolution * 4)
		_foam_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".FoamA", initial_data, false, _foam_resolution)
		_foam_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".FoamB", initial_data, false, _foam_resolution)
	if _is_surface_foam_source():
		var surface_initial_data := PackedByteArray()
		surface_initial_data.resize(_foam_resolution * _foam_resolution * 2)
		_surface_foam_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".SurfaceFoamA", surface_initial_data, false, _foam_resolution)
		_surface_foam_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".SurfaceFoamB", surface_initial_data, false, _foam_resolution)
	var displacement_initial_data := PackedByteArray()
	displacement_initial_data.resize(_config.resolution * _config.resolution * 4)
	for index in 3:
		_previous_displacement_ping[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".PreviousDisplacement%d" % index, displacement_initial_data)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_linear_repeat_sampler = _rd.sampler_create(sampler_state)
	_foam_sets.clear()
	_surface_foam_sets.clear()
	for snapshot_index in 3:
		for foam_index in 2:
			if _has_crest_foam():
				_foam_sets.append(_create_foam_set(_shaders[3], displacement_rid, _previous_displacement_ping[snapshot_index], _foam_ping[foam_index], _foam_ping[1 - foam_index]))
			if _is_surface_foam_source():
				_surface_foam_sets.append(_create_surface_foam_set(_shaders[5], displacement_rid, _previous_displacement_ping[snapshot_index], _surface_foam_ping[foam_index], _surface_foam_ping[1 - foam_index]))
	_store_displacement_sets.clear()
	for snapshot_index in 3:
		_store_displacement_sets.append(_create_store_displacement_set(_shaders[4], displacement_rid, _previous_displacement_ping[(snapshot_index + 1) % 3]))
	_foam_read_index = 0
	_surface_foam_read_index = 0
	_previous_displacement_read_index = 0
	foam_rid = _foam_ping[0] if _has_crest_foam() else RID()
	surface_foam_rid = _surface_foam_ping[0] if _is_surface_foam_source() else RID()
	previous_displacement_rid = _previous_displacement_ping[0]


func _create_foam_set(shader: RID, displacement: RID, previous_displacement: RID, previous_foam: RID, next_foam: RID) -> RID:
	var current_displacement_uniform := _create_sampler_uniform(0, displacement)
	var previous_displacement_uniform := _create_sampler_uniform(1, previous_displacement)
	var previous_foam_uniform := _create_sampler_uniform(2, previous_foam)
	var next_foam_uniform := RDUniform.new()
	next_foam_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	next_foam_uniform.binding = 3
	next_foam_uniform.add_id(next_foam)
	var uniform_set := _rd.uniform_set_create([current_displacement_uniform, previous_displacement_uniform, previous_foam_uniform, next_foam_uniform], shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _create_surface_foam_set(shader: RID, displacement: RID, previous_displacement: RID, previous_foam: RID, next_foam: RID) -> RID:
	var current_displacement_uniform := _create_sampler_uniform(0, displacement)
	var previous_displacement_uniform := _create_sampler_uniform(1, previous_displacement)
	var previous_foam_uniform := _create_sampler_uniform(2, previous_foam)
	var next_foam_uniform := RDUniform.new()
	next_foam_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	next_foam_uniform.binding = 3
	next_foam_uniform.add_id(next_foam)
	var uniform_set := _rd.uniform_set_create([current_displacement_uniform, previous_displacement_uniform, previous_foam_uniform, next_foam_uniform], shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _create_store_displacement_set(shader: RID, displacement: RID, destination: RID) -> RID:
	var displacement_uniform := RDUniform.new()
	displacement_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	displacement_uniform.binding = 0
	displacement_uniform.add_id(displacement)
	var destination_uniform := RDUniform.new()
	destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	destination_uniform.binding = 1
	destination_uniform.add_id(destination)
	var uniform_set := _rd.uniform_set_create([displacement_uniform, destination_uniform], shader, 0)
	_uniform_sets.append(uniform_set)
	return uniform_set


func _create_sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_linear_repeat_sampler)
	uniform.add_id(texture)
	return uniform


func _free_foam_resources() -> void:
	if _rd == null:
		return
	for uniform_set in _foam_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for uniform_set in _store_displacement_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for uniform_set in _surface_foam_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for texture in _foam_ping:
		if texture.is_valid():
			_rd.free_rid(texture)
	for texture in _surface_foam_ping:
		if texture.is_valid():
			_rd.free_rid(texture)
	for texture in _previous_displacement_ping:
		if texture.is_valid():
			_rd.free_rid(texture)
	if _linear_repeat_sampler.is_valid():
		_rd.free_rid(_linear_repeat_sampler)
	_foam_sets.clear()
	_surface_foam_sets.clear()
	_store_displacement_sets.clear()
	_foam_ping = [RID(), RID()]
	_surface_foam_ping = [RID(), RID()]
	_previous_displacement_ping = [RID(), RID(), RID()]
	_linear_repeat_sampler = RID()
	foam_rid = RID()
	surface_foam_rid = RID()
	previous_displacement_rid = RID()


func _foam_resources_ready() -> bool:
	if _store_displacement_sets.size() != 3:
		return false
	if _has_crest_foam():
		if _foam_sets.size() != 6:
			return false
		for uniform_set in _foam_sets:
			if not uniform_set.is_valid():
				return false
	for uniform_set in _store_displacement_sets:
		if not uniform_set.is_valid():
			return false
	if _is_surface_foam_source():
		if _surface_foam_sets.size() != 6:
			return false
		for uniform_set in _surface_foam_sets:
			if not uniform_set.is_valid():
				return false
	return true


func _is_surface_foam_source() -> bool:
	return _config != null and _config.id == &"SURFACE_FOAM"


func _has_crest_foam() -> bool:
	return _config != null and _config.id != &"SURFACE_FOAM"


func _validated_foam_resolution(value: int) -> int:
	if value <= 256:
		return 256
	if value <= 512:
		return 512
	return 1024

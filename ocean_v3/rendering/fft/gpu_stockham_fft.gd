class_name GPUStockhamFFT
extends RefCounted
## Unidad GPU persistente: evolución, IFFT Stockham 2D y ensamblado final.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl"
const UPDATE_FOAM_SHADER := "res://ocean_v3/rendering/fft/shaders/update_foam.glsl"
const STORE_DISPLACEMENT_SHADER := "res://ocean_v3/rendering/fft/shaders/store_previous_displacement.glsl"
const DEFAULT_FOAM_RESOLUTION := 1024

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var foam_rid := RID()
var previous_displacement_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _h0_target := RID()
var _transition_target_config: Resource = null
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _foam_ping: Array[RID] = [RID(), RID()]
var _previous_displacement_ping: Array[RID] = [RID(), RID()]
var _foam_read_index := 0
var _previous_displacement_read_index := 0
var _foam_resolution := DEFAULT_FOAM_RESOLUTION
var _linear_repeat_sampler := RID()
var _foam_residual_decay_multiplier := 1.0
var _foam_deposit_strength := 0.72
var _foam_advection_enabled := true
var _foam_advection_strength := 1.0
var _crest_foam_compute_enabled := true
var _crest_foam_update_hz := 60.0
var _crest_transition_alpha := 0.0
var _crest_effective_whitecap := 0.0
var _crest_current_whitecap := 0.0
var _crest_target_whitecap := 0.0
var _crest_foam_accumulator := 0.0
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()
var _foam_sets: Array[RID] = []
var _store_displacement_sets: Array[RID] = []
var _resource_prefix := "Ocean1B"
var _crest_updates_total := 0
var _crest_updates_window := 0
var _diagnostic_window_s := 0.0
var _crest_updates_per_second := 0.0


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix := "Ocean1B", foam_resolution := DEFAULT_FOAM_RESOLUTION) -> void:
	free_resources()
	_config = config
	_resource_prefix = resource_prefix
	_foam_resolution = _validated_foam_resolution(foam_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return

	var evolve_pipeline := _create_pipeline(EVOLVE_SHADER, resource_prefix + ".Evolve")
	var fft_pipeline := _create_pipeline(STOCKHAM_SHADER, resource_prefix + ".StockhamIFFT")
	var assemble_pipeline := _create_pipeline(ASSEMBLE_SHADER, resource_prefix + ".Assemble")
	var foam_pipeline := _create_pipeline(UPDATE_FOAM_SHADER, resource_prefix + ".UpdateFoam")
	var store_displacement_pipeline := _create_pipeline(STORE_DISPLACEMENT_SHADER, resource_prefix + ".StorePreviousDisplacement")
	if not evolve_pipeline.is_valid() or not fft_pipeline.is_valid() or not assemble_pipeline.is_valid() or not foam_pipeline.is_valid() or not store_displacement_pipeline.is_valid():
		free_resources()
		return

	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	h0_upload_byte_count = h0_data.size()
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
		_ping_c[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingC%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement")
	var normal_initial_data := PackedByteArray()
	normal_initial_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_initial_data)

	_rebuild_evolve_set()
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_c[0], _ping_a[1], _ping_b[1], _ping_c[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_c[1], _ping_a[0], _ping_b[0], _ping_c[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _ping_c[0], displacement_rid, normal_rid])
	_create_foam_resources(resource_prefix)
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_resources_ready()
	if not ready:
		last_error = "No se pudieron crear los uniform sets de %s." % resource_prefix


func upload_h0(h0_data: PackedByteArray) -> void:
	if ready and _h0.is_valid():
		_clear_h0_transition()
		_rd.texture_update(_h0, 0, h0_data)
		h0_upload_byte_count = h0_data.size()


func begin_h0_transition(target_h0_data: PackedByteArray, target_config: Resource) -> void:
	if not ready or target_config == null:
		return
	_clear_h0_transition()
	_h0_target = _create_texture(
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		_resource_prefix + ".H0Target",
		target_h0_data,
		true
	)
	_transition_target_config = target_config
	_rebuild_evolve_set()


func replace_current_h0(current_h0_data: PackedByteArray, current_config: Resource) -> void:
	if not ready or current_config == null:
		return
	_clear_h0_transition()
	_rd.texture_update(_h0, 0, current_h0_data)
	h0_upload_byte_count = current_h0_data.size()
	_config = current_config


func complete_h0_transition() -> void:
	if not ready or not _h0_target.is_valid():
		return
	if _evolve_set.is_valid():
		_rd.free_rid(_evolve_set)
		_evolve_set = RID()
	if _h0.is_valid():
		_rd.free_rid(_h0)
	_h0 = _h0_target
	_h0_target = RID()
	if _transition_target_config != null:
		_config = _transition_target_config
	_transition_target_config = null
	_rebuild_evolve_set()


func diagnostic_state() -> Dictionary:
	## Sólo inspección: expone el estado que llega al renderer, sin readback.
	return {
		"ready": ready,
		"h0_rid": _h0.get_id() if _h0.is_valid() else -1,
		"h0_target_rid": _h0_target.get_id() if _h0_target.is_valid() else -1,
		"h0_transition_active": _h0_target.is_valid(),
		"h0_upload_bytes": h0_upload_byte_count,
		"displacement_rid": displacement_rid.get_id() if displacement_rid.is_valid() else -1,
		"normal_rid": normal_rid.get_id() if normal_rid.is_valid() else -1,
		"foam_rid": foam_rid.get_id() if foam_rid.is_valid() else -1,
		"previous_displacement_rid": previous_displacement_rid.get_id() if previous_displacement_rid.is_valid() else -1,
		"foam_resolution": _foam_resolution,
		"crest_foam_compute_enabled": _crest_foam_compute_enabled,
		"crest_updates_total": _crest_updates_total,
		"crest_updates_per_second": _crest_updates_per_second,
		"crest_transition_active": _h0_target.is_valid(),
		"crest_transition_alpha": _crest_transition_alpha,
		"effective_whitecap": _crest_effective_whitecap,
		"current_whitecap": _crest_current_whitecap,
		"target_whitecap": _crest_target_whitecap,
		"crest_snapshot_count": 2 if _foam_advection_enabled else 0,
		"foam_gpu_bytes": _foam_resolution * _foam_resolution * 4 * 2,
		"surface_foam_gpu_bytes": 0,
		"previous_displacement_gpu_bytes": _config.resolution * _config.resolution * 4 * 2 if _foam_advection_enabled else 0,
	}


func update_config(config: Resource) -> void:
	## Cambiar de sea state sólo muta parámetros físicos macro (choppiness,
	## dirección, dispersión, viento, Hs). Resolución y dominio son invariantes,
	## por lo que las texturas y pipelines existentes siguen siendo válidos.
	_config = config


func set_foam_transport_settings(residual_decay_multiplier: float, deposit_strength: float, advection_enabled: bool, advection_strength: float) -> void:
	var snapshots_changed := _foam_advection_enabled != advection_enabled
	_foam_residual_decay_multiplier = maxf(residual_decay_multiplier, 0.0)
	_foam_deposit_strength = clampf(deposit_strength, 0.0, 2.0)
	_foam_advection_enabled = advection_enabled
	_foam_advection_strength = clampf(advection_strength, 0.0, 2.0)
	if snapshots_changed and ready:
		_free_foam_resources()
		_create_foam_resources(_resource_prefix)
		ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_resources_ready()


func set_crest_foam_compute_enabled(enabled: bool) -> void:
	_crest_foam_compute_enabled = enabled


func set_crest_foam_schedule(update_hz: float, phase_offset: float) -> void:
	_crest_foam_update_hz = clampf(update_hz, 30.0, 60.0)
	# Deterministic phase distributes the four HIRES updates over one period.
	_crest_foam_accumulator = (1.0 / _crest_foam_update_hz) * clampf(phase_offset, 0.0, 0.999)


func set_foam_resolution(foam_resolution: int) -> void:
	var validated := _validated_foam_resolution(foam_resolution)
	if validated == _foam_resolution:
		return
	_foam_resolution = validated
	if _rd == null or _shaders.size() < 5:
		return
	_free_foam_resources()
	_create_foam_resources(_resource_prefix)
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid() and _foam_resources_ready()


func dispatch(render_time: float, delta_s: float = 0.0, transition_alpha := 0.0) -> void:
	if not ready:
		return
	var groups = ceili(float(_config.resolution) / 8.0)
	var compute_list := _rd.compute_list_begin()

	_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(compute_list, _evolve_set, 0)
	var alpha := transition_alpha if _h0_target.is_valid() else 0.0
	var target_config := _transition_target_config if _transition_target_config != null else _config
	var current_whitecap: float = _config.foam_whitecap
	var target_whitecap: float = target_config.foam_whitecap
	var effective_whitecap: float = lerpf(current_whitecap, target_whitecap, alpha)
	_crest_transition_alpha = alpha
	_crest_current_whitecap = current_whitecap
	_crest_target_whitecap = target_whitecap
	_crest_effective_whitecap = effective_whitecap
	var evolution_depth_or_choppiness := lerpf(_config.choppiness, target_config.choppiness, alpha)
	var evolve_push := PackedFloat32Array([render_time, _config.gravity_mps2, evolution_depth_or_choppiness, _config.domain_size_m, alpha])
	_rd.compute_list_set_push_constant(compute_list, evolve_push.to_byte_array(), 20)
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
	var spatial_normalization := 1.0 / float(_config.resolution * _config.resolution)
	var assemble_push = PackedFloat32Array([
		_config.domain_size_m,
		spatial_normalization,
		_config.domain_size_m / float(_config.resolution),
		7.5,
		effective_whitecap,
		maxf(delta_s, 0.0) * lerpf(_config.foam_amount, target_config.foam_amount, alpha) * 7.5,
		maxf(delta_s, 0.0) * maxf(lerpf(_config.foam_decay, target_config.foam_decay, alpha), 0.5) * 1.15,
		lerpf(_config.foam_cascade_weight if _config.foam_enabled else 0.0, target_config.foam_cascade_weight if target_config.foam_enabled else 0.0, alpha),
	])
	_rd.compute_list_set_push_constant(compute_list, assemble_push.to_byte_array(), 32)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	_rd.compute_list_add_barrier(compute_list)

	var foam_groups = ceili(float(_foam_resolution) / 8.0)
	var crest_update_due := false
	var crest_delta := 0.0
	if (_config.foam_enabled or target_config.foam_enabled) and _crest_foam_compute_enabled:
		_crest_foam_accumulator += maxf(delta_s, 0.0)
		var crest_period := 1.0 / _crest_foam_update_hz
		if _crest_foam_accumulator >= crest_period:
			crest_update_due = true
			crest_delta = _crest_foam_accumulator
			_crest_foam_accumulator = fmod(_crest_foam_accumulator, crest_period)
	if crest_update_due:
		# Fresh whitecaps are born from current J; inherited history is advected, then
		# transition-only crest support releases foam without a current host crest.
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[3])
		_rd.compute_list_bind_uniform_set(compute_list, _foam_sets[_previous_displacement_read_index * 2 + _foam_read_index], 0)
		# update_foam receives rates per second and accumulated simulation delta; the shader
		# applies the exponential attack/release and residual decay internally.
		var foam_push := PackedFloat32Array([
			effective_whitecap,
			maxf(lerpf(_config.foam_amount, target_config.foam_amount, alpha), 0.0) * 7.5,
			lerpf(_config.foam_cascade_weight if _config.foam_enabled else 0.0, target_config.foam_cascade_weight if target_config.foam_enabled else 0.0, alpha),
			_foam_deposit_strength,
			maxf(lerpf(_config.foam_decay, target_config.foam_decay, alpha), 0.5) * 1.15 * _foam_residual_decay_multiplier,
			crest_delta,
			1.0 if _foam_advection_enabled else 0.0,
			_foam_advection_strength,
			# update_foam Params.domain ABI: x=domain metres, y=transition alpha,
			# z=signed target-current whitecap delta, w=transition active flag.
			_config.domain_size_m,
			alpha,
			target_whitecap - current_whitecap,
			1.0 if _h0_target.is_valid() else 0.0,
		])
		_rd.compute_list_set_push_constant(compute_list, foam_push.to_byte_array(), 48)
		_rd.compute_list_dispatch(compute_list, foam_groups, foam_groups, 1)
		_crest_updates_total += 1
		_crest_updates_window += 1
		_foam_read_index = 1 - _foam_read_index
		foam_rid = _foam_ping[_foam_read_index]
		_rd.compute_list_add_barrier(compute_list)

	# Capture current horizontal displacement after foam consumed the prior pair.
	if crest_update_due and _foam_advection_enabled:
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipelines[4])
		var previous_snapshot_index := _previous_displacement_read_index
		_rd.compute_list_bind_uniform_set(compute_list, _store_displacement_sets[previous_snapshot_index], 0)
		_rd.compute_list_set_push_constant(compute_list, PackedByteArray(), 0)
		_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	# Publish the exact old snapshot consumed by this foam update. Current
	# displacement is already published separately, so the material can show the
	# same motion vector without retaining another texture.
		previous_displacement_rid = _previous_displacement_ping[previous_snapshot_index]
		_previous_displacement_read_index = (previous_snapshot_index + 1) % 2
		_rd.compute_list_add_barrier(compute_list)
	_diagnostic_window_s += maxf(delta_s, 0.0)
	if _diagnostic_window_s >= 1.0:
		_crest_updates_per_second = float(_crest_updates_window) / _diagnostic_window_s
		_crest_updates_window = 0
		_diagnostic_window_s = 0.0
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
	if _evolve_set.is_valid():
		_rd.free_rid(_evolve_set)
	for texture in [_h0, _h0_target, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _ping_c[0], _ping_c[1], displacement_rid, normal_rid]:
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
	_h0_target = RID()
	_transition_target_config = null
	displacement_rid = RID()
	normal_rid = RID()
	foam_rid = RID()
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


func _rebuild_evolve_set() -> void:
	if _evolve_set.is_valid():
		_rd.free_rid(_evolve_set)
	var h0_target := _h0_target if _h0_target.is_valid() else _h0
	var uniforms: Array[RDUniform] = []
	for binding in 5:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = binding
		uniform.add_id([_h0, h0_target, _ping_a[0], _ping_b[0], _ping_c[0]][binding])
		uniforms.append(uniform)
	_evolve_set = _rd.uniform_set_create(uniforms, _shaders[0], 0)


func _clear_h0_transition() -> void:
	if _h0_target.is_valid() and _evolve_set.is_valid():
		_rd.free_rid(_evolve_set)
		_evolve_set = RID()
	if _h0_target.is_valid():
		_rd.free_rid(_h0_target)
	_h0_target = RID()
	_transition_target_config = null
	if _rd != null and _h0.is_valid() and _shaders.size() > 0:
		_rebuild_evolve_set()


func _create_foam_resources(resource_prefix: String) -> void:
	var initial_data := PackedByteArray()
	initial_data.resize(_foam_resolution * _foam_resolution * 4)
	_foam_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".FoamA", initial_data, false, _foam_resolution)
	_foam_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".FoamB", initial_data, false, _foam_resolution)
	var displacement_initial_data := PackedByteArray()
	displacement_initial_data.resize(_config.resolution * _config.resolution * 4)
	var snapshot_count := 2 if _foam_advection_enabled else 1
	if _foam_advection_enabled:
		for index in snapshot_count:
			_previous_displacement_ping[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".PreviousDisplacement%d" % index, displacement_initial_data)
	else:
		# The binding remains valid without allocating snapshot images; advection
		# is disabled in the push constants and both samples use current J.
		_previous_displacement_ping[0] = displacement_rid
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_linear_repeat_sampler = _rd.sampler_create(sampler_state)
	_foam_sets.clear()
	for snapshot_index in snapshot_count:
		for foam_index in 2:
			_foam_sets.append(_create_foam_set(_shaders[3], displacement_rid, _previous_displacement_ping[snapshot_index], _foam_ping[foam_index], _foam_ping[1 - foam_index]))
	_store_displacement_sets.clear()
	if _foam_advection_enabled:
		for snapshot_index in snapshot_count:
			_store_displacement_sets.append(_create_store_displacement_set(_shaders[4], displacement_rid, _previous_displacement_ping[(snapshot_index + 1) % snapshot_count]))
	_foam_read_index = 0
	_previous_displacement_read_index = 0
	foam_rid = _foam_ping[0]
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
	for texture in _foam_ping:
		if texture.is_valid():
			_rd.free_rid(texture)
	for texture in _previous_displacement_ping:
		if texture.is_valid() and texture != displacement_rid:
			_rd.free_rid(texture)
	if _linear_repeat_sampler.is_valid():
		_rd.free_rid(_linear_repeat_sampler)
	_foam_sets.clear()
	_store_displacement_sets.clear()
	_foam_ping = [RID(), RID()]
	_previous_displacement_ping = [RID(), RID()]
	_linear_repeat_sampler = RID()
	foam_rid = RID()
	previous_displacement_rid = RID()


func _foam_resources_ready() -> bool:
	if _store_displacement_sets.size() != (2 if _foam_advection_enabled else 0):
		return false
	if _foam_sets.size() != (4 if _foam_advection_enabled else 2):
		return false
	for uniform_set in _foam_sets:
		if not uniform_set.is_valid():
			return false
	for uniform_set in _store_displacement_sets:
		if not uniform_set.is_valid():
			return false
	return true


func _validated_foam_resolution(value: int) -> int:
	if value <= 256:
		return 256
	if value <= 512:
		return 512
	return 1024

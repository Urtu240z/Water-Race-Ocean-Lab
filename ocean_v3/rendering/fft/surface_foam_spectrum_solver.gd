class_name SurfaceFoamSpectrumSolver
extends RefCounted
## Incremental J-only solver for the independent Surface Foam field.
## It never owns physical-ocean displacement, normals, crest foam or snapshots.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_evolve_j.glsl"
const FFT_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_stockham_ifft_2.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_assemble_jacobian.glsl"
const UPDATE_SHADER := "res://ocean_v3/rendering/fft/shaders/update_surface_foam_jacobian.glsl"

var ready := false
var last_error := ""
var surface_foam_rid := RID()
var jacobian_rid := RID()
var previous_jacobian_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: SurfaceFoamReferenceConfig
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _jacobian: Array[RID] = [RID(), RID()]
var _foam: Array[RID] = [RID(), RID()]
var _sampler := RID()
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_sets: Array[RID] = [RID(), RID()]
var _foam_sets: Array[RID] = []
var _field_resolution := 1024
var _foam_read_index := 0
var _jacobian_read_index := 0
var _job_active := false
var _job_pass := 0
var _job_delta := 0.0
var _job_time := 0.0
var _simulation_time := 0.0
var _spectral_time := 0.0
var _time_since_last_job := 0.0
var _update_accumulator := 0.0
var _pass_credit := 0.0
var _update_hz := 30.0
var _enabled := true
var _whitecap := 0.0
var _amount := 8.573
var _birth_attack_s := 0.16
var _lifetime_s := 1.10
var _birth_selectivity := 0.28
var _evolution_speed := 0.35
var _completed_jobs_total := 0
var _passes_dispatched_total := 0
var _jobs_window := 0
var _passes_window := 0
var _diagnostic_window_s := 0.0
var _jobs_per_second := 0.0
var _passes_per_second := 0.0


func initialize(config: SurfaceFoamReferenceConfig, h0_data: PackedByteArray, resource_prefix := "Ocean2B.SurfaceFoam", field_resolution := 1024) -> void:
	free_resources()
	_config = config
	_field_resolution = _validated_resolution(field_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return
	for path in [EVOLVE_SHADER, FFT_SHADER, ASSEMBLE_SHADER, UPDATE_SHADER]:
		if not _create_pipeline(path, resource_prefix).is_valid():
			free_resources()
			return
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", config.resolution, h0_data, true)
	h0_upload_byte_count = h0_data.size()
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".DerivativeA%d" % index, config.resolution)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".DerivativeB%d" % index, config.resolution)
		_jacobian[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".Jacobian%d" % index, config.resolution)
		_foam[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".Field%d" % index, _field_resolution)
	_sampler = _create_sampler()
	_evolve_set = _create_image_set(_shaders[0], [_h0, _ping_a[0], _ping_b[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_a[1], _ping_b[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_a[0], _ping_b[0]])
	for index in 2:
		_assemble_sets[index] = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _jacobian[index]])
	for jacobian_index in 2:
		for foam_index in 2:
			_foam_sets.append(_create_foam_set(_jacobian[jacobian_index], _foam[foam_index], _foam[1 - foam_index]))
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_sets[0].is_valid() and _assemble_sets[1].is_valid() and _foam_sets.size() == 4
	if not ready:
		last_error = "No se pudieron crear los uniform sets de Surface Foam."
		return
	jacobian_rid = _jacobian[0]
	previous_jacobian_rid = _jacobian[1]
	surface_foam_rid = _foam[0]


func set_settings(enabled: bool, whitecap: float, amount: float, update_hz: float,
		birth_attack_s := 0.16, lifetime_s := 1.10, birth_selectivity := 0.28,
		evolution_speed := 0.35) -> void:
	_enabled = enabled
	_whitecap = clampf(whitecap, 0.0, 1.5)
	_amount = clampf(amount, 0.0, 10.0)
	_update_hz = clampf(update_hz, 30.0, 60.0)
	_birth_attack_s = clampf(birth_attack_s, 0.02, 1.0)
	_lifetime_s = clampf(lifetime_s, 0.1, 5.0)
	_birth_selectivity = clampf(birth_selectivity, 0.0, 1.0)
	_evolution_speed = clampf(evolution_speed, 0.0, 1.5)


func upload_h0(h0_data: PackedByteArray) -> void:
	if ready and _h0.is_valid():
		_rd.texture_update(_h0, 0, h0_data)
		h0_upload_byte_count = h0_data.size()


func total_job_passes() -> int:
	return 2 * _config.fft_stage_count() + 3


func advance(frame_delta: float) -> void:
	if not ready or not _enabled:
		return
	var safe_delta := maxf(frame_delta, 0.0)
	_diagnostic_window_s += safe_delta
	_time_since_last_job += safe_delta
	var period := 1.0 / _update_hz
	_update_accumulator += safe_delta
	_pass_credit = minf(_pass_credit + total_job_passes() * _update_hz * safe_delta, float(total_job_passes() * 2))
	if not _job_active and _update_accumulator >= period:
		_job_active = true
		_job_pass = 0
		_job_delta = _update_accumulator
		_update_accumulator = 0.0
		_simulation_time += _job_delta
		_spectral_time += _job_delta * _evolution_speed
		_job_time = _spectral_time
	var pass_budget := mini(int(floor(_pass_credit)), 24)
	if pass_budget <= 0 or not _job_active:
		return
	_pass_credit -= float(pass_budget)
	var groups := ceili(float(_config.resolution) / 8.0)
	var foam_groups := ceili(float(_field_resolution) / 8.0)
	var list := _rd.compute_list_begin()
	for _unused in pass_budget:
		if not _job_active:
			break
		_dispatch_job_pass(list, groups, foam_groups)
		_passes_dispatched_total += 1
		_passes_window += 1
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	if _diagnostic_window_s >= 1.0:
		_jobs_per_second = float(_jobs_window) / _diagnostic_window_s
		_passes_per_second = float(_passes_window) / _diagnostic_window_s
		_jobs_window = 0
		_passes_window = 0
		_diagnostic_window_s = 0.0


func _dispatch_job_pass(list: int, groups: int, foam_groups: int) -> void:
	var fft_count := 2 * _config.fft_stage_count()
	if _job_pass == 0:
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
		_rd.compute_list_bind_uniform_set(list, _evolve_set, 0)
		var compression := maxf(_config.domain_size_m / maxf(_config.feature_domain_m, 0.000001), 1.0)
		_rd.compute_list_set_push_constant(list, PackedFloat32Array([
			_job_time, _config.gravity_mps2, _config.depth_m, _config.domain_size_m,
			compression, 0.0, 0.0, 0.0
		]).to_byte_array(), 32)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	elif _job_pass <= fft_count:
		var fft_index := _job_pass - 1
		var axis := fft_index / _config.fft_stage_count()
		var stage := fft_index % _config.fft_stage_count()
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
		_rd.compute_list_bind_uniform_set(list, _fft_sets[fft_index % 2], 0)
		_rd.compute_list_set_push_constant(list, PackedInt32Array([2 << stage, axis, _config.resolution, 1]).to_byte_array(), 16)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	elif _job_pass == fft_count + 1:
		var write_jacobian := 1 - _jacobian_read_index
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[2])
		_rd.compute_list_bind_uniform_set(list, _assemble_sets[write_jacobian], 0)
		_rd.compute_list_set_push_constant(list, PackedFloat32Array([1.0, 0.0, 0.0, 0.0]).to_byte_array(), 16)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	else:
		var target_jacobian := 1 - _jacobian_read_index
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[3])
		_rd.compute_list_bind_uniform_set(list, _foam_sets[target_jacobian * 2 + _foam_read_index], 0)
		var source_gain := clampf((_amount / 8.573) * 2.05, 0.0, 4.0)
		_rd.compute_list_set_push_constant(list, PackedFloat32Array([
			_whitecap, source_gain, _birth_selectivity, 1.0,
			_job_delta, _birth_attack_s, _lifetime_s, 0.12
		]).to_byte_array(), 32)
		_rd.compute_list_dispatch(list, foam_groups, foam_groups, 1)
	_job_pass += 1
	if _job_pass >= total_job_passes():
		_jacobian_read_index = 1 - _jacobian_read_index
		_foam_read_index = 1 - _foam_read_index
		jacobian_rid = _jacobian[_jacobian_read_index]
		previous_jacobian_rid = _jacobian[1 - _jacobian_read_index]
		surface_foam_rid = _foam[_foam_read_index]
		_time_since_last_job = 0.0
		_job_active = false
		_completed_jobs_total += 1
		_jobs_window += 1


func diagnostic_state() -> Dictionary:
	return {"ready": ready, "total_job_passes": total_job_passes(), "field_resolution": _field_resolution, "h0_upload_bytes": h0_upload_byte_count, "completed_jobs_total": _completed_jobs_total, "passes_dispatched_total": _passes_dispatched_total, "jobs_per_second": _jobs_per_second, "passes_per_second": _passes_per_second, "simulation_time_s": _simulation_time, "temporal_alpha": temporal_alpha(), "update_hz": _update_hz, "birth_attack_s": _birth_attack_s, "lifetime_s": _lifetime_s, "birth_selectivity": _birth_selectivity, "evolution_speed": _evolution_speed, "gpu_bytes": _config.resolution * _config.resolution * (16 * 5 + 2 * 2) + _field_resolution * _field_resolution * 2 * 2}


func temporal_alpha() -> float:
	if not ready:
		return 0.0
	return clampf(_time_since_last_job * _update_hz, 0.0, 1.0)


func free_resources() -> void:
	ready = false
	if _rd == null:
		return
	for set_rid in _sets:
		if set_rid.is_valid(): _rd.free_rid(set_rid)
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _jacobian[0], _jacobian[1], _foam[0], _foam[1]]:
		if texture.is_valid(): _rd.free_rid(texture)
	if _sampler.is_valid(): _rd.free_rid(_sampler)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_sets.clear(); _pipelines.clear(); _shaders.clear()
	_h0 = RID(); _ping_a = [RID(), RID()]; _ping_b = [RID(), RID()]; _jacobian = [RID(), RID()]; _foam = [RID(), RID()]
	_sampler = RID(); surface_foam_rid = RID(); jacobian_rid = RID(); previous_jacobian_rid = RID()


func _create_pipeline(path: String, prefix: String) -> RID:
	var file: RDShaderFile = load(path)
	if file == null: last_error = "No se pudo cargar %s" % path; return RID()
	var shader := _rd.shader_create_from_spirv(file.get_spirv(), prefix + ".Shader")
	if not shader.is_valid():
		last_error = "No se pudo compilar %s" % path
		push_error(last_error)
		return RID()
	var pipeline := _rd.compute_pipeline_create(shader)
	_shaders.append(shader); _pipelines.append(pipeline)
	return pipeline


func _create_texture(format: int, name: String, resolution: int, data := PackedByteArray(), can_update := false) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = resolution; texture_format.height = resolution; texture_format.depth = 1; texture_format.array_layers = 1; texture_format.mipmaps = 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if can_update: texture_format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial: Array[PackedByteArray] = []
	if not data.is_empty(): initial.append(data)
	var rid := _rd.texture_create(texture_format, RDTextureView.new(), initial)
	_rd.set_resource_name(rid, name)
	return rid


func _create_image_set(shader: RID, textures: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; uniform.binding = binding; uniform.add_id(textures[binding]); uniforms.append(uniform)
	var set_rid := _rd.uniform_set_create(uniforms, shader, 0)
	_sets.append(set_rid)
	return set_rid


func _create_sampler() -> RID:
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	return _rd.sampler_create(state)


func _create_foam_set(jacobian: RID, previous: RID, next: RID) -> RID:
	var j := RDUniform.new(); j.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; j.binding = 0; j.add_id(_sampler); j.add_id(jacobian)
	var p := RDUniform.new(); p.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; p.binding = 1; p.add_id(_sampler); p.add_id(previous)
	var n := RDUniform.new(); n.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; n.binding = 2; n.add_id(next)
	var set_rid := _rd.uniform_set_create([j, p, n], _shaders[3], 0)
	_sets.append(set_rid)
	return set_rid


func _validated_resolution(value: int) -> int:
	return 256 if value <= 256 else 512 if value <= 512 else 1024

class_name SurfaceFoamSpectrumSolver
extends RefCounted
## Incremental J-only solver for the independent Surface Foam field.
## It never owns physical-ocean displacement, normals, crest foam or snapshots.

const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_evolve_j.glsl"
const FFT_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_stockham_ifft_2.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/surface_foam_assemble_jacobian.glsl"
const UPDATE_SHADER := "res://ocean_v3/rendering/fft/shaders/update_surface_foam_jacobian.glsl"
const TOPOLOGY_SHADER := "res://ocean_v3/rendering/fft/shaders/build_surface_foam_topology.glsl"
const DOWNSAMPLE_SHADER := "res://ocean_v3/rendering/fft/shaders/downsample_surface_foam_topology.glsl"
const PIPELINE_EVOLVE := 0
const PIPELINE_FFT := 1
const PIPELINE_ASSEMBLE := 2
const PIPELINE_UPDATE := 3
const PIPELINE_TOPOLOGY := 4
const PIPELINE_DOWNSAMPLE := 5
## Keep a slow render step from submitting an unbounded stale solver burst.
const MAX_PASSES_PER_RENDER_STEP := 24
const MAX_CATCHUP_SECONDS := 0.10

var ready := false
var last_error := ""
var surface_foam_rid := RID()
var jacobian_rid := RID()
var topology_rid := RID()
var h0_upload_byte_count := 0

var _rd: RenderingDevice
var _config: SurfaceFoamReferenceConfig
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _jacobian: Array[RID] = [RID(), RID()]
var _foam: Array[RID] = [RID(), RID()]
var _topology: Array[RID] = [RID(), RID()]
var _topology_mip_views: Array[Array] = [[], []]
var _sampler := RID()
var _topology_params_buffer := RID()
var _foam_params_buffer := RID()
var _assemble_params_buffer := RID()
var _evolve_params_buffer := RID()
var _fft_params_buffer := RID()
var _topology_params_bytes := PackedByteArray()
var _foam_params_bytes := PackedByteArray()
var _assemble_params_bytes := PackedByteArray()
var _evolve_params_bytes := PackedByteArray()
var _fft_params_bytes := PackedByteArray()
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_sets: Array[RID] = [RID(), RID()]
var _foam_sets: Array[RID] = []
var _topology_sets: Array[RID] = []
var _topology_downsample_sets: Array[Array] = [[], []]
var _field_resolution := 1024
var _topology_resolution := 1024
var _foam_read_index := 0
var _jacobian_read_index := 0
var _job_active := false
var _job_pass := 0
var _job_delta := 0.0
var _job_time := 0.0
var _simulation_time := 0.0
var _spectral_time := 0.0
var _update_accumulator := 0.0
var _pass_credit := 0.0
var _update_hz := 30.0
var _enabled := true
var _whitecap := 0.0
var _crest_whitecap := 0.0
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


func initialize(config: SurfaceFoamReferenceConfig, h0_data: PackedByteArray, resource_prefix := "Ocean2B.SurfaceFoam", field_resolution := 1024, topology_resolution := 1024) -> void:
	free_resources()
	_config = config
	_field_resolution = _validated_resolution(field_resolution)
	_topology_resolution = _validated_resolution(topology_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return
	for path in [EVOLVE_SHADER, FFT_SHADER, ASSEMBLE_SHADER, UPDATE_SHADER, TOPOLOGY_SHADER, DOWNSAMPLE_SHADER]:
		if not _create_pipeline(path, resource_prefix).is_valid():
			free_resources()
			return
	_topology_params_bytes.resize(16)
	_foam_params_bytes.resize(48)
	_assemble_params_bytes.resize(16)
	_evolve_params_bytes.resize(16)
	_fft_params_bytes.resize(16)
	_write_topology_params()
	_assemble_params_bytes.encode_float(0, 1.0)
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", config.resolution, h0_data, true)
	h0_upload_byte_count = h0_data.size()
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".DerivativeA%d" % index, config.resolution)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".DerivativeB%d" % index, config.resolution)
		_jacobian[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".Jacobian%d" % index, config.resolution)
		_foam[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".Field%d" % index, _field_resolution)
		_topology[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".Topology%d" % index, _topology_resolution, PackedByteArray(), false, true)
	_sampler = _create_sampler()
	_topology_params_buffer = _rd.uniform_buffer_create(16, _topology_params_bytes)
	_foam_params_buffer = _rd.uniform_buffer_create(48, PackedByteArray())
	_assemble_params_buffer = _rd.uniform_buffer_create(16, _assemble_params_bytes)
	_evolve_params_buffer = _rd.uniform_buffer_create(16, PackedByteArray())
	_fft_params_buffer = _rd.uniform_buffer_create(16, PackedByteArray())
	_evolve_set = _create_image_set(_shaders[PIPELINE_EVOLVE], [_h0, _ping_a[0], _ping_b[0]], _evolve_params_buffer)
	_fft_sets[0] = _create_image_set(_shaders[PIPELINE_FFT], [_ping_a[0], _ping_b[0], _ping_a[1], _ping_b[1]], _fft_params_buffer)
	_fft_sets[1] = _create_image_set(_shaders[PIPELINE_FFT], [_ping_a[1], _ping_b[1], _ping_a[0], _ping_b[0]], _fft_params_buffer)
	for index in 2:
		_assemble_sets[index] = _create_image_set(_shaders[PIPELINE_ASSEMBLE], [_ping_a[0], _ping_b[0], _jacobian[index]], _assemble_params_buffer)
	for jacobian_index in 2:
		for foam_index in 2:
			_foam_sets.append(_create_foam_set(_jacobian[jacobian_index], _foam[foam_index], _foam[1 - foam_index]))
	_topology_sets = []
	_topology_downsample_sets = [[], []]
	for index in 2:
		_topology_mip_views[index] = _create_topology_mip_views(_topology[index])
		_topology_sets.append(_create_topology_set(_jacobian[index], _topology_mip_views[index][0]))
		for mip in range(1, _topology_mip_views[index].size()):
			_topology_downsample_sets[index].append(_create_topology_downsample_set(_topology_mip_views[index][mip - 1], _topology_mip_views[index][mip]))
	ready = _assemble_params_buffer.is_valid() and _evolve_params_buffer.is_valid() and _fft_params_buffer.is_valid() and _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_sets[0].is_valid() and _assemble_sets[1].is_valid() and _foam_sets.size() == 4 and _topology_sets.size() == 2 and _topology_downsample_sets[0].size() == _topology_mip_count() - 1 and _topology_downsample_sets[1].size() == _topology_mip_count() - 1 and _all_topology_views_valid()
	if not ready:
		last_error = "No se pudieron crear los uniform sets de Surface Foam."
		return
	jacobian_rid = _jacobian[0]
	surface_foam_rid = _foam[0]
	topology_rid = _topology[0]


func set_settings(enabled: bool, whitecap: float, amount: float, update_hz: float,
		birth_attack_s := 0.16, lifetime_s := 1.10, birth_selectivity := 0.28,
		evolution_speed := 0.35, crest_whitecap := 0.0) -> void:
	_enabled = enabled
	_whitecap = clampf(whitecap, 0.0, 1.5)
	_crest_whitecap = clampf(crest_whitecap, 0.0, 1.5)
	_amount = clampf(amount, 0.0, 10.0)
	_update_hz = clampf(update_hz, 30.0, 60.0)
	_birth_attack_s = clampf(birth_attack_s, 0.02, 1.0)
	_lifetime_s = clampf(lifetime_s, 0.1, 5.0)
	_birth_selectivity = clampf(birth_selectivity, 0.0, 1.0)
	_evolution_speed = clampf(evolution_speed, 0.0, 1.5)
	if _rd != null and _topology_params_buffer.is_valid():
		_write_topology_params()
		_rd.buffer_update(_topology_params_buffer, 0, 16, _topology_params_bytes)


func upload_h0(h0_data: PackedByteArray) -> void:
	if ready and _h0.is_valid():
		_rd.texture_update(_h0, 0, h0_data)
		h0_upload_byte_count = h0_data.size()


func total_job_passes() -> int:
	# Evolve + IFFT + assemble + field update + topology base + every topology mip.
	return 2 * _config.fft_stage_count() + 3 + _topology_mip_count()


func advance(frame_delta: float) -> void:
	if not ready or not _enabled:
		return
	var safe_delta := maxf(frame_delta, 0.0)
	_diagnostic_window_s += safe_delta
	var period := 1.0 / _update_hz
	_update_accumulator += safe_delta
	# One complete job is enough to finish the active update without retaining
	# additional stale work after a hitch.
	_pass_credit = minf(_pass_credit + total_job_passes() * _update_hz * safe_delta, float(total_job_passes()))
	if not _job_active and _update_accumulator >= period:
		_job_active = true
		_job_pass = 0
		_job_delta = minf(_update_accumulator, MAX_CATCHUP_SECONDS)
		_update_accumulator = 0.0
		_simulation_time += _job_delta
		_spectral_time += _job_delta * _evolution_speed
		_job_time = _spectral_time
	var pass_budget := mini(int(floor(_pass_credit)), MAX_PASSES_PER_RENDER_STEP)
	if pass_budget <= 0 or not _job_active:
		return
	_pass_credit -= float(pass_budget)
	var groups := ceili(float(_config.resolution) / 8.0)
	var foam_groups := ceili(float(_field_resolution) / 8.0)
	var fft_count := 2 * _config.fft_stage_count()
	for _unused in pass_budget:
		if not _job_active:
			break
		if _job_pass == 0:
			_write_evolve_params()
			_rd.buffer_update(_evolve_params_buffer, 0, 16, _evolve_params_bytes)
		elif _job_pass == fft_count + 1:
			_write_foam_params()
			_rd.buffer_update(_foam_params_buffer, 0, 48, _foam_params_bytes)
		elif _job_pass > 0 and _job_pass <= fft_count:
			var fft_index := _job_pass - 1
			var axis := floori(float(fft_index) / float(_config.fft_stage_count()))
			var stage := fft_index % _config.fft_stage_count()
			_fft_params_bytes.encode_s32(0, 2 << stage)
			_fft_params_bytes.encode_s32(4, axis)
			_fft_params_bytes.encode_s32(8, _config.resolution)
			_fft_params_bytes.encode_s32(12, 1)
			_rd.buffer_update(_fft_params_buffer, 0, 16, _fft_params_bytes)
		var list := _rd.compute_list_begin()
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


func _write_topology_params() -> void:
	_topology_params_bytes.encode_float(0, _whitecap)
	_topology_params_bytes.encode_float(4, _crest_whitecap)
	_topology_params_bytes.encode_float(8, _config.domain_size_m)
	_topology_params_bytes.encode_float(12, float(_topology_resolution))


func _write_foam_params() -> void:
	var source_gain := clampf((_amount / 8.573) * 2.05, 0.0, 4.0)
	_foam_params_bytes.encode_float(0, _whitecap)
	_foam_params_bytes.encode_float(4, source_gain)
	_foam_params_bytes.encode_float(8, _birth_selectivity)
	_foam_params_bytes.encode_float(12, 1.0)
	_foam_params_bytes.encode_float(16, _job_delta)
	_foam_params_bytes.encode_float(20, _birth_attack_s)
	_foam_params_bytes.encode_float(24, _lifetime_s)
	_foam_params_bytes.encode_float(28, 0.12)
	_foam_params_bytes.encode_float(32, _config.field_domain_m)
	_foam_params_bytes.encode_float(36, _config.domain_size_m)
	_foam_params_bytes.encode_float(40, 2.25)
	_foam_params_bytes.encode_float(44, 0.0)


func _write_evolve_params() -> void:
	_evolve_params_bytes.encode_float(0, _job_time)
	_evolve_params_bytes.encode_float(4, _config.gravity_mps2)
	_evolve_params_bytes.encode_float(8, _config.depth_m)
	_evolve_params_bytes.encode_float(12, _config.domain_size_m)


func _dispatch_job_pass(list: int, groups: int, foam_groups: int) -> void:
	var fft_count := 2 * _config.fft_stage_count()
	if _job_pass == 0:
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_EVOLVE])
		_rd.compute_list_bind_uniform_set(list, _evolve_set, 0)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	elif _job_pass <= fft_count:
		var fft_index := _job_pass - 1
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_FFT])
		_rd.compute_list_bind_uniform_set(list, _fft_sets[fft_index % 2], 0)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	elif _job_pass == fft_count + 1:
		var write_jacobian := 1 - _jacobian_read_index
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_ASSEMBLE])
		_rd.compute_list_bind_uniform_set(list, _assemble_sets[write_jacobian], 0)
		_rd.compute_list_dispatch(list, groups, groups, 1)
	elif _job_pass == fft_count + 2:
		var target_jacobian := 1 - _jacobian_read_index
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_UPDATE])
		_rd.compute_list_bind_uniform_set(list, _foam_sets[target_jacobian * 2 + _foam_read_index], 0)
		_rd.compute_list_dispatch(list, foam_groups, foam_groups, 1)
	elif _job_pass == fft_count + 3:
		var target_jacobian := 1 - _jacobian_read_index
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_TOPOLOGY])
		_rd.compute_list_bind_uniform_set(list, _topology_sets[target_jacobian], 0)
		_rd.compute_list_dispatch(list, ceili(float(_topology_resolution) / 8.0), ceili(float(_topology_resolution) / 8.0), 1)
	elif _job_pass > fft_count + 3:
		var target_jacobian := 1 - _jacobian_read_index
		var mip := _job_pass - (fft_count + 4)
		_rd.compute_list_bind_compute_pipeline(list, _pipelines[PIPELINE_DOWNSAMPLE])
		_rd.compute_list_bind_uniform_set(list, _topology_downsample_sets[target_jacobian][mip], 0)
		var mip_resolution := maxi(_topology_resolution >> (mip + 1), 1)
		_rd.compute_list_dispatch(list, ceili(float(mip_resolution) / 8.0), ceili(float(mip_resolution) / 8.0), 1)
	_job_pass += 1
	if _job_pass >= total_job_passes():
		_jacobian_read_index = 1 - _jacobian_read_index
		_foam_read_index = 1 - _foam_read_index
		topology_rid = _topology[_jacobian_read_index]
		jacobian_rid = _jacobian[_jacobian_read_index]
		surface_foam_rid = _foam[_foam_read_index]
		_job_active = false
		_completed_jobs_total += 1
		_jobs_window += 1


func diagnostic_state() -> Dictionary:
	var topology_mip_count := floori(log(float(_topology_resolution)) / log(2.0)) + 1
	var topology_bytes := _topology_resolution * _topology_resolution * 4 * 4.0 / 3.0 * 2.0
	return {"ready": ready, "total_job_passes": total_job_passes(), "field_resolution": _field_resolution, "topology_resolution": _topology_resolution, "topology_format": "RG16F", "topology_channels": "R=Surface raw, G=Crest raw", "topology_mip_levels": topology_mip_count, "topology_mip_generation": "compute", "h0_upload_bytes": h0_upload_byte_count, "completed_jobs_total": _completed_jobs_total, "passes_dispatched_total": _passes_dispatched_total, "jobs_per_second": _jobs_per_second, "passes_per_second": _passes_per_second, "simulation_time_s": _simulation_time, "update_hz": _update_hz, "birth_attack_s": _birth_attack_s, "lifetime_s": _lifetime_s, "birth_selectivity": _birth_selectivity, "evolution_speed": _evolution_speed, "topology_gpu_bytes": int(topology_bytes), "gpu_bytes": _config.resolution * _config.resolution * (16 * 5 + 2 * 2) + _field_resolution * _field_resolution * 2 * 2 + int(topology_bytes) * 2}


func free_resources() -> void:
	ready = false
	if _rd == null:
		return
	for set_rid in _sets:
		if set_rid.is_valid(): _rd.free_rid(set_rid)
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _jacobian[0], _jacobian[1], _foam[0], _foam[1], _topology[0], _topology[1]]:
		if texture.is_valid(): _rd.free_rid(texture)
	if _sampler.is_valid(): _rd.free_rid(_sampler)
	if _topology_params_buffer.is_valid(): _rd.free_rid(_topology_params_buffer)
	if _foam_params_buffer.is_valid(): _rd.free_rid(_foam_params_buffer)
	if _assemble_params_buffer.is_valid(): _rd.free_rid(_assemble_params_buffer)
	if _evolve_params_buffer.is_valid(): _rd.free_rid(_evolve_params_buffer)
	if _fft_params_buffer.is_valid(): _rd.free_rid(_fft_params_buffer)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_sets.clear(); _pipelines.clear(); _shaders.clear(); _topology_sets.clear(); _topology_downsample_sets = [[], []]; _topology_mip_views = [[], []]
	_h0 = RID(); _ping_a = [RID(), RID()]; _ping_b = [RID(), RID()]; _jacobian = [RID(), RID()]; _foam = [RID(), RID()]; _topology = [RID(), RID()]
	_sampler = RID(); _topology_params_buffer = RID(); _foam_params_buffer = RID(); _assemble_params_buffer = RID(); _evolve_params_buffer = RID(); _fft_params_buffer = RID(); surface_foam_rid = RID(); jacobian_rid = RID(); topology_rid = RID()


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


func _create_texture(format: int, name: String, resolution: int, data := PackedByteArray(), can_update := false, with_mipmaps := false) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = resolution; texture_format.height = resolution; texture_format.depth = 1; texture_format.array_layers = 1; texture_format.mipmaps = (floori(log(float(resolution)) / log(2.0)) + 1) if with_mipmaps else 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if can_update: texture_format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial: Array[PackedByteArray] = []
	if not data.is_empty(): initial.append(data)
	var rid := _rd.texture_create(texture_format, RDTextureView.new(), initial)
	_rd.set_resource_name(rid, name)
	return rid


func _create_image_set(shader: RID, textures: Array[RID], params_buffer := RID()) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; uniform.binding = binding; uniform.add_id(textures[binding]); uniforms.append(uniform)
	if params_buffer.is_valid():
		var params := RDUniform.new(); params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding = textures.size(); params.add_id(params_buffer); uniforms.append(params)
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
	var params := RDUniform.new(); params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding = 3; params.add_id(_foam_params_buffer)
	var set_rid := _rd.uniform_set_create([j, p, n, params], _shaders[PIPELINE_UPDATE], 0)
	_sets.append(set_rid)
	return set_rid


func _create_topology_set(jacobian: RID, topology: RID) -> RID:
	var j := RDUniform.new(); j.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; j.binding = 0; j.add_id(_sampler); j.add_id(jacobian)
	var t := RDUniform.new(); t.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; t.binding = 1; t.add_id(topology)
	var p := RDUniform.new(); p.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; p.binding = 2; p.add_id(_topology_params_buffer)
	var set_rid := _rd.uniform_set_create([j, t, p], _shaders[PIPELINE_TOPOLOGY], 0)
	_sets.append(set_rid)
	return set_rid


func _create_topology_mip_views(topology: RID) -> Array[RID]:
	var views: Array[RID] = []
	for mip in _topology_mip_count():
		var view := _rd.texture_create_shared_from_slice(RDTextureView.new(), topology, 0, mip, 1)
		if not view.is_valid():
			last_error = "No se pudo crear la view del mip %d de Surface Foam Topology." % mip
		views.append(view)
	return views


func _create_topology_downsample_set(source_mip: RID, destination_mip: RID) -> RID:
	var source := RDUniform.new(); source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; source.binding = 0; source.add_id(_sampler); source.add_id(source_mip)
	var destination := RDUniform.new(); destination.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; destination.binding = 1; destination.add_id(destination_mip)
	var set_rid := _rd.uniform_set_create([source, destination], _shaders[PIPELINE_DOWNSAMPLE], 0)
	_sets.append(set_rid)
	return set_rid


func _topology_mip_count() -> int:
	return floori(log(float(_topology_resolution)) / log(2.0)) + 1


func _all_topology_views_valid() -> bool:
	for views in _topology_mip_views:
		if views.size() != _topology_mip_count(): return false
		for view in views:
			if not view.is_valid(): return false
	return true


func _validated_resolution(value: int) -> int:
	return 256 if value <= 256 else 512 if value <= 512 else 1024

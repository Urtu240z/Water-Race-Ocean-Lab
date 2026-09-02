class_name SurfaceFoamShortSourceSolver
extends RefCounted
## Reuses the MAIN FFT SHORT Jacobian while preserving Surface Foam history,
## topology and mip generation. It owns no H0, spectrum evolution or FFT passes.

const EXTRACT_SHADER := "res://ocean_v3/rendering/fft/shaders/extract_surface_foam_short_jacobian.glsl"
const UPDATE_SHADER := "res://ocean_v3/rendering/fft/shaders/update_surface_foam_jacobian.glsl"
const TOPOLOGY_SHADER := "res://ocean_v3/rendering/fft/shaders/build_surface_foam_topology.glsl"
const DOWNSAMPLE_SHADER := "res://ocean_v3/rendering/fft/shaders/downsample_surface_foam_topology.glsl"

var ready := false
var last_error := ""
var surface_foam_rid := RID()
var jacobian_rid := RID()
var topology_rid := RID()

var _rd: RenderingDevice
var _jacobian := RID()
var _foam: Array[RID] = [RID(), RID()]
var _topology: Array[RID] = [RID(), RID()]
var _topology_mip_views: Array[Array] = [[], []]
var _sampler := RID()
var _extract_shader := RID()
var _update_shader := RID()
var _topology_shader := RID()
var _downsample_shader := RID()
var _extract_pipeline := RID()
var _update_pipeline := RID()
var _topology_pipeline := RID()
var _downsample_pipeline := RID()
var _sets: Array[RID] = []
var _extract_set := RID()
var _foam_sets: Array[RID] = []
var _topology_sets: Array[RID] = []
var _topology_downsample_sets: Array[Array] = [[], []]
var _topology_params_buffer := RID()
var _foam_params_buffer := RID()
var _topology_params_bytes := PackedByteArray()
var _foam_params_bytes := PackedByteArray()
var _source_resolution := 0
var _source_domain_m := 37.0
var _field_domain := 88.0
var _field_resolution := 1024
var _topology_resolution := 1024
var _foam_read_index := 0
var _topology_read_index := 0
var _job_active := false
var _job_pass := 0
var _job_delta := 0.0
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
var _completed_jobs_total := 0
var _passes_dispatched_total := 0
var _jobs_window := 0
var _passes_window := 0
var _diagnostic_window_s := 0.0
var _jobs_per_second := 0.0
var _passes_per_second := 0.0


func initialize(displacement_short: RID, short_resolution: int, short_domain_m: float,
		field_resolution := 1024, topology_resolution := 1024, field_domain_m := 88.0,
		resource_prefix := "Ocean2B.SurfaceFoamShortSource") -> void:
	free_resources()
	_source_resolution = max(short_resolution, 1)
	_source_domain_m = maxf(short_domain_m, 0.001)
	_field_domain = maxf(field_domain_m, 0.001)
	_field_resolution = _validated_resolution(field_resolution)
	_topology_resolution = _validated_resolution(topology_resolution)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not displacement_short.is_valid():
		last_error = "No se pudo inicializar la fuente MAIN FFT SHORT de Surface Foam."
		return
	_extract_shader = _load_shader(EXTRACT_SHADER, resource_prefix + ".Extract")
	_update_shader = _load_shader(UPDATE_SHADER, resource_prefix + ".Update")
	_topology_shader = _load_shader(TOPOLOGY_SHADER, resource_prefix + ".Topology")
	_downsample_shader = _load_shader(DOWNSAMPLE_SHADER, resource_prefix + ".Downsample")
	if not _extract_shader.is_valid() or not _update_shader.is_valid() or not _topology_shader.is_valid() or not _downsample_shader.is_valid():
		free_resources()
		return
	_extract_pipeline = _rd.compute_pipeline_create(_extract_shader)
	_update_pipeline = _rd.compute_pipeline_create(_update_shader)
	_topology_pipeline = _rd.compute_pipeline_create(_topology_shader)
	_downsample_pipeline = _rd.compute_pipeline_create(_downsample_shader)
	_topology_params_bytes.resize(16)
	_foam_params_bytes.resize(48)
	_write_topology_params()
	_jacobian = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, resource_prefix + ".Jacobian", _source_resolution)
	for index in 2:
		_foam[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".Field%d" % index, _field_resolution)
		_topology[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, resource_prefix + ".Topology%d" % index, _topology_resolution, true)
	_sampler = _create_sampler()
	_topology_params_buffer = _rd.uniform_buffer_create(16, _topology_params_bytes)
	_foam_params_buffer = _rd.uniform_buffer_create(48, PackedByteArray())
	_extract_set = _create_extract_set(displacement_short)
	for foam_index in 2:
		_foam_sets.append(_create_foam_set(_foam[foam_index], _foam[1 - foam_index]))
	for index in 2:
		_topology_mip_views[index] = _create_topology_mip_views(_topology[index])
		_topology_sets.append(_create_topology_set(_topology_mip_views[index][0]))
		for mip in range(1, _topology_mip_count()):
			_topology_downsample_sets[index].append(_create_topology_downsample_set(_topology_mip_views[index][mip - 1], _topology_mip_views[index][mip]))
	ready = _extract_pipeline.is_valid() and _update_pipeline.is_valid() and _topology_pipeline.is_valid() and _downsample_pipeline.is_valid() \
		and _jacobian.is_valid() and _extract_set.is_valid() and _foam_sets.size() == 2 and _foam_sets[0].is_valid() and _foam_sets[1].is_valid() \
		and _topology_sets.size() == 2 and _topology_sets[0].is_valid() and _topology_sets[1].is_valid() \
		and _topology_downsample_sets[0].size() == _topology_mip_count() - 1 and _topology_downsample_sets[1].size() == _topology_mip_count() - 1
	if not ready:
		last_error = "No se pudieron crear los recursos MAIN FFT SHORT de Surface Foam."
		return
	jacobian_rid = _jacobian
	surface_foam_rid = _foam[0]
	topology_rid = _topology[0]


func set_settings(enabled: bool, whitecap: float, amount: float, update_hz: float,
		birth_attack_s := 0.16, lifetime_s := 1.10, birth_selectivity := 0.28,
		_evolution_speed := 0.35, crest_whitecap := 0.0) -> void:
	_enabled = enabled
	_whitecap = clampf(whitecap, 0.0, 1.5)
	_crest_whitecap = clampf(crest_whitecap, 0.0, 1.5)
	_amount = clampf(amount, 0.0, 10.0)
	_update_hz = clampf(update_hz, 30.0, 60.0)
	_birth_attack_s = clampf(birth_attack_s, 0.02, 1.0)
	_lifetime_s = clampf(lifetime_s, 0.1, 5.0)
	_birth_selectivity = clampf(birth_selectivity, 0.0, 1.0)
	if _rd != null and _topology_params_buffer.is_valid():
		_write_topology_params()
		_rd.buffer_update(_topology_params_buffer, 0, 16, _topology_params_bytes)


func total_job_passes() -> int:
	# Extract exact SHORT J, then run the unchanged foam/history/topology pipeline.
	return 2


func advance(frame_delta: float) -> void:
	if not ready or not _enabled:
		return
	var safe_delta := maxf(frame_delta, 0.0)
	_diagnostic_window_s += safe_delta
	_update_accumulator += safe_delta
	var period := 1.0 / _update_hz
	_pass_credit = minf(_pass_credit + total_job_passes() * _update_hz * safe_delta, float(total_job_passes() * 2))
	if not _job_active and _update_accumulator >= period:
		_job_active = true
		_job_pass = 0
		_job_delta = _update_accumulator
		_update_accumulator = 0.0
	var pass_budget := mini(int(floor(_pass_credit)), 4)
	if pass_budget <= 0 or not _job_active:
		return
	_pass_credit -= float(pass_budget)
	for _unused in pass_budget:
		if not _job_active:
			break
		# RenderingDevice forbids buffer updates while a compute list is active.
		# The update pass consumes the current job delta, so upload it immediately
		# before opening that list.
		if _job_pass == 1:
			_write_foam_params()
			_rd.buffer_update(_foam_params_buffer, 0, 48, _foam_params_bytes)
		var list := _rd.compute_list_begin()
		_dispatch_job_pass(list)
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


func _dispatch_job_pass(list: int) -> void:
	if _job_pass == 0:
		_rd.compute_list_bind_compute_pipeline(list, _extract_pipeline)
		_rd.compute_list_bind_uniform_set(list, _extract_set, 0)
		var source_groups := ceili(float(_source_resolution) / 8.0)
		_rd.compute_list_dispatch(list, source_groups, source_groups, 1)
	else:
		_rd.compute_list_bind_compute_pipeline(list, _update_pipeline)
		_rd.compute_list_bind_uniform_set(list, _foam_sets[_foam_read_index], 0)
		var foam_groups := ceili(float(_field_resolution) / 8.0)
		_rd.compute_list_dispatch(list, foam_groups, foam_groups, 1)
		_rd.compute_list_add_barrier(list)
		var write_topology := 1 - _topology_read_index
		_rd.compute_list_bind_compute_pipeline(list, _topology_pipeline)
		_rd.compute_list_bind_uniform_set(list, _topology_sets[write_topology], 0)
		var topology_groups := ceili(float(_topology_resolution) / 8.0)
		_rd.compute_list_dispatch(list, topology_groups, topology_groups, 1)
		_rd.compute_list_add_barrier(list)
		for mip in _topology_downsample_sets[write_topology].size():
			_rd.compute_list_bind_compute_pipeline(list, _downsample_pipeline)
			_rd.compute_list_bind_uniform_set(list, _topology_downsample_sets[write_topology][mip], 0)
			var mip_resolution := maxi(_topology_resolution >> (mip + 1), 1)
			var mip_groups := ceili(float(mip_resolution) / 8.0)
			_rd.compute_list_dispatch(list, mip_groups, mip_groups, 1)
			_rd.compute_list_add_barrier(list)
	_job_pass += 1
	if _job_pass >= total_job_passes():
		_foam_read_index = 1 - _foam_read_index
		_topology_read_index = 1 - _topology_read_index
		surface_foam_rid = _foam[_foam_read_index]
		jacobian_rid = _jacobian
		topology_rid = _topology[_topology_read_index]
		_job_active = false
		_completed_jobs_total += 1
		_jobs_window += 1


func diagnostic_state() -> Dictionary:
	var topology_bytes := _topology_resolution * _topology_resolution * 4 * 4.0 / 3.0 * 2.0
	var field_bytes := _field_resolution * _field_resolution * 4 * 2.0
	var jacobian_bytes := _source_resolution * _source_resolution * 2.0
	return {"ready": ready, "source": "MAIN_FFT_SHORT", "total_job_passes": total_job_passes(), "source_resolution": _source_resolution, "source_domain_m": _source_domain_m, "field_resolution": _field_resolution, "topology_resolution": _topology_resolution, "topology_format": "RG16F", "topology_channels": "R=Surface raw, G=Crest raw", "topology_mip_generation": "compute", "completed_jobs_total": _completed_jobs_total, "passes_dispatched_total": _passes_dispatched_total, "jobs_per_second": _jobs_per_second, "passes_per_second": _passes_per_second, "update_hz": _update_hz, "birth_attack_s": _birth_attack_s, "lifetime_s": _lifetime_s, "birth_selectivity": _birth_selectivity, "topology_gpu_bytes": int(topology_bytes), "gpu_bytes": int(jacobian_bytes + field_bytes + topology_bytes)}


func free_resources() -> void:
	ready = false
	if _rd != null:
		for set_rid in _sets:
			if set_rid.is_valid(): _rd.free_rid(set_rid)
		for texture in [_jacobian, _foam[0], _foam[1], _topology[0], _topology[1]]:
			if texture.is_valid(): _rd.free_rid(texture)
		for rid in [_sampler, _topology_params_buffer, _foam_params_buffer, _extract_pipeline, _update_pipeline, _topology_pipeline, _downsample_pipeline, _extract_shader, _update_shader, _topology_shader, _downsample_shader]:
			if rid.is_valid(): _rd.free_rid(rid)
	_sets.clear()
	_jacobian = RID(); _foam = [RID(), RID()]; _topology = [RID(), RID()]
	_topology_mip_views = [[], []]; _topology_downsample_sets = [[], []]; _topology_sets.clear(); _foam_sets.clear()
	_sampler = RID(); _topology_params_buffer = RID(); _foam_params_buffer = RID()
	_extract_shader = RID(); _update_shader = RID(); _topology_shader = RID(); _downsample_shader = RID()
	_extract_pipeline = RID(); _update_pipeline = RID(); _topology_pipeline = RID(); _downsample_pipeline = RID()
	_extract_set = RID()
	surface_foam_rid = RID(); jacobian_rid = RID(); topology_rid = RID()


func _load_shader(path: String, name: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	if shader_file == null:
		last_error = "No se pudo cargar %s" % path
		return RID()
	var shader := _rd.shader_create_from_spirv(shader_file.get_spirv(), name)
	if not shader.is_valid():
		last_error = "No se pudo compilar %s" % path
		push_error(last_error)
	return shader


func _create_texture(format: int, name: String, resolution: int, with_mipmaps := false) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = resolution; texture_format.height = resolution; texture_format.depth = 1; texture_format.array_layers = 1
	texture_format.mipmaps = _topology_mip_count() if with_mipmaps else 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var rid := _rd.texture_create(texture_format, RDTextureView.new())
	_rd.set_resource_name(rid, name)
	return rid


func _create_sampler() -> RID:
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	return _rd.sampler_create(state)


func _create_extract_set(displacement_short: RID) -> RID:
	var source := RDUniform.new(); source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; source.binding = 0; source.add_id(_sampler); source.add_id(displacement_short)
	var destination := RDUniform.new(); destination.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; destination.binding = 1; destination.add_id(_jacobian)
	var set_rid := _rd.uniform_set_create([source, destination], _extract_shader, 0); _sets.append(set_rid)
	return set_rid


func _create_foam_set(previous: RID, next: RID) -> RID:
	var j := RDUniform.new(); j.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; j.binding = 0; j.add_id(_sampler); j.add_id(_jacobian)
	var p := RDUniform.new(); p.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; p.binding = 1; p.add_id(_sampler); p.add_id(previous)
	var n := RDUniform.new(); n.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; n.binding = 2; n.add_id(next)
	var params := RDUniform.new(); params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding = 3; params.add_id(_foam_params_buffer)
	var set_rid := _rd.uniform_set_create([j, p, n, params], _update_shader, 0); _sets.append(set_rid)
	return set_rid


func _create_topology_set(topology: RID) -> RID:
	var j := RDUniform.new(); j.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; j.binding = 0; j.add_id(_sampler); j.add_id(_jacobian)
	var t := RDUniform.new(); t.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; t.binding = 1; t.add_id(topology)
	var params := RDUniform.new(); params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding = 2; params.add_id(_topology_params_buffer)
	var set_rid := _rd.uniform_set_create([j, t, params], _topology_shader, 0); _sets.append(set_rid)
	return set_rid


func _create_topology_mip_views(topology: RID) -> Array[RID]:
	var views: Array[RID] = []
	for mip in _topology_mip_count():
		views.append(_rd.texture_create_shared_from_slice(RDTextureView.new(), topology, 0, mip, 1))
	return views


func _create_topology_downsample_set(source_mip: RID, destination_mip: RID) -> RID:
	var source := RDUniform.new(); source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; source.binding = 0; source.add_id(_sampler); source.add_id(source_mip)
	var destination := RDUniform.new(); destination.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; destination.binding = 1; destination.add_id(destination_mip)
	var set_rid := _rd.uniform_set_create([source, destination], _downsample_shader, 0); _sets.append(set_rid)
	return set_rid


func _write_topology_params() -> void:
	_topology_params_bytes.encode_float(0, _whitecap)
	_topology_params_bytes.encode_float(4, _crest_whitecap)
	_topology_params_bytes.encode_float(8, _source_domain_m)
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
	_foam_params_bytes.encode_float(32, _field_domain)
	_foam_params_bytes.encode_float(36, _source_domain_m)
	_foam_params_bytes.encode_float(40, 2.25)
	_foam_params_bytes.encode_float(44, 0.0)


func _topology_mip_count() -> int:
	return floori(log(float(_topology_resolution)) / log(2.0)) + 1


func _validated_resolution(value: int) -> int:
	return 256 if value <= 256 else 512 if value <= 512 else 1024

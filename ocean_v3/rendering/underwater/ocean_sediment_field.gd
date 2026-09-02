class_name OceanSedimentField
extends RefCounted
## Persistent world-space GPU sediment concentration field.
## The field owns simulation only; presentation is handled by OceanSedimentSystem.

const COMPUTE_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_field_compute.glsl"
const MAX_INJECTIONS := 16
const FIELD_RESOLUTION := 256

var ready := false
var last_error := ""
var resolution := FIELD_RESOLUTION
var field_rids: Array[RID] = [RID(), RID()]
var source_rid := RID()
var injection_buffer_rid := RID()
var completed_read_index := 0
var completed_dispatch_serial := 0

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _uniform_sets: Array[RID] = []
var _samplers: Array[RID] = []
var _source_width := 1
var _source_height := 1


func initialize(
		field_resolution: int,
		_field_origin_xz: Vector2,
		_field_extent_m: Vector2,
		bathymetry_width: int,
		bathymetry_height: int,
		bathymetry_source_bytes: PackedByteArray,
		resource_prefix := "OceanV3.Sediment") -> void:
	free_resources()
	last_error = ""
	completed_read_index = 0
	completed_dispatch_serial = 0
	resolution = clampi(field_resolution, 64, 512)
	resolution = 64 if resolution < 96 else (128 if resolution < 192 else 256)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible para SedimentField."
		return
	var source_code := FileAccess.get_file_as_string(COMPUTE_SHADER_PATH)
	if source_code.is_empty():
		last_error = "No se pudo cargar %s" % COMPUTE_SHADER_PATH
		return
	# Compile directly so a stale/malformed .import resource cannot be used.
	# #[compute] is an editor importer directive, not GLSL source.
	if source_code.begins_with("#[compute]"):
		var first_newline := source_code.find("\n")
		if first_newline >= 0:
			source_code = source_code.substr(first_newline + 1)
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source_code
	var spirv := _rd.shader_compile_spirv_from_source(shader_source)
	if spirv.bytecode_compute.is_empty():
		last_error = "No se pudo compilar %s: %s" % [
			COMPUTE_SHADER_PATH,
			spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)]
		push_error(last_error)
		return
	_shader = _rd.shader_create_from_spirv(spirv, resource_prefix + ".Shader")
	if not _shader.is_valid():
		last_error = "No se pudo compilar %s" % COMPUTE_SHADER_PATH
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "No se pudo crear el pipeline de SedimentField."
		return
	_rd.set_resource_name(_pipeline, resource_prefix + ".Pipeline")
	for index in 2:
		var zero_field := PackedByteArray()
		zero_field.resize(resolution * resolution * 2)
		field_rids[index] = _create_texture(
			RenderingDevice.DATA_FORMAT_R16_SFLOAT,
			resolution,
			resolution,
			zero_field,
			resource_prefix + ".Field%d" % index)
	if bathymetry_width >= 2 and bathymetry_height >= 2 and not bathymetry_source_bytes.is_empty():
		_source_width = bathymetry_width
		_source_height = bathymetry_height
		source_rid = _create_texture(
			RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			_source_width,
			_source_height,
			bathymetry_source_bytes,
			resource_prefix + ".BathymetrySource")
	else:
		_source_width = 1
		_source_height = 1
		var neutral := PackedFloat32Array([0.0, 0.0]).to_byte_array()
		source_rid = _create_texture(
			RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			1,
			1,
			neutral,
			resource_prefix + ".NeutralBathymetrySource")
	var zero_injections := PackedByteArray()
	zero_injections.resize(MAX_INJECTIONS * 16)
	injection_buffer_rid = _rd.storage_buffer_create(zero_injections.size(), zero_injections)
	_rd.set_resource_name(injection_buffer_rid, resource_prefix + ".InjectionBuffer")
	_uniform_sets = [
		_create_uniform_set(0, 1, resource_prefix + ".Set01"),
		_create_uniform_set(1, 0, resource_prefix + ".Set10"),
	]
	ready = _pipeline.is_valid() and source_rid.is_valid() and injection_buffer_rid.is_valid()
	for uniform_set in _uniform_sets:
		ready = ready and uniform_set.is_valid()
	if not ready:
		last_error = "No se pudieron crear los uniform sets de SedimentField."


func advance(
		read_index: int,
		write_index: int,
		field_origin_xz: Vector2,
		field_extent_m: Vector2,
		delta_s: float,
		time_s: float,
		current_direction_xz: Vector2,
		current_speed_mps: float,
		orbital_strength_mps: float,
		wave_direction_xz: Vector2,
		wave_k_rad_m: float,
		wave_omega_rad_s: float,
		diffusion: float,
	settling_rate: float,
	shallow_start_m: float,
	shallow_end_m: float,
	wave_resuspension_strength: float,
	source_enabled: bool,
	injections: PackedByteArray,
	injection_count: int) -> bool:
	if not ready or _rd == null or not _pipeline.is_valid():
		return false
	read_index = clampi(read_index, 0, 1)
	write_index = clampi(write_index, 0, 1)
	if read_index == write_index:
		return false
	if injections.size() == MAX_INJECTIONS * 16:
		_rd.buffer_update(injection_buffer_rid, 0, injections.size(), injections)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_sets[read_index], 0)
	var safe_extent := Vector2(maxf(field_extent_m.x, 0.001), maxf(field_extent_m.y, 0.001))
	var current_dir := current_direction_xz.normalized()
	var wave_dir := wave_direction_xz.normalized()
	var push := PackedFloat32Array([
		field_origin_xz.x, field_origin_xz.y, safe_extent.x, safe_extent.y,
		maxf(delta_s, 0.0), clampf(diffusion, 0.0, 1.0), maxf(settling_rate, 0.0), maxf(current_speed_mps, 0.0),
		current_dir.x, current_dir.y, maxf(orbital_strength_mps, 0.0), time_s,
		wave_dir.x, wave_dir.y, maxf(wave_k_rad_m, 0.0), maxf(wave_omega_rad_s, 0.0),
		maxf(shallow_start_m, 0.0), maxf(shallow_end_m, shallow_start_m + 0.001), maxf(wave_resuspension_strength, 0.0), 1.0 if source_enabled else 0.0,
		float(clampi(injection_count, 0, MAX_INJECTIONS)), float(_source_width), float(_source_height), 0.0,
	])
	_rd.compute_list_set_push_constant(list, push.to_byte_array(), push.size() * 4)
	_rd.compute_list_dispatch(list, ceili(float(resolution) / 8.0), ceili(float(resolution) / 8.0), 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	# The render-thread command sequence is now ordered as READ -> WRITE ->
	# barrier -> end. The main thread publishes this completed target on the next
	# frame; it never samples or synchronizes the GPU here.
	completed_read_index = write_index
	completed_dispatch_serial += 1
	return true


func get_texture_rid(index: int) -> RID:
	return field_rids[clampi(index, 0, 1)]


func has_valid_rids() -> bool:
	return ready and field_rids[0].is_valid() and field_rids[1].is_valid() \
		and source_rid.is_valid() and injection_buffer_rid.is_valid()


func diagnostic_state() -> Dictionary:
	return {
		"ready": ready,
		"resolution": resolution,
		"field_format": "R16_SFLOAT",
		"field_bytes": resolution * resolution * 2 * 2,
		"source_rid": source_rid.get_id() if source_rid.is_valid() else -1,
		"injection_buffer_rid": injection_buffer_rid.get_id() if injection_buffer_rid.is_valid() else -1,
		"read_rid_valid": field_rids[completed_read_index].is_valid(),
		"write_rid_valid": field_rids[1 - completed_read_index].is_valid(),
		"completed_read_index": completed_read_index,
		"completed_dispatch_serial": completed_dispatch_serial,
		"last_error": last_error,
	}


func free_resources() -> void:
	ready = false
	if _rd == null:
		field_rids = [RID(), RID()]
		source_rid = RID()
		injection_buffer_rid = RID()
		_uniform_sets.clear()
		_samplers.clear()
		_pipeline = RID()
		_shader = RID()
		completed_read_index = 0
		completed_dispatch_serial = 0
		return
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for sampler in _samplers:
		if sampler.is_valid():
			_rd.free_rid(sampler)
	_samplers.clear()
	for rid in field_rids:
		if rid.is_valid():
			_rd.free_rid(rid)
	for rid in [source_rid, injection_buffer_rid, _pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	field_rids = [RID(), RID()]
	source_rid = RID()
	injection_buffer_rid = RID()
	completed_read_index = 0
	completed_dispatch_serial = 0
	_pipeline = RID()
	_shader = RID()
	_rd = null


func _create_texture(format: int, width: int, height: int, data: PackedByteArray, resource_name: String) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format as RenderingDevice.DataFormat
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var initial_data: Array[PackedByteArray] = []
	if not data.is_empty():
		initial_data.append(data)
	var texture := _rd.texture_create(texture_format, RDTextureView.new(), initial_data)
	_rd.set_resource_name(texture, resource_name)
	return texture


func _create_uniform_set(read_index: int, write_index: int, resource_prefix: String) -> RID:
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler := _rd.sampler_create(sampler_state)
	_samplers.append(sampler)
	var previous := RDUniform.new()
	previous.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	previous.binding = 0
	previous.add_id(sampler)
	previous.add_id(field_rids[read_index])
	var bathymetry := RDUniform.new()
	bathymetry.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	bathymetry.binding = 1
	bathymetry.add_id(sampler)
	bathymetry.add_id(source_rid)
	var next := RDUniform.new()
	next.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	next.binding = 2
	next.add_id(field_rids[write_index])
	var injections := RDUniform.new()
	injections.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	injections.binding = 3
	injections.add_id(injection_buffer_rid)
	var result := _rd.uniform_set_create([previous, bathymetry, next, injections], _shader, 0)
	_rd.set_resource_name(result, resource_prefix)
	# The sampler is shared only by this uniform set; retain it through the set.
	return result

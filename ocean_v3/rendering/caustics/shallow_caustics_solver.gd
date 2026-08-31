class_name ShallowCausticsSolver
extends RefCounted
## Campo GPU P0 de causticas someras. Consume exclusivamente las normales ya
## ensambladas por el FFT; no duplica espectro, IFFT ni hace readbacks.

const UPDATE_SHADER := "res://ocean_v3/rendering/caustics/shaders/generate_shallow_caustics.glsl"

var ready := false
var last_error := ""
var caustics_rid := RID()
var field_origin_xz := Vector2.ZERO
var field_extent_m := 96.0

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _set := RID()
var _field := RID()
var _resolution := 256
var _accumulator := 0.0
var _has_origin := false
var _domains_m := PackedFloat32Array()


func initialize(normal_rids: Array[RID], domains_m: PackedFloat32Array, resolution: int, resource_prefix := "Ocean.Caustics") -> void:
	free_resources()
	_resolution = _validated_resolution(resolution)
	if normal_rids.size() != 4 or domains_m.size() != 4:
		last_error = "Caustics requires the four Ocean V3 render normal maps."
		return
	_domains_m = domains_m.duplicate()
	for normal_rid in normal_rids:
		if not normal_rid.is_valid():
			last_error = "Caustics received an invalid FFT normal map."
			return
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "Global RenderingDevice unavailable for shallow caustics."
		return
	var shader_file: RDShaderFile = load(UPDATE_SHADER)
	if shader_file == null:
		last_error = "Could not load %s." % UPDATE_SHADER
		return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), resource_prefix + ".Shader")
	if not _shader.is_valid():
		last_error = "Could not create shallow caustics shader."
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	_sampler = _create_sampler()
	_field = _create_field(resource_prefix + ".Field")
	_set = _create_set(normal_rids)
	ready = _pipeline.is_valid() and _sampler.is_valid() and _field.is_valid() and _set.is_valid()
	if not ready:
		last_error = "Could not create shallow caustics GPU resources."
		free_resources()
		return
	caustics_rid = _field


func advance(delta_s: float, camera_world_xz: Vector2, sun_direction_world: Vector3,
		enabled: bool, update_hz: float, extent_m: float, debug_mode: int) -> bool:
	if not ready or not enabled:
		return false
	field_extent_m = maxf(extent_m, 8.0)
	var texel_m := field_extent_m / float(_resolution)
	var desired_origin := camera_world_xz - Vector2.ONE * (field_extent_m * 0.5)
	var snapped_origin := Vector2(
		floor(desired_origin.x / texel_m) * texel_m,
		floor(desired_origin.y / texel_m) * texel_m
	)
	var origin_changed := not _has_origin or snapped_origin != field_origin_xz
	field_origin_xz = snapped_origin
	_has_origin = true
	_accumulator += maxf(delta_s, 0.0)
	var period := 1.0 / clampf(update_hz, 1.0, 60.0)
	if not origin_changed and _accumulator < period:
		return false
	_accumulator = fmod(_accumulator, period)
	var light := sun_direction_world.normalized()
	if light.length_squared() <= 1.0e-8 or light.y <= 0.001:
		# Sun below the local horizon: write a deterministic black field instead
		# of retaining a stale bright pattern.
		light = Vector3(0.0, -1.0, 0.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	var push := PackedFloat32Array([
		field_origin_xz.x, field_origin_xz.y, field_extent_m, 0.0,
		light.x, light.y, light.z, 1.0,
		0.0, 0.0, 1.0, float(clampi(debug_mode, 0, 5)),
		0.18, 0.18, 1.0, 0.65,
		_domains_m[0], _domains_m[1], _domains_m[2], _domains_m[3],
	])
	_rd.compute_list_set_push_constant(list, push.to_byte_array(), 80)
	var groups := ceili(float(_resolution) / 8.0)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()
	return true


func free_resources() -> void:
	ready = false
	if _rd != null:
		if _set.is_valid(): _rd.free_rid(_set)
		if _field.is_valid(): _rd.free_rid(_field)
		if _sampler.is_valid(): _rd.free_rid(_sampler)
		if _pipeline.is_valid(): _rd.free_rid(_pipeline)
		if _shader.is_valid(): _rd.free_rid(_shader)
	_set = RID()
	_field = RID()
	_sampler = RID()
	_pipeline = RID()
	_shader = RID()
	caustics_rid = RID()
	_accumulator = 0.0
	_has_origin = false
	_domains_m = PackedFloat32Array()


func _create_field(resource_name: String) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = _resolution
	format.height = _resolution
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var rid := _rd.texture_create(format, RDTextureView.new())
	_rd.set_resource_name(rid, resource_name)
	return rid


func _create_sampler() -> RID:
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return _rd.sampler_create(state)


func _create_set(normal_rids: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in 4:
		var source := RDUniform.new()
		source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source.binding = binding
		source.add_id(_sampler)
		source.add_id(normal_rids[binding])
		uniforms.append(source)
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output.binding = 4
	output.add_id(_field)
	uniforms.append(output)
	return _rd.uniform_set_create(uniforms, _shader, 0)


func _validated_resolution(value: int) -> int:
	return 128 if value <= 128 else 256 if value <= 256 else 512

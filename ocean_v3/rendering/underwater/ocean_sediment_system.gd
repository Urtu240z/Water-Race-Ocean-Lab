@tool
class_name OceanSedimentSystem
extends Node3D
## V1 sediment presentation and scheduling. The simulation is the single
## world-anchored OceanSedimentField; particles only populate its local view.

const FIELD_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_sediment_field.gd")
const PARTICLE_PROCESS_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles_process.gdshader"
const PARTICLE_RENDER_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles.gdshader"
const MAX_INJECTIONS := 16
const TEST_INJECTION_RADIUS_M := 9.0
const TEST_INJECTION_STRENGTH := 0.90
const TEST_SEARCH_RADIUS_M := 20.0
const TEST_PREFERRED_DISTANCE_M := 8.0
const TEST_MARKER_LIFETIME_S := 6.0

enum DebugMode { OFF, FIELD, SOURCE, CLOUDS, WISPS }

@export_group("Underwater / Sediment")
@export var sediment_enabled := true
@export_range(64, 512, 64) var sediment_field_resolution := 256
@export_range(1.0, 60.0, 1.0, "suffix: Hz") var sediment_update_hz := 20.0
@export_range(1.0, 20.0, 1.0, "suffix: Hz") var sediment_air_update_hz := 5.0
@export_range(0.0, 4.0, 0.01) var sediment_strength := 1.0
@export_range(0.0, 20.0, 0.1, "suffix: m") var sediment_shallow_start_m := 1.0
@export_range(0.1, 30.0, 0.1, "suffix: m") var sediment_shallow_end_m := 5.0
@export_range(0.0, 4.0, 0.01) var sediment_wave_resuspension_strength := 0.65
@export var sediment_current_direction := Vector2(1.0, 0.0)
@export_range(0.0, 4.0, 0.01, "suffix: m/s") var sediment_current_speed := 0.20
@export_range(0.0, 2.0, 0.01, "suffix: m/s") var sediment_orbital_strength := 0.08
@export_range(0.0, 1.0, 0.01) var sediment_diffusion := 0.10
@export_range(0.0, 1.0, 0.005, "suffix: 1/s") var sediment_settling_rate := 0.08
@export_range(0.0, 4.0, 0.01) var sediment_cloud_strength := 1.0
@export_range(0.0, 4.0, 0.01) var sediment_wisp_strength := 1.0
@export_range(8.0, 80.0, 1.0, "suffix: m") var sediment_render_distance_m := 36.0
@export_range(0.0, 2.0, 0.01) var sediment_above_water_optics_strength := 1.0
@export_enum("OFF", "FIELD", "SOURCE", "CLOUDS", "WISPS") var sediment_debug_mode: int = DebugMode.OFF
@export var sediment_test_marker_enabled := true
@export_tool_button("Inject Test Sediment", "Burst") var inject_test_sediment_button = inject_test_sediment

var _field: OceanSedimentField
var _field_texture := Texture2DRD.new()
var _process_shader: Shader
var _render_shader: Shader
var _cloud_particles: GPUParticles3D
var _wisp_particles: GPUParticles3D
var _cloud_material: ShaderMaterial
var _wisp_material: ShaderMaterial
var _cloud_process_material: ShaderMaterial
var _wisp_process_material: ShaderMaterial
var _surface: OceanClipmapSurface
var _bathymetry: BathymetryData
var _ocean: Node
var _configured := false
var _configuration_requested := false
var _particles_created := false
var _field_published := false
var _camera_underwater := false
var _update_accumulator := 0.0
var _completed_read_index := 0
var _published_dispatch_serial := 0
var _dispatch_queued := false
var _last_render_time := 0.0
var _pending_injections: Array[Vector4] = []
var _last_dispatch_usec := 0
var _dispatch_count := 0
var _last_dispatch_period_s := 0.0
var _init_reported := false
var _init_failure_reported := false
var _render_device_wait_reported := false
var _runtime_injection_requested := false
var _runtime_debug_mode_applied := false
var _initialization_retry_timer := 0.0
var _bathymetry_wait_elapsed := 0.0
var _bathymetry_wait_reported := false
var _test_injection_sequence := 0
var _last_queued_injection_count := 0
var _test_marker: MeshInstance3D
var _test_marker_remaining_s := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	top_level = true
	_runtime_injection_requested = _has_runtime_injection_trigger()
	_apply_runtime_debug_mode()
	set_process_unhandled_input(true)


func configure(ocean: Node, bathymetry: BathymetryData, surface: OceanClipmapSurface) -> void:
	if Engine.is_editor_hint() or _configuration_requested:
		return
	_ocean = ocean
	_surface = surface
	_bathymetry = bathymetry
	_configuration_requested = true
	_try_begin_initialization()


func _try_begin_initialization() -> void:
	if _configured or not _configuration_requested:
		return
	_refresh_bathymetry_from_ocean()
	if _bathymetry == null or not _bathymetry.is_valid():
		return
	_field = FIELD_SCRIPT.new()
	_init_failure_reported = false
	var source_bytes := _build_bathymetry_source_bytes(_bathymetry)
	var width := _bathymetry.width
	var height := _bathymetry.height
	var origin := _bathymetry.world_origin_xz
	var extent := _bathymetry.world_max_xz() - origin
	RenderingServer.call_on_render_thread(_field.initialize.bind(
		sediment_field_resolution,
		origin,
		extent,
		width,
		height,
		source_bytes,
		"OceanV3.Sediment"))
	_configured = true
	_set_emitter_from_camera()


func _refresh_bathymetry_from_ocean() -> void:
	if _bathymetry != null and _bathymetry.is_valid():
		return
	if _ocean == null or not is_instance_valid(_ocean):
		return
	var runtime_fft := _ocean.get_node_or_null(^"OpenOceanFFT") as OpenOceanFFTModule
	if runtime_fft == null:
		return
	var candidate := runtime_fft.coastal_bathymetry_data as BathymetryData
	if candidate != null and candidate.is_valid():
		_bathymetry = candidate


func _print_bathymetry_wait_diagnostic() -> void:
	var valid := _bathymetry != null and _bathymetry.is_valid()
	print("SEDIMENT INIT WAIT")
	print("bathymetry_present=%s bathymetry_valid=%s width=%d height=%d" % [
		_bathymetry != null, valid, _bathymetry.width if _bathymetry != null else 0,
		_bathymetry.height if _bathymetry != null else 0])
	print("world_origin_xz=%s extent_m=%s" % [_field_origin(), _field_extent()])


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _configuration_requested:
		return
	_update_test_marker(delta)
	if not _configured:
		_bathymetry_wait_elapsed += maxf(delta, 0.0)
		_refresh_bathymetry_from_ocean()
		if _bathymetry_wait_elapsed >= 1.0 and not _bathymetry_wait_reported:
			_bathymetry_wait_reported = true
			_print_bathymetry_wait_diagnostic()
		_initialization_retry_timer -= maxf(delta, 0.0)
		if _initialization_retry_timer > 0.0:
			return
		_try_begin_initialization()
		return
	if _field == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	_set_emitter_from_camera()
	if _field.ready and _field.has_valid_rids():
		_publish_completed_field()
		if not _particles_created and _field_published:
			_ensure_particles()
			_print_init_diagnostic()
		_update_particles()
	elif not _field.ready and not _field.last_error.is_empty() and not _init_failure_reported:
		if _field.last_error.begins_with("RenderingDevice global"):
			# The callback is render-thread queued and can run before the renderer
			# exposes its device in headless/startup transitions. Retry the same
			# configuration later without creating materials or blocking.
			_configured = false
			_field = null
			_initialization_retry_timer = 0.25
			if not _render_device_wait_reported:
				_render_device_wait_reported = true
				print("SEDIMENT INIT WAIT: RenderingDevice global no disponible; se reintentará sin crear materiales.")
			return
		else:
			_init_failure_reported = true
			push_error("SEDIMENT INIT: %s" % _field.last_error)
	if _runtime_injection_requested:
		_request_test_injection()
	var hz := sediment_update_hz if _camera_underwater else sediment_air_update_hz
	if not sediment_enabled or not _field.ready or not _field.has_valid_rids() or _dispatch_queued:
		return
	_update_accumulator += maxf(delta, 0.0)
	var period := 1.0 / maxf(hz, 1.0)
	if _update_accumulator < period:
		return
	var step_delta := minf(_update_accumulator, 0.25)
	_update_accumulator = fmod(_update_accumulator, period)
	_dispatch_field(step_delta)


func set_camera_underwater(camera_underwater: bool) -> void:
	_camera_underwater = camera_underwater
	_apply_particle_visibility()


func inject_sediment(world_position: Vector3, radius_m: float, strength: float) -> bool:
	if not _injection_validation(world_position).get("accepted", false):
		return false
	var injection := Vector4(world_position.x, world_position.z, maxf(radius_m, 0.05), clampf(strength, 0.0, 1.0))
	if _pending_injections.size() >= MAX_INJECTIONS:
		_pending_injections.pop_front()
	_pending_injections.append(injection)
	return true


func inject_test_sediment() -> void:
	_runtime_injection_requested = true
	_request_test_injection()


func _request_test_injection() -> void:
	_runtime_injection_requested = false
	if not _field_published or _bathymetry == null or not _bathymetry.is_valid():
		print("SEDIMENT TEST FAILED: field is not ready or published.")
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		print("SEDIMENT TEST FAILED: no active camera.")
		return
	var target := _find_test_position(camera)
	if target.is_empty():
		print("SEDIMENT TEST FAILED: no valid water/seabed cell within %.1f metres." % TEST_SEARCH_RADIUS_M)
		return
	var sample_position: Vector3 = target["world_position"]
	var validation := _injection_validation(sample_position)
	var accepted := inject_sediment(sample_position, TEST_INJECTION_RADIUS_M, TEST_INJECTION_STRENGTH)
	_test_injection_sequence += 1
	if accepted:
		_show_test_marker(sample_position)
	print("SEDIMENT TEST INJECTION #%d" % _test_injection_sequence)
	print("camera_world=%s" % camera.global_position)
	print("target_world=%s distance_from_camera=%.3f" % [sample_position, camera.global_position.distance_to(sample_position)])
	print("raw_field_uv=%s inside_field=%s" % [validation.get("raw_uv", Vector2.ZERO), validation.get("inside_field", false)])
	print("bathymetry_in_bounds=%s water=%s depth=%.3f" % [validation.get("bathymetry_in_bounds", false), validation.get("water", false), validation.get("depth_m", 0.0)])
	print("radius=%.3f strength=%.3f queued=%s pending_queue=%d" % [TEST_INJECTION_RADIUS_M, TEST_INJECTION_STRENGTH, accepted, _pending_injections.size()])
	print("FIELD DEBUG PROXY: expected_center_after_dispatch=%.3f (GPU impulse, no readback); marker_lifetime_s=%.1f" % [TEST_INJECTION_STRENGTH * exp(-sediment_settling_rate / maxf(sediment_update_hz, 1.0)), TEST_MARKER_LIFETIME_S])


func _find_test_position(camera: Camera3D) -> Dictionary:
	var camera_xz := Vector2(camera.global_position.x, camera.global_position.z)
	var forward := -camera.global_transform.basis.z
	var forward_xz := Vector2(forward.x, forward.z).normalized()
	if forward_xz.length_squared() <= 0.0001:
		forward_xz = Vector2(0.0, -1.0)
	var preferred_xz := camera_xz + forward_xz * TEST_PREFERRED_DISTANCE_M
	var best_index := -1
	var best_score := INF
	for index in _bathymetry.cell_count():
		if _bathymetry.land_water_mask[index] == 0 or _bathymetry.depth_m[index] <= 0.001:
			continue
		var x := index % _bathymetry.width
		var z := int(index / _bathymetry.width)
		var world_xz := _bathymetry.world_origin_xz + Vector2(float(x), float(z)) * _bathymetry.cell_size_m
		var distance_sq := world_xz.distance_squared_to(camera_xz)
		if distance_sq > TEST_SEARCH_RADIUS_M * TEST_SEARCH_RADIUS_M:
			continue
		var forward_alignment := (world_xz - camera_xz).normalized().dot(forward_xz)
		var score := world_xz.distance_squared_to(preferred_xz) + (1.0 - forward_alignment) * 16.0
		if score < best_score:
			best_score = score
			best_index = index
	if best_index >= 0:
		var best_x := best_index % _bathymetry.width
		var best_z := int(best_index / _bathymetry.width)
		var world_xz := _bathymetry.world_origin_xz + Vector2(float(best_x), float(best_z)) * _bathymetry.cell_size_m
		return {"world_position": Vector3(world_xz.x, _bathymetry.sea_level_y - _bathymetry.depth_m[best_index] + 0.45, world_xz.y)}
	return {}


func _injection_validation(world_position: Vector3) -> Dictionary:
	var raw_uv := (Vector2(world_position.x, world_position.z) - _field_origin()) / Vector2(
		maxf(_field_extent().x, 0.001), maxf(_field_extent().y, 0.001))
	var inside_field := raw_uv.x >= 0.0 and raw_uv.x <= 1.0 and raw_uv.y >= 0.0 and raw_uv.y <= 1.0
	var bathymetry_ready := _bathymetry != null and _bathymetry.is_valid()
	var sample = _bathymetry.sample_bathymetry(Vector2(world_position.x, world_position.z)) if bathymetry_ready else null
	var field_ready := _configured and _field != null and _field.ready and _field.has_valid_rids()
	var in_bounds := sample != null and sample.in_bounds
	var water := sample != null and sample.is_water
	return {
		"accepted": field_ready and inside_field and in_bounds and water,
		"field_ready": field_ready,
		"raw_uv": raw_uv,
		"inside_field": inside_field,
		"bathymetry_in_bounds": in_bounds,
		"water": water,
		"depth_m": sample.depth_m if sample != null else 0.0,
	}


func _show_test_marker(world_position: Vector3) -> void:
	if not sediment_test_marker_enabled:
		return
	if _test_marker != null and is_instance_valid(_test_marker):
		_test_marker.queue_free()
	_test_marker = MeshInstance3D.new()
	_test_marker.name = "SedimentTestInjectionMarker"
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.70
	_test_marker.mesh = sphere
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.30, 0.04, 0.90)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.08, 0.01)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_test_marker.material_override = material
	_test_marker.global_position = world_position
	_test_marker.top_level = true
	add_child(_test_marker)
	_test_marker_remaining_s = TEST_MARKER_LIFETIME_S


func _update_test_marker(delta: float) -> void:
	if _test_marker == null or not is_instance_valid(_test_marker):
		return
	_test_marker_remaining_s -= maxf(delta, 0.0)
	if _test_marker_remaining_s <= 0.0:
		_test_marker.queue_free()
		_test_marker = null


func _has_runtime_injection_trigger() -> bool:
	var arguments: PackedStringArray = OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	for argument in arguments:
		if argument.trim_prefix("--").to_upper() == "INJECT_SEDIMENT_TEST":
			return true
	return false


func _apply_runtime_debug_mode() -> void:
	if _runtime_debug_mode_applied:
		return
	_runtime_debug_mode_applied = true
	var arguments: PackedStringArray = OS.get_cmdline_args()
	arguments.append_array(OS.get_cmdline_user_args())
	for argument in arguments:
		match argument.trim_prefix("--").to_upper():
			"SEDIMENT_DEBUG_FIELD": sediment_debug_mode = DebugMode.FIELD
			"SEDIMENT_DEBUG_SOURCE": sediment_debug_mode = DebugMode.SOURCE
			"SEDIMENT_DEBUG_CLOUDS": sediment_debug_mode = DebugMode.CLOUDS
			"SEDIMENT_DEBUG_WISPS": sediment_debug_mode = DebugMode.WISPS
			"SEDIMENT_DEBUG_OFF": sediment_debug_mode = DebugMode.OFF


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.pressed and not key_event.echo and key_event.keycode == KEY_F8:
		_runtime_injection_requested = true
		_request_test_injection()


func get_debug_state() -> Dictionary:
	return {
		"enabled": sediment_enabled,
		"camera_underwater": _camera_underwater,
		"configured": _configured,
		"field_published": _field_published,
		"field": _field.diagnostic_state() if _field != null else {},
		"field_origin_xz": _field_origin(),
		"field_extent_m": _field_extent(),
		"bathymetry_valid": _bathymetry != null and _bathymetry.is_valid(),
		"bathymetry_width": _bathymetry.width if _bathymetry != null else 0,
		"bathymetry_height": _bathymetry.height if _bathymetry != null else 0,
		"bathymetry_sea_level_y": _bathymetry.sea_level_y if _bathymetry != null else 0.0,
		"particles_created": _particles_created,
		"texture_rd_published": _field_published,
		"completed_read_index": _completed_read_index,
		"dispatch_queued": _dispatch_queued,
		"update_hz_underwater": sediment_update_hz,
		"update_hz_air": sediment_air_update_hz,
		"dispatch_count": _dispatch_count,
		"last_dispatch_period_s": _last_dispatch_period_s,
		"pending_injections": _pending_injections.size(),
		"last_queued_injection_count": _last_queued_injection_count,
		"cloud_amount": _cloud_particles.amount if _cloud_particles != null else 0,
		"wisp_amount": _wisp_particles.amount if _wisp_particles != null else 0,
		"cloud_emitting": _cloud_particles.emitting if _cloud_particles != null else false,
		"wisp_emitting": _wisp_particles.emitting if _wisp_particles != null else false,
	}


func _dispatch_field(step_delta: float) -> void:
	var read_index := _completed_read_index
	var write_index := 1 - read_index
	var injection_count := mini(_pending_injections.size(), MAX_INJECTIONS)
	var injection_floats := PackedFloat32Array()
	injection_floats.resize(MAX_INJECTIONS * 4)
	for index in mini(_pending_injections.size(), MAX_INJECTIONS):
		var injection := _pending_injections[index]
		injection_floats[index * 4] = injection.x
		injection_floats[index * 4 + 1] = injection.y
		injection_floats[index * 4 + 2] = injection.z
		injection_floats[index * 4 + 3] = injection.w
	var injection_bytes := injection_floats.to_byte_array()
	# Bind captures the packed bytes/count for the render-thread command before
	# the main-thread queue is released. A subsequent input can therefore queue a
	# new impulse without racing the dispatch currently in flight.
	_dispatch_queued = true
	_last_render_time += step_delta
	_last_dispatch_period_s = step_delta
	_dispatch_count += 1
	_last_dispatch_usec = Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(_field.advance.bind(
		read_index,
		write_index,
		_field_origin(),
		_field_extent(),
		step_delta,
		_last_render_time,
		sediment_current_direction,
		sediment_current_speed,
		sediment_orbital_strength,
		Vector2(0.87, 0.50),
		0.22,
		0.72,
		sediment_diffusion,
		sediment_settling_rate,
		sediment_shallow_start_m,
		sediment_shallow_end_m,
		sediment_wave_resuspension_strength * sediment_strength,
		_bathymetry != null and _bathymetry.is_valid(),
		injection_bytes,
		injection_count))
	_pending_injections.clear()
	_last_queued_injection_count = injection_count


func _publish_completed_field() -> void:
	if _field == null:
		return
	var diagnostic := _field.diagnostic_state()
	var completed_serial := int(diagnostic.get("completed_dispatch_serial", 0))
	if completed_serial != _published_dispatch_serial:
		_completed_read_index = int(diagnostic.get("completed_read_index", _completed_read_index))
		_published_dispatch_serial = completed_serial
		_dispatch_queued = false
	if _surface == null or not is_instance_valid(_surface):
		return
	var material := _surface.get_surface_material()
	if material == null or material.shader == null:
		return
	if not _field.get_texture_rid(_completed_read_index).is_valid():
		return
	_field_texture.texture_rd_rid = _field.get_texture_rid(_completed_read_index)
	_surface.set_sediment_field(
		_field_texture,
		sediment_enabled,
		_field_origin(),
		_field_extent(),
		sediment_above_water_optics_strength,
		sediment_debug_mode)
	_field_published = true


func _ensure_particles() -> void:
	if _particles_created:
		return
	if _cloud_particles != null and is_instance_valid(_cloud_particles):
		return
	if _process_shader == null or _render_shader == null:
		_process_shader = load(PARTICLE_PROCESS_SHADER_PATH) as Shader
		_render_shader = load(PARTICLE_RENDER_SHADER_PATH) as Shader
		if _process_shader == null or _render_shader == null:
			return
	_cloud_particles = _create_particle_layer("SedimentClouds")
	_wisp_particles = _create_particle_layer("SedimentWisps")
	_cloud_particles.amount = 520
	_wisp_particles.amount = 160
	_cloud_particles.draw_pass_1 = _create_quad()
	_wisp_particles.draw_pass_1 = _create_quad()
	add_child(_cloud_particles)
	add_child(_wisp_particles)
	_cloud_particles.owner = null
	_wisp_particles.owner = null
	_cloud_process_material = _create_process_material(1.0, 0.05, 1.5)
	_wisp_process_material = _create_process_material(19.0, 0.5, 2.5)
	_cloud_material = _create_render_material(false)
	_wisp_material = _create_render_material(true)
	_cloud_particles.process_material = _cloud_process_material
	_wisp_particles.process_material = _wisp_process_material
	(_cloud_particles.draw_pass_1 as QuadMesh).material = _cloud_material
	(_wisp_particles.draw_pass_1 as QuadMesh).material = _wisp_material
	_particles_created = true
	_apply_particle_visibility()


func _print_init_diagnostic() -> void:
	if _init_reported or _field == null or not _field.has_valid_rids():
		return
	var state := _field.diagnostic_state()
	var water_cells := 0
	for value in _bathymetry.land_water_mask:
		if value != 0:
			water_cells += 1
	print("SEDIMENT INIT")
	print("bathymetry_valid=%s width=%d height=%d water_cells=%d" % [
		_bathymetry.is_valid(), _bathymetry.width, _bathymetry.height, water_cells])
	print("world_origin_xz=%s extent_m=%s sea_level_y=%.3f" % [
		_bathymetry.world_origin_xz, _field_extent(), _bathymetry.sea_level_y])
	print("field_resolution=%d field_ready=%s read_rid_valid=%s write_rid_valid=%s" % [
		state.get("resolution", 0), state.get("ready", false), state.get("read_rid_valid", false), state.get("write_rid_valid", false)])
	print("texture_rd_published=%s particle_materials_created=%s" % [_field_published, _particles_created])
	var shallow_probe := _find_shallow_probe()
	if shallow_probe.is_empty():
		print("shallow_source_probe=none")
	else:
		print("shallow_source_probe world_position=%s depth_m=%.3f water_mask=%s" % [
			shallow_probe["world_position"], shallow_probe["depth_m"], shallow_probe["water_mask"]])
	_init_reported = true


func _find_shallow_probe() -> Dictionary:
	if _bathymetry == null or not _bathymetry.is_valid():
		return {}
	for index in _bathymetry.cell_count():
		var depth_m := _bathymetry.depth_m[index]
		if _bathymetry.land_water_mask[index] == 0 or depth_m < sediment_shallow_start_m or depth_m >= sediment_shallow_end_m:
			continue
		var x := index % _bathymetry.width
		var z := int(index / _bathymetry.width)
		var world_xz := _bathymetry.world_origin_xz + Vector2(float(x), float(z)) * _bathymetry.cell_size_m
		return {
			"world_position": Vector3(world_xz.x, _bathymetry.sea_level_y - depth_m, world_xz.y),
			"depth_m": depth_m,
			"water_mask": _bathymetry.land_water_mask[index],
		}
	return {}


func _create_particle_layer(layer_name: String) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.lifetime = 26.0
	particles.preprocess = 20.0
	particles.randomness = 0.25
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-42.0, -42.0, -42.0), Vector3(84.0, 84.0, 84.0))
	particles.emitting = false
	particles.visible = false
	return particles


func _create_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	return quad


func _create_process_material(layer_seed: float, height_min: float, height_max: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _process_shader
	material.set_shader_parameter(&"bathymetry_texture", _build_bathymetry_preview_texture())
	material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	material.set_shader_parameter(&"bathymetry_origin_xz", _field_origin())
	material.set_shader_parameter(&"bathymetry_extent_m", _field_extent())
	material.set_shader_parameter(&"bathymetry_depth_scale_m", 32.0)
	material.set_shader_parameter(&"sea_level_y", _bathymetry.sea_level_y if _bathymetry != null else 0.0)
	material.set_shader_parameter(&"spawn_radius_m", sediment_render_distance_m)
	material.set_shader_parameter(&"layer_seed", layer_seed)
	material.set_shader_parameter(&"height_min_m", height_min)
	material.set_shader_parameter(&"height_max_m", height_max)
	material.set_shader_parameter(&"current_direction_xz", sediment_current_direction.normalized())
	material.set_shader_parameter(&"current_speed_mps", sediment_current_speed)
	material.set_shader_parameter(&"orbital_strength_mps", sediment_orbital_strength)
	material.set_shader_parameter(&"wave_k_rad_m", 0.22)
	material.set_shader_parameter(&"wave_omega_rad_s", 0.72)
	material.set_shader_parameter(&"vertical_wander_m", 0.08 if layer_seed < 10.0 else 0.14)
	return material


func _create_render_material(is_wisps: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _render_shader
	material.set_shader_parameter(&"sediment_field_texture", _field_texture)
	material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	material.set_shader_parameter(&"particle_color", Color(0.34, 0.29, 0.19, 0.065 if not is_wisps else 0.035))
	material.set_shader_parameter(&"strength", sediment_wisp_strength if is_wisps else sediment_cloud_strength)
	material.set_shader_parameter(&"field_threshold", 0.10 if is_wisps else 0.15)
	material.set_shader_parameter(&"field_contrast", 0.80 if is_wisps else 0.68)
	material.set_shader_parameter(&"wisps", is_wisps)
	return material


func _update_particles() -> void:
	if _cloud_process_material == null or _wisp_process_material == null:
		return
	for material in [_cloud_process_material, _wisp_process_material]:
		material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
		material.set_shader_parameter(&"bathymetry_origin_xz", _field_origin())
		material.set_shader_parameter(&"bathymetry_extent_m", _field_extent())
		material.set_shader_parameter(&"bathymetry_depth_scale_m", 32.0)
		material.set_shader_parameter(&"current_direction_xz", sediment_current_direction.normalized())
		material.set_shader_parameter(&"current_speed_mps", sediment_current_speed)
		material.set_shader_parameter(&"orbital_strength_mps", sediment_orbital_strength)
		material.set_shader_parameter(&"spawn_radius_m", sediment_render_distance_m)
	if _cloud_material != null:
		_cloud_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_cloud_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_cloud_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	if _wisp_material != null:
		_wisp_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_wisp_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_wisp_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	_apply_particle_visibility()


func _apply_particle_visibility() -> void:
	var clouds_visible := sediment_enabled and _camera_underwater and _field_published and sediment_cloud_strength > 0.0
	var wisps_visible := sediment_enabled and _camera_underwater and _field_published and sediment_wisp_strength > 0.0
	if _cloud_particles != null:
		_cloud_particles.emitting = clouds_visible
		_cloud_particles.visible = clouds_visible
	if _wisp_particles != null:
		_wisp_particles.emitting = wisps_visible
		_wisp_particles.visible = wisps_visible
	if _cloud_material != null:
		_cloud_material.set_shader_parameter(&"strength", sediment_cloud_strength * (8.0 if sediment_debug_mode == DebugMode.CLOUDS else 1.0))
	if _wisp_material != null:
		_wisp_material.set_shader_parameter(&"strength", sediment_wisp_strength * (8.0 if sediment_debug_mode == DebugMode.WISPS else 1.0))


func _set_emitter_from_camera() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	global_position = Vector3(camera.global_position.x, _bathymetry.sea_level_y if _bathymetry != null else 0.0, camera.global_position.z)
	global_basis = Basis.IDENTITY


func _field_origin() -> Vector2:
	return _bathymetry.world_origin_xz if _bathymetry != null and _bathymetry.is_valid() else Vector2.ZERO


func _field_extent() -> Vector2:
	return _bathymetry.world_max_xz() - _field_origin() if _bathymetry != null and _bathymetry.is_valid() else Vector2.ONE


func _build_bathymetry_source_bytes(data: BathymetryData) -> PackedByteArray:
	if data == null or not data.is_valid():
		return PackedFloat32Array([0.0, 0.0]).to_byte_array()
	var values := PackedFloat32Array()
	values.resize(data.cell_count() * 2)
	for index in data.cell_count():
		values[index * 2] = maxf(data.depth_m[index], 0.0)
		values[index * 2 + 1] = 1.0 if data.land_water_mask[index] != 0 else 0.0
	return values.to_byte_array()


func _build_bathymetry_preview_texture() -> Texture2D:
	# Particle shaders need a Texture2D sampler. This is one immutable upload of the
	# existing bake; the simulation itself samples its RD copy and never reads back.
	if _bathymetry == null or not _bathymetry.is_valid():
		var neutral := Image.create(1, 1, false, Image.FORMAT_RG8)
		neutral.fill(Color(0.0, 0.0, 0.0, 1.0))
		return ImageTexture.create_from_image(neutral)
	var packed := PackedByteArray()
	packed.resize(_bathymetry.cell_count() * 2)
	for index in _bathymetry.cell_count():
		packed[index * 2] = clampi(int(round(clampf(_bathymetry.depth_m[index] / 32.0, 0.0, 1.0) * 255.0)), 0, 255)
		packed[index * 2 + 1] = 255 if _bathymetry.land_water_mask[index] != 0 else 0
	var image := Image.create_from_data(_bathymetry.width, _bathymetry.height, false, Image.FORMAT_RG8, packed)
	return ImageTexture.create_from_image(image)


func _exit_tree() -> void:
	if _field == null:
		return
	_field_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_field.free_resources)

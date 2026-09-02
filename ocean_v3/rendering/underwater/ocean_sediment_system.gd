@tool
class_name OceanSedimentSystem
extends Node3D
## V1 sediment presentation and scheduling. The simulation is the single
## world-anchored OceanSedimentField; particles only populate its local view.

const FIELD_SCRIPT := preload("res://ocean_v3/rendering/underwater/ocean_sediment_field.gd")
const PARTICLE_PROCESS_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles_process.gdshader"
const PARTICLE_RENDER_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_particles.gdshader"
const FIELD_DEBUG_SHADER_PATH := "res://ocean_v3/rendering/underwater/ocean_sediment_field_debug.gdshader"
const MAX_INJECTIONS := 16
const TEST_INJECTION_RADIUS_M := 9.0
const TEST_INJECTION_STRENGTH := 0.90
const TEST_SEARCH_RADIUS_M := 15.0
const TEST_PREFERRED_DISTANCE_M := 8.0
const TEST_MARKER_LIFETIME_S := 9.0
const TEST_FIELD_DEBUG_SIZE_M := 36.0

enum DebugMode {
	OFF,
	FIELD_SURFACE,
	SOURCE_SURFACE,
	CLOUDS,
	WISPS,
	FIELD_UNDERWATER,
	CANDIDATES,
	FIELD_PARTICLE_MATCH,
	FIELD_UV,
	ALPHA_DENSITY,
	ALPHA_SOFT_SHAPE,
	ALPHA_DISTANCE,
	ALPHA_FINAL,
	PRODUCTION_EXAGGERATED,
	OPTICS_PARTICLE_T,
	OPTICS_BACKGROUND_T,
	OPTICS_COMPENSATION,
	OPTICS_FINAL_ALPHA,
	OPTICAL_COMPENSATION_OFF,
	OPTICAL_COMPENSATION_ON,
	BACKGROUND_DEPTH,
	PARTICLE_DEPTH,
	DEPTH_DELTA,
}

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
@export_group("Production Visual Tuning")
@export_range(0.0, 8.0, 0.05) var sediment_alpha_multiplier := 3.0
# RGB is used for the particle tint; alpha is controlled by the multiplier above.
@export var sediment_particle_color := Color(0.52, 0.38, 0.20, 1.0)
@export_range(0.25, 8.0, 0.05) var sediment_particle_size_multiplier := 1.5
@export_range(64, 10000, 64) var sediment_particle_count := 680
@export_range(0.0, 10.0, 0.05, "suffix: s") var sediment_fade_in_seconds := 1.0
@export_range(0.0, 10.0, 0.05, "suffix: s") var sediment_fade_out_seconds := 1.5
@export_range(0.0, 4.0, 0.01, "suffix: m") var sediment_geometry_edge_softness_m := 1.0
@export_range(0.0, 200.0, 1.0, "suffix: m") var sediment_distance_fade_start_m := 36.0
@export_range(1.0, 240.0, 1.0, "suffix: m") var sediment_distance_fade_end_m := 72.0
@export_group("Sediment Optical Compensation")
@export var sediment_optical_compensation_enabled := true
@export_range(1.0, 8.0, 0.1, "suffix: x") var sediment_optical_compensation_max := 4.0
@export_group("Sediment Debug")
@export_enum("OFF", "FIELD SURFACE", "SOURCE SURFACE", "CLOUDS", "WISPS", "SEDIMENT FIELD UNDERWATER", "SEDIMENT CANDIDATES", "SEDIMENT FIELD PARTICLE MATCH", "SEDIMENT FIELD UV", "SEDIMENT ALPHA DENSITY", "SEDIMENT ALPHA SOFT SHAPE", "SEDIMENT ALPHA DISTANCE", "SEDIMENT ALPHA FINAL", "SEDIMENT PRODUCTION EXAGGERATED", "SEDIMENT OPTICS PARTICLE_T", "SEDIMENT OPTICS BACKGROUND_T", "SEDIMENT OPTICS COMPENSATION", "SEDIMENT OPTICS FINAL_ALPHA", "SEDIMENT OPTICAL COMPENSATION OFF", "SEDIMENT OPTICAL COMPENSATION ON", "SEDIMENT BACKGROUND DEPTH", "SEDIMENT PARTICLE DEPTH", "SEDIMENT DEPTH DELTA") var sediment_debug_mode: int = DebugMode.OFF
@export var sediment_test_marker_enabled := true
# Editor tooling only. Runtime validation must use Ctrl+Shift+J, never this button.
@export_tool_button("Inject Test Sediment (Editor Tool)", "Burst") var inject_test_sediment_button = inject_test_sediment

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
var _performance_enabled := true
var _performance_field_enabled := true
var _performance_particles_enabled := true
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
var _test_injection_wait_reported := false
var _test_blocked_reported := false
var _runtime_debug_mode_applied := false
var _initialization_retry_timer := 0.0
var _bathymetry_wait_elapsed := 0.0
var _bathymetry_wait_reported := false
var _test_injection_sequence := 0
var _last_queued_injection_count := 0
var _test_marker: Node3D
var _test_marker_remaining_s := 0.0
var _field_debug_mesh: MeshInstance3D
var _field_debug_material: ShaderMaterial
var _field_debug_shader: Shader
var _last_test_target := Vector3.ZERO
var _last_test_target_valid := false
var _pending_dispatch_diagnostic := {}
var _aabb_debug_reported := false


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
	if Engine.is_editor_hint():
		return
	if not _performance_enabled:
		_apply_particle_visibility()
		_update_field_debug_visual()
		return
	if not _configuration_requested:
		_report_test_blocked_once("not configured")
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
			_report_test_blocked_once("not configured")
			return
		_try_begin_initialization()
		_report_test_blocked_once("not configured")
		return
	if _field == null:
		_report_test_blocked_once("field null")
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_report_test_blocked_once("no camera")
		return
	_set_emitter_from_camera()
	if _field.ready and _field.has_valid_rids():
		if _performance_field_enabled:
			_publish_completed_field()
		if not _particles_created and _field_published and _performance_particles_enabled:
			_ensure_particles()
			_print_init_diagnostic()
		if _performance_particles_enabled:
			_update_particles()
		else:
			_apply_particle_visibility()
		_update_field_debug_visual()
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
	if not sediment_enabled or not _performance_field_enabled or not _field.ready or not _field.has_valid_rids() or _dispatch_queued:
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


func set_performance_gates(master_enabled: bool, field_enabled: bool, particles_enabled: bool) -> void:
	_performance_enabled = master_enabled
	_performance_field_enabled = field_enabled
	_performance_particles_enabled = particles_enabled
	_apply_particle_visibility()
	_update_field_debug_visual()
	_publish_surface_field_state()


func inject_sediment(world_position: Vector3, radius_m: float, strength: float) -> bool:
	if not _performance_enabled or not _performance_field_enabled:
		return false
	if not _injection_validation(world_position).get("accepted", false):
		return false
	var injection := Vector4(world_position.x, world_position.z, maxf(radius_m, 0.05), clampf(strength, 0.0, 1.0))
	if _pending_injections.size() >= MAX_INJECTIONS:
		_pending_injections.pop_front()
	_pending_injections.append(injection)
	return true


func inject_test_sediment() -> void:
	print("SEDIMENT inject_test_sediment() RUNTIME editor_hint=%s inside_tree=%s instance_id=%d" % [
		Engine.is_editor_hint(),
		is_inside_tree(),
		get_instance_id(),
	])
	_runtime_injection_requested = true
	_test_injection_wait_reported = false
	_test_blocked_reported = false


func _report_test_blocked_once(reason: String) -> void:
	if _runtime_injection_requested and not _test_blocked_reported:
		_test_blocked_reported = true
		print("SEDIMENT TEST BLOCKED: %s" % reason)


func _request_test_injection() -> void:
	if not _field_published or _bathymetry == null or not _bathymetry.is_valid():
		if not _test_injection_wait_reported:
			_test_injection_wait_reported = true
			print("SEDIMENT TEST WAIT: waiting for the field to publish its first texture.")
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		if not _test_injection_wait_reported:
			_test_injection_wait_reported = true
			print("SEDIMENT TEST WAIT: waiting for an active camera.")
		return
	var target := _find_test_position(camera)
	if target.is_empty():
		_runtime_injection_requested = false
		print("SEDIMENT TEST FAILED: no valid visible seabed near camera")
		return
	var sample_position: Vector3 = target["world_position"]
	var validation := _injection_validation(sample_position)
	var accepted := inject_sediment(sample_position, TEST_INJECTION_RADIUS_M, TEST_INJECTION_STRENGTH)
	_runtime_injection_requested = false
	_test_injection_sequence += 1
	if accepted:
		_last_test_target = sample_position
		_last_test_target_valid = true
		_show_test_marker(sample_position)
	print("SEDIMENT TEST INJECTION #%d" % _test_injection_sequence)
	print("camera_world=%s" % camera.global_position)
	print("target_world=%s horizontal_distance=%.3f 3D_distance=%.3f camera_forward_dot_to_target=%.3f target_in_front=%s in_frustum=%s" % [
		sample_position,
		float(target.get("horizontal_distance", 0.0)),
		float(target.get("distance_3d", 0.0)),
		float(target.get("forward_dot", -1.0)),
		bool(target.get("target_in_front", false)),
		bool(target.get("in_frustum", false)),
	])
	print("raw_field_uv=%s inside_field=%s" % [validation.get("raw_uv", Vector2.ZERO), validation.get("inside_field", false)])
	print("bathymetry_in_bounds=%s water=%s depth=%.3f" % [validation.get("bathymetry_in_bounds", false), validation.get("water", false), validation.get("depth_m", 0.0)])
	print("radius=%.3f strength=%.3f queued=%s pending_queue=%d" % [TEST_INJECTION_RADIUS_M, TEST_INJECTION_STRENGTH, accepted, _pending_injections.size()])
	print("FIELD DEBUG PROXY: expected_center_after_dispatch=%.3f (GPU impulse, no readback); marker_lifetime_s=%.1f" % [TEST_INJECTION_STRENGTH * exp(-sediment_settling_rate / maxf(sediment_update_hz, 1.0)), TEST_MARKER_LIFETIME_S])
	_print_particle_height_diagnostic(sample_position, validation)
	_print_production_alpha_diagnostic()
	_print_optical_compensation_diagnostic(camera, sample_position)


func _find_test_position(camera: Camera3D) -> Dictionary:
	var camera_xz := Vector2(camera.global_position.x, camera.global_position.z)
	var forward := -camera.global_transform.basis.z
	if forward.length_squared() <= 0.0001:
		return {}
	forward = forward.normalized()
	var preferred_position := camera.global_position + forward * TEST_PREFERRED_DISTANCE_M
	var viewport_rect := get_viewport().get_visible_rect()
	var best_index := -1
	var best_score := INF
	var best_target := {}
	for index in _bathymetry.cell_count():
		if _bathymetry.land_water_mask[index] == 0 or _bathymetry.depth_m[index] <= 0.001:
			continue
		var x := index % _bathymetry.width
		var z := floori(float(index) / float(_bathymetry.width))
		var world_xz := _bathymetry.world_origin_xz + Vector2(float(x), float(z)) * _bathymetry.cell_size_m
		var distance_sq := world_xz.distance_squared_to(camera_xz)
		if distance_sq > TEST_SEARCH_RADIUS_M * TEST_SEARCH_RADIUS_M:
			continue
		var candidate := Vector3(world_xz.x, _bathymetry.sea_level_y - _bathymetry.depth_m[index] + 0.45, world_xz.y)
		var to_candidate := candidate - camera.global_position
		var distance_3d := to_candidate.length()
		if distance_3d <= 0.001 or distance_3d > TEST_SEARCH_RADIUS_M:
			continue
		var forward_dot := forward.dot(to_candidate / distance_3d)
		if forward_dot <= 0.10 or camera.is_position_behind(candidate):
			continue
		var screen_position := camera.unproject_position(candidate)
		var in_frustum := viewport_rect.grow(-2.0).has_point(screen_position)
		if not in_frustum:
			continue
		var score := candidate.distance_squared_to(preferred_position) + (1.0 - forward_dot) * 16.0
		if score < best_score:
			best_score = score
			best_index = index
			best_target = {
				"world_position": candidate,
				"horizontal_distance": sqrt(distance_sq),
				"distance_3d": distance_3d,
				"forward_dot": forward_dot,
				"target_in_front": true,
				"in_frustum": true,
			}
	if best_index >= 0:
		return best_target
	return {}


func _injection_validation(world_position: Vector3) -> Dictionary:
	var raw_uv := (Vector2(world_position.x, world_position.z) - _field_origin()) / Vector2(
		maxf(_field_extent().x, 0.001), maxf(_field_extent().y, 0.001))
	var inside_field := raw_uv.x >= 0.0 and raw_uv.x <= 1.0 and raw_uv.y >= 0.0 and raw_uv.y <= 1.0
	var bathymetry_ready := _bathymetry != null and _bathymetry.is_valid()
	var sample = _bathymetry.sample_bathymetry(Vector2(world_position.x, world_position.z)) if bathymetry_ready else null
	var field_ready := _configured and _field != null and _field.ready and _field.has_valid_rids()
	var in_bounds: bool = false
	var water: bool = false
	if sample != null:
		in_bounds = bool(sample.in_bounds)
		water = bool(sample.is_water)
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
	_test_marker = Node3D.new()
	_test_marker.name = "SedimentTestInjectionMarker"
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.08, 0.78, 0.96)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.01, 0.36)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var ring := MeshInstance3D.new()
	ring.name = "InjectionRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 1.55
	torus.outer_radius = 1.82
	torus.rings = 24
	torus.ring_segments = 12
	ring.mesh = torus
	ring.material_override = material
	_test_marker.add_child(ring)
	var pillar := MeshInstance3D.new()
	pillar.name = "InjectionPillar"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.12
	cylinder.bottom_radius = 0.18
	cylinder.height = 5.0
	pillar.mesh = cylinder
	pillar.position.y = 2.5
	pillar.material_override = material
	_test_marker.add_child(pillar)
	add_child(_test_marker)
	_test_marker.top_level = true
	_test_marker.global_position = world_position
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
			"SEDIMENT_DEBUG_FIELD": sediment_debug_mode = DebugMode.FIELD_SURFACE
			"SEDIMENT_DEBUG_SOURCE": sediment_debug_mode = DebugMode.SOURCE_SURFACE
			"SEDIMENT_DEBUG_CLOUDS": sediment_debug_mode = DebugMode.CLOUDS
			"SEDIMENT_DEBUG_WISPS": sediment_debug_mode = DebugMode.WISPS
			"SEDIMENT_DEBUG_FIELD_UNDERWATER", "SEDIMENT_FIELD_UNDERWATER": sediment_debug_mode = DebugMode.FIELD_UNDERWATER
			"SEDIMENT_DEBUG_CANDIDATES", "SEDIMENT_CANDIDATES": sediment_debug_mode = DebugMode.CANDIDATES
			"SEDIMENT_DEBUG_FIELD_PARTICLE_MATCH", "SEDIMENT_FIELD_PARTICLE_MATCH": sediment_debug_mode = DebugMode.FIELD_PARTICLE_MATCH
			"SEDIMENT_DEBUG_FIELD_UV", "SEDIMENT_FIELD_UV": sediment_debug_mode = DebugMode.FIELD_UV
			"SEDIMENT_ALPHA_DENSITY": sediment_debug_mode = DebugMode.ALPHA_DENSITY
			"SEDIMENT_ALPHA_SOFT_SHAPE": sediment_debug_mode = DebugMode.ALPHA_SOFT_SHAPE
			"SEDIMENT_ALPHA_DISTANCE": sediment_debug_mode = DebugMode.ALPHA_DISTANCE
			"SEDIMENT_ALPHA_FINAL": sediment_debug_mode = DebugMode.ALPHA_FINAL
			"SEDIMENT_PRODUCTION_EXAGGERATED": sediment_debug_mode = DebugMode.PRODUCTION_EXAGGERATED
			"SEDIMENT_OPTICS_PARTICLE_T": sediment_debug_mode = DebugMode.OPTICS_PARTICLE_T
			"SEDIMENT_OPTICS_BACKGROUND_T": sediment_debug_mode = DebugMode.OPTICS_BACKGROUND_T
			"SEDIMENT_OPTICS_COMPENSATION": sediment_debug_mode = DebugMode.OPTICS_COMPENSATION
			"SEDIMENT_OPTICS_FINAL_ALPHA": sediment_debug_mode = DebugMode.OPTICS_FINAL_ALPHA
			"SEDIMENT_OPTICAL_COMPENSATION_OFF": sediment_debug_mode = DebugMode.OPTICAL_COMPENSATION_OFF
			"SEDIMENT_OPTICAL_COMPENSATION_ON": sediment_debug_mode = DebugMode.OPTICAL_COMPENSATION_ON
			"SEDIMENT_DEBUG_OFF": sediment_debug_mode = DebugMode.OFF


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.pressed and not key_event.echo and key_event.ctrl_pressed \
		and key_event.shift_pressed and key_event.keycode == KEY_J:
		print("SEDIMENT RUNTIME TRIGGER RECEIVED")
		print("SEDIMENT RUNTIME DEBUG MODE=%s (select it on the Remote tree, not Local)" % DebugMode.find_key(sediment_debug_mode))
		inject_test_sediment()
		get_viewport().set_input_as_handled()


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
		"test_injection_pending": _runtime_injection_requested,
		"last_queued_injection_count": _last_queued_injection_count,
		"last_test_target": _last_test_target,
		"has_last_test_target": _last_test_target_valid,
		"particle_debug_mode": sediment_debug_mode,
		"particle_culling_debug_disabled": _is_particle_debug_mode(),
		"cloud_amount": _cloud_particles.amount if _cloud_particles != null else 0,
		"wisp_amount": _wisp_particles.amount if _wisp_particles != null else 0,
		"cloud_emitting": _cloud_particles.emitting if _cloud_particles != null else false,
		"wisp_emitting": _wisp_particles.emitting if _wisp_particles != null else false,
	}


func _dispatch_field(step_delta: float) -> void:
	if not _performance_enabled or not _performance_field_enabled or not sediment_enabled:
		return
	var read_index := _completed_read_index
	var write_index := 1 - read_index
	var serial_before := int(_field.diagnostic_state().get("completed_dispatch_serial", 0))
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
	if injection_count > 0:
		_pending_dispatch_diagnostic = {
			"read_index": read_index,
			"write_index": write_index,
			"injection_count": injection_count,
			"serial_before": serial_before,
		}


func _publish_completed_field() -> void:
	if _field == null:
		return
	var diagnostic := _field.diagnostic_state()
	var completed_serial := int(diagnostic.get("completed_dispatch_serial", 0))
	if completed_serial != _published_dispatch_serial:
		_completed_read_index = int(diagnostic.get("completed_read_index", _completed_read_index))
		_published_dispatch_serial = completed_serial
		_dispatch_queued = false
	if not _field.get_texture_rid(_completed_read_index).is_valid():
		return
	_field_texture.texture_rd_rid = _field.get_texture_rid(_completed_read_index)
	_field_published = true
	if not _pending_dispatch_diagnostic.is_empty() and completed_serial > int(_pending_dispatch_diagnostic.get("serial_before", completed_serial)):
		print("SEDIMENT DISPATCH read_index=%d write_index=%d injection_count=%d serial_before=%d serial_after=%d published_index=%d published_rid_id=%d" % [
			int(_pending_dispatch_diagnostic.get("read_index", -1)),
			int(_pending_dispatch_diagnostic.get("write_index", -1)),
			int(_pending_dispatch_diagnostic.get("injection_count", 0)),
			int(_pending_dispatch_diagnostic.get("serial_before", 0)),
			completed_serial,
			_completed_read_index,
			_field.get_texture_rid(_completed_read_index).get_id(),
		])
		_pending_dispatch_diagnostic.clear()
	_publish_surface_field_state()


func _publish_surface_field_state() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var material := _surface.get_surface_material()
	if material == null or material.shader == null or not _field_published:
		return
	_surface.set_sediment_field(
		_field_texture,
		sediment_enabled and _performance_enabled,
		_field_origin(),
		_field_extent(),
		sediment_above_water_optics_strength,
		_surface_debug_mode())


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
	_apply_particle_counts()
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
		var z := floori(float(index) / float(_bathymetry.width))
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
	particles.visibility_aabb = _particle_visibility_aabb()
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
	material.set_shader_parameter(&"particle_lifetime_seconds", 26.0)
	material.set_shader_parameter(&"fade_in_seconds", sediment_fade_in_seconds)
	material.set_shader_parameter(&"fade_out_seconds", sediment_fade_out_seconds)
	return material


func _create_render_material(is_wisps: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _render_shader
	# Draw after the ocean's transparent surface so the depth published by the
	# sediment billboards is the depth seen by the post-transparent medium pass.
	material.render_priority = 127
	material.set_shader_parameter(&"sediment_field_texture", _field_texture)
	material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	# Stage 4: retain the validated field response. Visual tuning is exposed as
	# render-only controls; wisps stay half as strong as the near-seabed clouds.
	material.set_shader_parameter(&"particle_color", _production_particle_color(is_wisps))
	material.set_shader_parameter(&"alpha_multiplier", sediment_alpha_multiplier)
	material.set_shader_parameter(&"size_multiplier", sediment_particle_size_multiplier)
	_set_optical_material_parameters(material)
	material.set_shader_parameter(&"strength", sediment_wisp_strength if is_wisps else sediment_cloud_strength)
	material.set_shader_parameter(&"field_threshold", 0.10 if is_wisps else 0.15)
	material.set_shader_parameter(&"field_contrast", 0.80 if is_wisps else 0.68)
	material.set_shader_parameter(&"wisps", is_wisps)
	material.set_shader_parameter(&"debug_mode", 0)
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
		material.set_shader_parameter(&"particle_lifetime_seconds", 26.0)
		material.set_shader_parameter(&"fade_in_seconds", sediment_fade_in_seconds)
		material.set_shader_parameter(&"fade_out_seconds", sediment_fade_out_seconds)
	if _cloud_particles != null or _wisp_particles != null:
		_apply_particle_counts()
	if _cloud_material != null:
		_cloud_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_cloud_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_cloud_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
		_cloud_material.set_shader_parameter(&"particle_color", _production_particle_color(false))
		_cloud_material.set_shader_parameter(&"alpha_multiplier", sediment_alpha_multiplier)
		_cloud_material.set_shader_parameter(&"size_multiplier", sediment_particle_size_multiplier)
		_set_optical_material_parameters(_cloud_material)
		_cloud_material.set_shader_parameter(&"geometry_edge_softness_m", sediment_geometry_edge_softness_m)
		_cloud_material.set_shader_parameter(&"distance_fade_start_m", sediment_distance_fade_start_m)
		_cloud_material.set_shader_parameter(&"distance_fade_end_m", maxf(sediment_distance_fade_end_m, sediment_distance_fade_start_m + 0.01))
		_cloud_material.set_shader_parameter(&"debug_mode", _particle_shader_debug_mode())
	if _wisp_material != null:
		_wisp_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
		_wisp_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
		_wisp_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
		_wisp_material.set_shader_parameter(&"particle_color", _production_particle_color(true))
		_wisp_material.set_shader_parameter(&"alpha_multiplier", sediment_alpha_multiplier)
		_wisp_material.set_shader_parameter(&"size_multiplier", sediment_particle_size_multiplier)
		_set_optical_material_parameters(_wisp_material)
		_wisp_material.set_shader_parameter(&"geometry_edge_softness_m", sediment_geometry_edge_softness_m)
		_wisp_material.set_shader_parameter(&"distance_fade_start_m", sediment_distance_fade_start_m)
		_wisp_material.set_shader_parameter(&"distance_fade_end_m", maxf(sediment_distance_fade_end_m, sediment_distance_fade_start_m + 0.01))
		_wisp_material.set_shader_parameter(&"debug_mode", _particle_shader_debug_mode())
	if _cloud_particles != null:
		_cloud_particles.visibility_aabb = _particle_visibility_aabb()
	if _wisp_particles != null:
		_wisp_particles.visibility_aabb = _particle_visibility_aabb()
	_apply_particle_visibility()


func _production_particle_color(is_wisps: bool) -> Color:
	var base_alpha := 0.08 if is_wisps else 0.16
	return Color(sediment_particle_color.r, sediment_particle_color.g, sediment_particle_color.b, base_alpha)


func _effective_optical_compensation_enabled() -> bool:
	var value: Variant = sediment_optical_compensation_enabled
	return value if value is bool else true


func _effective_optical_compensation_max() -> float:
	var value: Variant = sediment_optical_compensation_max
	return maxf(float(value), 1.0) if value is float or value is int else 4.0


func _set_optical_material_parameters(material: ShaderMaterial) -> void:
	if material == null:
		return
	# Older scenes may have serialized these newly-added exports as null. Keep
	# the production defaults instead of forwarding a null shader uniform.
	var compensation_enabled := _effective_optical_compensation_enabled()
	var compensation_max := _effective_optical_compensation_max()
	var sea_level := _bathymetry.sea_level_y if _bathymetry != null else 0.0
	var absorption := Vector3(0.35, 0.14, 0.10)
	var absorption_scale := 1.0
	var max_distance := 120.0
	var camera_world_position := Vector3.ZERO
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		camera_world_position = camera.global_position
	if _ocean != null and is_instance_valid(_ocean):
		var absorption_value: Variant = _ocean.get(&"absorption_coeff_rgb")
		if absorption_value is Vector3:
			absorption = absorption_value
		var scale_value: Variant = _ocean.get(&"underwater_absorption_scale")
		if scale_value is float or scale_value is int:
			absorption_scale = float(scale_value)
		var distance_value: Variant = _ocean.get(&"underwater_max_optical_distance_m")
		if distance_value is float or distance_value is int:
			max_distance = float(distance_value)
	material.set_shader_parameter(&"sea_level_y", sea_level)
	material.set_shader_parameter(&"camera_world_position", camera_world_position)
	material.set_shader_parameter(&"optical_absorption_coeff_rgb", absorption)
	material.set_shader_parameter(&"optical_absorption_scale", absorption_scale)
	material.set_shader_parameter(&"optical_max_distance_m", max_distance)
	material.set_shader_parameter(&"optical_compensation_max", compensation_max)
	material.set_shader_parameter(&"optical_compensation_enabled", compensation_enabled)


func _apply_particle_counts() -> void:
	var total := maxi(sediment_particle_count, 2)
	var cloud_amount := clampi(roundi(float(total) * 0.765), 1, total - 1)
	var wisp_amount := total - cloud_amount
	if _cloud_particles != null and _cloud_particles.amount != cloud_amount:
		_cloud_particles.amount = cloud_amount
	if _wisp_particles != null and _wisp_particles.amount != wisp_amount:
		_wisp_particles.amount = wisp_amount


func _apply_particle_visibility() -> void:
	var particle_debug := _is_particle_debug_mode()
	var particles_active := _performance_enabled and _performance_particles_enabled
	var clouds_visible := particles_active and sediment_enabled and _camera_underwater and _field_published and (particle_debug or sediment_cloud_strength > 0.0)
	var wisps_visible := particles_active and sediment_enabled and _camera_underwater and _field_published and (particle_debug or sediment_wisp_strength > 0.0)
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
	if particle_debug and not _aabb_debug_reported:
		print("SEDIMENT PARTICLE AABB DEBUG: culling disabled with %s; production AABB restores when debug mode is OFF." % _particle_visibility_aabb())
		_aabb_debug_reported = true
	elif not particle_debug:
		_aabb_debug_reported = false


func _surface_debug_mode() -> int:
	if sediment_debug_mode == DebugMode.FIELD_SURFACE:
		return 1
	if sediment_debug_mode == DebugMode.SOURCE_SURFACE:
		return 2
	return 0


func _is_particle_debug_mode() -> bool:
	# Stage 2/3 already proved particle data only with culling disabled. Keep the
	# same temporary AABB for Stage 4 so an invisible production test cannot be
	# mistaken for an alpha failure when it is actually renderer culling.
	return sediment_debug_mode == DebugMode.CANDIDATES \
		or sediment_debug_mode == DebugMode.FIELD_PARTICLE_MATCH \
		or sediment_debug_mode == DebugMode.ALPHA_DENSITY \
		or sediment_debug_mode == DebugMode.ALPHA_SOFT_SHAPE \
		or sediment_debug_mode == DebugMode.ALPHA_DISTANCE \
		or sediment_debug_mode == DebugMode.ALPHA_FINAL \
		or sediment_debug_mode == DebugMode.PRODUCTION_EXAGGERATED \
		or sediment_debug_mode == DebugMode.OPTICS_PARTICLE_T \
		or sediment_debug_mode == DebugMode.OPTICS_BACKGROUND_T \
		or sediment_debug_mode == DebugMode.OPTICS_COMPENSATION \
		or sediment_debug_mode == DebugMode.OPTICS_FINAL_ALPHA \
		or sediment_debug_mode == DebugMode.OPTICAL_COMPENSATION_OFF \
		or sediment_debug_mode == DebugMode.OPTICAL_COMPENSATION_ON \
		or sediment_debug_mode == DebugMode.BACKGROUND_DEPTH \
		or sediment_debug_mode == DebugMode.PARTICLE_DEPTH \
		or sediment_debug_mode == DebugMode.DEPTH_DELTA


func _particle_shader_debug_mode() -> int:
	if sediment_debug_mode == DebugMode.CANDIDATES:
		return 1
	if sediment_debug_mode == DebugMode.FIELD_PARTICLE_MATCH:
		return 2
	if sediment_debug_mode == DebugMode.ALPHA_DENSITY:
		return 3
	if sediment_debug_mode == DebugMode.ALPHA_SOFT_SHAPE:
		return 4
	if sediment_debug_mode == DebugMode.ALPHA_DISTANCE:
		return 5
	if sediment_debug_mode == DebugMode.ALPHA_FINAL:
		return 6
	if sediment_debug_mode == DebugMode.PRODUCTION_EXAGGERATED:
		return 7
	if sediment_debug_mode == DebugMode.OPTICS_PARTICLE_T:
		return 8
	if sediment_debug_mode == DebugMode.OPTICS_BACKGROUND_T:
		return 9
	if sediment_debug_mode == DebugMode.OPTICS_COMPENSATION:
		return 10
	if sediment_debug_mode == DebugMode.OPTICS_FINAL_ALPHA:
		return 11
	if sediment_debug_mode == DebugMode.OPTICAL_COMPENSATION_OFF:
		return 12
	if sediment_debug_mode == DebugMode.OPTICAL_COMPENSATION_ON:
		return 13
	if sediment_debug_mode == DebugMode.BACKGROUND_DEPTH:
		return 14
	if sediment_debug_mode == DebugMode.PARTICLE_DEPTH:
		return 15
	if sediment_debug_mode == DebugMode.DEPTH_DELTA:
		return 16
	return 0


func _print_production_alpha_diagnostic() -> void:
	if _cloud_material == null or _wisp_material == null:
		print("SEDIMENT PRODUCTION ALPHA: materials unavailable")
		return
	var cloud_color: Color = _cloud_material.get_shader_parameter(&"particle_color")
	var wisp_color: Color = _wisp_material.get_shader_parameter(&"particle_color")
	var cloud_strength: float = float(_cloud_material.get_shader_parameter(&"strength"))
	var wisp_strength: float = float(_wisp_material.get_shader_parameter(&"strength"))
	var cloud_threshold: float = float(_cloud_material.get_shader_parameter(&"field_threshold"))
	var wisp_threshold: float = float(_wisp_material.get_shader_parameter(&"field_threshold"))
	var cloud_contrast: float = float(_cloud_material.get_shader_parameter(&"field_contrast"))
	var wisp_contrast: float = float(_wisp_material.get_shader_parameter(&"field_contrast"))
	print("SEDIMENT PRODUCTION ALPHA color=%s alpha_multiplier=%.3f size_multiplier=%.3f particles=%d fade_in_s=%.2f fade_out_s=%.2f edge_softness_m=%.2f distance_fade_m=[%.1f,%.1f] cloud_color_a=%.3f cloud_strength=%.3f cloud_threshold=%.3f cloud_contrast=%.3f wisp_color_a=%.3f wisp_strength=%.3f wisp_threshold=%.3f wisp_contrast=%.3f" % [
		sediment_particle_color, sediment_alpha_multiplier, sediment_particle_size_multiplier,
		sediment_particle_count, sediment_fade_in_seconds, sediment_fade_out_seconds,
		sediment_geometry_edge_softness_m, sediment_distance_fade_start_m, sediment_distance_fade_end_m,
		cloud_color.a, cloud_strength, cloud_threshold, cloud_contrast,
		wisp_color.a, wisp_strength, wisp_threshold, wisp_contrast,
	])
	var field_samples := PackedFloat32Array([0.15, 0.25, 0.50, 0.90])
	var cloud_max := PackedFloat32Array()
	var wisp_max := PackedFloat32Array()
	for field_value in field_samples:
		cloud_max.append(_production_alpha_upper_bound(field_value, cloud_threshold, cloud_contrast, cloud_color.a, cloud_strength, sediment_alpha_multiplier))
		wisp_max.append(_production_alpha_upper_bound(field_value, wisp_threshold, wisp_contrast, wisp_color.a, wisp_strength, sediment_alpha_multiplier))
	print("SEDIMENT PRODUCTION ALPHA UPPER_BOUND soft_shape=1 distance_fade=1 field=[0.15,0.25,0.50,0.90] cloud=%s wisp=%s" % [cloud_max, wisp_max])
	_print_particle_render_binding_diagnostic()


func _print_optical_compensation_diagnostic(camera: Camera3D, particle_world_position: Vector3) -> void:
	var absorption := Vector3(0.35, 0.14, 0.10)
	var absorption_scale := 1.0
	var max_distance := 120.0
	if _ocean != null and is_instance_valid(_ocean):
		var absorption_value: Variant = _ocean.get(&"absorption_coeff_rgb")
		if absorption_value is Vector3:
			absorption = absorption_value
		var scale_value: Variant = _ocean.get(&"underwater_absorption_scale")
		if scale_value is float or scale_value is int:
			absorption_scale = float(scale_value)
		var distance_value: Variant = _ocean.get(&"underwater_max_optical_distance_m")
		if distance_value is float or distance_value is int:
			max_distance = float(distance_value)
	var particle_segment := particle_world_position - camera.global_position
	var particle_path := camera.global_position.distance_to(particle_world_position)
	var sea_level := _bathymetry.sea_level_y if _bathymetry != null else 0.0
	if particle_world_position.y >= sea_level and absf(particle_segment.y) > 0.00001:
		var surface_fraction := clampf((sea_level - camera.global_position.y) / particle_segment.y, 0.0, 1.0)
		particle_path *= surface_fraction
	particle_path = minf(particle_path, max_distance)
	var particle_t := Vector3(
		exp(-absorption.x * absorption_scale * particle_path),
		exp(-absorption.y * absorption_scale * particle_path),
		exp(-absorption.z * absorption_scale * particle_path))
	print("SEDIMENT OPTICS PARTICLE_T path_m=%.3f T=%s (background depth is GPU visual diagnostic)" % [particle_path, particle_t])
	print("SEDIMENT OPTICS BACKGROUND_T visual mode=SEDIMENT OPTICS BACKGROUND_T (GPU depth-driven)")
	print("SEDIMENT OPTICS COMPENSATION max=%.2fx enabled=%s formula=T_particle/max(T_background,0.02), clamped=[0,%.2f]" % [_effective_optical_compensation_max(), _effective_optical_compensation_enabled(), _effective_optical_compensation_max()])
	print("SEDIMENT OPTICS FINAL_ALPHA visual mode=SEDIMENT OPTICS FINAL_ALPHA")


func _print_particle_render_binding_diagnostic() -> void:
	var cloud_quad := _cloud_particles.draw_pass_1 as QuadMesh if _cloud_particles != null else null
	var wisp_quad := _wisp_particles.draw_pass_1 as QuadMesh if _wisp_particles != null else null
	var cloud_bound := cloud_quad != null and cloud_quad.material == _cloud_material
	var wisp_bound := wisp_quad != null and wisp_quad.material == _wisp_material
	var cloud_mode := int(_cloud_material.get_shader_parameter(&"debug_mode")) if _cloud_material != null else -1
	var wisp_mode := int(_wisp_material.get_shader_parameter(&"debug_mode")) if _wisp_material != null else -1
	print("SEDIMENT PARTICLE RENDER BINDING cloud_bound=%s cloud_mode=%d cloud_emitting=%s cloud_visible=%s cloud_amount=%d cloud_local_coords=%s wisp_bound=%s wisp_mode=%d wisp_emitting=%s wisp_visible=%s wisp_amount=%d wisp_local_coords=%s" % [
		cloud_bound, cloud_mode,
		_cloud_particles.emitting if _cloud_particles != null else false,
		_cloud_particles.visible if _cloud_particles != null else false,
		_cloud_particles.amount if _cloud_particles != null else 0,
		_cloud_particles.local_coords if _cloud_particles != null else true,
		wisp_bound, wisp_mode,
		_wisp_particles.emitting if _wisp_particles != null else false,
		_wisp_particles.visible if _wisp_particles != null else false,
		_wisp_particles.amount if _wisp_particles != null else 0,
		_wisp_particles.local_coords if _wisp_particles != null else true,
	])


func _production_alpha_upper_bound(field_value: float, threshold: float, contrast: float, color_alpha: float, strength: float, alpha_multiplier: float = 1.0) -> float:
	var t := clampf((field_value - threshold) / maxf(1.0 - threshold, 0.001), 0.0, 1.0)
	var shaped := t * t * (3.0 - 2.0 * t)
	var density := pow(maxf(shaped, 0.0), maxf(contrast, 0.1))
	return density * maxf(color_alpha, 0.0) * maxf(strength, 0.0) * maxf(alpha_multiplier, 0.0)


func _particle_visibility_aabb() -> AABB:
	# Stage 2/3 deliberately disable culling to distinguish an AABB issue from a
	# process/material issue. Production retains the measured camera-local bounds.
	if _is_particle_debug_mode():
		return AABB(Vector3(-1000.0, -1000.0, -1000.0), Vector3(2000.0, 2000.0, 2000.0))
	var extent := maxf(84.0, sediment_render_distance_m * 2.0 + sediment_particle_size_multiplier * 4.0)
	return AABB(Vector3.ONE * (-0.5 * extent), Vector3.ONE * extent)


func _update_field_debug_visual() -> void:
	var enabled := (sediment_debug_mode == DebugMode.FIELD_UNDERWATER or sediment_debug_mode == DebugMode.FIELD_UV) \
		and _performance_enabled and _field_published and _last_test_target_valid
	if not enabled:
		if _field_debug_mesh != null and is_instance_valid(_field_debug_mesh):
			_field_debug_mesh.visible = false
		return
	if not _ensure_field_debug_mesh():
		return
	_field_debug_mesh.global_position = _last_test_target + Vector3(0.0, 0.12, 0.0)
	_field_debug_mesh.visible = true
	_field_debug_material.set_shader_parameter(&"sediment_field_texture", _field_texture)
	_field_debug_material.set_shader_parameter(&"sediment_field_origin_xz", _field_origin())
	_field_debug_material.set_shader_parameter(&"sediment_field_extent_m", _field_extent())
	_field_debug_material.set_shader_parameter(&"debug_mode", 1 if sediment_debug_mode == DebugMode.FIELD_UV else 0)


func _ensure_field_debug_mesh() -> bool:
	if _field_debug_mesh != null and is_instance_valid(_field_debug_mesh):
		return true
	if _field_debug_shader == null:
		_field_debug_shader = load(FIELD_DEBUG_SHADER_PATH) as Shader
	if _field_debug_shader == null:
		push_error("SEDIMENT FIELD DEBUG: could not load %s" % FIELD_DEBUG_SHADER_PATH)
		return false
	_field_debug_material = ShaderMaterial.new()
	_field_debug_material.shader = _field_debug_shader
	var plane := PlaneMesh.new()
	plane.size = Vector2(TEST_FIELD_DEBUG_SIZE_M, TEST_FIELD_DEBUG_SIZE_M)
	_field_debug_mesh = MeshInstance3D.new()
	_field_debug_mesh.name = "SedimentFieldUnderwaterDebug"
	_field_debug_mesh.mesh = plane
	_field_debug_mesh.material_override = _field_debug_material
	add_child(_field_debug_mesh)
	_field_debug_mesh.owner = null
	_field_debug_mesh.top_level = true
	return true


func _print_particle_height_diagnostic(target: Vector3, validation: Dictionary) -> void:
	var depth_m: float = float(validation.get("depth_m", 0.0))
	var preview_depth_m: float = float(round(clampf(depth_m / 32.0, 0.0, 1.0) * 255.0)) / 255.0 * 32.0
	var seabed_y: float = (_bathymetry.sea_level_y if _bathymetry != null else 0.0) - depth_m
	var preview_seabed_y: float = (_bathymetry.sea_level_y if _bathymetry != null else 0.0) - preview_depth_m
	print("SEDIMENT PARTICLE HEIGHT target=%s seabed_y=%.3f preview_depth_m=%.3f preview_seabed_y=%.3f cloud_y_range=[%.3f, %.3f] wisp_y_range=[%.3f, %.3f] preview_error_m=%.3f" % [
		target,
		seabed_y,
		preview_depth_m,
		preview_seabed_y,
		preview_seabed_y + 0.05,
		preview_seabed_y + 1.5,
		preview_seabed_y + 0.5,
		preview_seabed_y + 2.5,
		preview_seabed_y - seabed_y,
	])


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

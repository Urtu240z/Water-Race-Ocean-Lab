@tool
class_name WaterLensFX
extends Node

const EFFECT_SCRIPT := preload("res://ocean_v3/rendering/underwater/water_lens_effect.gd")
const MAX_DROPLETS := 64
const SIMULATION_HZ := 30.0
const EPSILON := 0.0001

@export_group("Lens FX / Entry")
@export var enabled := true
@export_range(0.08, 0.25, 0.005, "suffix: s") var entry_duration_min_s := 0.10
@export_range(0.08, 0.25, 0.005, "suffix: s") var entry_duration_max_s := 0.20
@export_range(0.0, 1.0, 0.01) var entry_distortion := 0.85
@export_range(0.0, 2.0, 0.01) var entry_bubble_amount := 0.8
@export_range(1.0, 20.0, 0.1, "suffix: m/s") var entry_velocity_reference_mps := 8.0
@export_group("Lens FX / Exit")
@export_range(0.10, 0.35, 0.005, "suffix: s") var exit_sheet_duration_min_s := 0.14
@export_range(0.10, 0.35, 0.005, "suffix: s") var exit_sheet_duration_max_s := 0.28
@export_range(0.0, 1.0, 0.01) var exit_sheet_distortion := 0.75
@export_range(0.0, 1.0, 0.01) var exit_wetness_amount := 0.72
@export_group("Lens FX / Droplets")
@export_range(8, MAX_DROPLETS, 1) var max_droplets := 36
@export_range(0.003, 0.08, 0.001) var droplet_min_radius := 0.008
@export_range(0.003, 0.15, 0.001) var droplet_max_radius := 0.045
@export_range(0.0, 1.0, 0.01) var gravity_strength := 0.12
@export_range(0.0, 1.0, 0.01) var pinning_strength := 0.72
@export_range(0.0, 0.2, 0.001) var evaporation_rate := 0.012
@export_range(0.0, 1.0, 0.01) var refraction_strength := 0.65
@export_group("Lens FX / Airflow")
@export_range(0.0, 2.0, 0.01) var airflow_strength := 0.9
@export_range(1.0, 60.0, 0.5, "suffix: m/s") var speed_reference_mps := 22.0
@export_range(0.0, 4.0, 0.01) var max_clearing_force := 1.8
@export_group("Lens FX / Performance")
@export_range(10.0, 60.0, 1.0, "suffix: Hz") var simulation_hz := SIMULATION_HZ
@export_group("Lens FX / Debug")
@export_enum("OFF", "WETNESS_MASK", "AIRFLOW", "LENS_WETNESS", "DROPLET_VELOCITY") var debug_mode := 0

var lens_wetness := 0.0
var jetski_linear_velocity := Vector3.ZERO
var jetski_vertical_velocity_mps := 0.0

var _effect: WaterLensEffect
var _compositor: Compositor
var _world_environment: WorldEnvironment
var _camera: Camera3D
var _attached := false
var _underwater := false
var _sim_accumulator := 0.0
var _time_s := 0.0
var _entry_elapsed := 1.0
var _entry_duration := 0.15
var _exit_elapsed := 1.0
var _exit_duration := 0.20
var _entry_strength := 0.0
var _exit_strength := 0.0
var _event_seed := 1.0
var _rng := RandomNumberGenerator.new()
var _droplets: Array[Dictionary] = []
var _last_camera_position := Vector3.ZERO
var _has_camera_position := false
var _velocity_is_explicit := false

func configure(_ocean: Node) -> void:
	if not is_inside_tree() or Engine.is_editor_hint(): return
	_rng.seed = 0x57415445524C454E
	call_deferred(&"_initialize")

func set_medium_state(underwater: bool, jetski_velocity: Vector3 = Vector3.ZERO, vertical_velocity_mps := 0.0) -> void:
	if jetski_velocity.length_squared() > EPSILON:
		jetski_linear_velocity = jetski_velocity
		jetski_vertical_velocity_mps = vertical_velocity_mps if absf(vertical_velocity_mps) > EPSILON else jetski_velocity.y
		_velocity_is_explicit = true
	if underwater == _underwater: return
	if underwater:
		_on_entry()
	else:
		_on_exit()
	_underwater = underwater

func set_jetski_velocity(velocity: Vector3) -> void:
	jetski_linear_velocity = velocity
	jetski_vertical_velocity_mps = velocity.y
	_velocity_is_explicit = true

func set_enabled(value: bool) -> void:
	enabled = value
	if _effect != null:
		_effect.enabled = value and (lens_wetness > EPSILON or _entry_elapsed < 1.0 or _exit_elapsed < 1.0)

func _ready() -> void:
	if not Engine.is_editor_hint():
		_rng.seed = 0x57415445524C454E
		call_deferred(&"_initialize")

func _initialize() -> void:
	if _attached or Engine.is_editor_hint() or not is_inside_tree(): return
	_effect = EFFECT_SCRIPT.new()
	# CompositorEffect defaults to enabled; keep the dry startup path completely
	# idle until the first transition publishes frame data.
	_effect.enabled = false
	var scene := get_tree().current_scene
	var target := scene.find_child("WorldEnvironment", true, false) if scene != null else null
	if target is WorldEnvironment:
		_world_environment = target
		_compositor = _world_environment.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_world_environment.compositor = _compositor
	else:
		_camera = get_viewport().get_camera_3d()
		if _camera == null: return
		_compositor = _camera.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			_camera.compositor = _compositor
	var effects := _compositor.compositor_effects.duplicate()
	effects.append(_effect)
	_compositor.compositor_effects = effects
	_attached = true
	_last_camera_position = get_viewport().get_camera_3d().global_position if get_viewport().get_camera_3d() != null else Vector3.ZERO
	_has_camera_position = true

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _attached: return
	_time_s += maxf(delta, 0.0)
	_sim_accumulator += maxf(delta, 0.0)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_camera = camera
		if _has_camera_position and delta > EPSILON and not _velocity_is_explicit:
			# Fallback only: a gameplay vehicle can override this with
			# set_jetski_velocity() so camera smoothing never becomes authority.
			jetski_linear_velocity = (camera.global_position - _last_camera_position) / delta
		_last_camera_position = camera.global_position
		_has_camera_position = true
	if _sim_accumulator >= 1.0 / maxf(simulation_hz, 1.0):
		var step := _sim_accumulator
		_sim_accumulator = 0.0
		_simulate(step)
	_publish_frame()

func _on_entry() -> void:
	var speed := maxf(-jetski_vertical_velocity_mps, 0.0)
	_entry_strength = clampf(speed / maxf(entry_velocity_reference_mps, 0.1), 0.15, 1.0)
	_entry_duration = lerpf(entry_duration_max_s, entry_duration_min_s, _entry_strength)
	_entry_elapsed = 0.0
	_exit_elapsed = 1.0
	_event_seed = _rng.randf_range(0.1, 10000.0)
	_add_droplets(int(round(4.0 + 10.0 * _entry_strength)), _entry_strength * 0.42)

func _on_exit() -> void:
	_exit_strength = clampf(0.35 + jetski_linear_velocity.length() / maxf(speed_reference_mps, 0.1) * 0.65, 0.0, 1.0)
	_exit_duration = lerpf(exit_sheet_duration_max_s, exit_sheet_duration_min_s, _exit_strength)
	_exit_elapsed = 0.0
	_entry_elapsed = 1.0
	_event_seed = _rng.randf_range(0.1, 10000.0)
	lens_wetness = clampf(lens_wetness + exit_wetness_amount * (0.65 + _exit_strength * 0.35), 0.0, 1.0)
	_add_droplets(int(round(10.0 + 20.0 * _exit_strength)), 0.4 + _exit_strength * 0.45)

func _add_droplets(count: int, amount: float) -> void:
	for index in range(clampi(count, 0, MAX_DROPLETS)):
		if _droplets.size() >= min(max_droplets, MAX_DROPLETS): break
		var radius := _rng.randf_range(droplet_min_radius, droplet_max_radius)
		_droplets.append({
			"position": Vector2(_rng.randf_range(0.06, 0.94), _rng.randf_range(0.06, 0.94)),
			"radius": radius,
			"distortion": refraction_strength * _rng.randf_range(0.35, 1.0),
			"velocity": Vector2(_rng.randf_range(-0.015, 0.015), _rng.randf_range(-0.01, 0.01)),
			"opacity": clampf(amount * _rng.randf_range(0.5, 1.0), 0.0, 1.0),
			"pinning": _rng.randf_range(0.55, 1.0),
			"seed": _rng.randf_range(0.1, 10000.0),
			"age": 0.0,
			"lifetime": _rng.randf_range(4.0, 14.0),
		})

func _simulate(delta: float) -> void:
	if _entry_elapsed < 1.0: _entry_elapsed = minf(_entry_elapsed + delta / maxf(_entry_duration, 0.01), 1.0)
	if _exit_elapsed < 1.0: _exit_elapsed = minf(_exit_elapsed + delta / maxf(_exit_duration, 0.01), 1.0)
	var speed := jetski_linear_velocity.length()
	var airflow := clampf(speed / maxf(speed_reference_mps, 0.1), 0.0, 3.0)
	var airflow_force := minf(airflow * airflow * airflow_strength, max_clearing_force)
	var camera := get_viewport().get_camera_3d()
	var airflow_screen := Vector2(0.0, -1.0)
	if camera != null and speed > EPSILON:
		var local_velocity := camera.global_basis.inverse() * jetski_linear_velocity
		airflow_screen = Vector2(-local_velocity.x, local_velocity.y)
		if airflow_screen.length_squared() > EPSILON: airflow_screen = airflow_screen.normalized()
	var alive: Array[Dictionary] = []
	for drop in _droplets:
		drop["age"] = float(drop["age"]) + delta
		var radius: float = drop["radius"]
		var pinning: float = drop["pinning"]
		var velocity: Vector2 = drop["velocity"]
		velocity += Vector2(0.0, gravity_strength * (1.0 - pinning)) * delta
		# Airflow progressively overcomes surface tension. At low speed the
		# original pinning remains dominant; at high speed even pinned drops
		# stretch and migrate instead of disappearing at a threshold.
		var airflow_mobility := clampf(airflow_force * 0.55, 0.0, 1.0)
		var mobility := lerpf(1.0 - pinning, 1.0, airflow_mobility)
		velocity += airflow_screen * airflow_force * mobility * delta
		velocity += Vector2(cos(_time_s * 1.7 + float(drop["seed"])), sin(_time_s * 1.3 + float(drop["seed"]))) * 0.002 * delta
		drop["velocity"] = velocity
		drop["position"] = (drop["position"] as Vector2) + velocity * delta
		# Airflow stretches and evacuates water continuously; no speed threshold
		# deletes a droplet. Low-speed drops remain pinned and dry slowly.
		drop["radius"] = radius * (1.0 - minf(airflow_force * delta * 0.08, 0.16))
		drop["opacity"] = float(drop["opacity"]) * (1.0 - evaporation_rate * delta * (1.0 + airflow * 0.35 + airflow_force * 1.5))
		var position: Vector2 = drop["position"]
		var keep := float(drop["age"]) < float(drop["lifetime"]) and float(drop["opacity"]) > 0.015
		keep = keep and position.x > -0.15 and position.x < 1.15 and position.y > -0.15 and position.y < 1.15
		if keep: alive.append(drop)
	_droplets = alive
	lens_wetness = clampf(lens_wetness - evaporation_rate * delta * (1.0 + airflow * 0.25), 0.0, 1.0)

func _publish_frame() -> void:
	if _effect == null: return
	# The stable underwater medium does not need a wet-lens pass. Once the entry
	# impulse has decayed, the compositor sleeps until exit wetness or a new event.
	var active := enabled and (lens_wetness > EPSILON or _entry_elapsed < 1.0 or _exit_elapsed < 1.0)
	_effect.enabled = active
	if not active: return
	var camera := get_viewport().get_camera_3d()
	var size := get_viewport().get_visible_rect().size if camera != null else Vector2(1.0, 1.0)
	var airflow := jetski_linear_velocity.length()
	var airflow_screen := Vector2(0.0, -1.0)
	if camera != null and airflow > EPSILON:
		var local_velocity := camera.global_basis.inverse() * jetski_linear_velocity
		airflow_screen = Vector2(-local_velocity.x, local_velocity.y).normalized()
	var values := PackedFloat32Array()
	values.resize(PARAMS_FLOAT_COUNT)
	values[0] = size.x; values[1] = size.y; values[2] = _time_s; values[3] = float(debug_mode)
	values[4] = lens_wetness; values[5] = _entry_strength * entry_bubble_amount; values[6] = _entry_elapsed; values[7] = _exit_elapsed
	values[8] = airflow_screen.x; values[9] = airflow_screen.y; values[10] = clampf(airflow / maxf(speed_reference_mps, 0.1), 0.0, 1.0); values[11] = airflow
	values[12] = _event_seed; values[13] = cos(_event_seed); values[14] = sin(_event_seed); values[15] = maxf(_entry_strength, _exit_strength)
	var offset := 16
	for index in range(MAX_DROPLETS):
		var drop := _droplets[index] if index < _droplets.size() else {}
		var position: Vector2 = drop.get("position", Vector2(-1.0, -1.0))
		var velocity: Vector2 = drop.get("velocity", Vector2.ZERO)
		values[offset] = position.x; values[offset + 1] = position.y; values[offset + 2] = float(drop.get("radius", 0.0)); values[offset + 3] = float(drop.get("distortion", 0.0))
		values[offset + 4] = velocity.x; values[offset + 5] = velocity.y; values[offset + 6] = float(drop.get("opacity", 0.0)); values[offset + 7] = float(drop.get("pinning", 1.0))
		values[offset + 8] = float(drop.get("seed", 0.0)); values[offset + 9] = float(drop.get("age", 0.0)); values[offset + 10] = float(drop.get("lifetime", 0.0)); values[offset + 11] = 0.0
		offset += 12
	_effect.set_frame_data(values, true)

func get_debug_state() -> Dictionary:
	return {"wetness": lens_wetness, "speed_mps": jetski_linear_velocity.length(), "active_droplets": _droplets.size(), "simulation_active": _effect != null and _effect.enabled}

func get_dispatch_count() -> int:
	return _effect.get_dispatch_count() if _effect != null else 0

func _exit_tree() -> void:
	if _effect != null:
		if _compositor != null:
			var effects := _compositor.compositor_effects.duplicate()
			effects.erase(_effect)
			_compositor.compositor_effects = effects
		_effect.enabled = false
		_effect.set_frame_data(PackedFloat32Array(), false)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false

const PARAMS_FLOAT_COUNT := 784

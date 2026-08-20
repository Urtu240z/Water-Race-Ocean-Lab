extends Node
## Fuente única de tiempo para los futuros sistemas de Ocean V3.

signal paused_changed(is_paused: bool)
signal reset_completed(simulation_seed: int)
signal seed_changed(simulation_seed: int)
signal time_scale_changed(scale: float)

var simulation_time: float = 0.0
var _previous_simulation_time: float = 0.0
var simulation_seed: int = 20260820
var time_scale: float = 1.0:
	set(value):
		time_scale = maxf(value, 0.0)
		time_scale_changed.emit(time_scale)

var _is_paused := false


func _physics_process(_delta: float) -> void:
	if not _is_paused:
		_previous_simulation_time = simulation_time
		advance_deterministic(1.0 / float(Engine.physics_ticks_per_second))


func advance_deterministic(step_seconds: float) -> void:
	if _is_paused:
		return
	simulation_time += maxf(step_seconds, 0.0) * time_scale


func pause() -> void:
	set_paused(true)


func resume() -> void:
	set_paused(false)


func toggle_paused() -> void:
	set_paused(not _is_paused)


func set_paused(value: bool) -> void:
	if _is_paused == value:
		return
	_is_paused = value
	paused_changed.emit(_is_paused)


func is_paused() -> bool:
	return _is_paused


func get_render_time() -> float:
	## Godot interpola visualmente entre el estado físico anterior y el actual.
	## Pausado devuelve el estado físico actual; el módulo conserva su último mapa.
	if _is_paused:
		return simulation_time
	return lerpf(_previous_simulation_time, simulation_time, Engine.get_physics_interpolation_fraction())


func reset_simulation(preserve_seed := true, next_seed := simulation_seed) -> void:
	if not preserve_seed:
		set_seed(next_seed)
	simulation_time = 0.0
	_previous_simulation_time = 0.0
	reset_completed.emit(simulation_seed)


func set_seed(value: int) -> void:
	if simulation_seed == value:
		return
	simulation_seed = value
	seed_changed.emit(simulation_seed)


func start_simulation_with_seed(next_seed: int) -> void:
	reset_simulation(false, next_seed)

extends Camera3D

@export var movement_speed := 12.0
@export var sprint_multiplier := 4.0
@export var mouse_sensitivity := 0.0025

var _is_active := false
var _slow_speed_mps := -1.0


func _ready() -> void:
	# Herramienta visual movida desde _process(); no participa en física.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func set_active(value: bool) -> void:
	_is_active = value
	current = value
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE)


func _process(delta: float) -> void:
	if not _is_active:
		return

	var movement := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		movement -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		movement += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		movement -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		movement += global_transform.basis.x
	if Input.is_key_pressed(KEY_E):
		movement += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		movement -= Vector3.UP

	if movement.length_squared() == 0.0:
		return

	var speed := movement_speed
	if Input.is_key_pressed(KEY_SPACE):
		speed = get_slow_speed_mps()
	elif Input.is_key_pressed(KEY_SHIFT):
		speed = get_sprint_speed_mps()
	global_position += movement.normalized() * speed * delta


func get_sprint_speed_mps() -> float:
	return movement_speed * sprint_multiplier


func set_sprint_speed_mps(value: float) -> void:
	sprint_multiplier = maxf(value, movement_speed) / maxf(movement_speed, 0.001)


func get_slow_speed_mps() -> float:
	if _slow_speed_mps > 0.0:
		return _slow_speed_mps
	return movement_speed * 0.25


func set_slow_speed_mps(value: float) -> void:
	_slow_speed_mps = clampf(value, 0.5, movement_speed)


func _input(event: InputEvent) -> void:
	if not _is_active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		rotation.x = clampf(rotation.x - event.relative.y * mouse_sensitivity, -1.45, 1.45)

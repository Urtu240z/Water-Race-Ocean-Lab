class_name CoastalPropagationSample
extends RefCounted
## Resultado reutilizable para queries CPU de la propagación 3B.

var depth_m := 0.0
var local_k := 0.0
var wavelength_m := 0.0
var phase_speed_mps := 0.0
var group_velocity_mps := 0.0
var shoaling_scale := 1.0
var phase_offset_rad := 0.0
var phase_rad := 0.0
var render_phase_rad := 0.0
var phase_gradient_x := 0.0
var phase_gradient_z := 0.0
var local_direction_xz := Vector2.RIGHT
var render_direction_xz := Vector2.RIGHT
var shadow_scale := 1.0
var reached := false
var valid := false
var in_bounds := false


func set_invalid() -> CoastalPropagationSample:
	depth_m = 0.0
	local_k = 0.0
	wavelength_m = 0.0
	phase_speed_mps = 0.0
	group_velocity_mps = 0.0
	shoaling_scale = 1.0
	phase_offset_rad = 0.0
	phase_rad = 0.0
	render_phase_rad = 0.0
	phase_gradient_x = 0.0
	phase_gradient_z = 0.0
	local_direction_xz = Vector2.RIGHT
	render_direction_xz = Vector2.RIGHT
	shadow_scale = 0.0
	reached = false
	valid = false
	in_bounds = false
	return self

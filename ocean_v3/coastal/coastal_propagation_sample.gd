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
	valid = false
	in_bounds = false
	return self

class_name BathymetrySample
extends RefCounted
## Resultado reutilizable de BathymetryData.sample_bathymetry().

var depth_m := 0.0
var gradient_x := 0.0
var gradient_z := 0.0
var gradient := Vector2.ZERO
var slope_magnitude := 0.0
var slope := 0.0
var is_water := false
var shore_signed_distance_m := 0.0
var depth_is_measured := false
var in_bounds := false


func set_flat() -> BathymetrySample:
	depth_m = 0.0
	gradient_x = 0.0
	gradient_z = 0.0
	gradient = Vector2.ZERO
	slope_magnitude = 0.0
	slope = 0.0
	is_water = false
	shore_signed_distance_m = 0.0
	depth_is_measured = false
	in_bounds = false
	return self

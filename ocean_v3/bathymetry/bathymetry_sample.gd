class_name BathymetrySample
extends RefCounted
## Resultado reutilizable de BathymetryData.sample_bathymetry().

var depth_m := 0.0
var gradient_x := 0.0
var gradient_z := 0.0
var slope_magnitude := 0.0
var is_water := false
var in_bounds := false


func set_flat() -> BathymetrySample:
	depth_m = 0.0
	gradient_x = 0.0
	gradient_z = 0.0
	slope_magnitude = 0.0
	is_water = false
	in_bounds = false
	return self

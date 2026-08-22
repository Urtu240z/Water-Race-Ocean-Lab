class_name CoastalWarpSample
extends RefCounted
## Resultado reutilizable para queries CPU del warp world->deep (3B.2A).

var deep_xz := Vector2.ZERO
var jacobian_det := 0.0
var jacobian_j00 := 0.0
var jacobian_j01 := 0.0
var jacobian_j10 := 0.0
var jacobian_j11 := 0.0
var r_deep := 0.0
var valid := false
var jacobian_class := 3 # CoastalWarpData.JacobianClass.INVALID
var in_bounds := false


func set_invalid() -> CoastalWarpSample:
	deep_xz = Vector2.ZERO
	jacobian_det = 0.0
	jacobian_j00 = 0.0
	jacobian_j01 = 0.0
	jacobian_j10 = 0.0
	jacobian_j11 = 0.0
	r_deep = 0.0
	valid = false
	jacobian_class = 3
	in_bounds = false
	return self

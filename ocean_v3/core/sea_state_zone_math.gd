class_name SeaStateZoneMath
extends RefCounted
## Shared CPU policy for OceanSeaStateZone3D and OceanQueryReduced.
## The shader mirrors this oriented-rectangle SDF and its smooth feather.

static func weight_and_gradient(point: Vector2, center: Vector2, axis: Vector2,
		half_extents: Vector2, feather_distance: float) -> Vector4:
	var safe_axis := axis.normalized() if axis.length_squared() > 1.0e-8 else Vector2.RIGHT
	var tangent := Vector2(-safe_axis.y, safe_axis.x)
	var local_point := Vector2((point - center).dot(safe_axis), (point - center).dot(tangent))
	var q := local_point.abs() - half_extents
	var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0))
	var sdf := outside.length() + minf(maxf(q.x, q.y), 0.0)
	var gradient_local := Vector2.ZERO
	if sdf > 0.0 and outside.length_squared() > 1.0e-12:
		gradient_local = Vector2(signf(local_point.x) * outside.x, signf(local_point.y) * outside.y).normalized()
	else:
		gradient_local = Vector2(signf(local_point.x), 0.0) if q.x > q.y else Vector2(0.0, signf(local_point.y))
	var gradient := safe_axis * gradient_local.x + tangent * gradient_local.y
	var feather := maxf(feather_distance, 0.0)
	if feather <= 1.0e-6 or sdf <= 0.0:
		return Vector4(1.0, 0.0, 0.0, sdf)
	if sdf >= feather:
		return Vector4(0.0, 0.0, 0.0, sdf)
	var t := clampf(sdf / feather, 0.0, 1.0)
	var weight := 1.0 - smoothstep(0.0, 1.0, t)
	var weight_derivative := -6.0 * t * (1.0 - t) / feather
	return Vector4(weight, gradient.x * weight_derivative, gradient.y * weight_derivative, sdf)

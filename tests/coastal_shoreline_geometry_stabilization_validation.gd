extends SceneTree
## Validación determinista de la envolvente geométrica near-shore.
## No crea una escena ni hace readback GPU: modela la misma curva en metros para
## medir continuidad, calidad de triángulos y sensibilidad al offset de rejilla.

const VERTICAL_RANGE_M := Vector2(0.25, 6.0)
const HORIZONTAL_RANGE_M := Vector2(0.75, 12.0)
const MIN_VALID_DEPTH_M := 0.25
const GRID_SPAN_M := 24.0
const RAW_DEEP_HEIGHT_M := 0.42
const RAW_DEEP_HORIZONTAL_M := 0.32

var _failures := 0


func _initialize() -> void:
	_validate_shader_contract()
	_validate_synthetic_cases()
	_validate_triangle_quality()
	_validate_paused_reproduction()
	_validate_camera_slide()
	if _failures == 0:
		print("COASTAL_SHORELINE_GEOMETRY_STABILIZATION: PASS")
		quit(0)
	else:
		push_error("COASTAL_SHORELINE_GEOMETRY_STABILIZATION: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	var surface := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var wireframe := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader")
	_check(surface.contains("shore_stabilization_weights_and_gradients"), "shader: vertex world-space envelope and gradients")
	_check(surface.contains("shore_weight_gradient_from_fragment"), "shader: pixel normal product-rule gradient")
	_check(surface.contains("shore_pre_envelope_height"), "shader: final envelope keeps pre-envelope height")
	_check(wireframe.contains("shore_stabilization_weights"), "wireframe: same world-space envelope")
	_check(surface.contains("displacement.xz *= shore_horizontal_weight_varying") and surface.contains("displacement.y *= shore_vertical_weight_varying"), "shader: horizontal and vertical geometry channels")


func _validate_synthetic_cases() -> void:
	var cases := ["flat_deep", "smooth_ramp", "steep_cliff", "narrow_channel", "island", "near_vertical_wall"]
	for case_name in cases:
		var continuity := _continuity_metrics(case_name)
		print("SHORE CASE=%s depth_range=[%.4f,%.4f] weight_jump_v=%.6f weight_jump_h=%.6f height_jump=%.6f xz_jump=%.6f" % [
			case_name, continuity.depth_min, continuity.depth_max,
			continuity.vertical_jump, continuity.horizontal_jump,
			continuity.height_jump, continuity.xz_jump])
		_check(continuity.non_finite == 0, "%s: sin NaN/Inf" % case_name)
		_check(continuity.vertical_min >= -1.0e-6 and continuity.vertical_max <= 1.0 + 1.0e-6, "%s: vertical weight acotado" % case_name)
		_check(continuity.horizontal_min >= -1.0e-6 and continuity.horizontal_max <= 1.0 + 1.0e-6, "%s: horizontal weight acotado" % case_name)
		_check(continuity.deep_identity_error < 1.0e-6, "%s: deep water identity" % case_name)
		_check(continuity.horizontal_jump <= continuity.vertical_jump + 0.12, "%s: horizontal transition no es más abrupta que vertical" % case_name)
		_check(continuity.height_jump < 0.55 and continuity.xz_jump < 0.55, "%s: continuidad por muestra" % case_name)


func _validate_triangle_quality() -> void:
	var aggregate_before := {"max_edge": 0.0, "min_area": INF, "flips": 0, "max_slope": 0.0}
	var aggregate_after := {"max_edge": 0.0, "min_area": INF, "flips": 0, "max_slope": 0.0}
	for spacing in [0.25, 0.5, 1.0]:
		for case_name in ["smooth_ramp", "steep_cliff", "narrow_channel", "island", "near_vertical_wall"]:
			var before: Dictionary = _triangle_metrics(case_name, spacing, false)
			var after: Dictionary = _triangle_metrics(case_name, spacing, true)
			print("TRI case=%s spacing=%.2f before(edge=%.5f area=%.6f flips=%d slope=%.5f) after(edge=%.5f area=%.6f flips=%d slope=%.5f)" % [
				case_name, spacing, before.max_edge, before.min_area, before.flips, before.max_slope,
				after.max_edge, after.min_area, after.flips, after.max_slope])
			_merge_triangle_metrics(aggregate_before, before)
			_merge_triangle_metrics(aggregate_after, after)
	print("TRI AGGREGATE before(edge=%.5f area=%.6f flips=%d slope=%.5f) after(edge=%.5f area=%.6f flips=%d slope=%.5f)" % [
		aggregate_before.max_edge, aggregate_before.min_area, aggregate_before.flips, aggregate_before.max_slope,
		aggregate_after.max_edge, aggregate_after.min_area, aggregate_after.flips, aggregate_after.max_slope])
	_check(aggregate_after.flips == 0, "triangles: envelope no produce flipped triangles")
	_check(aggregate_after.max_edge <= aggregate_before.max_edge + 1.0e-5, "triangles: envelope no aumenta max edge stretch")
	_check(aggregate_after.min_area > 0.0, "triangles: área positiva después")


func _validate_camera_slide() -> void:
	var world_point := Vector2(-18.40, 0.0)
	var spacing := 0.5
	var before_values: Array[Vector3] = []
	var after_values: Array[Vector3] = []
	for offset in [0.00, 0.05, 0.10, 0.15, 0.20, 0.25]:
		before_values.append(_grid_interpolated_surface("smooth_ramp", world_point, spacing, Vector2(offset, 0.0), false))
		after_values.append(_grid_interpolated_surface("smooth_ramp", world_point, spacing, Vector2(offset, 0.0), true))
	var before_error := _range_of_vectors(before_values)
	var after_error := _range_of_vectors(after_values)
	print("CAMERA SLIDE paused_model offsets=[0,.05,.10,.15,.20,.25] before=%.7f after=%.7f reduction=%.2fx" % [before_error, after_error, before_error / max(after_error, 1.0e-7)])
	_check(after_error < before_error, "camera slide: envelope reduces fixed-world interpolation variation")


func _validate_paused_reproduction() -> void:
	var world_point := Vector2(-18.40, 0.0)
	print("PAUSED REPRO seed=shore_synthetic_01 coastal=OFF/ON modes=FULL/HEIGHT_ONLY")
	for offset in [0.00, 0.10, 0.25, 1.00]:
		var coastal_off_full := _grid_interpolated_surface("smooth_ramp", world_point, 0.5, Vector2(offset, 0.0), false, false)
		var coastal_on_full := _grid_interpolated_surface("smooth_ramp", world_point, 0.5, Vector2(offset, 0.0), true, false)
		var coastal_on_height := _grid_interpolated_surface("smooth_ramp", world_point, 0.5, Vector2(offset, 0.0), true, true)
		print("PAUSED offset=%.2f OFF_FULL=(%.5f,%.5f,%.5f) ON_FULL=(%.5f,%.5f,%.5f) ON_HEIGHT=(%.5f,%.5f,%.5f)" % [
			offset,
			coastal_off_full.x, coastal_off_full.y, coastal_off_full.z,
			coastal_on_full.x, coastal_on_full.y, coastal_on_full.z,
			coastal_on_height.x, coastal_on_height.y, coastal_on_height.z])


func _continuity_metrics(case_name: String) -> Dictionary:
	var result := {
		"depth_min": INF, "depth_max": -INF,
		"vertical_min": INF, "vertical_max": -INF,
		"horizontal_min": INF, "horizontal_max": -INF,
		"vertical_jump": 0.0, "horizontal_jump": 0.0,
		"height_jump": 0.0, "xz_jump": 0.0,
		"deep_identity_error": 0.0, "non_finite": 0,
	}
	var previous_weights := Vector2.ZERO
	var previous_surface := Vector3.ZERO
	var previous_valid := false
	for sample_index in range(161):
		var x := -20.0 + float(sample_index) * 0.25
		var point := Vector2(x, 0.0)
		var depth := _depth(case_name, point)
		var weights := _shore_weights(depth)
		var raw := _raw_displacement(point, depth)
		var stabilized := _apply_envelope(raw, weights)
		result.depth_min = minf(result.depth_min, depth)
		result.depth_max = maxf(result.depth_max, depth)
		result.vertical_min = minf(result.vertical_min, weights.x)
		result.vertical_max = maxf(result.vertical_max, weights.x)
		result.horizontal_min = minf(result.horizontal_min, weights.y)
		result.horizontal_max = maxf(result.horizontal_max, weights.y)
		result.deep_identity_error = maxf(result.deep_identity_error, _deep_identity_error(depth, weights))
		if not is_finite(depth) or not is_finite(weights.x) or not is_finite(weights.y) or not is_finite(stabilized.x) or not is_finite(stabilized.y) or not is_finite(stabilized.z):
			result.non_finite += 1
		if previous_valid:
			result.vertical_jump = maxf(result.vertical_jump, absf(weights.x - previous_weights.x))
			result.horizontal_jump = maxf(result.horizontal_jump, absf(weights.y - previous_weights.y))
			result.height_jump = maxf(result.height_jump, absf(stabilized.y - previous_surface.y))
			result.xz_jump = maxf(result.xz_jump, Vector2(stabilized.x - previous_surface.x, stabilized.z - previous_surface.z).length())
		previous_weights = weights
		previous_surface = stabilized
		previous_valid = true
	return result


func _triangle_metrics(case_name: String, spacing: float, stabilized: bool) -> Dictionary:
	var result := {"max_edge": 0.0, "min_area": INF, "flips": 0, "max_slope": 0.0}
	var cells := int(roundi(GRID_SPAN_M / spacing))
	for iz in range(cells):
		for ix in range(cells):
			var p00 := Vector2(-GRID_SPAN_M * 0.5 + float(ix) * spacing, -GRID_SPAN_M * 0.5 + float(iz) * spacing)
			var p10 := p00 + Vector2(spacing, 0.0)
			var p01 := p00 + Vector2(0.0, spacing)
			var p11 := p00 + Vector2(spacing, spacing)
			var v00 := _world_vertex(p00, case_name, stabilized)
			var v10 := _world_vertex(p10, case_name, stabilized)
			var v01 := _world_vertex(p01, case_name, stabilized)
			var v11 := _world_vertex(p11, case_name, stabilized)
			_measure_triangle(result, v00, v10, v01, spacing)
			_measure_triangle(result, v11, v01, v10, spacing)
	return result


func _measure_triangle(result: Dictionary, a: Vector3, b: Vector3, c: Vector3, spacing: float) -> void:
	var ab := b - a
	var bc := c - b
	var ca := a - c
	for edge in [ab, bc, ca]:
		result.max_edge = maxf(result.max_edge, edge.length() / spacing)
		result.max_slope = maxf(result.max_slope, absf(edge.y) / maxf(Vector2(edge.x, edge.z).length(), 1.0e-5))
	var area := ab.cross(c - a).length() * 0.5
	result.min_area = minf(result.min_area, area)
	if ab.cross(c - a).y >= 0.0:
		result.flips += 1


func _merge_triangle_metrics(target: Dictionary, source: Dictionary) -> void:
	target.max_edge = maxf(target.max_edge, source.max_edge)
	target.min_area = minf(target.min_area, source.min_area)
	target.flips += source.flips
	target.max_slope = maxf(target.max_slope, source.max_slope)


func _grid_interpolated_surface(case_name: String, world_point: Vector2, spacing: float, offset: Vector2, stabilized: bool, height_only := false) -> Vector3:
	var grid := (world_point - offset) / spacing
	var ix := floori(grid.x)
	var iz := floori(grid.y)
	var fraction := Vector2(grid.x - float(ix), grid.y - float(iz))
	var base := offset + Vector2(float(ix), float(iz)) * spacing
	var p00 := _world_vertex(base, case_name, stabilized, height_only)
	var p10 := _world_vertex(base + Vector2(spacing, 0.0), case_name, stabilized, height_only)
	var p01 := _world_vertex(base + Vector2(0.0, spacing), case_name, stabilized, height_only)
	var p11 := _world_vertex(base + Vector2(spacing, spacing), case_name, stabilized, height_only)
	return p00.lerp(p10, fraction.x).lerp(p01.lerp(p11, fraction.x), fraction.y)


func _range_of_vectors(values: Array[Vector3]) -> float:
	var result := 0.0
	for first in values:
		for second in values:
			result = maxf(result, first.distance_to(second))
	return result


func _world_vertex(point: Vector2, case_name: String, stabilized: bool, height_only := false) -> Vector3:
	var displacement := _raw_displacement(point, _depth(case_name, point))
	if height_only:
		displacement.x = 0.0
		displacement.z = 0.0
	if stabilized:
		displacement = _apply_envelope(displacement, _shore_weights(_depth(case_name, point)))
	return Vector3(point.x + displacement.x, displacement.y, point.y + displacement.z)


func _apply_envelope(displacement: Vector3, weights: Vector2) -> Vector3:
	return Vector3(displacement.x * weights.y, displacement.y * weights.x, displacement.z * weights.y)


func _raw_displacement(point: Vector2, depth: float) -> Vector3:
	var shallow := 1.0 - _shore_weights(depth).x
	var phase := point.x * 0.52 + point.y * 0.17
	return Vector3(
		(RAW_DEEP_HORIZONTAL_M + 2.25 * shallow) * cos(phase),
		(RAW_DEEP_HEIGHT_M + 1.65 * shallow) * sin(phase),
		(0.22 + 1.30 * shallow) * cos(point.y * 0.37 - point.x * 0.13))


func _shore_weights(depth_m: float) -> Vector2:
	var depth := maxf(depth_m, 0.0)
	var water_presence := _smoothstep(0.0, maxf(MIN_VALID_DEPTH_M, 0.001), depth)
	var vertical := water_presence * _smoothstep(VERTICAL_RANGE_M.x, VERTICAL_RANGE_M.y, depth)
	var horizontal := water_presence * _smoothstep(HORIZONTAL_RANGE_M.x, HORIZONTAL_RANGE_M.y, depth)
	return Vector2(vertical, horizontal)


func _deep_identity_error(depth: float, weights: Vector2) -> float:
	if depth < HORIZONTAL_RANGE_M.y:
		return 0.0
	return maxf(absf(weights.x - 1.0), absf(weights.y - 1.0))


func _depth(case_name: String, point: Vector2) -> float:
	match case_name:
		"flat_deep":
			return 20.0
		"smooth_ramp":
			return clampf((point.x + 20.0) * 0.75, -1.0, 20.0)
		"steep_cliff":
			return 0.1 + 19.5 * _smoothstep(-1.0, 1.0, point.x * 3.0)
		"narrow_channel":
			return 1.0 + 16.0 * _smoothstep(2.0, 6.0, absf(point.y))
		"island":
			var radius := point.length()
			return -1.0 + 18.0 * _smoothstep(5.0, 9.0, radius)
		"near_vertical_wall":
			return 0.1 + 19.5 * _smoothstep(-1.0, 1.0, point.x * 8.0)
	return 20.0


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var denominator := maxf(edge1 - edge0, 1.0e-6)
	var t := clampf((value - edge0) / denominator, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _check(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("SHORELINE TEST: %s" % label)

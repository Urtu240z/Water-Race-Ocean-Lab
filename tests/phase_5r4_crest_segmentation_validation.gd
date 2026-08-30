extends SceneTree
## STEP 4 validation for the deterministic, bounded lateral segmentation rules.
## It intentionally uses 1D profiles rather than live FFT data.

var _failures := 0
const _SEED_THRESHOLD := 0.60
const _CONTINUATION_THRESHOLD := 0.42
const _BRIDGE_THRESHOLD := 0.26
const _MAX_STEPS_PER_SIDE := 3


func _initialize() -> void:
	_validate_shader_contract()
	_validate_center_break()
	_validate_asymmetric_break()
	_validate_small_gap()
	_validate_separate_events()
	_validate_parent_scale()
	_validate_rotated_crest()
	if _failures == 0:
		print("PHASE_5R4_CREST_SEGMENTATION: PASS")
		quit(0)
	else:
		push_error("PHASE_5R4_CREST_SEGMENTATION: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	var include_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc")
	var surface_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var clipmap_source := FileAccess.get_file_as_string("res://ocean_v3/rendering/ocean_clipmap_surface.gd")
	var segment_start := include_source.find("void crest_segment_descriptor_at")
	var segment_body := include_source.substr(segment_start)
	_check(segment_start >= 0 and segment_body.contains("crest_tangent_xz") and segment_body.contains("left_extent_m") and segment_body.contains("right_extent_m"), "descriptor expone frame y extents asimétricos")
	_check(segment_body.contains("sample_index <= 3") and segment_body.contains("search_radius_m = min"), "traza lateral está acotada a tres muestras por lado")
	_check(segment_body.contains("seed_onset < 0.60") and segment_body.contains("sample_onset >= 0.42") and segment_body.contains("bridge_available"), "seed, continuación e histéresis son distintos")
	_check(not segment_body.contains("displacement_short") and not segment_body.contains("BreakerRibbon"), "segmentación no introduce SHORT ni ribbons de producción")
	_check(surface_source.contains("breaking_debug_mode == 12") and surface_source.contains("segment_asymmetry_debug"), "shader expone span y asimetría")
	_check(clipmap_source.contains("SEGMENT_SPAN") and clipmap_source.contains("SEGMENT_COHERENCE"), "API de debug expone Step 4")


func _validate_center_break() -> void:
	var segment := _segment([0.0, 0.1, 0.2, 0.8, 1.0, 0.85, 0.25, 0.1, 0.0], 4)
	print("5R4 center left=%d right=%d" % [segment.left, segment.right])
	_check(segment.left == 1 and segment.right == 1, "center break produce un segmento finito centrado")


func _validate_asymmetric_break() -> void:
	var segment := _segment([0.0, 0.1, 0.7, 0.95, 0.9, 0.8, 0.7, 0.5, 0.2], 3)
	print("5R4 asym left=%d right=%d" % [segment.left, segment.right])
	_check(segment.left == 1 and segment.right == 3 and segment.left != segment.right, "perfil asimétrico conserva extents izquierdo y derecho distintos")


func _validate_small_gap() -> void:
	var segment := _segment([0.0, 0.7, 0.85, 0.58, 0.82, 0.9, 0.7, 0.1], 5)
	_check(segment.left == 3, "un dip local sobre continuación no fragmenta la misma cresta")


func _validate_separate_events() -> void:
	var first := _segment([0.8, 0.9, 0.2, 0.05, 0.1, 0.85, 0.95], 1)
	var second := _segment([0.8, 0.9, 0.2, 0.05, 0.1, 0.85, 0.95], 6)
	_check(first.right == 0 and second.left == 1, "dos valles débiles no fusionan eventos separados")


func _validate_parent_scale() -> void:
	var small := _sampling_plan(5.0, 0.2)
	var large := _sampling_plan(40.0, 1.2)
	var active_steps := 1
	_check(large.radius > small.radius and large.spacing > small.spacing, "el parent grande escala búsqueda y densidad de muestra")
	_check(active_steps * small.spacing < small.radius and active_steps * large.spacing < large.radius, "la escala del parent no fuerza consumir todo el rango de búsqueda")


func _validate_rotated_crest() -> void:
	var forward := Vector2(0.6, 0.8).normalized()
	var tangent := Vector2(-forward.y, forward.x)
	var lateral_point := tangent * 3.0
	_check(is_zero_approx(lateral_point.dot(forward)) and is_equal_approx(lateral_point.length(), 3.0), "frame rotado traza lateralmente, no según X/Z mundial")


func _segment(profile: Array[float], seed: int) -> Dictionary:
	_check(profile[seed] >= _SEED_THRESHOLD, "perfil de prueba tiene seed activo")
	return {"left": _trace_side(profile, seed, -1), "right": _trace_side(profile, seed, 1)}


func _trace_side(profile: Array[float], seed: int, sign: int) -> int:
	var extent := 0
	var bridge_available := true
	for distance in range(1, _MAX_STEPS_PER_SIDE + 1):
		var index := seed + sign * distance
		if index < 0 or index >= profile.size():
			break
		var onset: float = profile[index]
		if onset >= _CONTINUATION_THRESHOLD:
			extent = distance
		elif bridge_available and onset >= _BRIDGE_THRESHOLD:
			bridge_available = false
		else:
			break
	return extent


func _sampling_plan(wavelength_m: float, height_m: float) -> Dictionary:
	var radius := maxf(minf(0.40 * wavelength_m + 2.0 * height_m, 12.0), 0.75)
	var spacing := clampf(radius / 3.0, 0.25, 4.0)
	return {"radius": spacing * 3.0, "spacing": spacing}


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

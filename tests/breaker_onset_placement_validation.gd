extends SceneTree
## Validación aislada del onset/corredor: no requiere GPU ni assets Paradise.

const PropagationDataScript := preload("res://ocean_v3/coastal/coastal_propagation_data.gd")

var _failures := 0


func _process(_delta: float) -> bool:
	var pool_script: GDScript = load("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	var pool = pool_script.new()
	root.add_child(pool)
	var gentle = _build_ramp(128, 3, 0.08)
	pool._propagation = gentle
	var gentle_medium: Array[Dictionary] = pool._place_anchors_for_energy(0.75, 0.5)
	var gentle_large: Array[Dictionary] = pool._place_anchors_for_energy(1.0, 0.5)
	_check(gentle_medium.size() > 0 and gentle_large.size() > 0, "gentle beach: corredor surf válido")
	if gentle_medium.size() > 0 and gentle_large.size() > 0:
		_check(float(gentle_large[0]["xz"].x) > float(gentle_medium[0]["xz"].x), "Hs grande: onset más offshore")
		_check(float(gentle_large[0]["available_corridor_length_m"]) >= float(gentle_large[0]["required_development_distance_m"]), "available >= required development")
		_check(float(gentle_large[0]["spawn_pressure"]) >= pool.anchor_min_depth_pressure, "spawn permanece prebreak")
		_check(float(gentle_large[0]["spawn_shore_vertical_weight"]) >= pool.CORRIDOR_SPAWN_VERTICAL_WEIGHT_MIN, "spawn conserva autoridad FFT vertical")
	var cliff = _build_cliff(128, 3)
	pool._propagation = cliff
	var cliff_candidate := {"xz": Vector2(110.0, 1.0), "direction": Vector2.RIGHT, "wavelength_m": 16.0, "phase_speed_mps": 5.0, "shoaling": 1.0, "depth_m": 20.0}
	var cliff_corridor: Dictionary = pool._evaluate_breaking_corridor(cliff_candidate, 1.0, 0.5)
	_check(not bool(cliff_corridor.get("surf_corridor_eligible", false)), "cliff: NO_SURF_CORRIDOR")
	_check(str(cliff_corridor.get("corridor_reason", "")).begins_with("NO_"), "cliff: razón explícita")
	var partial: Dictionary = pool._find_valid_crest_run(PackedByteArray([1, 1, 0, 1, 1, 1, 1]))
	_check(int(partial.get("start", -1)) == 3 and int(partial.get("end", -1)) == 6, "stencil parcial: no cruza muestra inválida")
	_check(pool.CORRIDOR_SAMPLE_COUNT == 16, "corredor: 16 muestras CPU deterministas")
	print("BREAKER_ONSET_PLACEMENT: gentle_medium=%d gentle_large=%d cliff=%s corridor_evals=%d elapsed_ms=%.3f" % [gentle_medium.size(), gentle_large.size(), str(cliff_corridor.get("corridor_reason", "")), pool._corridor_evaluation_count, float(pool._corridor_evaluation_usec) * 0.001])
	pool.queue_free()
	if _failures == 0:
		print("BREAKER_ONSET_PLACEMENT: PASS")
		quit(0)
	else:
		push_error("BREAKER_ONSET_PLACEMENT: %d fallos" % _failures)
		quit(1)
	return false


func _build_ramp(width: int, height: int, slope: float):
	var data = PropagationDataScript.new()
	data.world_origin_xz = Vector2.ZERO
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
	data.k0_rad_m = 0.392699
	data.omega_ref_rad_s = 1.962
	data.incoming_direction_xz = Vector2.RIGHT
	data.min_valid_depth_m = 0.25
	var count := width * height
	for field in ["depth_m", "local_k", "wavelength_m", "phase_speed_mps", "group_velocity_mps", "shoaling_scale", "phase_offset_rad", "phase_rad", "phase_gradient_x", "phase_gradient_z", "local_direction_x", "local_direction_z", "render_direction_x", "render_direction_z"]:
		data.set(field, PackedFloat32Array())
		data.get(field).resize(count)
	data.valid_mask.resize(count)
	data.reached_mask.resize(count)
	for z in height:
		for x in width:
			var index := z * width + x
			data.depth_m[index] = 0.35 + float(x) * slope
			data.local_k[index] = data.k0_rad_m
			data.wavelength_m[index] = TAU / data.k0_rad_m
			data.phase_speed_mps[index] = data.omega_ref_rad_s / data.k0_rad_m
			data.group_velocity_mps[index] = data.phase_speed_mps[index]
			data.shoaling_scale[index] = 1.0
			data.valid_mask[index] = 1
			data.reached_mask[index] = 1
			data.local_direction_x[index] = -1.0
			data.render_direction_x[index] = 1.0
	return data


func _build_cliff(width: int, height: int):
	var data = _build_ramp(width, height, 0.0)
	for z in height:
		for x in width:
			var index := z * width + x
			data.depth_m[index] = 20.0 if x < 120 else 0.30
	return data


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

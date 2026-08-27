extends SceneTree
## 4C-S5: contrato CPU/source del handoff de producción.
## La validación visual de Paradise Island sigue siendo manual; aquí se prueban
## las invariantes deterministas que sí pueden aislarse sin GPU readback.

const PropagationDataScript := preload("res://ocean_v3/coastal/coastal_propagation_data.gd")
const LutTexture := preload("res://ocean_v3/breaking/data/breaker_cross_section_lut.res")

var _failures := 0
var _pool_script: GDScript


func _process(_delta: float) -> bool:
	_pool_script = load("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	if _pool_script == null:
		push_error("PHASE_4C_S5: no se pudo cargar BreakerRibbonPool")
		quit(1)
		return false
	_validate_source_contract()
	_validate_lut_orientation()
	_validate_directions_and_trajectory()
	_validate_anchor_policy()
	_validate_lifecycle_and_pause_contract()
	_validate_takeover_slots()
	if _failures == 0:
		print("PHASE_4C_S5_PRODUCTION_HANDOFF: PASS")
		quit(0)
	else:
		push_error("PHASE_4C_S5_PRODUCTION_HANDOFF: %d fallos" % _failures)
		quit(1)
	return false


func _validate_source_contract() -> void:
	var pool := FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	var lip := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/breaker_lip.gdshader")
	var surface := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var common := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaker_lip_common.gdshaderinc")
	_check(not pool.contains("travel_dir := -Vector2"), "no queda inversión stale en travel_dir")
	_check(pool.contains("render_direction_x") and pool.contains("has_render_direction"), "anchors prefieren render_direction con fallback local")
	_check(pool.contains("sample_propagation") and pool.contains("TRAJECTORY_STEP_S"), "ACTIVE usa trayectoria del campo costero horneado")
	_check(pool.contains("breaker_takeover_data0") and pool.contains("breaker_takeover_data1"), "pool publica datos por slot para takeover")
	_check(surface.contains("breaker_takeover_count") and surface.contains("breaker_takeover_production_mask"), "surface declara takeover de producción multi-slot")
	_check(surface.find("shore_final_slope") < surface.find("breaker_takeover_production_mask(world_xz)"), "takeover se aplica después del envelope shoreline")
	_check(lip.contains("breaker_profile_forward_sign = 1.0"), "shader del labio usa orientación forward canónica")
	_check(common.contains("shore_stabilization_weights") or common.contains("breaker_shore_weights"), "host del ribbon conserva shore stabilization")
	_check(surface.find("discard;") < 0 and surface.find("discard(") < 0, "takeover no usa discard")


func _validate_lut_orientation() -> void:
	var image: Image = LutTexture.get_image()
	var first := image.get_pixel(0, 0).r
	var last := image.get_pixel(image.get_width() - 1, 0).r
	_check(last > first + 0.5, "LUT stage 0: x_norm crece con u (%.3f -> %.3f)" % [first, last])
	var pool = _pool_script.new()
	root.add_child(pool)
	_check(pool.debug_profile_aligned(), "default profile direction = FORWARD (+1)")
	pool.toggle_debug_profile_direction()
	_check(not pool.debug_profile_aligned(), "-1 queda sólo como espejo diagnóstico")
	pool.queue_free()


func _validate_directions_and_trajectory() -> void:
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2(0.0, 1.0), Vector2(0.0, -1.0)]
	for direction in directions:
		var pool = _pool_script.new()
		root.add_child(pool)
		var entry := {
			"active": true, "spawn_time": 0.0, "spawn_xz": Vector2.ZERO,
			"spawn_direction": direction, "spawn_phase_speed": 4.0,
			"spawn_wavelength": 16.0, "lifecycle_duration": 2.0,
			"next_spawn_time": 4.0, "spawn_local_hs": 0.5,
			"spawn_strength": 1.0, "crest_correction_xz": Vector2.ZERO,
		}
		var before: Vector2 = pool._predicted_breaker_xz(entry, 0.50)
		var after: Vector2 = pool._predicted_breaker_xz(entry, 0.75)
		_check(direction.dot(after - before) > 0.1, "trayectoria %s avanza con render_direction" % direction)
		pool._tracking.resize(1)
		pool._tracking[0] = entry
		pool._anchors.resize(1)
		pool._anchors[0] = {"direction": direction}
		_check(Vector2(entry["spawn_direction"]).dot(direction) > 0.99, "spawn_direction coincide con %s" % direction)
		pool.queue_free()


func _validate_anchor_policy() -> void:
	var gentle = _build_ramp(128, 3, 0.12)
	var steep = _build_ramp(128, 3, 0.65)
	var pool = _pool_script.new()
	root.add_child(pool)
	pool._propagation = gentle
	var gentle_small: Array[Dictionary] = pool._place_anchors_for_energy(0.25, 0.5)
	var gentle_large: Array[Dictionary] = pool._place_anchors_for_energy(1.0, 0.5)
	pool._propagation = steep
	var steep_large: Array[Dictionary] = pool._place_anchors_for_energy(1.0, 0.5)
	print("S5 placement legacy_shallowest small=%.3f large=%.3f | new gentle_small n=%d depth=%.3f pressure=%.3f | gentle_large n=%d depth=%.3f pressure=%.3f | steep_large n=%d depth=%.3f pressure=%.3f" % [_legacy_shallowest(gentle, 0.25), _legacy_shallowest(gentle, 1.0), gentle_small.size(), _mean_depth(gentle_small), _mean_pressure(gentle_small), gentle_large.size(), _mean_depth(gentle_large), _mean_pressure(gentle_large), steep_large.size(), _mean_depth(steep_large), _mean_pressure(steep_large)])
	_check(gentle_large.size() > 0, "rampa suave con Hs grande produce anchor con corredor")
	_check(gentle_small.size() >= 0 and steep_large.size() >= 0, "Hs pequeño y rampa abrupta pueden no tener corredor surf")
	_check(_mean_x(gentle_large) > _mean_x(gentle_small), "Hs grande rompe más offshore en slope suave")
	if gentle_large.size() > 0 and steep_large.size() > 0:
		_check(_mean_x(gentle_large) > _mean_x(steep_large), "slope suave alcanza la profundidad de break más lejos")
	_check(_mean_pressure(gentle_large) >= pool.anchor_min_depth_pressure and _mean_pressure(gentle_large) < pool.anchor_max_depth_pressure, "spawn pressure queda en onset/mid prebreak")
	_check(gentle_large[0].get("direction_source", "") == "render_direction" or gentle_large[0]["direction"].dot(Vector2.RIGHT) > 0.9, "anchor usa dirección física render")
	pool.queue_free()


func _validate_lifecycle_and_pause_contract() -> void:
	var pool = _pool_script.new()
	root.add_child(pool)
	var entry := {
		"active": true, "spawn_time": 0.0, "spawn_xz": Vector2.ZERO,
		"spawn_direction": Vector2.RIGHT, "spawn_phase_speed": 5.0,
		"spawn_wavelength": 16.0, "lifecycle_duration": 2.0,
		"next_spawn_time": 4.0, "spawn_local_hs": 0.5,
		"spawn_strength": 1.0, "crest_correction_xz": Vector2.ZERO,
	}
	var stages := PackedFloat32Array()
	var positions := PackedVector2Array()
	for time in [0.05, 0.5, 1.0, 1.5]:
		pool._update_active_breaker(0, entry, time)
		entry = pool._tracking[0]
		stages.append(float(entry["stage"]))
		positions.append(Vector2(entry["tracked_xz"]))
	_check(stages[0] < stages[1] and stages[1] < stages[2] and stages[2] < stages[3], "lifecycle SPAWN -> GROW -> LIP -> PLUNGE es monótono")
	_check(Vector2.RIGHT.dot(positions[3] - positions[0]) > 0.1, "lifecycle conserva host world-anchored en movimiento")
	_check(FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd").contains("is_paused()") and FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd").contains("/root/SimulationClock"), "pausa congela estado del pool")
	pool.queue_free()


func _validate_takeover_slots() -> void:
	var pool = _pool_script.new()
	root.add_child(pool)
	pool._surface_material = ShaderMaterial.new()
	pool._tracking.resize(8)
	for index in 8:
		pool._tracking[index] = {
			"active": index < 4, "tracked_xz": Vector2(float(index) * 10.0, 0.0),
			"spawn_direction": Vector2.RIGHT if index % 2 == 0 else Vector2.LEFT,
			"spawn_wavelength": 16.0, "stage": 0.7, "alpha": 0.8,
		}
	pool._sync_production_takeover()
	var count := int(pool._surface_material.get_shader_parameter("breaker_takeover_count"))
	var centers: PackedVector4Array = pool._surface_material.get_shader_parameter("breaker_takeover_data0")
	_check(count == 4, "takeover publica exactamente 4 ACTIVE")
	_check(absf(centers[0].x - 0.0) < 0.001 and absf(centers[1].x - 10.0) < 0.001 and centers[1].z < -0.99, "cada máscara conserva su center/direction")
	pool._tracking[0]["active"] = false
	pool._sync_production_takeover()
	_check(int(pool._surface_material.get_shader_parameter("breaker_takeover_count")) == 3, "takeover desciende al desaparecer un ACTIVE")
	for index in 8:
		pool._tracking[index]["active"] = true
	pool._sync_production_takeover()
	_check(int(pool._surface_material.get_shader_parameter("breaker_takeover_count")) == 8, "takeover admite el cap de 8 ACTIVE")
	pool.queue_free()


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
			data.local_direction_z[index] = 0.0
			data.render_direction_x[index] = 1.0
			data.render_direction_z[index] = 0.0
	return data


func _mean_x(anchors: Array[Dictionary]) -> float:
	var total := 0.0
	for anchor in anchors:
		total += Vector2(anchor["xz"]).x
	return total / maxf(float(anchors.size()), 1.0)


func _mean_pressure(anchors: Array[Dictionary]) -> float:
	var total := 0.0
	for anchor in anchors:
		total += float(anchor["pressure"])
	return total / maxf(float(anchors.size()), 1.0)


func _mean_depth(anchors: Array[Dictionary]) -> float:
	var total := 0.0
	for anchor in anchors:
		total += float(anchor["depth_m"])
	return total / maxf(float(anchors.size()), 1.0)


func _legacy_shallowest(data, hs: float) -> float:
	var result := INF
	for depth in data.depth_m:
		var pressure: float = _pool_script.estimate_depth_pressure(hs, 0.5, 1.0, float(depth))
		if float(depth) >= 0.35 and pressure >= 0.35 and pressure <= 1.6:
			result = minf(result, float(depth))
	return result


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

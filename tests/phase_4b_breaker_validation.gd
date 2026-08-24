extends SceneTree
## Phase 4B: valida el contrato del takeover de geometría local de breaker.
## Sin render ni readback: comprueba el contrato de shaders/inc, los mirrors CPU
## de edge/envelope y el comportamiento determinista del pool de slots.

const PoolScript := preload("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
const PropagationDataScript := preload("res://ocean_v3/coastal/coastal_propagation_data.gd")

var _failures := 0


func _initialize() -> void:
	_validate_shader_contract()
	_validate_lip_mirrors()
	_validate_pool_logic()
	if _failures == 0:
		print("PHASE_4B_BREAKER_GEOMETRY: PASS")
		quit(0)
	else:
		push_error("PHASE_4B_BREAKER_GEOMETRY: %d fallos" % _failures)
		quit(1)


func _validate_shader_contract() -> void:
	var inc := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaking_common.gdshaderinc")
	var lip_common := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_breaker_lip_common.gdshaderinc")
	var ribbon := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/breaker_lip.gdshader")
	var surface := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	var pool := FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd")

	_check(not inc.is_empty() and not lip_common.is_empty() and not ribbon.is_empty(), "inc, include del labio y shader existen")
	_check(ribbon.contains("ocean_breaking_common.gdshaderinc"), "breaker_lip comparte el detector vía include")
	_check(ribbon.contains("ocean_breaker_lip_common.gdshaderinc"), "breaker_lip incluye sus funciones específicas sin contaminar el clipmap")
	_check(surface.contains("ocean_breaking_common.gdshaderinc"), "el clipmap incluye el detector compartido")
	_check(not surface.contains("ocean_breaker_lip_common.gdshaderinc"), "el clipmap no incluye funciones específicas del ribbon")
	_check(lip_common.contains("surface_displacement_break") and lip_common.contains("surface_slope_break") and lip_common.contains("breaker_edge_fade") and lip_common.contains("breaker_envelope"), "el include del ribbon contiene sólo sus funciones específicas activas")
	_check(inc.contains("prebreak_indices_at") and inc.contains("long_height_at") and inc.contains("breaking_local_state_at"), "el inc expone el campo PREBREAK y el estado local")
	# El trigger (long_height_at / prebreak_indices_at) no debe tocar MID/SHORT;
	# las funciones de integración visual (surface_*) sí los usan, y eso es legal.
	var long_height_start := inc.find("float long_height_at")
	var local_state_start := inc.find("// 4B: estado escalar local")
	var long_height_body := inc.substr(long_height_start, local_state_start - long_height_start)
	_check(long_height_body.contains("displacement_long_coastal") and long_height_body.contains("displacement_long_remainder") and not long_height_body.contains("displacement_mid") and not long_height_body.contains("displacement_short"), "long_height_at samplea SÓLO LONG (COASTAL+REMAINDER): MID/SHORT no entran en el trigger")
	_check(ribbon.contains("instance uniform vec2 anchor_xz") and ribbon.contains("instance uniform vec2 direction_xz"), "cada slot declara anchor y dirección por instancia")
	_check(ribbon.contains("breaker_envelope(indices.w)"), "el takeover se origina del campo PREBREAK (LONG-only)")
	_check(not ribbon.contains("sample_water(") and not ribbon.contains("RenderingServer") and not ribbon.contains("get_image"), "breaker_lip no invoca OceanQuery ni readbacks")
	_check(not pool.contains("get_image") and not pool.contains("read_pixels") and not pool.contains("RenderingServer"), "el pool no hace readback GPU->CPU")

	# Los uniforms copiados desde el clipmap deben estar declarados en el shader
	# del labio (los declara el propio breaker_lip, no el inc).
	for uniform_name in PoolScript._UNIFORMS_TO_COPY:
		_check(ribbon.contains(String(uniform_name)), "uniform compartido declarado en breaker_lip: %s" % uniform_name)


func _validate_lip_mirrors() -> void:
	_check(PoolScript.breaker_envelope(0.0) == 0.0, "envolvente: prebreak 0 -> 0 (sin estado binario)")
	_check(PoolScript.breaker_envelope(0.5) > 0.99, "envolvente: prebreak alto -> 1")
	_check(PoolScript.breaker_envelope(0.1) < PoolScript.breaker_envelope(0.3), "envolvente: monótona creciente")

	var fade_center := PoolScript.edge_fade(0.545, 0.5)
	var fade_edge_u := PoolScript.edge_fade(0.005, 0.5)
	var fade_edge_v := PoolScript.edge_fade(0.5, 0.005)
	_check(fade_center > 0.95, "edge_fade: plena en el centro del ribetón")
	_check(fade_edge_u < 0.05 and fade_edge_v < 0.05, "edge_fade: 0 en los bordes (sin seams de recorte)")

	var pressure := PoolScript.estimate_depth_pressure(0.5, 0.5, 1.0, 1.0)
	_check(absf(pressure - 0.5 / (0.78 * 1.0)) < 0.001, "presión de profundidad: réplica del shader (H/(gamma*h))")


func _validate_pool_logic() -> void:
	var propagation = _build_bank_propagation(65, 49)
	var pool: BreakerRibbonPool = PoolScript.new()
	root.add_child(pool)
	pool.configure(propagation, null, 0.5, 0.5, 0.0, null)
	var count := pool.anchor_count()
	print("4B POOL anchors=%d (max=%d) spacing_min=%.1f" % [count, pool.max_breakers, pool.anchor_min_spacing_m])
	_check(count > 0, "banco con zona de pre-break genera anchors")
	_check(count <= pool.max_breakers, "nunca más slots que max_breakers")
	_check(_snapshots_equal(pool.anchor_snapshot(), pool.anchor_snapshot()), "mismo modelo/batimetría -> misma disposición (determinismo)")
	for anchor in pool.anchor_snapshot():
		var direction: Vector2 = anchor["direction"]
		_check(absf(direction.length() - 1.0) < 0.001, "dirección del slot normalizada")
		var depth: float = anchor["depth_m"]
		_check(depth >= 0.35, "slot fuera del umbral de profundidad mínima")
	var spacing_ok := true
	var anchors: Array = pool.anchor_snapshot()
	for i in anchors.size():
		for j in range(i + 1, anchors.size()):
			if (Vector2(anchors[i]["xz"]) - Vector2(anchors[j]["xz"])).length() < pool.anchor_min_spacing_m - 0.01:
				spacing_ok = false
	_check(spacing_ok, "separación mínima entre slots")

	pool.set_energy_model(0.05, 0.5)
	_check(pool.anchor_count() == 0, "Hs mínima -> sin zona de pre-break -> 0 slots (ningún breaker)")
	pool.set_energy_model(0.5, 0.5)
	_check(pool.anchor_count() > 0, "restaurar Hs -> vuelven los slots")
	pool.disable()
	_check(pool.anchor_count() == 0 and not pool.visible, "disable -> 0 slots y oculto (Coastal OFF / sin batimetría)")
	for child in pool.get_children():
		child.free()
	pool.free()


func _snapshots_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _build_bank_propagation(width: int, height: int):
	var data = PropagationDataScript.new()
	data.world_origin_xz = Vector2(-float(width) * 0.5, -float(height) * 0.5)
	data.width = width
	data.height = height
	data.cell_size_m = 1.0
	data.k0_rad_m = 0.392699
	data.omega_ref_rad_s = 1.962
	data.incoming_direction_xz = Vector2.RIGHT
	data.min_valid_depth_m = 0.25
	data.propagation_kind = 1
	var count := width * height
	data.depth_m.resize(count)
	data.local_k.resize(count)
	data.wavelength_m.resize(count)
	data.phase_speed_mps.resize(count)
	data.group_velocity_mps.resize(count)
	data.shoaling_scale.resize(count)
	data.phase_offset_rad.resize(count)
	data.valid_mask.resize(count)
	data.phase_rad.resize(count)
	data.phase_gradient_x.resize(count)
	data.phase_gradient_z.resize(count)
	data.local_direction_x.resize(count)
	data.local_direction_z.resize(count)
	data.reached_mask.resize(count)
	for z in height:
		for x in width:
			var index := z * width + x
			var world_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z))
			var bank_weight := exp(-(world_xz.x * world_xz.x / 900.0 + world_xz.y * world_xz.y / 1800.0))
			data.depth_m[index] = 18.0 - 17.5 * bank_weight
			data.local_k[index] = data.k0_rad_m
			data.wavelength_m[index] = TAU / data.k0_rad_m
			data.phase_speed_mps[index] = data.omega_ref_rad_s / data.k0_rad_m
			data.group_velocity_mps[index] = data.phase_speed_mps[index]
			data.shoaling_scale[index] = 1.0
			data.phase_offset_rad[index] = 0.0
			data.valid_mask[index] = 1
			data.phase_rad[index] = data.k0_rad_m * world_xz.x
			data.phase_gradient_x[index] = data.k0_rad_m
			data.phase_gradient_z[index] = 0.0
			data.local_direction_x[index] = 1.0
			data.local_direction_z[index] = 0.0
			data.reached_mask[index] = 1
	return data


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

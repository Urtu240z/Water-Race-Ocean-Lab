extends SceneTree
## Contrato aislado para la instrumentación runtime del detector de breakers.
## No consulta OceanQuery: comprueba que el HUD recibe los datos del mismo estado
## que decide el spawn y que FORCE SPAWN sólo omite el gate score/probability/roll.

var _failures := 0


var _ran := false


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run()
	return false


func _run() -> void:
	var pool_script: GDScript = load("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	if pool_script == null:
		_fail("no se pudo cargar BreakerRibbonPool")
		_quit()
		return
	var source := FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	_check(source.contains("enum DebugMode { LIP, TAKEOVER, REGION, FORCE_LIP, DETECTOR, OFF }"), "J incluye DETECTOR antes de OFF")
	_check(source.contains("_apply_detector_diagnostics"), "el detector persiste el desglose por slot")
	_check(source.contains("detector_gate_reason"), "el detector publica razón concreta de no-spawn")
	_check(source.contains("force_spawn_selected_slot"), "existe FORCE SPAWN aislado")
	var diagnostics_start := source.find("func _apply_detector_diagnostics")
	var diagnostics_end := source.find("\n\nfunc ", diagnostics_start + 1)
	var diagnostics_source := source.substr(diagnostics_start, diagnostics_end - diagnostics_start)
	_check(not diagnostics_source.contains("_call_breaker_heights") and not diagnostics_source.contains("_call_breaker_slopes"), "diagnóstico no añade una query")
	_check(source.contains("SPAWN_S_START_LAMBDA := -0.28") and source.contains("SPAWN_S_END_LAMBDA := -0.06"), "window de spawn sin tuning")
	_check(source.contains("SCORE_PRESSURE_WEIGHT := 0.45") and source.contains("SCORE_PROMINENCE_WEIGHT := 0.35") and source.contains("SCORE_STEEPNESS_WEIGHT := 0.20"), "pesos sin tuning")
	_check(source.contains("SPAWN_PROB_SOFT_LO := 0.30") and source.contains("SPAWN_PROB_SOFT_HI := 0.70"), "probabilidad sin tuning")
	_validate_force_spawn(pool_script)
	_quit()


func _validate_force_spawn(pool_script: GDScript) -> void:
	var pool = pool_script.new()
	root.add_child(pool)
	var direction := Vector2(0.0, 1.0)
	var anchor := {
		"xz": Vector2(10.0, 20.0),
		"direction": direction,
		"wavelength_m": 12.0,
		"phase_speed_mps": 4.0,
		"shoaling": 1.0,
		"depth_m": 4.0,
		"current_eligibility": 1.0,
		"zone_breaking_activity": 1.0,
	}
	var anchors: Array[Dictionary] = []
	anchors.append(anchor)
	pool.set("_anchors", anchors)
	var tracking_state: Array[Dictionary] = []
	tracking_state.append(pool.call("_base_state", {
		"detector_initialized": true,
		"candidate_s": -1.8,
		"candidate_s_lambda": -0.15,
		"wave_serial": 3,
		"final_score": 0.0,
		"probability": 0.0,
		"roll": 0.99,
	}))
	pool.set("_tracking", tracking_state)
	pool.set("_last_track_time", 1.0)
	pool.set_debug_slot(0)
	_check(pool.force_spawn_selected_slot(), "FORCE SPAWN acepta candidato real seleccionado")
	var tracking: Array = pool.get("_tracking")
	_check(bool(tracking[0].get("active", false)), "FORCE SPAWN deja active=1")
	_check(Vector2(tracking[0]["spawn_xz"]).is_equal_approx(Vector2(10.0, 18.2)), "FORCE SPAWN conserva posición candidate real")
	_check(Vector2(tracking[0]["spawn_direction"]).is_equal_approx(direction), "FORCE SPAWN conserva direction real")
	_check(is_equal_approx(float(tracking[0]["spawn_wavelength"]), 12.0), "FORCE SPAWN conserva wavelength real")
	_check(str(tracking[0]["detector_gate_reason"]) == "FORCE_SPAWN", "FORCE SPAWN queda marcado sólo como diagnóstico")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	push_error("BREAKER_DETECTOR_RUNTIME_DIAGNOSTICS: " + message)


func _quit() -> void:
	if _failures == 0:
		print("BREAKER_DETECTOR_RUNTIME_DIAGNOSTICS: PASS")
	else:
		print("BREAKER_DETECTOR_RUNTIME_DIAGNOSTICS: FAIL (%d)" % _failures)
	quit(1 if _failures > 0 else 0)

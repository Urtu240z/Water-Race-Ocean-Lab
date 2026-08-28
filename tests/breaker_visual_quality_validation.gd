extends SceneTree
## Validación source-level de la presentación visual del breaker de producción.
## No sustituye la inspección visual de Paradise Island; aísla los contratos que
## evitan que el pase visual introduzca cámara-espacio, discard o readbacks.

var _failures := 0


func _process(_delta: float) -> bool:
	var pool := FileAccess.get_file_as_string("res://ocean_v3/breaking/breaker_ribbon_pool.gd")
	var lip := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/breaker_lip.gdshader")
	var surface := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")

	_check(pool.contains("ribbon_width_m := 6.0"), "la huella visual usa anchura 6 m")
	_check(pool.contains("ribbon_length_lambda := 1.55"), "la huella visual usa 1.55 longitudes")
	_check(pool.contains("_profile_length_scale()"), "takeover y ribbon comparten escala de perfil")
	_check(pool.contains('"GROW"') and pool.contains('"LIP"') and pool.contains('"PLUNGE"') and pool.contains('"FADE"'), "lifecycle conserva las cinco lecturas visuales")

	_check(lip.contains("breaker_profile_height_hs = 2.35"), "el lip usa volumen vertical reforzado")
	_check(lip.contains("breaker_profile_length_scale = 0.82"), "el perfil cubre una longitud visible suficiente")
	_check(lip.contains("breaker_stage") and lip.contains("breaker_whitewater_color"), "whitewater recibe stage y color de producción")
	_check(lip.contains("float foam_mask") and lip.contains("smoothstep"), "whitewater es procedural y estable")
	_check(lip.find("discard;") < 0 and lip.find("discard(") < 0, "breaker lip no usa discard")
	_check(surface.contains("breaker_takeover_production_mask") and surface.contains("breaker_takeover_submerge_hs = 0.38"), "FFT comparte takeover suave con la huella")
	_check(surface.contains("smoothstep(0.06, 0.22, q)") and surface.contains("smoothstep(0.76, 1.12, lateral)"), "takeover tiene fades espaciales amplios")
	_check(surface.find("discard;") < 0 and surface.find("discard(") < 0, "surface takeover no usa discard")

	if _failures == 0:
		print("BREAKER_VISUAL_QUALITY: PASS")
		quit(0)
	else:
		push_error("BREAKER_VISUAL_QUALITY: %d fallos" % _failures)
		quit(1)
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

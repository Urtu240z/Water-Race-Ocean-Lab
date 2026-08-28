extends SceneTree
## Reflection Phase 1C: contratos source-level para shaping local de roughness.
## La inspección visual de la escena sigue siendo necesaria; este test evita
## convertir el highlight en color/emission o cambiar el SPECULAR físico.

var _failures := 0


func _process(_delta: float) -> bool:
	var shader := FileAccess.get_file_as_string("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_check(shader.contains("reflection_crest_specular_enabled"), "crest roughness shaping tiene toggle")
	_check(shader.contains("reflection_crest_roughness_gain") and shader.contains("reflection_crest_mask_gain"), "crest shaping expone controles mínimos")
	_check(shader.contains("reflection_crest_min_roughness_scale"), "crest shaping limita la caída de roughness")
	_check(shader.contains("reflection_crest_mask"), "la máscara viaja desde el vertex al fragment")
	_check(shader.contains("curv_long") and shader.contains("curv_mid"), "la máscara reutiliza convexidad LONG/MID")
	_check(shader.contains("unresolved_detail_metrics.x") and shader.contains("unresolved_detail_metrics.y"), "MID/SHORT fragmentan el soporte del highlight")
	_check(shader.contains("reflection_crest_shaped_roughness"), "roughness se modula en una función aislada")
	_check(shader.contains("max(reflection_min_roughness, base_roughness * roughness_scale)"), "roughness conserva el suelo físico existente")
	_check(shader.contains("const float WATER_SPECULAR_LEVEL = 0.356835") and shader.contains("WATER_SPECULAR_LEVEL * reflection_environment_specular_boost"), "SPECULAR conserva la base física y usa el boost artístico")
	_check(shader.find("EMISSION = vec3(0.0);") >= 0, "el pase no usa emission para falsear el highlight")
	_check(shader.find("uniform sampler2D reflection_crest") < 0, "no añade texturas ni captures de reflexión")

	if _failures == 0:
		print("REFLECTION_CREST_SPECULAR: PASS")
		quit(0)
	else:
		push_error("REFLECTION_CREST_SPECULAR: %d fallos" % _failures)
		quit(1)
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

extends Node
## Registro pequeño para aislar futuros módulos durante los benchmarks.

signal module_state_changed(module_id: StringName, enabled: bool)

var _modules: Dictionary = {}


func register_module(module_id: StringName, enabled := true) -> void:
	_modules[module_id] = enabled
	module_state_changed.emit(module_id, enabled)


func unregister_module(module_id: StringName) -> void:
	_modules.erase(module_id)


func set_module_enabled(module_id: StringName, enabled: bool) -> void:
	if not _modules.has(module_id):
		push_warning("Módulo Ocean V3 no registrado: %s" % module_id)
		return
	if _modules[module_id] == enabled:
		return
	_modules[module_id] = enabled
	module_state_changed.emit(module_id, enabled)


func is_module_enabled(module_id: StringName) -> bool:
	return _modules.get(module_id, false)


func active_module_count() -> int:
	var active_count := 0
	for enabled in _modules.values():
		if enabled:
			active_count += 1
	return active_count


func module_states() -> Dictionary:
	return _modules.duplicate()

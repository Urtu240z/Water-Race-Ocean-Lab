extends Node
## Prueba mínima de arranque: si esto corre, el motor arranca con esta escena.

var _log_path := "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/minimal_boot_log.txt"


func _ready() -> void:
	var f := FileAccess.open(_log_path, FileAccess.WRITE)
	if f != null:
		f.store_line("MINIMAL_BOOT_READY")
		f.close()
		print("MINIMAL_BOOT_READY")
	else:
		print("MINIMAL_BOOT_LOG_OPEN_FAILED")
	get_tree().quit(0)


func _process(_delta: float) -> void:
	pass

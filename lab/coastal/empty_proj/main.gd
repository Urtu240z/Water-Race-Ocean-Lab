extends Node
func _ready():
	var f := FileAccess.open("C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/empty_proj_ran.txt", FileAccess.WRITE)
	if f != null:
		f.store_line("EMPTY_PROJ_READY")
		f.close()
	get_tree().quit(0)


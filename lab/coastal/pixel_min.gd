extends SceneTree
## MÃ­nimo: Â¿el SceneTree con ventana y D3D12 funciona en --script?


func _initialize() -> void:
	var f := FileAccess.open("C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/pixel_min_abs_log.txt", FileAccess.WRITE)
	f.store_line("initialize ok")
	f.close()
	_frames = 0


var _frames := 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		var f := FileAccess.open("C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/pixel_min_abs_log.txt", FileAccess.READ_WRITE)
		f.seek_end()
		f.store_line("process ok frames=10")
		f.close()
		quit(0)
	return false

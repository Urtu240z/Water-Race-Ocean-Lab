extends Node
## Compila el shader de superficie en el renderer REAL (D3D12) y escribe el
## resultado a archivo. Ejecutar como escena.

var _log_path := "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/shader_compile_log.txt"


func _ready() -> void:
	# Crear un ShaderMaterial con el shader de superficie para forzar la
	# compilaciÃ³n en el driver real.
	var material := ShaderMaterial.new()
	material.shader = load("res://ocean_v3/rendering/shaders/ocean_surface.gdshader")
	_log("shader cargado: " + str(material.shader != null))
	# Forzar a que el driver compile el shader aÃ±adiendo un mesh que lo use.
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	mesh_instance.mesh = box
	mesh_instance.material_override = material
	add_child(mesh_instance)
	# Esperar unos frames a que el shader se compile.
	_frames = 0


var _frames := 0


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 30:
		_log("frames=30, shader compilado sin crashear")
		var f := FileAccess.open(_log_path, FileAccess.WRITE)
		if f != null:
			f.store_line("DONE")
			f.close()
		get_tree().quit(0)


func _log(msg: String) -> void:
	var f := FileAccess.open(_log_path, FileAccess.WRITE)
	if f != null:
		f.store_line(msg)
		f.close()
	print(msg)


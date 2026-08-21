extends Node
## Compila los shaders COMPUTE del FFT en el renderer real y escribe resultado.

var _log_path := "C:/Users/ehort/Documents/GODOT PROJECTS/Water Race Ocean Lab/lab/coastal/fft_compile_log.txt"


func _ready() -> void:
	var f := FileAccess.open(_log_path, FileAccess.WRITE)
	var log := func(msg: String) -> void:
		if f != null: f.store_line(msg)
		print(msg)
	var rd := RenderingServer.get_rendering_device()
	log("rd=" + str(rd != null))
	if rd == null:
		if f != null: f.close()
		get_tree().quit(1)
		return
	for path in [
		"res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl",
		"res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl",
		"res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl",
	]:
		var sf: RDShaderFile = load(path)
		if sf == null:
			log(path + ": load null")
			continue
		var spirv = sf.get_spirv()
		if spirv == null or spirv.get_stages() == null or spirv.get_stages().size() == 0:
			log(path + ": spirv vacio")
			continue
		var rid := rd.shader_create_from_spirv(spirv, "FFT." + path.get_file())
		log(path + ": " + ("OK" if rid.is_valid() else "FALLO"))
		if rid.is_valid(): rd.free_rid(rid)
	if f != null: f.close()
	get_tree().quit(0)

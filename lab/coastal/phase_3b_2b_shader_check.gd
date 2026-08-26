extends SceneTree
## Diagnóstico: compilar los shaders del océano en el renderer real (D3D12) y
## reportar errores de compilación SPIR-V.

const SURFACE_SHADER := "res://ocean_v3/rendering/shaders/ocean_surface.gdshader"
const WIREFRAME_SHADER := "res://ocean_v3/rendering/shaders/ocean_wireframe.gdshader"
const EVOLVE_SHADER := "res://ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://ocean_v3/rendering/fft/shaders/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://ocean_v3/rendering/fft/shaders/assemble_maps.glsl"


func _initialize() -> void:
	var out := FileAccess.open("res://lab/coastal/shader_check_log.txt", FileAccess.WRITE)
	var write_log := func(msg: String) -> void:
		if out != null:
			out.store_line(msg)
		print(msg)
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		write_log.call("SHADER_CHECK: RenderingDevice null (headless)")
		if out != null: out.close()
		quit(1)
		return
	for path in [SURFACE_SHADER, WIREFRAME_SHADER, EVOLVE_SHADER, STOCKHAM_SHADER, ASSEMBLE_SHADER]:
		var shader_file: RDShaderFile = load(path)
		if shader_file == null:
			write_log.call("SHADER_CHECK " + path + ": no se pudo cargar")
			continue
		var spirv := shader_file.get_spirv()
		if spirv == null or spirv.get_stages() == null or spirv.get_stages().size() == 0:
			write_log.call("SHADER_CHECK " + path + ": SPIR-V vacío")
			continue
		var rid := rd.shader_create_from_spirv(spirv, "Check." + path.get_file())
		if rid.is_valid():
			write_log.call("SHADER_CHECK " + path + ": OK")
			rd.free_rid(rid)
		else:
			write_log.call("SHADER_CHECK " + path + ": FALLO compilación")
	if out != null: out.close()
	quit(0)

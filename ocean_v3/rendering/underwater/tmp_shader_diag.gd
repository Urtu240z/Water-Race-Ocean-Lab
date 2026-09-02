extends SceneTree

func _init() -> void:
	var shader_file := load("res://ocean_v3/rendering/underwater/underwater_medium.glsl") as RDShaderFile
	if shader_file == null:
		print("SHADER_FILE_NULL")
		quit(1)
	var spirv := shader_file.get_spirv()
	print("COMPUTE_ERROR=", spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
	quit()

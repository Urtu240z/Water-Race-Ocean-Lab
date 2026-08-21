extends SceneTree
## Captura de verificación de la demo 3B.2B: arranca la demo con el bake del
## warp, espera a que renderice, captura un frame a PNG (para inspección visual)
## y sale. NO modifica nada del render.

const OUT_PNG := "res://lab/coastal/phase_3b_2b_demo_capture.png"


func _initialize() -> void:
	var scene: PackedScene = load("res://lab/coastal/phase_3b_2b_fft_demo.tscn")
	var demo = scene.instantiate()
	root.add_child(demo)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_frames = 0


var _frames := 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 200:
		var img := root.get_texture().get_image()
		img.save_png(OUT_PNG)
		print("3B.2B CAPTURE guardado: ", OUT_PNG, " ", img.get_width(), "x", img.get_height())
		quit(0)
	return false

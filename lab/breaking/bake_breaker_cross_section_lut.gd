extends SceneTree
## Baker offline: hornea la cross-section aprobada del LAB a una LUT RGBA16F.
## Uso: godot --headless -s res://lab/breaking/bake_breaker_cross_section_lut.gd
##
## La LUT guarda la DEFORMACIÓN relativa a stage=0 (no la posición absoluta):
##   R = x_norm - x0_norm   (delta horizontal normalizado; overhang preservado)
##   G = y_delta / HEIGHT_REF
##   B = dR/du, A = dG/du   (derivadas para reconstruir la normal con overhang)
## stage 0 => R=G=0 exactamente (el ribbon queda sobre el FFT).

const CrossSection := preload("res://lab/breaking/breaker_cross_section.gd")

const WIDTH := 128
const HEIGHT := 64
const DST := "res://ocean_v3/breaking/data/breaker_cross_section_lut.res"


func _initialize() -> void:
	var r := PackedFloat32Array()
	var y_delta := PackedFloat32Array()
	r.resize(WIDTH * HEIGHT)
	y_delta.resize(WIDTH * HEIGHT)
	var max_abs_y := 0.0

	for j in HEIGHT:
		var stage := float(j) / float(HEIGHT - 1)
		var start0 := CrossSection.point(0.0, 0.0)
		var end0 := CrossSection.point(1.0, 0.0)
		var start_stage := CrossSection.point(0.0, stage)
		var end_stage := CrossSection.point(1.0, stage)
		var span0 := end0.x - start0.x
		var span_s := end_stage.x - start_stage.x
		for i in WIDTH:
			var u := float(i) / float(WIDTH - 1)
			var p0 := CrossSection.point(u, 0.0)
			var p := CrossSection.point(u, stage)
			var x0_norm := (p0.x - start0.x) / span0
			var x_norm := (p.x - start_stage.x) / span_s
			var idx := j * WIDTH + i
			r[idx] = x_norm - x0_norm
			y_delta[idx] = p.y - p0.y
			max_abs_y = maxf(max_abs_y, absf(y_delta[idx]))

	if max_abs_y < 1.0e-6:
		max_abs_y = 1.0

	var image := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBAH)
	for j in HEIGHT:
		for i in WIDTH:
			var idx := j * WIDTH + i
			var R := r[idx]
			var G := y_delta[idx] / max_abs_y
			var il := maxi(i - 1, 0)
			var ir := mini(i + 1, WIDTH - 1)
			var u_l := float(il) / float(WIDTH - 1)
			var u_r := float(ir) / float(WIDTH - 1)
			var du := u_r - u_l
			var dRdu := 0.0
			var dGdu := 0.0
			if du > 1.0e-9:
				dRdu = (r[j * WIDTH + ir] - r[j * WIDTH + il]) / du
				dGdu = ((y_delta[j * WIDTH + ir] - y_delta[j * WIDTH + il]) / max_abs_y) / du
			image.set_pixel(i, j, Color(R, G, dRdu, dGdu))

	var texture := ImageTexture.create_from_image(image)
	var err := ResourceSaver.save(texture, DST)
	if err == OK:
		print("BREAKER_CROSS_SECTION_LUT: saved %s (%dx%d RGBAH, HEIGHT_REF=%.4f)" % [DST, WIDTH, HEIGHT, max_abs_y])
		quit(0)
	else:
		push_error("BREAKER_CROSS_SECTION_LUT: error guardando (code %d)" % err)
		quit(1)

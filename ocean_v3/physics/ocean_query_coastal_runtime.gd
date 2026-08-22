class_name OceanQueryCoastalRuntime
extends RefCounted
## Runtime CPU inmutable de la corrección coastal 3B.3.
##
## Replica la semántica de muestreo del shader 3B.2B sobre q (coordenada
## paramétrica): bilinear para deep/det/J/shoaling y alpha de validez, sin
## Resource, Dictionary ni allocation por query. El caller lee los campos
## públicos inmediatamente después de sample().

var enabled := false
var origin_x := 0.0
var origin_z := 0.0
var width := 0
var height := 0
var cell_size := 1.0
var detj_safe_threshold := 0.5

var deep_x := PackedFloat32Array()
var deep_z := PackedFloat32Array()
var det_j := PackedFloat32Array()
var j00 := PackedFloat32Array()
var j01 := PackedFloat32Array()
var j10 := PackedFloat32Array()
var j11 := PackedFloat32Array()
var warp_valid := PackedByteArray()
var shoaling := PackedFloat32Array()
var propagation_valid := PackedByteArray()

# Resultado de la última muestra. Se reinicia a open ocean antes de cada query.
var deep_sample_x := 0.0
var deep_sample_z := 0.0
var confidence := 0.0
var effective_shoaling := 1.0
var sample_j00 := 1.0
var sample_j01 := 0.0
var sample_j10 := 0.0
var sample_j11 := 1.0


func configure(warp_data, propagation_data) -> bool:
	enabled = false
	if warp_data == null or propagation_data == null or not warp_data.is_valid() or not propagation_data.is_valid():
		return false
	if warp_data.width != propagation_data.width or warp_data.height != propagation_data.height \
			or not is_equal_approx(warp_data.cell_size_m, propagation_data.cell_size_m) \
			or warp_data.world_origin_xz != propagation_data.world_origin_xz:
		push_error("OceanQueryCoastalRuntime requiere grids warp/propagation idénticos.")
		return false
	origin_x = warp_data.world_origin_xz.x
	origin_z = warp_data.world_origin_xz.y
	width = warp_data.width
	height = warp_data.height
	cell_size = warp_data.cell_size_m
	detj_safe_threshold = warp_data.detj_safe_threshold
	deep_x = warp_data.deep_x
	deep_z = warp_data.deep_z
	det_j = warp_data.jacobian_det
	j00 = warp_data.jacobian_j00
	j01 = warp_data.jacobian_j01
	j10 = warp_data.jacobian_j10
	j11 = warp_data.jacobian_j11
	warp_valid = warp_data.valid_mask
	shoaling = propagation_data.shoaling_scale
	propagation_valid = propagation_data.valid_mask
	enabled = true
	return true


func clear() -> void:
	enabled = false


func sample(qx: float, qz: float) -> float:
	## Devuelve confidence; los demás resultados se exponen arriba. c==0 implica
	## exactamente open ocean y S_eff=1, igual que el shader de producción.
	deep_sample_x = qx
	deep_sample_z = qz
	confidence = 0.0
	effective_shoaling = 1.0
	sample_j00 = 1.0
	sample_j01 = 0.0
	sample_j10 = 0.0
	sample_j11 = 1.0
	if not enabled or width < 2 or height < 2 or cell_size <= 0.0:
		return 0.0
	var gx: float = (qx - origin_x) / cell_size
	var gz: float = (qz - origin_z) / cell_size
	if gx < 0.0 or gz < 0.0 or gx > float(width - 1) or gz > float(height - 1):
		return 0.0
	var x0: int = mini(int(floor(gx)), width - 2)
	var z0: int = mini(int(floor(gz)), height - 2)
	var tx: float = gx - float(x0)
	var tz: float = gz - float(z0)
	var i00: int = z0 * width + x0
	var i10: int = i00 + 1
	var i01: int = i00 + width
	var i11: int = i01 + 1
	# coast_active del shader: el alpha linear del field debe superar 0.5.
	var propagation_alpha: float = _bilinear_byte(propagation_valid, i00, i10, i01, i11, tx, tz)
	if propagation_alpha <= 0.5:
		return 0.0
	deep_sample_x = _bilinear(deep_x, i00, i10, i01, i11, tx, tz)
	deep_sample_z = _bilinear(deep_z, i00, i10, i01, i11, tx, tz)
	sample_j00 = _bilinear(j00, i00, i10, i01, i11, tx, tz)
	sample_j01 = _bilinear(j01, i00, i10, i01, i11, tx, tz)
	sample_j10 = _bilinear(j10, i00, i10, i01, i11, tx, tz)
	sample_j11 = _bilinear(j11, i00, i10, i01, i11, tx, tz)
	var sampled_det: float = _bilinear(det_j, i00, i10, i01, i11, tx, tz)
	var warp_alpha: float = _bilinear_byte(warp_valid, i00, i10, i01, i11, tx, tz)
	confidence = smoothstep(0.0, detj_safe_threshold, sampled_det) * warp_alpha
	if confidence <= 0.0:
		deep_sample_x = qx
		deep_sample_z = qz
		sample_j00 = 1.0
		sample_j01 = 0.0
		sample_j10 = 0.0
		sample_j11 = 1.0
		return 0.0
	effective_shoaling = lerpf(1.0, _bilinear(shoaling, i00, i10, i01, i11, tx, tz), confidence)
	return confidence


func _bilinear(values: PackedFloat32Array, i00: int, i10: int, i01: int, i11: int, tx: float, tz: float) -> float:
	return lerpf(lerpf(values[i00], values[i10], tx), lerpf(values[i01], values[i11], tx), tz)


func _bilinear_byte(values: PackedByteArray, i00: int, i10: int, i01: int, i11: int, tx: float, tz: float) -> float:
	return lerpf(lerpf(float(values[i00]), float(values[i10]), tx), lerpf(float(values[i01]), float(values[i11]), tx), tz)

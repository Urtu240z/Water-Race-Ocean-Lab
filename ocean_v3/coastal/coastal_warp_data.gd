class_name CoastalWarpData
extends Resource
## Fase 3B.2A: mapping 2D world_xz -> deep_xz (bake offline).
##
## Convenio (documentado en PHASE_3B_2A_WARP_NOTES.md):
##   d0 = incoming_direction_xz (unitario)
##   n0 = perpendicular(d0) = (-d0.y, d0.x)
##   s_deep = phi / k0            (coordenada longitudinal = fase/k0, Eikonal)
##   r_deep = dot(p_frontera_upstream, n0)   (etiqueta transversal del characteristic,
##                                            obtenida por BACKTRACE con -local_direction)
##   deep_xz = deep_origin_xz + d0 * s_deep + n0 * r_deep
##
## En fondo plano (profundidad uniforme) con deep_origin = d0 * min_s, el mapping
## es la IDENTIDAD salvo redondeo: deep_xz ~= world_xz.
##
## Jacobiano (diferencias finitas centrales sobre el campo deep_xz):
##   J = d(deep_xz)/d(world_xz);  detJ.
## Clasificación por nodo:
##   SAFE          detJ > threshold
##   NEAR_CAUSTIC  0 < detJ <= threshold
##   FOLDED        detJ <= 0
##   INVALID       warp no definido (tierra / shadow / backtrace fallido)
## NO se ocultan folds con clamp: se reportan explícitamente.

const SampleScript := preload("res://ocean_v3/coastal/coastal_warp_sample.gd")

enum JacobianClass { SAFE = 0, NEAR_CAUSTIC = 1, FOLDED = 2, INVALID = 3 }
enum BoundaryHit { NONE = 0, UPSTREAM = 1, LATERAL = 2, LAND_OR_SHADOW = 3, STEPS_EXCEEDED = 4 }

@export var world_origin_xz := Vector2.ZERO
@export var width := 0
@export var height := 0
@export var cell_size_m := 1.0
@export var incoming_direction_xz := Vector2.RIGHT
@export var deep_origin_xz := Vector2.ZERO
@export var k0_rad_m := 0.0
@export var omega_ref_rad_s := 0.0
@export var detj_safe_threshold := 0.5

@export_storage var deep_x := PackedFloat32Array()
@export_storage var deep_z := PackedFloat32Array()
@export_storage var jacobian_det := PackedFloat32Array()
@export_storage var valid_mask := PackedByteArray()
# Debug/inspección (no redundante: permiten validar continuidad y caustics).
@export_storage var r_deep := PackedFloat32Array()
@export_storage var backtrace_steps := PackedInt32Array()
@export_storage var boundary_hit := PackedByteArray()
@export_storage var jacobian_class := PackedByteArray()

var _warp_texture: ImageTexture


func is_valid() -> bool:
	var count := width * height
	return width >= 2 and height >= 2 and cell_size_m > 0.0 and k0_rad_m > 0.0 \
		and deep_x.size() == count and deep_z.size() == count and jacobian_det.size() == count \
		and valid_mask.size() == count and r_deep.size() == count and backtrace_steps.size() == count \
		and boundary_hit.size() == count and jacobian_class.size() == count


func world_max_xz() -> Vector2:
	return world_origin_xz + Vector2(float(width - 1), float(height - 1)) * cell_size_m


func approximate_memory_bytes() -> int:
	# 2 float32 (deep) + 1 float32 (detJ) + 1 float32 (r_deep) + 1 int32 (steps)
	# + 3 máscaras byte.
	return width * height * (4 * 4 + 1 * 4 + 3)


func sample_warp(world_xz: Vector2, reuse = null):
	var result = reuse if reuse != null else SampleScript.new()
	if width < 2 or height < 2 or cell_size_m <= 0.0:
		return result.set_invalid()
	var grid := (world_xz - world_origin_xz) / cell_size_m
	result.in_bounds = grid.x >= 0.0 and grid.y >= 0.0 and grid.x <= float(width - 1) and grid.y <= float(height - 1)
	grid.x = clampf(grid.x, 0.0, float(width - 1))
	grid.y = clampf(grid.y, 0.0, float(height - 1))
	var x0 := mini(int(floor(grid.x)), width - 2)
	var z0 := mini(int(floor(grid.y)), height - 2)
	var tx := grid.x - float(x0)
	var tz := grid.y - float(z0)
	var i00 := z0 * width + x0
	var i10 := i00 + 1
	var i01 := i00 + width
	var i11 := i01 + 1
	result.deep_xz = Vector2(_bilinear(deep_x, i00, i10, i01, i11, tx, tz), _bilinear(deep_z, i00, i10, i01, i11, tx, tz))
	result.jacobian_det = _bilinear(jacobian_det, i00, i10, i01, i11, tx, tz)
	result.r_deep = _bilinear(r_deep, i00, i10, i01, i11, tx, tz)
	var nearest := clampi(int(round(grid.y)), 0, height - 1) * width + clampi(int(round(grid.x)), 0, width - 1)
	result.valid = valid_mask[nearest] != 0
	result.jacobian_class = jacobian_class[nearest]
	return result


func shader_warp_confidence(world_xz: Vector2) -> float:
	## Réplica CPU del confidence del shader: detJ bilineal, alpha de valid
	## bilineal y cero fuera del rectángulo. Sólo para HUD/diagnóstico.
	if width < 2 or height < 2 or cell_size_m <= 0.0:
		return 0.0
	var grid := (world_xz - world_origin_xz) / cell_size_m
	if grid.x < 0.0 or grid.y < 0.0 or grid.x > float(width - 1) or grid.y > float(height - 1):
		return 0.0
	var x0 := mini(int(floor(grid.x)), width - 2)
	var z0 := mini(int(floor(grid.y)), height - 2)
	var tx := grid.x - float(x0)
	var tz := grid.y - float(z0)
	var i00 := z0 * width + x0
	var i10 := i00 + 1
	var i01 := i00 + width
	var i11 := i01 + 1
	var det_j := _bilinear(jacobian_det, i00, i10, i01, i11, tx, tz)
	var valid_alpha := lerpf(lerpf(float(valid_mask[i00]), float(valid_mask[i10]), tx), lerpf(float(valid_mask[i01]), float(valid_mask[i11]), tx), tz)
	return smoothstep(0.0, detj_safe_threshold, det_j) * valid_alpha


func build_gpu_textures() -> Dictionary:
	if not is_valid():
		return {}
	var values := PackedFloat32Array()
	values.resize(width * height * 4)
	for index in width * height:
		var base := index * 4
		values[base] = deep_x[index]
		values[base + 1] = deep_z[index]
		values[base + 2] = jacobian_det[index]
		values[base + 3] = 1.0 if valid_mask[index] != 0 else 0.0
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, values.to_byte_array())
	_warp_texture = ImageTexture.create_from_image(image)
	return {"warp": _warp_texture}


func _bilinear(values: PackedFloat32Array, i00: int, i10: int, i01: int, i11: int, tx: float, tz: float) -> float:
	return lerpf(lerpf(values[i00], values[i10], tx), lerpf(values[i01], values[i11], tx), tz)

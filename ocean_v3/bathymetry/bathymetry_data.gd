class_name BathymetryData
extends Resource
## Campo 2D world-space horneado. No conoce cámara, clipmap, LOD ni meshes.
## Convención: gradient = ∇depth, apunta hacia aumento de profundidad.
## width/height son nodos de muestra, incluido el borde: extent=(size-1)*cell.

const SampleScript := preload("res://ocean_v3/bathymetry/bathymetry_sample.gd")

@export var world_origin_xz := Vector2.ZERO
@export var width := 0
@export var height := 0
@export var cell_size_m := 1.0
@export var sea_level_y := 0.0
@export var optical_seabed_feather_m := 0.0

@export_storage var depth_m := PackedFloat32Array()
@export_storage var gradient_x := PackedFloat32Array()
@export_storage var gradient_z := PackedFloat32Array()
@export_storage var slope_magnitude := PackedFloat32Array()
@export_storage var land_water_mask := PackedByteArray() # 1 water, 0 land/shore.
@export_storage var shore_signed_distance_m := PackedFloat32Array() # water +, land -.
@export_storage var depth_source_mask := PackedByteArray() # 0 synthetic/open water, 1 measured from mesh.
@export_storage var real_seabed_coverage := PackedByteArray() # 1 = real geometry hit, 0 = no hit.
@export_storage var optical_seabed_confidence := PackedByteArray() # Interior erosion for Water Optics, 0..255.
# Reservado para coast type/material futuro; 0 = sin clasificar en Fase 3A.
@export_storage var coast_metadata := PackedByteArray()


func is_valid() -> bool:
	return width >= 2 and height >= 2 and cell_size_m > 0.0 and depth_m.size() == width * height and gradient_x.size() == depth_m.size() and gradient_z.size() == depth_m.size() and slope_magnitude.size() == depth_m.size() and land_water_mask.size() == depth_m.size()


func has_real_seabed_coverage() -> bool:
	return is_valid() and real_seabed_coverage.size() == cell_count() and optical_seabed_confidence.size() == cell_count()


func build_gpu_seabed_coverage_texture() -> Texture2D:
	if not has_real_seabed_coverage():
		return null
	var packed_values := PackedByteArray()
	packed_values.resize(cell_count() * 2)
	for index in cell_count():
		packed_values[index * 2] = real_seabed_coverage[index]
		packed_values[index * 2 + 1] = optical_seabed_confidence[index]
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RG8, packed_values)
	return ImageTexture.create_from_image(image)


func cell_count() -> int:
	return width * height


func world_max_xz() -> Vector2:
	return world_origin_xz + Vector2(float(width - 1), float(height - 1)) * cell_size_m


func approximate_memory_bytes() -> int:
	# depth, gradiente X/Z, slope y shore distance + cuatro máscaras/metadata.
	return cell_count() * (5 * 4 + 1 + 1 + 1 + 1 + 1)


func sample_bathymetry(world_xz: Vector2, reuse = null):
	var result = reuse if reuse != null else SampleScript.new()
	# Hot path: el baker valida tamaños al crear el Resource; aquí sólo se
	# comprueba la forma mínima para no recorrer metadata/arrays cada query.
	if width < 2 or height < 2 or cell_size_m <= 0.0:
		return result.set_flat()
	var grid := (world_xz - world_origin_xz) / cell_size_m
	result.in_bounds = grid.x >= 0.0 and grid.y >= 0.0 and grid.x <= float(width - 1) and grid.y <= float(height - 1)
	# Las queries fuera devuelven el borde clamped, pero lo marcan explícitamente.
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
	result.depth_m = lerpf(lerpf(depth_m[i00], depth_m[i10], tx), lerpf(depth_m[i01], depth_m[i11], tx), tz)
	result.gradient_x = lerpf(lerpf(gradient_x[i00], gradient_x[i10], tx), lerpf(gradient_x[i01], gradient_x[i11], tx), tz)
	result.gradient_z = lerpf(lerpf(gradient_z[i00], gradient_z[i10], tx), lerpf(gradient_z[i01], gradient_z[i11], tx), tz)
	result.slope_magnitude = lerpf(lerpf(slope_magnitude[i00], slope_magnitude[i10], tx), lerpf(slope_magnitude[i01], slope_magnitude[i11], tx), tz)
	result.slope = result.slope_magnitude
	if shore_signed_distance_m.size() == depth_m.size():
		result.shore_signed_distance_m = lerpf(lerpf(shore_signed_distance_m[i00], shore_signed_distance_m[i10], tx), lerpf(shore_signed_distance_m[i01], shore_signed_distance_m[i11], tx), tz)
	else:
		result.shore_signed_distance_m = 0.0
	# La máscara es nearest-node para no crear agua por interpolación sobre tierra.
	var nearest_x := clampi(int(round(grid.x)), 0, width - 1)
	var nearest_z := clampi(int(round(grid.y)), 0, height - 1)
	var nearest_index := nearest_z * width + nearest_x
	result.is_water = land_water_mask[nearest_index] != 0
	result.depth_is_measured = depth_source_mask.size() == depth_m.size() and depth_source_mask[nearest_index] != 0
	result.gradient = Vector2(result.gradient_x, result.gradient_z)
	return result


func depth_at_node(x: int, z: int) -> float:
	return depth_m[_index(x, z)]


func _index(x: int, z: int) -> int:
	return z * width + x

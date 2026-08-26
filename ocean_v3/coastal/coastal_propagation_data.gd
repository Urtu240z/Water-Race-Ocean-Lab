class_name CoastalPropagationData
extends Resource
## Transformación local, determinista y muestreable derivada de BathymetryData.
## Mantiene datos CPU y texturas GPU del mismo grid; no hace raycasts.

const SampleScript := preload("res://ocean_v3/coastal/coastal_propagation_sample.gd")

@export var world_origin_xz := Vector2.ZERO
@export var width := 0
@export var height := 0
@export var cell_size_m := 1.0
@export var omega_ref_rad_s := 0.0
@export var k0_rad_m := 0.0
@export var incoming_direction_xz := Vector2.RIGHT
@export var min_valid_depth_m := 0.25
@export var propagation_kind := 0 # 0 STRAIGHT_3B, 1 EIKONAL_2D_3B1.
@export var eikonal_sweeps := 0
@export var eikonal_cycles := 0
@export var eikonal_directional_sweeps := 0
@export var eikonal_final_max_change_s := 0.0
@export var eikonal_max_residual_rad_m := 0.0
@export var eikonal_interior_residual_rad_m := 0.0

@export_storage var depth_m := PackedFloat32Array()
@export_storage var local_k := PackedFloat32Array()
@export_storage var wavelength_m := PackedFloat32Array()
@export_storage var phase_speed_mps := PackedFloat32Array()
@export_storage var group_velocity_mps := PackedFloat32Array()
@export_storage var shoaling_scale := PackedFloat32Array()
@export_storage var phase_offset_rad := PackedFloat32Array()
@export_storage var valid_mask := PackedByteArray()
@export_storage var phase_rad := PackedFloat32Array()
@export_storage var render_phase_rad := PackedFloat32Array()
@export_storage var phase_gradient_x := PackedFloat32Array()
@export_storage var phase_gradient_z := PackedFloat32Array()
@export_storage var local_direction_x := PackedFloat32Array()
@export_storage var local_direction_z := PackedFloat32Array()
@export_storage var render_direction_x := PackedFloat32Array()
@export_storage var render_direction_z := PackedFloat32Array()
@export_storage var reached_mask := PackedByteArray()
@export_storage var shadow_scale := PackedFloat32Array()
@export_storage var cut_locus_mask := PackedByteArray()

var _field_texture: ImageTexture
var _metrics_texture: ImageTexture
var _phase_texture: ImageTexture


func is_valid() -> bool:
	var count := width * height
	return width >= 2 and height >= 2 and cell_size_m > 0.0 and omega_ref_rad_s > 0.0 and k0_rad_m > 0.0 and depth_m.size() == count and local_k.size() == count and wavelength_m.size() == count and phase_speed_mps.size() == count and group_velocity_mps.size() == count and shoaling_scale.size() == count and phase_offset_rad.size() == count and valid_mask.size() == count and phase_rad.size() == count and phase_gradient_x.size() == count and phase_gradient_z.size() == count and local_direction_x.size() == count and local_direction_z.size() == count and reached_mask.size() == count


func has_render_direction() -> bool:
	var count := width * height
	return render_direction_x.size() == count and render_direction_z.size() == count


func has_render_phase() -> bool:
	return render_phase_rad.size() == width * height


func has_cut_locus_mask() -> bool:
	return cut_locus_mask.size() == width * height


func world_max_xz() -> Vector2:
	return world_origin_xz + Vector2(float(width - 1), float(height - 1)) * cell_size_m


func approximate_memory_bytes() -> int:
	# Straight legacy: 13 float32 + dos máscaras. Eikonal añade render_direction,
	# render_phase y, cuando existe, una máscara byte de cut locus para debug CPU.
	var float_fields := 13 + (2 if has_render_direction() else 0) + (1 if has_render_phase() else 0)
	var byte_fields := 3 if has_cut_locus_mask() else 2
	return width * height * (float_fields * 4 + byte_fields)


func approximate_gpu_memory_bytes() -> int:
	# Tres RGBA32F: campo, métricas y fase/dirección/reached.
	return width * height * 3 * 4 * 4


func sample_propagation(world_xz: Vector2, reuse = null):
	var result = reuse if reuse != null else SampleScript.new()
	if width < 2 or height < 2 or cell_size_m <= 0.0:
		return result.set_invalid()
	var count: int = width * height
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
	result.depth_m = _bilinear(depth_m, i00, i10, i01, i11, tx, tz)
	result.local_k = _bilinear(local_k, i00, i10, i01, i11, tx, tz)
	result.wavelength_m = _bilinear(wavelength_m, i00, i10, i01, i11, tx, tz)
	result.phase_speed_mps = _bilinear(phase_speed_mps, i00, i10, i01, i11, tx, tz)
	result.group_velocity_mps = _bilinear(group_velocity_mps, i00, i10, i01, i11, tx, tz)
	result.shoaling_scale = _bilinear(shoaling_scale, i00, i10, i01, i11, tx, tz)
	result.phase_offset_rad = _bilinear(phase_offset_rad, i00, i10, i01, i11, tx, tz)
	result.phase_rad = _bilinear(phase_rad, i00, i10, i01, i11, tx, tz)
	result.render_phase_rad = _bilinear(render_phase_rad, i00, i10, i01, i11, tx, tz) if has_render_phase() else result.phase_rad
	result.phase_gradient_x = _bilinear(phase_gradient_x, i00, i10, i01, i11, tx, tz)
	result.phase_gradient_z = _bilinear(phase_gradient_z, i00, i10, i01, i11, tx, tz)
	result.local_direction_xz = Vector2(_bilinear(local_direction_x, i00, i10, i01, i11, tx, tz), _bilinear(local_direction_z, i00, i10, i01, i11, tx, tz)).normalized()
	if has_render_direction():
		result.render_direction_xz = Vector2(_bilinear(render_direction_x, i00, i10, i01, i11, tx, tz), _bilinear(render_direction_z, i00, i10, i01, i11, tx, tz)).normalized()
	else:
		result.render_direction_xz = result.local_direction_xz
	var nearest := clampi(int(round(grid.y)), 0, height - 1) * width + clampi(int(round(grid.x)), 0, width - 1)
	result.reached = reached_mask[nearest] != 0
	result.valid = valid_mask[nearest] != 0 and result.reached
	if shadow_scale.size() == count:
		result.shadow_scale = _bilinear(shadow_scale, i00, i10, i01, i11, tx, tz)
	else:
		result.shadow_scale = 1.0 if result.valid else 0.0
	return result


func build_gpu_textures() -> Dictionary:
	if not is_valid():
		return {}
	var field_values := PackedFloat32Array()
	var metric_values := PackedFloat32Array()
	var phase_values := PackedFloat32Array()
	field_values.resize(width * height * 4)
	metric_values.resize(width * height * 4)
	phase_values.resize(width * height * 4)
	for index in width * height:
		var base := index * 4
		field_values[base] = phase_offset_rad[index]
		field_values[base + 1] = shoaling_scale[index]
		field_values[base + 2] = local_k[index]
		field_values[base + 3] = 1.0 if valid_mask[index] != 0 else 0.0
		metric_values[base] = depth_m[index]
		metric_values[base + 1] = wavelength_m[index]
		metric_values[base + 2] = phase_speed_mps[index]
		metric_values[base + 3] = group_velocity_mps[index]
		phase_values[base] = phase_rad[index]
		phase_values[base + 1] = local_direction_x[index]
		phase_values[base + 2] = local_direction_z[index]
		phase_values[base + 3] = 1.0 if reached_mask[index] != 0 else 0.0
	var field_image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, field_values.to_byte_array())
	var metrics_image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, metric_values.to_byte_array())
	var phase_image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, phase_values.to_byte_array())
	_field_texture = ImageTexture.create_from_image(field_image)
	_metrics_texture = ImageTexture.create_from_image(metrics_image)
	_phase_texture = ImageTexture.create_from_image(phase_image)
	return {"field": _field_texture, "metrics": _metrics_texture, "phase": _phase_texture}


func _bilinear(values: PackedFloat32Array, i00: int, i10: int, i01: int, i11: int, tx: float, tz: float) -> float:
	return lerpf(lerpf(values[i00], values[i10], tx), lerpf(values[i01], values[i11], tx), tz)

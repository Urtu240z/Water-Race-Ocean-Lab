@tool
class_name BathymetryDebug
extends MeshInstance3D
## Overlay de tooling: no participa en la representación final del océano.

enum Mode { DEPTH, GRADIENT_SLOPE, LAND_WATER, SHORE_DISTANCE, DEPTH_SOURCE }

@export var data: Variant = null:
	set(value):
		data = value
		rebuild()
@export var mode: Mode = Mode.DEPTH:
	set(value):
		mode = value
		rebuild()
@export_range(0.01, 2.0, 0.01, "suffix:m") var vertical_offset_m := 0.08:
	set(value):
		vertical_offset_m = value
		rebuild()
@export_range(0.1, 200.0, 0.1, "suffix:m") var depth_color_range_m := 20.0:
	set(value):
		depth_color_range_m = value
		rebuild()
@export_range(0.1, 200.0, 0.1, "suffix:m") var shore_distance_color_range_m := 32.0:
	set(value):
		shore_distance_color_range_m = value
		rebuild()


func rebuild() -> void:
	if data == null or not data.is_valid():
		mesh = null
		return
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in data.height - 1:
		for x in data.width - 1:
			var p00 := _point(x, z)
			var p10 := _point(x + 1, z)
			var p01 := _point(x, z + 1)
			var p11 := _point(x + 1, z + 1)
			_add_triangle(surface_tool, p00, p10, p11, _color_at(x, z), _color_at(x + 1, z), _color_at(x + 1, z + 1))
			_add_triangle(surface_tool, p00, p11, p01, _color_at(x, z), _color_at(x + 1, z + 1), _color_at(x, z + 1))
	mesh = surface_tool.commit()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func _point(x: int, z: int) -> Vector3:
	var world_xz = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
	return Vector3(world_xz.x, data.sea_level_y + vertical_offset_m, world_xz.y)


func _color_at(x: int, z: int) -> Color:
	var index = z * data.width + x
	match mode:
		Mode.DEPTH:
			var t := clampf(data.depth_m[index] / depth_color_range_m, 0.0, 1.0)
			return Color(0.02, lerpf(0.20, 0.85, t), lerpf(0.20, 1.0, t), 0.78)
		Mode.GRADIENT_SLOPE:
			var slope_t := clampf(data.slope_magnitude[index], 0.0, 1.0)
			return Color(slope_t, 1.0 - slope_t, 0.08, 0.82)
		Mode.LAND_WATER:
			return Color(0.06, 0.35, 0.95, 0.75) if data.land_water_mask[index] != 0 else Color(0.72, 0.42, 0.12, 0.82)
		Mode.SHORE_DISTANCE:
			var shore_distance: float = data.shore_signed_distance_m[index] if data.shore_signed_distance_m.size() == data.depth_m.size() else 0.0
			var distance_t := clampf(absf(shore_distance) / shore_distance_color_range_m, 0.0, 1.0)
			if shore_distance >= 0.0:
				return Color(0.05, lerpf(0.85, 0.12, distance_t), lerpf(0.98, 0.42, distance_t), 0.86)
			return Color(lerpf(0.95, 0.25, distance_t), lerpf(0.62, 0.12, distance_t), 0.04, 0.88)
		Mode.DEPTH_SOURCE:
			if data.land_water_mask[index] == 0:
				return Color(0.35, 0.25, 0.16, 0.82)
			var measured: bool = data.depth_source_mask.size() == data.depth_m.size() and data.depth_source_mask[index] != 0
			return Color(0.08, 0.92, 0.28, 0.88) if measured else Color(0.82, 0.16, 0.95, 0.88)
	return Color.WHITE


func _add_triangle(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	tool.set_color(ca); tool.add_vertex(a)
	tool.set_color(cb); tool.add_vertex(b)
	tool.set_color(cc); tool.add_vertex(c)

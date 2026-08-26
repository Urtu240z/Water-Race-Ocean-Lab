@tool
class_name CoastalEikonalDebug
extends MeshInstance3D
## Overlay CPU de diagnóstico para CoastalPropagationData.
## No modifica el campo ni participa en el render final del océano.

enum Mode { REACHED, LOCAL_DIRECTION, SHADOW_SCALE }

@export var data: Resource = null:
	set(value):
		data = value
		rebuild()
@export var mode: Mode = Mode.REACHED:
	set(value):
		mode = value
		rebuild()
@export_range(-100.0, 100.0, 0.01, "suffix:m") var y_offset_m := 0.12:
	set(value):
		y_offset_m = value
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
	material.no_depth_test = true
	material.render_priority = 120
	material_override = material


func _point(x: int, z: int) -> Vector3:
	var world_xz: Vector2 = data.world_origin_xz + Vector2(float(x), float(z)) * data.cell_size_m
	return Vector3(world_xz.x, y_offset_m, world_xz.y)


func _color_at(x: int, z: int) -> Color:
	var index: int = z * data.width + x
	if data.valid_mask[index] == 0:
		return Color(0.18, 0.12, 0.10, 0.82)
	match mode:
		Mode.REACHED:
			return Color(0.10, 0.88, 0.32, 0.86) if data.reached_mask[index] != 0 else Color(0.72, 0.20, 0.12, 0.86)
		Mode.LOCAL_DIRECTION:
			if data.reached_mask[index] == 0:
				return Color(0.18, 0.12, 0.10, 0.82)
			var direction := Vector2(data.local_direction_x[index], data.local_direction_z[index]).normalized()
			return Color(0.5 + 0.5 * direction.x, 0.5 + 0.5 * direction.y, 0.18, 0.88)
		Mode.SHADOW_SCALE:
			if data.reached_mask[index] == 0:
				return Color(0.18, 0.12, 0.10, 0.82)
			var scale: float = data.shadow_scale[index] if data.shadow_scale.size() == data.width * data.height else 1.0
			return Color(lerpf(0.08, 0.98, clampf(scale, 0.0, 1.0)), lerpf(0.08, 0.92, clampf(scale, 0.0, 1.0)), 0.12, 0.88)
	return Color.WHITE


func _add_triangle(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	tool.set_color(ca)
	tool.add_vertex(a)
	tool.set_color(cb)
	tool.add_vertex(b)
	tool.set_color(cc)
	tool.add_vertex(c)

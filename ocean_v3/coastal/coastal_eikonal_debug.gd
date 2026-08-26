@tool
class_name CoastalEikonalDebug
extends MeshInstance3D
## Overlay CPU de diagnóstico para CoastalPropagationData.
## Una sola PlaneMesh horizontal y una textura RGBA con un píxel por celda.
## No modifica el campo ni participa en el render final del océano.

enum Mode { REACHED, LOCAL_DIRECTION, SHADOW_SCALE }

@export var data: Resource = null:
	set(value):
		data = value
		rebuild()
@export var base_y := 0.0:
	set(value):
		base_y = value
		_update_plane_transform()
@export var mode: Mode = Mode.REACHED:
	set(value):
		mode = value
		_rebuild_texture()
@export_range(-100.0, 100.0, 0.01, "suffix:m") var y_offset_m := 0.12:
	set(value):
		y_offset_m = value
		_update_plane_transform()

var last_debug_triangle_count := 0
var _image_texture: ImageTexture = null
var _debug_material: StandardMaterial3D = null


func rebuild() -> void:
	if data == null or not data.is_valid():
		mesh = null
		material_override = null
		_image_texture = null
		_debug_material = null
		last_debug_triangle_count = 0
		return
	_ensure_plane_geometry()
	_rebuild_texture()


func _ensure_plane_geometry() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(
		float(data.width - 1) * data.cell_size_m,
		float(data.height - 1) * data.cell_size_m
	)
	mesh = plane
	last_debug_triangle_count = 2
	_update_plane_transform()
	_debug_material = StandardMaterial3D.new()
	_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_debug_material.no_depth_test = true
	_debug_material.render_priority = 120
	_debug_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material_override = _debug_material


func _update_plane_transform() -> void:
	if data == null or not data.is_valid():
		return
	var world_min: Vector2 = data.world_origin_xz
	var world_max: Vector2 = world_min + Vector2(
		float(data.width - 1) * data.cell_size_m,
		float(data.height - 1) * data.cell_size_m
	)
	var center := (world_min + world_max) * 0.5
	var center_position := Vector3(center.x, base_y + y_offset_m, center.y)
	if is_inside_tree():
		global_position = center_position
	else:
		position = center_position


func _rebuild_texture() -> void:
	if data == null or not data.is_valid() or _debug_material == null:
		return
	var pixels := PackedByteArray()
	pixels.resize(data.width * data.height * 4)
	for z in data.height:
		for x in data.width:
			var color := _color_at(x, z)
			var offset: int = (z * data.width + x) * 4
			pixels[offset] = int(round(clampf(color.r, 0.0, 1.0) * 255.0))
			pixels[offset + 1] = int(round(clampf(color.g, 0.0, 1.0) * 255.0))
			pixels[offset + 2] = int(round(clampf(color.b, 0.0, 1.0) * 255.0))
			pixels[offset + 3] = int(round(clampf(color.a, 0.0, 1.0) * 255.0))
	var image := Image.create_from_data(data.width, data.height, false, Image.FORMAT_RGBA8, pixels)
	_image_texture = ImageTexture.create_from_image(image)
	_debug_material.albedo_texture = _image_texture


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

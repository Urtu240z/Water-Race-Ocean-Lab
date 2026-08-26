@tool
extends EditorNode3DGizmoPlugin

const ZoneScript := preload("res://ocean_v3/core/ocean_sea_state_zone_3d.gd")

const HANDLE_X := 0
const HANDLE_Z := 1
const HANDLE_FEATHER := 2
const LINE_Y := 0.035
const CORNER_SEGMENTS := 8

var _editor_plugin: EditorPlugin


func _init(editor_plugin: EditorPlugin = null) -> void:
	_editor_plugin = editor_plugin
	create_material("core", Color(0.16, 0.86, 1.0))
	create_material("feather", Color(0.95, 0.66, 0.16))
	create_handle_material("handles")


func _get_gizmo_name() -> String:
	return "OceanSeaStateZone3D"


func _get_priority() -> int:
	return 1


func _has_gizmo(node: Node3D) -> bool:
	return node is OceanSeaStateZone3D or node.get_script() == ZoneScript


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var zone := gizmo.get_node_3d() as OceanSeaStateZone3D
	if zone == null:
		return

	var core := _rectangle_lines(zone.box_size_m * 0.5)
	var core_material := get_material("core", gizmo)
	var feather_material := get_material("feather", gizmo)
	if not zone.enabled:
		core_material = get_material("feather", gizmo)
		feather_material = get_material("core", gizmo)
	gizmo.add_lines(_rounded_offset_lines(zone.box_size_m * 0.5, zone.feather_distance_m), feather_material, false)
	gizmo.add_lines(core, core_material, false)

	var half := zone.box_size_m * 0.5
	var handle_y := LINE_Y
	var handles := PackedVector3Array([
		Vector3(half.x, handle_y, 0.0),
		Vector3(0.0, handle_y, half.y),
		Vector3(half.x + zone.feather_distance_m, handle_y, 0.0),
	])
	gizmo.add_handles(handles, get_material("handles", gizmo), PackedInt32Array([HANDLE_X, HANDLE_Z, HANDLE_FEATHER]))


func _rectangle_lines(half: Vector2) -> PackedVector3Array:
	var y := LINE_Y
	return PackedVector3Array([
		Vector3(-half.x, y, -half.y), Vector3(half.x, y, -half.y),
		Vector3(half.x, y, -half.y), Vector3(half.x, y, half.y),
		Vector3(half.x, y, half.y), Vector3(-half.x, y, half.y),
		Vector3(-half.x, y, half.y), Vector3(-half.x, y, -half.y),
	])


func _rounded_offset_lines(half: Vector2, offset: float) -> PackedVector3Array:
	if offset <= 0.0001:
		return _rectangle_lines(half)
	var y := LINE_Y
	var radius := offset
	var corners := [
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
	]
	var start_angles := [0.0, PI * 0.5, PI, PI * 1.5]
	var outline := PackedVector3Array()
	for corner_index in corners.size():
		var center: Vector2 = corners[corner_index]
		var start: float = start_angles[corner_index]
		for segment in CORNER_SEGMENTS + 1:
			var angle := start + PI * 0.5 * float(segment) / float(CORNER_SEGMENTS)
			outline.append(Vector3(center.x + cos(angle) * radius, y, center.y + sin(angle) * radius))
	var lines := PackedVector3Array()
	for index in outline.size():
		var next := (index + 1) % outline.size()
		lines.append(outline[index])
		lines.append(outline[next])
	return lines


func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	match handle_id:
		HANDLE_X:
			return "Box Size X"
		HANDLE_Z:
			return "Box Size Z"
		HANDLE_FEATHER:
			return "Feather Distance"
	return "OceanSeaStateZone3D Handle"


func _get_handle_value(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> Variant:
	var zone := gizmo.get_node_3d() as OceanSeaStateZone3D
	if zone == null:
		return 0.0
	match handle_id:
		HANDLE_X:
			return zone.box_size_m.x
		HANDLE_Z:
			return zone.box_size_m.y
		HANDLE_FEATHER:
			return zone.feather_distance_m
	return 0.0


func _set_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var zone := gizmo.get_node_3d() as OceanSeaStateZone3D
	if zone == null:
		return
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_direction := camera.project_ray_normal(screen_pos)
	var plane_normal := zone.global_transform.basis.y.normalized()
	var plane := Plane(plane_normal, -plane_normal.dot(zone.global_position))
	var distance := plane.intersects_ray(ray_origin, ray_direction)
	if distance == null:
		return
	var local_point := zone.to_local(ray_origin + ray_direction * distance)
	var half := zone.box_size_m * 0.5
	match handle_id:
		HANDLE_X:
			zone.box_size_m = Vector2(maxf(absf(local_point.x) * 2.0, 0.1), zone.box_size_m.y)
		HANDLE_Z:
			zone.box_size_m = Vector2(zone.box_size_m.x, maxf(absf(local_point.z) * 2.0, 0.1))
		HANDLE_FEATHER:
			zone.feather_distance_m = maxf(absf(local_point.x) - half.x, 0.0)


func _commit_handle(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	var zone := gizmo.get_node_3d() as OceanSeaStateZone3D
	if zone == null:
		return
	var property_name := _property_for_handle(handle_id)
	if property_name.is_empty():
		return
	var current: Variant = zone.get(property_name)
	if cancel:
		zone.set(property_name, restore)
		return
	if _editor_plugin == null:
		return
	var undo_redo := _editor_plugin.get_undo_redo()
	undo_redo.create_action("Edit OceanSeaStateZone3D %s" % _get_handle_name(gizmo, handle_id, false))
	undo_redo.add_do_property(zone, property_name, current)
	undo_redo.add_undo_property(zone, property_name, restore)
	undo_redo.commit_action()


func _property_for_handle(handle_id: int) -> StringName:
	match handle_id:
		HANDLE_X, HANDLE_Z:
			return &"box_size_m"
		HANDLE_FEATHER:
			return &"feather_distance_m"
	return &""

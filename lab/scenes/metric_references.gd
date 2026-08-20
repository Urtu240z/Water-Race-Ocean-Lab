extends Node3D
## Marcadores de altura en metros; son instrumentación, no assets finales.

const MEASUREMENTS: Array[float] = [1.0, 5.0, 10.0, 25.0, 50.0, 100.0]


func _ready() -> void:
	for index in MEASUREMENTS.size():
		_create_marker(MEASUREMENTS[index], Vector3(-18.0 + index * 7.0, 0.0, 0.0))


func _create_marker(height_meters: float, marker_position: Vector3) -> void:
	var marker := Node3D.new()
	marker.position = marker_position
	add_child(marker)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.85, 1.0, 1.0)

	var column := MeshInstance3D.new()
	var column_mesh := BoxMesh.new()
	column_mesh.size = Vector3(0.12, height_meters, 0.12)
	column.mesh = column_mesh
	column.material_override = material
	column.position.y = height_meters * 0.5
	marker.add_child(column)

	var base := MeshInstance3D.new()
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.5, 0.06, 0.06)
	base.mesh = base_mesh
	base.material_override = material
	marker.add_child(base)

	var label := Label3D.new()
	label.text = "%dm" % int(height_meters)
	label.font_size = 48
	label.outline_size = 8
	label.position = Vector3(0.0, height_meters + 0.35, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.add_child(label)

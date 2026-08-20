extends Camera3D

@export var target_path: NodePath


func _ready() -> void:
	var target := get_node_or_null(target_path) as Node3D
	if target != null:
		look_at(target.global_position, Vector3.UP)

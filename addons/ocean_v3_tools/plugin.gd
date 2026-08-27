@tool
extends EditorPlugin

const SeaStateZoneGizmoPlugin := preload("res://addons/ocean_v3_tools/sea_state_zone_gizmo_plugin.gd")
const CoastalBakeAuthoringScript := preload("res://ocean_v3/coastal/coastal_bake_authoring.gd")

var _gizmo_plugin: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_gizmo_plugin = SeaStateZoneGizmoPlugin.new(self)
	add_node_3d_gizmo_plugin(_gizmo_plugin)
	add_custom_type("CoastalBakeAuthoring", "Node", CoastalBakeAuthoringScript, null)


func _exit_tree() -> void:
	if _gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_gizmo_plugin)
		_gizmo_plugin = null
	remove_custom_type("CoastalBakeAuthoring")

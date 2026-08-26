@tool
class_name OceanSeaStateZone3D
extends Node3D
## Local absolute wave-state override over an oriented XZ rectangle.

const ZONE_GROUP := &"ocean_sea_state_zone"

@export_category("Sea State Zone")
@export var enabled: bool = true:
	set(value):
		enabled = value
		_mark_zone_dirty()
@export var priority: int = 0:
	set(value):
		priority = value
		_mark_zone_dirty()
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		_mark_zone_dirty()

@export_category("Geometry")
@export var box_size_m: Vector2 = Vector2(100.0, 100.0):
	set(value):
		box_size_m = Vector2(maxf(value.x, 0.0), maxf(value.y, 0.0))
		_mark_zone_dirty()
@export_range(0.0, 10000.0, 0.5) var feather_distance_m: float = 20.0:
	set(value):
		feather_distance_m = maxf(value, 0.0)
		_mark_zone_dirty()

@export_category("Wave Multipliers")
@export_range(0.0, 2.0, 0.01) var long_amplitude_multiplier: float = 1.0:
	set(value):
		long_amplitude_multiplier = clampf(value, 0.0, 2.0)
		_mark_zone_dirty()
@export_range(0.0, 2.0, 0.01) var mid_amplitude_multiplier: float = 1.0:
	set(value):
		mid_amplitude_multiplier = clampf(value, 0.0, 2.0)
		_mark_zone_dirty()
@export_range(0.0, 2.0, 0.01) var short_amplitude_multiplier: float = 1.0:
	set(value):
		short_amplitude_multiplier = clampf(value, 0.0, 2.0)
		_mark_zone_dirty()
@export_range(0.0, 2.0, 0.01) var choppiness_multiplier: float = 1.0:
	set(value):
		choppiness_multiplier = clampf(value, 0.0, 2.0)
		_mark_zone_dirty()

@export_category("Foam")
@export_range(0.0, 2.0, 0.01) var foam_generation_multiplier: float = 1.0:
	set(value):
		foam_generation_multiplier = clampf(value, 0.0, 2.0)
		_mark_zone_dirty()

var _owner_ocean: OceanV3 = null


func _ready() -> void:
	set_notify_transform(true)
	add_to_group(ZONE_GROUP)
	tree_exiting.connect(_on_tree_exiting)
	_register_with_ocean()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_mark_zone_dirty()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not scale.is_equal_approx(Vector3.ONE):
		warnings.append("OceanSeaStateZone3D uses box_size_m for its physical extent. Keep Node3D scale at (1,1,1); use the zone gizmo handles or Box Size.")
	if box_size_m.x < 0.1 or box_size_m.y < 0.1:
		warnings.append("OceanSeaStateZone3D Box Size should be at least 0.1 m on X and Z.")
	if is_inside_tree():
		var active_zone_count := 0
		for node in get_tree().get_nodes_in_group(ZONE_GROUP):
			if node is OceanSeaStateZone3D and node.enabled:
				active_zone_count += 1
		if active_zone_count > 8:
			warnings.append("More than 8 active OceanSeaStateZone3D nodes exist; only the first 8 by priority/path are composed.")
	return warnings


func _register_with_ocean() -> void:
	var ocean := get_tree().get_first_node_in_group(&"ocean_v3_root") as OceanV3
	if ocean != null:
		_owner_ocean = ocean
		ocean.register_sea_state_zone(self)


func _on_tree_exiting() -> void:
	if _owner_ocean != null and is_instance_valid(_owner_ocean):
		_owner_ocean.unregister_sea_state_zone(self)
	_owner_ocean = null


func _mark_zone_dirty() -> void:
	if Engine.is_editor_hint():
		update_gizmos()
		update_configuration_warnings()
	if _owner_ocean != null and is_instance_valid(_owner_ocean):
		_owner_ocean.mark_sea_state_zones_dirty()
	elif is_inside_tree():
		_register_with_ocean()


func descriptor() -> Dictionary:
	var axis_3d := global_basis.x
	var axis := Vector2(axis_3d.x, axis_3d.z)
	if axis.length_squared() <= 1.0e-8:
		axis = Vector2.RIGHT
	else:
		axis = axis.normalized()
	return {
		"center": Vector2(global_position.x, global_position.z),
		"axis": axis,
		"half_extents": box_size_m * 0.5,
		"feather": feather_distance_m,
		"strength": strength,
		"target": Vector4(long_amplitude_multiplier, mid_amplitude_multiplier, short_amplitude_multiplier, choppiness_multiplier),
		"foam_generation_multiplier": foam_generation_multiplier,
		"priority": priority,
		"path_key": str(get_path()),
	}

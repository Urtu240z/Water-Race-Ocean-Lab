class_name OceanReflectionPhase1ConfigV4
extends Resource
## Environment-only water reflection controls. No screen-space resources are used.

@export var enabled := true
@export_range(0.0, 1.0, 0.001) var water_specular := 0.356835
@export_range(0.0, 1.0, 0.005) var min_roughness := 0.045
@export_range(0.0, 1.0, 0.005) var base_roughness := 0.055
@export_range(0.0, 1.0, 0.005) var distance_roughness := 0.18
@export_range(0.0, 1.0, 0.005) var slope_roughness_gain := 0.16
@export var distance_range_m := Vector2(90.0, 650.0)
@export var slope_range := Vector2(0.08, 0.55)


func is_valid() -> bool:
	return water_specular >= 0.0 and water_specular <= 1.0 \
		and min_roughness >= 0.0 and base_roughness >= min_roughness \
		and distance_roughness >= base_roughness and distance_roughness <= 1.0 \
		and slope_roughness_gain >= 0.0 and slope_roughness_gain <= 1.0 \
		and distance_range_m.y > distance_range_m.x and slope_range.y > slope_range.x

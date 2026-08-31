class_name OceanOpticsPhase1ConfigV4
extends Resource
## Coastal-depth Beer-Lambert response. No screen-space refraction is used.

enum Mode { OFF, ABSORPTION_ONLY, ON, DEBUG_DEPTH, DEBUG_TRANSMITTANCE }

@export var mode: Mode = Mode.ON
@export var absorption_rgb := Vector3(0.34, 0.12, 0.055)
@export var shallow_color := Color(0.08, 0.30, 0.31)
@export var deep_color := Color(0.008, 0.045, 0.095)
@export_range(0.01, 4.0, 0.01) var depth_scale := 1.0
@export_range(1.0, 100.0, 0.5) var max_optical_depth_m := 18.0
@export_range(0.0, 1.0, 0.01) var color_strength := 0.64
@export_range(0.0, 1.0, 0.01) var transmission_strength := 0.72


func is_valid() -> bool:
	return absorption_rgb.x >= 0.0 and absorption_rgb.y >= 0.0 and absorption_rgb.z >= 0.0 \
		and depth_scale > 0.0 and max_optical_depth_m > 0.0 \
		and color_strength >= 0.0 and color_strength <= 1.0 \
		and transmission_strength >= 0.0 and transmission_strength <= 1.0

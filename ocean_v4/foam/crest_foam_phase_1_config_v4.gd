class_name OceanCrestFoamPhase1ConfigV4
extends Resource
## Direct, ephemeral crest foam. It owns no history, textures or compute work.

enum Mode { OFF, TRIGGER_ONLY, ON, DEBUG_RAW, DEBUG_FINAL }

@export var mode: Mode = Mode.ON
@export var height_range_m := Vector2(0.10, 0.65)
@export var slope_range := Vector2(0.05, 0.30)
@export var mid_detail_range := Vector2(0.02, 0.18)
@export var distance_fade_range_m := Vector2(110.0, 380.0)
@export_range(0.0, 1.0, 0.01) var mid_fragmentation := 0.42
@export_range(0.0, 1.0, 0.01) var strength := 0.90
@export var color := Color(0.84, 0.89, 0.88)
@export_range(0.0, 1.0, 0.01) var roughness := 0.78
@export_range(0.0, 1.0, 0.01) var specular := 0.12


func is_valid() -> bool:
	return height_range_m.y > height_range_m.x and slope_range.y > slope_range.x \
		and mid_detail_range.y > mid_detail_range.x \
		and distance_fade_range_m.y > distance_fade_range_m.x \
		and mid_fragmentation >= 0.0 and mid_fragmentation <= 1.0 \
		and strength >= 0.0 and strength <= 1.0

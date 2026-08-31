class_name OceanCrestFoamPhase1ConfigV4
extends Resource
## Direct, ephemeral crest foam. It owns no history, textures or compute work.
## Phase 1B shapes an interpolated LONG crest into a soft edge and denser core.

enum Mode { OFF, DEBUG_LONG_RAW, ON, DEBUG_LONG_MID_RAW, DEBUG_FINAL }

@export var mode: Mode = Mode.ON
@export var height_range_m := Vector2(0.10, 0.65)
@export var slope_range := Vector2(0.05, 0.30)
@export var mid_detail_range := Vector2(0.02, 0.18)
@export var distance_fade_range_m := Vector2(110.0, 380.0)
@export var edge_range := Vector2(0.08, 0.32)
@export var core_range := Vector2(0.28, 0.62)
@export_range(0.0, 1.0, 0.01) var mid_density_floor := 0.72
@export_range(0.0, 1.0, 0.01) var mid_modulation_strength := 0.28
@export_range(0.0, 1.0, 0.01) var strength := 0.76
@export var color := Color(0.84, 0.89, 0.88)
@export_range(0.0, 1.0, 0.01) var roughness := 0.78
@export_range(0.0, 1.0, 0.01) var specular := 0.12


func is_valid() -> bool:
	return height_range_m.y > height_range_m.x and slope_range.y > slope_range.x \
		and mid_detail_range.y > mid_detail_range.x \
		and distance_fade_range_m.y > distance_fade_range_m.x \
		and edge_range.y > edge_range.x and core_range.y > core_range.x \
		and mid_density_floor >= 0.0 and mid_density_floor <= 1.0 \
		and mid_modulation_strength >= 0.0 and mid_modulation_strength <= 1.0 \
		and strength >= 0.0 and strength <= 1.0

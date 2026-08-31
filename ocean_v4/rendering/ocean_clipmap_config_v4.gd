class_name OceanClipmapConfigV4
extends Resource

@export var cells_per_side := 126
@export var base_spacing_m := 0.25
@export var level_count := 10
@export var sea_level_y := 0.0
@export var extra_cull_margin_m := 4.0
@export var short_fade_range_m := Vector2(24.0, 80.0)
@export var mid_fade_range_m := Vector2(96.0, 280.0)
@export var long_fade_range_m := Vector2(768.0, 2500.0)


func is_valid() -> bool:
	return cells_per_side >= 4 and cells_per_side % 2 == 0 and base_spacing_m > 0.0 and level_count >= 1


func spacing_for_level(level: int) -> float:
	return base_spacing_m * pow(2.0, level)


func outer_width_for_level(level: int) -> float:
	return float(cells_per_side) * spacing_for_level(level)


func inner_width_for_level(level: int) -> float:
	return 0.0 if level == 0 else outer_width_for_level(level - 1)

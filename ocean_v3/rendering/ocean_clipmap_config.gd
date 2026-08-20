class_name OceanClipmapConfig
extends Resource
## Parámetros estructurales del renderer clipmap. No alteran el campo FFT.

@export var cells_per_side: int = 128
@export var base_spacing_m := 0.25
@export var level_count: int = 10
@export var sea_level_y := 0.0
@export var horizon_distance_m := 7000.0
@export var extra_cull_margin_m := 4.0
@export var short_fade_range_m := Vector2(24.0, 80.0)
@export var mid_fade_range_m := Vector2(96.0, 320.0)
@export var long_fade_range_m := Vector2(768.0, 2500.0)


func is_valid() -> bool:
	return (
		cells_per_side >= 4
		and cells_per_side % 2 == 0
		and base_spacing_m > 0.0
		and level_count >= 1
		and horizon_distance_m > 0.0
		and extra_cull_margin_m >= 0.0
		and _fade_range_is_valid(short_fade_range_m)
		and _fade_range_is_valid(mid_fade_range_m)
		and _fade_range_is_valid(long_fade_range_m)
	)


func spacing_for_level(level: int) -> float:
	return base_spacing_m * pow(2.0, level)


func outer_width_for_level(level: int) -> float:
	return float(cells_per_side) * spacing_for_level(level)


func inner_width_for_level(level: int) -> float:
	return 0.0 if level == 0 else outer_width_for_level(level - 1)


func final_half_extent_m() -> float:
	return outer_width_for_level(level_count - 1) * 0.5


func _fade_range_is_valid(fade_range: Vector2) -> bool:
	return fade_range.x >= 0.0 and fade_range.y > fade_range.x

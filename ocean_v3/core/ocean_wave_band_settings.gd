@tool
class_name OceanWaveBandSettings
extends Resource
## Editable physical spectrum settings for one canonical LONG/MID/SHORT band.
## Material and Surface Foam controls deliberately do not belong here.

@export_range(0.0, 10.0, 0.01) var target_hs_m := 0.25
@export_range(0.0, 4.0, 0.01) var choppiness := 0.70
@export var wind_direction := Vector2(1.0, 0.30).normalized()
@export_range(1.0, 12.0, 0.1) var directional_spread := 5.0
@export_range(1.0, 100000.0, 1.0) var fetch_length_m := 3000.0
@export_range(0.0, 1.0, 0.01) var swell := 0.45
@export_range(0.0, 1.0, 0.01) var detail := 1.0
@export_range(0.0, 1.0, 0.01) var jonswap_spread := 0.35

@export_group("Advanced")
@export_range(0.01, 1000.0, 0.01) var min_wavelength_m := 4.0
@export_range(0.01, 2000.0, 0.01) var max_wavelength_m := 20.0
@export_range(0.0, 100.0, 0.01) var transition_width_m := 0.75
@export_range(0.0, 10.0, 0.01) var short_wave_damping_m := 0.35

# Legacy physical whitecap parameters remain part of the generated FFT config,
# but are intentionally not surfaced by OceanV3's main authoring inspector yet.
@export_storage var foam_enabled := true
@export_storage var foam_whitecap := 0.54
@export_storage var foam_amount := 0.16
@export_storage var foam_decay := 5.5
@export_storage var foam_cascade_weight := 0.5


func apply_to(config: OpenOceanFFTConfig, id: StringName, wind_speed_mps: float) -> void:
	config.id = id
	config.wind_speed_mps = maxf(wind_speed_mps, 0.0)
	config.wind_direction = wind_direction.normalized() if wind_direction.length_squared() > 1.0e-8 else Vector2.RIGHT
	config.directional_spread = directional_spread
	config.choppiness = choppiness
	config.target_hs_m = target_hs_m
	config.fetch_length_m = fetch_length_m
	config.swell = swell
	config.detail = detail
	config.jonswap_spread = jonswap_spread
	config.min_wavelength_m = min_wavelength_m
	config.max_wavelength_m = maxf(max_wavelength_m, min_wavelength_m)
	config.transition_width_m = transition_width_m
	config.short_wave_damping_m = short_wave_damping_m
	config.foam_enabled = foam_enabled
	config.foam_whitecap = foam_whitecap
	config.foam_amount = foam_amount
	config.foam_decay = foam_decay
	config.foam_cascade_weight = foam_cascade_weight


func copy_from(config: OpenOceanFFTConfig) -> void:
	target_hs_m = config.target_hs_m
	choppiness = config.choppiness
	wind_direction = config.wind_direction
	directional_spread = config.directional_spread
	fetch_length_m = config.fetch_length_m
	swell = config.swell
	detail = config.detail
	jonswap_spread = config.jonswap_spread
	min_wavelength_m = config.min_wavelength_m
	max_wavelength_m = config.max_wavelength_m
	transition_width_m = config.transition_width_m
	short_wave_damping_m = config.short_wave_damping_m
	foam_enabled = config.foam_enabled
	foam_whitecap = config.foam_whitecap
	foam_amount = config.foam_amount
	foam_decay = config.foam_decay
	foam_cascade_weight = config.foam_cascade_weight

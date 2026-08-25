@tool
class_name OceanWavePreset
extends Resource
## A reusable starting point for OceanV3's physical LONG/MID/SHORT spectrum.

@export var preset_name := "Custom Wave Preset"
@export_range(0.0, 60.0, 0.1) var global_wind_speed_mps := 12.0
@export var long_band: OceanWaveBandSettings
@export var mid_band: OceanWaveBandSettings
@export var short_band: OceanWaveBandSettings
@export_range(0.0, 1.0, 0.01) var short_geometry_strength := 0.25


func build_cascades() -> Array[OpenOceanFFTConfig]:
	var result: Array[OpenOceanFFTConfig] = []
	var bands: Array[OceanWaveBandSettings] = [_band_or_default(long_band, 0), _band_or_default(mid_band, 1), _band_or_default(short_band, 2)]
	var ids: Array[StringName] = [&"LONG", &"MID", &"SHORT"]
	for index in 3:
		var config := OpenOceanFFTConfig.new()
		_apply_technical_invariants(config, index)
		bands[index].apply_to(config, ids[index], global_wind_speed_mps)
		result.append(config)
	return result


func _band_or_default(value: OceanWaveBandSettings, index: int) -> OceanWaveBandSettings:
	if value != null:
		return value
	var fallback := OceanWaveBandSettings.new()
	match index:
		0:
			fallback.min_wavelength_m = 16.0
			fallback.max_wavelength_m = 128.0
			fallback.transition_width_m = 4.0
			fallback.short_wave_damping_m = 0.35
			fallback.fetch_length_m = 25000.0
			fallback.swell = 0.8
			fallback.jonswap_spread = 0.05
		1:
			fallback.min_wavelength_m = 4.0
			fallback.max_wavelength_m = 20.0
			fallback.transition_width_m = 0.75
			fallback.short_wave_damping_m = 0.35
			fallback.fetch_length_m = 3000.0
			fallback.swell = 0.45
			fallback.jonswap_spread = 0.35
		2:
			fallback.min_wavelength_m = 0.5
			fallback.max_wavelength_m = 5.0
			fallback.transition_width_m = 0.15
			fallback.short_wave_damping_m = 0.2
			fallback.fetch_length_m = 300.0
			fallback.swell = 0.15
			fallback.jonswap_spread = 0.75
	return fallback


func _apply_technical_invariants(config: OpenOceanFFTConfig, index: int) -> void:
	config.resolution = 256
	config.gravity_mps2 = 9.81
	config.energy = 0.00016
	match index:
		0: config.domain_size_m = 512.0
		1: config.domain_size_m = 137.0
		2: config.domain_size_m = 37.0

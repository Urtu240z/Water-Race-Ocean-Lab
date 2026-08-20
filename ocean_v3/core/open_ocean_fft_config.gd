class_name OpenOceanFFTConfig
extends Resource
## Configuración física de una cascada espectral. El módulo sigue siendo único.

@export var id: StringName = &"MID"
@export var resolution: int = 256
@export var domain_size_m: float = 128.0
@export var gravity_mps2: float = 9.81
@export var min_wavelength_m: float = 4.0
@export var max_wavelength_m: float = 20.0
@export var transition_width_m: float = 0.75
@export var wind_direction := Vector2(1.0, 0.30).normalized()
@export var wind_speed_mps: float = 12.0
@export var energy: float = 0.00016
@export_range(1.0, 12.0, 0.1) var directional_spread: float = 4.0
@export var short_wave_damping_m: float = 0.35
@export_range(0.0, 1.5, 0.01) var choppiness: float = 1.0
@export var target_hs_m: float = 0.65

# Métricas de inicialización: no se actualizan por frame ni requieren readback GPU.
var measured_hs_m := 0.0
var out_of_band_energy_ratio := 0.0


func is_valid() -> bool:
	return (
		not id.is_empty()
		and resolution >= 2
		and (resolution & (resolution - 1)) == 0
		and domain_size_m > 0.0
		and gravity_mps2 > 0.0
		and min_wavelength_m > 0.0
		and max_wavelength_m >= min_wavelength_m
		and transition_width_m >= 0.0
		and wind_speed_mps >= 0.0
		and energy >= 0.0
		and target_hs_m >= 0.0
	)


func fft_stage_count() -> int:
	return int(round(log(float(resolution)) / log(2.0)))


func compute_pass_count() -> int:
	return 2 * fft_stage_count() + 2


func approximate_gpu_bytes() -> int:
	# H0 + 4 ping-pong RGBA32F + displacement RGBA32F + normal RGBA16F.
	return resolution * resolution * (16 * 6 + 8)


static func reference_cascades() -> Array[OpenOceanFFTConfig]:
	var long_band := OpenOceanFFTConfig.new()
	long_band.id = &"LONG"
	long_band.resolution = 256
	long_band.domain_size_m = 512.0
	long_band.min_wavelength_m = 16.0
	long_band.max_wavelength_m = 128.0
	long_band.transition_width_m = 4.0
	long_band.wind_direction = Vector2(1.0, 0.15).normalized()
	long_band.target_hs_m = 0.50
	long_band.choppiness = 0.75
	long_band.short_wave_damping_m = 0.35

	var mid_band := OpenOceanFFTConfig.new()
	mid_band.id = &"MID"
	mid_band.resolution = 256
	mid_band.domain_size_m = 128.0
	mid_band.min_wavelength_m = 4.0
	mid_band.max_wavelength_m = 20.0
	mid_band.transition_width_m = 0.75
	mid_band.wind_direction = Vector2(1.0, 0.30).normalized()
	mid_band.target_hs_m = 0.38
	mid_band.choppiness = 1.0
	mid_band.short_wave_damping_m = 0.35

	var short_band := OpenOceanFFTConfig.new()
	short_band.id = &"SHORT"
	short_band.resolution = 256
	short_band.domain_size_m = 32.0
	short_band.min_wavelength_m = 0.5
	short_band.max_wavelength_m = 5.0
	short_band.transition_width_m = 0.15
	short_band.wind_direction = Vector2(1.0, 0.45).normalized()
	short_band.target_hs_m = 0.15
	short_band.choppiness = 0.90
	short_band.short_wave_damping_m = 0.20

	return [long_band, mid_band, short_band]

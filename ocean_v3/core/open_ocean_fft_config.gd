class_name OpenOceanFFTConfig
extends Resource
## Configuración física mínima de la única cascada permitida en Fase 1A.

@export var resolution: int = 256
@export var domain_size_m: float = 128.0
@export var gravity_mps2: float = 9.81
@export var wind_direction := Vector2(1.0, 0.35)
@export var wind_speed_mps: float = 12.0
@export var energy: float = 0.00016
@export_range(1.0, 12.0, 0.1) var directional_spread: float = 4.0
@export var short_wave_damping_m: float = 0.35
@export_range(0.0, 1.5, 0.01) var choppiness: float = 1.0


func is_valid() -> bool:
	return (
		resolution >= 2
		and (resolution & (resolution - 1)) == 0
		and domain_size_m > 0.0
		and gravity_mps2 > 0.0
		and wind_speed_mps >= 0.0
		and energy >= 0.0
	)


func fft_stage_count() -> int:
	return int(round(log(float(resolution)) / log(2.0)))


func compute_pass_count() -> int:
	return 2 * fft_stage_count() + 2


func approximate_gpu_bytes() -> int:
	# H0 + 4 ping-pong RGBA32F + displacement RGBA32F + normal RGBA16F.
	return resolution * resolution * (16 * 6 + 8)

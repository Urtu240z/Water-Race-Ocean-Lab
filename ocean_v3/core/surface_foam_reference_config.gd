class_name SurfaceFoamReferenceConfig
extends Resource
## Configuración técnica aislada para la máscara Surface Foam compatible con
## GodotOceanWaves. No representa energía/altura del océano físico.

@export var id: StringName = &"SURFACE_FOAM"
@export var resolution := 512
@export var domain_size_m := 88.0
@export var gravity_mps2 := 9.81
@export var depth_m := 20.0
@export var wind_direction := Vector2.RIGHT
@export var wind_speed_mps := 25.0
@export var fetch_length_m := 6000.0
@export_range(0.0, 1.0, 0.001) var swell := 0.779
# 0 = Hasselmann completo/direccional; 1 = 1/(2π) isotrópico.
@export_range(0.0, 1.0, 0.01) var directional_spread := 0.0
@export_range(0.0, 1.0, 0.01) var detail := 1.0

# API mínima que reutiliza GPUStockhamFFT. No hay target_hs_m, band-pass ni
# multiplicador de choppiness en la ruta reference-compatible.
var foam_enabled := false
var foam_whitecap := 0.0
var foam_amount := 0.0
var foam_decay := 0.5
var foam_cascade_weight := 0.0


func is_valid() -> bool:
	return resolution >= 2 \
		and (resolution & (resolution - 1)) == 0 \
		and domain_size_m > 0.0 \
		and gravity_mps2 > 0.0 \
		and depth_m > 0.0 \
		and wind_speed_mps > 0.0 \
		and fetch_length_m > 0.0


func fft_stage_count() -> int:
	return int(round(log(float(resolution)) / log(2.0)))


func compute_pass_count() -> int:
	# Evolve + IFFT axes + assemble + R16F Surface Foam + previous snapshot.
	return 2 * fft_stage_count() + 3


func approximate_gpu_bytes() -> int:
	# H0 + six RGBA32F Stockham work maps + RGBA32F displacement + RGBA16F
	# derivative target. The persistent R16F accumulator is counted by solver.
	return resolution * resolution * (16 * 8 + 8)

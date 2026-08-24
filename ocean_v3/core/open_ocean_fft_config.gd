class_name OpenOceanFFTConfig
extends Resource
## Configuración física de una cascada espectral. El módulo sigue siendo único.

enum SpectrumModel {
	PHILLIPS,
	JONSWAP_HASSELMANN,
}

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
# A/B de espectro. PHILLIPS = actual (sin cambios). JONSWAP_HASSELMANN = nuevo.
@export var spectrum_model: int = SpectrumModel.PHILLIPS
# JONSWAP+Hasselmann (deep/open-ocean, sin TMA). La altura final la fija target_hs_m.
@export var fetch_length_m := 1000.0
@export_range(0.0, 1.0, 0.05) var swell := 0.5
@export var jonswap_alpha := 0.0081
@export_range(0.0, 1.0, 0.05) var detail := 1.0
# 5R.1: mezcla direccional JONSWAP. 0 = Hasselmann (direccional), 1 = flat/isotrópico.
@export_range(0.0, 1.0, 0.05) var jonswap_spread := 0.2

# Whitecaps: physical per-band controls for the dedicated high-resolution R16F
# persistent field. normal_map.a retains the prior 256² mask for diagnostics
# only. Rates are interpreted per second and multiplied by the real frame delta
# by GPUStockhamFFT before dispatch.
@export var foam_enabled := true
@export_range(0.0, 2.0, 0.01) var foam_whitecap := 0.5
@export_range(0.0, 4.0, 0.01) var foam_amount := 0.8
@export_range(0.0, 12.0, 0.01) var foam_decay := 5.0
@export_range(0.0, 1.0, 0.01) var foam_cascade_weight := 1.0

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
		and foam_whitecap >= 0.0
		and foam_amount >= 0.0
		and foam_decay >= 0.0
		and foam_cascade_weight >= 0.0
		and foam_cascade_weight <= 1.0
		# La configuración pública es positiva; Tessendorf aplica lambda negativa
		# internamente para comprimir crestas. No se permite choppiness negativo.
		and choppiness >= 0.0
	)


func fft_stage_count() -> int:
	return int(round(log(float(resolution)) / log(2.0)))


func compute_pass_count() -> int:
	# Evolve + Stockham axes + assemble + high-resolution foam update.
	return 2 * fft_stage_count() + 3


func approximate_gpu_bytes() -> int:
	# H0 + 6 ping-pong RGBA32F (height/displacement + spectral derivatives)
	# + displacement RGBA32F + normal RGBA16F.
	return resolution * resolution * (16 * 8 + 8)

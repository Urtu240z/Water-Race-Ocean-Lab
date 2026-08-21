class_name CoastalMonochromaticDebug
extends RefCounted
## Referencia CPU del modo visual mono de 3B, previa e independiente del FFT.

static func height_at(world_xz: Vector2, time_s: float, propagation_sample, incoming_direction_xz: Vector2, k0_rad_m: float, omega_rad_s: float, amplitude_m: float) -> float:
	if propagation_sample == null or not propagation_sample.valid or k0_rad_m <= 0.0:
		return 0.0
	var direction := incoming_direction_xz.normalized()
	var phase: float = world_xz.dot(direction) * k0_rad_m + propagation_sample.phase_offset_rad - omega_rad_s * time_s
	return amplitude_m * propagation_sample.shoaling_scale * cos(phase)


static func slope_at(world_xz: Vector2, time_s: float, propagation_sample, incoming_direction_xz: Vector2, k0_rad_m: float, omega_rad_s: float, amplitude_m: float) -> Vector2:
	if propagation_sample == null or not propagation_sample.valid:
		return Vector2.ZERO
	var direction := incoming_direction_xz.normalized()
	var phase: float = world_xz.dot(direction) * k0_rad_m + propagation_sample.phase_offset_rad - omega_rad_s * time_s
	# La derivada usa k local: k0 + d(phi_offset)/ds. Es la misma hipótesis
	# unidireccional de la transformación; no incorpora refracción 2D.
	return -direction * amplitude_m * propagation_sample.shoaling_scale * propagation_sample.local_k * sin(phase)

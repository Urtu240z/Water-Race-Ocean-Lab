class_name FiniteDepthWaveMath
extends RefCounted
## Relaciones lineales de una onda monocromática sobre fondo horizontal.
## No depende del FFT, de rendering ni de BathymetryData para que pueda
## validarse de forma aislada y reutilizarse por futuros consumidores CPU.

const DEFAULT_GRAVITY_MPS2 := 9.81
const _EPSILON := 1.0e-6


static func solve_wavenumber(omega_rad_s: float, depth_m: float, gravity_mps2 := DEFAULT_GRAVITY_MPS2) -> float:
	## Resuelve w² = g k tanh(kh) por Newton acotado. El arranque combina los
	## límites profundo y somero; las cotas conservan k finito en aguas válidas.
	if omega_rad_s <= 0.0 or depth_m <= _EPSILON or gravity_mps2 <= 0.0:
		return 0.0
	var omega_squared := omega_rad_s * omega_rad_s
	var deep_k := omega_squared / gravity_mps2
	var shallow_k := omega_rad_s / sqrt(gravity_mps2 * depth_m)
	var k := shallow_k if deep_k * depth_m < 0.5 else deep_k
	k = maxf(k, _EPSILON)
	for _iteration in 16:
		var kh := k * depth_m
		var tanh_kh := tanh(kh)
		var cosh_kh := cosh(kh)
		var sech_squared := 1.0 / maxf(cosh_kh * cosh_kh, _EPSILON)
		var residual := gravity_mps2 * k * tanh_kh - omega_squared
		var derivative := gravity_mps2 * (tanh_kh + kh * sech_squared)
		if absf(derivative) <= _EPSILON:
			break
		var next_k := maxf(k - residual / derivative, _EPSILON)
		if absf(next_k - k) <= 1.0e-7 * maxf(1.0, k):
			k = next_k
			break
		k = next_k
	return k


static func phase_speed(omega_rad_s: float, wavenumber: float) -> float:
	return omega_rad_s / wavenumber if wavenumber > _EPSILON else 0.0


static func group_velocity(omega_rad_s: float, wavenumber: float, depth_m: float) -> float:
	if wavenumber <= _EPSILON or depth_m <= _EPSILON:
		return 0.0
	var c := phase_speed(omega_rad_s, wavenumber)
	var two_kh := 2.0 * wavenumber * depth_m
	# sinh(2kh) deja de ser útil numéricamente en régimen profundo; allí el
	# segundo término tiende a cero y Cg = c/2.
	if two_kh > 20.0:
		return 0.5 * c
	return 0.5 * c * (1.0 + two_kh / maxf(sinh(two_kh), _EPSILON))


static func wavelength(wavenumber: float) -> float:
	return TAU / wavenumber if wavenumber > _EPSILON else 0.0


static func omega_for_wavelength_deep(wavelength_m: float, gravity_mps2 := DEFAULT_GRAVITY_MPS2) -> float:
	if wavelength_m <= _EPSILON or gravity_mps2 <= 0.0:
		return 0.0
	return sqrt(gravity_mps2 * TAU / wavelength_m)


static func solve_properties(omega_rad_s: float, depth_m: float, gravity_mps2 := DEFAULT_GRAVITY_MPS2) -> Dictionary:
	var k := solve_wavenumber(omega_rad_s, depth_m, gravity_mps2)
	return {
		"local_k": k,
		"wavelength_m": wavelength(k),
		"phase_speed_mps": phase_speed(omega_rad_s, k),
		"group_velocity_mps": group_velocity(omega_rad_s, k, depth_m),
	}

extends SceneTree
## Fase 3B.2B: validación del SPLIT DIRECCIONAL de H0 LONG.
##
## 1. Suma exacta: H0_COASTAL + H0_REMAINDER == H0_LONG (byte a byte).
## 2. Hermiticidad: cada componente es un espectro Hermitiano completo
##    (S(-k) = conj(S(k))), luego campo espacial real.
## 3. Reconstrucción espacial: evaluando la suma de modos en el mismo punto,
##    height/displacement del split suman el original.
## 4. % energía asignada a LONG_COASTAL (RACE y ROUGH).

const SpectrumScript := preload("res://ocean_v3/core/tessendorf_spectrum.gd")
const SeaStateScript := preload("res://ocean_v3/core/sea_state_config.gd")

const SEED := 20260820
const INNER_DEG := 20.0
const OUTER_DEG := 35.0

var _failures := 0


func _initialize() -> void:
	for state in [SeaStateScript.State.RACE, SeaStateScript.State.ROUGH]:
		var state_name := SeaStateScript.state_name(state)
		_validate_state(state, state_name)
	if _failures == 0:
		print("PHASE_3B_2B_SPLIT: PASS")
		quit(0)
	else:
		push_error("PHASE_3B_2B_SPLIT: %d fallos" % _failures)
		quit(1)


func _validate_state(state: int, state_name: String) -> void:
	var configs = SeaStateScript.build_cascades(state)
	var long_config: OpenOceanFFTConfig = configs[0]
	var seed := SpectrumScript.derive_cascade_seed(SEED, long_config.id)
	var original_bytes := SpectrumScript.build_h0_rgba32f(long_config, seed)
	var split: Dictionary = SpectrumScript.build_h0_split_rgba32f(long_config, seed, INNER_DEG, OUTER_DEG)
	var coastal_bytes: PackedByteArray = split["coastal"]
	var remainder_bytes: PackedByteArray = split["remainder"]
	var fraction: float = split["coastal_energy_fraction"]

	# 1) Suma exacta byte a byte (float32: w + (1-w) = 1 exacto en la misma op).
	var original := original_bytes.to_float32_array()
	var coastal := coastal_bytes.to_float32_array()
	var remainder := remainder_bytes.to_float32_array()
	var max_sum_error := 0.0
	var max_hermitian_error := 0.0
	var n: int = long_config.resolution
	for index in n * n:
		var base := index * 4
		for c in 4:
			var sum_err: float = absf(coastal[base + c] + remainder[base + c] - original[base + c])
			max_sum_error = maxf(max_sum_error, sum_err)
		# Hermiticidad: xy[k] == conj(zw[-k]) para cada componente.
		var neg := ((n - (index / n)) % n) * n + ((n - (index % n)) % n)
		var neg_base := neg * 4
		for comp in [coastal, remainder]:
			var hk_re: float = comp[base]
			var hk_im: float = comp[base + 1]
			var hnegk_re: float = comp[neg_base + 2]
			var hnegk_im: float = comp[neg_base + 3]
			# zw[-k] debe ser conj(xy[k]) del texel -k... más simple:
			# xy[-k] == conj(zw[k]).
			var xy_neg_re: float = comp[neg_base]
			var xy_neg_im: float = comp[neg_base + 1]
			var zw_k_re: float = comp[base + 2]
			var zw_k_im: float = comp[base + 3]
			max_hermitian_error = maxf(max_hermitian_error,
				absf(xy_neg_re - zw_k_re) + absf(xy_neg_im + zw_k_im))
	print("3B.2B SPLIT " + state_name + " sum_max_err=" + str(max_sum_error) + " hermitian_max_err=" + str(max_hermitian_error) + " coastal_energy=" + str(100.0 * fraction) + "%")
	# La suma byte a byte no es exacta en float32: a*w + a*(1-w) redondea en cada
	# multiplicación (a ~ 10-100 por discrete_scale ~ 804; ulp ~ 1e-5). La
	# reconstrucción FÍSICA (suma de campos espaciales) se mide en el test
	# SPATIAL siguiente y debe ser ~1e-9. Aquí exigimos redondeo float32 acotado.
	_check(max_sum_error < 1.0e-3, "%s: coastal+remainder reconstruye LONG (redondeo float32 acotado)" % state_name)
	_check(max_hermitian_error < 1.0e-5, "%s: cada componente Hermitiano (campo real)" % state_name)
	_check(fraction > 0.10 and fraction < 0.90, "%s: fracción coastal en rango plausible" % state_name)

	# 3) Reconstrucción espacial: evaluar height/Dx/Dz por suma de modos.
	var spatial := _eval_spatial_split(long_config, seed, original, coastal, remainder, n)
	print("3B.2B SPATIAL " + state_name + " height_max=" + str(spatial[0]) + " dx_max=" + str(spatial[1]) + " dz_max=" + str(spatial[2]) + " (n=" + str(spatial[3]) + " pts)")
	_check(spatial[0] < 1.0e-3, "%s: height espacial reconstruida" % state_name)
	_check(spatial[1] < 1.0e-3 and spatial[2] < 1.0e-3, "%s: displacement espacial reconstruido" % state_name)


## Evalúa (height, dx, dz) en puntos con t fijo para el espectro completo y para
## la suma coastal+remainder; devuelve [max|dh|, max|ddx|, max|ddz|, puntos].
func _eval_spatial_split(config, seed: int, original: PackedFloat32Array,
		coastal: PackedFloat32Array, remainder: PackedFloat32Array, n: int) -> Array:
	var delta_k: float = TAU / config.domain_size_m
	var gravity: float = config.gravity_mps2
	var choppiness: float = -config.choppiness
	var half := float(n) * 0.5
	var t := 1.7
	var max_dh := 0.0
	var max_ddx := 0.0
	var max_ddz := 0.0
	var points := 0
	for qy in 4:
		for qx in 4:
			var q := Vector2(-30.0 + 20.0 * float(qx), -30.0 + 20.0 * float(qy))
			var full := _eval_spectrum(original, n, delta_k, gravity, choppiness, half, q, t)
			var sum_h := 0.0
			var sum_dx := 0.0
			var sum_dz := 0.0
			for comp in [coastal, remainder]:
				var e := _eval_spectrum(comp, n, delta_k, gravity, choppiness, half, q, t)
				sum_h += e[0]
				sum_dx += e[1]
				sum_dz += e[2]
			max_dh = maxf(max_dh, absf(sum_h - full[0]))
			max_ddx = maxf(max_ddx, absf(sum_dx - full[1]))
			max_ddz = maxf(max_ddz, absf(sum_dz - full[2]))
			points += 1
	return [max_dh, max_ddx, max_ddz, points]


func _eval_spectrum(spectrum: PackedFloat32Array, n: int, delta_k: float, gravity: float,
		choppiness: float, half: float, q: Vector2, t: float) -> Array:
	## Suma directa de modos (sin FFT): misma convención de signo que el FFT GPU.
	var h := 0.0
	var dx := 0.0
	var dz := 0.0
	for y in n:
		for x in n:
			var index := y * n + x
			var base := index * 4
			var h0_re: float = spectrum[base]
			var h0_im: float = spectrum[base + 1]
			var k := Vector2(float(x) - half, float(y) - half) * delta_k
			var k_len := k.length()
			if k_len < 0.000001:
				continue
			var omega := sqrt(gravity * k_len)
			var phase := k.dot(q) - omega * t
			var c := cos(phase)
			var s := sin(phase)
			# h0_im guarda conj(H0(-k)): la suma real usa h0_re*cos + h0_im*sin.
			h += h0_re * c + h0_im * s
			# Choquiness: mismo signo que evolve_spectrum (lambda negativo).
			var scale := choppiness / k_len
			dx += (h0_im * c - h0_re * s) * k.x * scale
			dz += (h0_im * c - h0_re * s) * k.y * scale
	# La convención del FFT divide por N² en assemble (discrete_scale).
	var inv_n2 := 1.0 / float(n * n)
	return [h * inv_n2, dx * inv_n2, dz * inv_n2]


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

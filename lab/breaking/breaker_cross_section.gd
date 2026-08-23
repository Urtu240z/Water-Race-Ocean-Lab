class_name BreakerCrossSection
extends RefCounted
## Prototipo aislado: sección transversal de una ola rompiente tipo PLUNGING.
##
## La silueta es una curva abierta EXPLÍCITA formada por dos tramos:
##   - outer curve: cara visible (agua trasera → subida → cresta → punta).
##   - inner curve: interior del labio/tubo (punta → baja por dentro → base → salida).
## Ambas se unen en la punta (compartida) y salen por delante cerca del agua.
##
## Cada tramo se define por PUNTOS DE CONTROL por keyframe (13 OUTER + 14 INNER,
## 26 únicos); entre keyframes se interpola por índice y se suaviza con
## Catmull-Rom CENTRÍPETO (sin overshoot). `point(s, stage)` recorre la curva
## remuestreada por LONGITUD DE ARCO (búsqueda binaria), uniforme en s.
##
## Plano local: X = forward (hacia la costa), Y = up. En stage alto la coordenada
## X deja de ser monótona tras la punta (advance → reverse → advance) => overhang
## real con forma de C abierta, sin círculo ni espiral.

const _STAGE_KEYS: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]

# OUTER (13): agua trasera, subida, cara, cresta (redondeada, casi plana arriba),
# approach y punta/nose (máximo forward).
const _OUTER_SHAPES: Array = [
	# 0.0 — swell suave (sin reverse).
	[
		Vector2(-6.00, 0.00), Vector2(-5.20, 0.00), Vector2(-4.60, 0.03),
		Vector2(-3.70, 0.10), Vector2(-2.80, 0.20), Vector2(-1.90, 0.32),
		Vector2(-1.00, 0.42), Vector2(-0.10, 0.48), Vector2(0.75, 0.52),
		Vector2(1.55, 0.53), Vector2(2.15, 0.50), Vector2(2.55, 0.42),
		Vector2(2.75, 0.34),
	],
	# 0.25 — cara baja, cresta redondeada (sin reverse).
	[
		Vector2(-6.00, 0.00), Vector2(-5.20, 0.00), Vector2(-4.60, 0.08),
		Vector2(-3.70, 0.25), Vector2(-2.80, 0.48), Vector2(-1.90, 0.72),
		Vector2(-1.00, 0.92), Vector2(-0.10, 1.05), Vector2(0.75, 1.12),
		Vector2(1.55, 1.14), Vector2(2.15, 1.08), Vector2(2.55, 0.94),
		Vector2(2.75, 0.78),
	],
	# 0.5 — cara clara, cresta formada (SIN overhang: X sigue avanzando).
	[
		Vector2(-6.00, 0.00), Vector2(-5.20, 0.00), Vector2(-4.60, 0.12),
		Vector2(-3.70, 0.38), Vector2(-2.80, 0.72), Vector2(-1.90, 1.10),
		Vector2(-1.00, 1.48), Vector2(-0.10, 1.78), Vector2(0.75, 1.95),
		Vector2(1.55, 2.00), Vector2(2.15, 1.90), Vector2(2.55, 1.70),
		Vector2(2.75, 1.50),
	],
	# 0.75 — labio proyectado, reverse moderado (overhang claro pero contenido).
	[
		Vector2(-6.00, 0.00), Vector2(-5.20, 0.00), Vector2(-4.60, 0.14),
		Vector2(-3.70, 0.44), Vector2(-2.80, 0.88), Vector2(-1.90, 1.36),
		Vector2(-1.00, 1.86), Vector2(-0.10, 2.24), Vector2(0.75, 2.48),
		Vector2(1.55, 2.56), Vector2(2.15, 2.50), Vector2(2.55, 2.32),
		Vector2(2.75, 2.10),
	],
	# 1.0 — plunging completo (C abierta).
	[
		Vector2(-6.00, 0.00), Vector2(-5.20, 0.00), Vector2(-4.60, 0.15),
		Vector2(-3.70, 0.50), Vector2(-2.80, 1.05), Vector2(-1.90, 1.65),
		Vector2(-1.00, 2.25), Vector2(-0.10, 2.65), Vector2(0.75, 2.85),
		Vector2(1.55, 2.88), Vector2(2.15, 2.82), Vector2(2.55, 2.62),
		Vector2(2.75, 2.38),
	],
]

# INNER (14): punta (compartida), giro corto abajo, retorno interior amplio,
# pared interior curva, bottom turn, salida delantera.
const _INNER_SHAPES: Array = [
	# 0.0 — interior degenerado (sin reverse).
	[
		Vector2(2.75, 0.34), Vector2(2.90, 0.26), Vector2(3.05, 0.18),
		Vector2(3.20, 0.12), Vector2(3.35, 0.08), Vector2(3.50, 0.05),
		Vector2(3.65, 0.03), Vector2(3.80, 0.02), Vector2(3.95, 0.01),
		Vector2(4.10, 0.00), Vector2(4.25, 0.00), Vector2(4.40, 0.00),
		Vector2(4.55, 0.00), Vector2(4.70, 0.00),
	],
	# 0.25 — sin reverse.
	[
		Vector2(2.75, 0.78), Vector2(2.90, 0.62), Vector2(3.05, 0.46),
		Vector2(3.20, 0.32), Vector2(3.35, 0.22), Vector2(3.50, 0.14),
		Vector2(3.65, 0.09), Vector2(3.80, 0.05), Vector2(3.95, 0.03),
		Vector2(4.10, 0.01), Vector2(4.25, 0.00), Vector2(4.40, 0.00),
		Vector2(4.55, 0.00), Vector2(4.70, 0.00),
	],
	# 0.5 — SIN overhang: nose (x=2.75) ≤ inner1 (x=2.85).
	[
		Vector2(2.75, 1.50), Vector2(2.85, 1.30), Vector2(2.95, 1.05),
		Vector2(3.05, 0.82), Vector2(3.15, 0.62), Vector2(3.25, 0.46),
		Vector2(3.35, 0.33), Vector2(3.45, 0.23), Vector2(3.55, 0.15),
		Vector2(3.65, 0.10), Vector2(3.75, 0.06), Vector2(3.90, 0.03),
		Vector2(4.05, 0.01), Vector2(4.20, 0.00),
	],
	# 0.75 — reverse moderado.
	[
		Vector2(2.75, 2.10), Vector2(2.60, 1.90), Vector2(2.40, 1.80),
		Vector2(2.15, 1.80), Vector2(1.95, 1.70), Vector2(1.80, 1.50),
		Vector2(1.72, 1.25), Vector2(1.70, 1.00), Vector2(1.80, 0.78),
		Vector2(2.00, 0.55), Vector2(2.30, 0.36), Vector2(2.70, 0.22),
		Vector2(3.10, 0.18), Vector2(3.40, 0.20),
	],
	# 1.0 — retorno interior amplio + bottom turn (advance → reverse → advance).
	[
		Vector2(2.75, 2.38), Vector2(2.58, 2.30), Vector2(2.25, 2.34),
		Vector2(1.85, 2.43), Vector2(1.35, 2.30), Vector2(0.95, 2.02),
		Vector2(0.75, 1.65), Vector2(0.72, 1.20), Vector2(0.85, 0.82),
		Vector2(1.15, 0.50), Vector2(1.65, 0.28), Vector2(2.35, 0.15),
		Vector2(3.20, 0.15), Vector2(3.80, 0.32),
	],
]

const _RESAMPLE_COUNT := 256

static var _cache_stage := -1.0
static var _samples := PackedVector2Array()
static var _cum := PackedFloat32Array()


static func point(s: float, stage: float) -> Vector2:
	## Punto sobre la silueta (remuestreada por longitud de arco).
	_ensure_cache(stage)
	var total := _cum[_RESAMPLE_COUNT - 1]
	var target := clampf(s, 0.0, 1.0) * total
	var lo := 0
	var hi := _RESAMPLE_COUNT - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _cum[mid] < target:
			lo = mid + 1
		else:
			hi = mid
	var i := clampi(lo - 1, 0, _RESAMPLE_COUNT - 2)
	var seg_len := _cum[i + 1] - _cum[i]
	var f := (target - _cum[i]) / maxf(seg_len, 1.0e-9)
	return _samples[i].lerp(_samples[i + 1], f)


static func normal(s: float, stage: float) -> Vector2:
	## Normal 2D por diferencia finita sobre la silueta (tangente → perpendicular).
	var eps := 0.003
	var p0 := point(clampf(s - eps, 0.0, 1.0), stage)
	var p1 := point(clampf(s + eps, 0.0, 1.0), stage)
	var tangent := p1 - p0
	var n := Vector2(-tangent.y, tangent.x)
	return n.normalized() if n.length_squared() > 1.0e-8 else Vector2.UP


static func _ensure_cache(stage: float) -> void:
	if absf(stage - _cache_stage) < 1.0e-6:
		return
	_cache_stage = stage
	_build_cache(stage)


static func _build_cache(stage: float) -> void:
	var outer: Array = _interpolated_points(stage, _OUTER_SHAPES)
	var inner: Array = _interpolated_points(stage, _INNER_SHAPES)
	# Polilínea completa: outer (atrás→punta) + inner[1..] (punta→salida).
	var ctrl := PackedVector2Array()
	for p in outer:
		ctrl.append(p as Vector2)
	for i in range(1, inner.size()):
		ctrl.append(inner[i] as Vector2)
	var n := ctrl.size()
	var seg_count := n - 1
	_samples.resize(_RESAMPLE_COUNT)
	_cum.resize(_RESAMPLE_COUNT)
	for idx in _RESAMPLE_COUNT:
		var u_full := float(idx) / float(_RESAMPLE_COUNT - 1) * float(seg_count)
		var seg := clampi(int(floor(u_full)), 0, seg_count - 1)
		var lu := u_full - float(seg)
		var p0: Vector2 = ctrl[clampi(seg - 1, 0, n - 1)]
		var p1: Vector2 = ctrl[seg]
		var p2: Vector2 = ctrl[seg + 1]
		var p3: Vector2 = ctrl[clampi(seg + 2, 0, n - 1)]
		_samples[idx] = _catmull_rom(p0, p1, p2, p3, lu)
	_cum[0] = 0.0
	for idx in range(1, _RESAMPLE_COUNT):
		_cum[idx] = _cum[idx - 1] + _samples[idx - 1].distance_to(_samples[idx])


static func _interpolated_points(stage: float, shapes: Array) -> Array:
	var t := clampf(stage, 0.0, 1.0)
	var idx := 0
	for i in _STAGE_KEYS.size() - 1:
		if t <= _STAGE_KEYS[i + 1]:
			idx = i
			break
	var a := _STAGE_KEYS[idx]
	var b := _STAGE_KEYS[idx + 1]
	var f := (t - a) / maxf(b - a, 1.0e-6)
	var a_pts: Array = shapes[idx]
	var b_pts: Array = shapes[idx + 1]
	var out: Array = []
	for i in a_pts.size():
		out.append((a_pts[i] as Vector2).lerp(b_pts[i] as Vector2, f))
	return out


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	## Catmull-Rom CENTRÍPETO (alpha=0.5): sin el overshoot del uniforme.
	var d01 := sqrt(p0.distance_to(p1))
	var d12 := sqrt(p1.distance_to(p2))
	var d23 := sqrt(p2.distance_to(p3))
	var t0 := 0.0
	var t1 := d01
	var t2 := d01 + d12
	var t3 := d01 + d12 + d23
	var t := t1 + (t2 - t1) * u
	var a1 := _lerp3(p0, p1, t0, t1, t)
	var a2 := _lerp3(p1, p2, t1, t2, t)
	var a3 := _lerp3(p2, p3, t2, t3, t)
	var b1 := _lerp3(a1, a2, t0, t2, t)
	var b2 := _lerp3(a2, a3, t1, t3, t)
	return _lerp3(b1, b2, t1, t2, t)


static func _lerp3(a: Vector2, b: Vector2, ta: float, tb: float, t: float) -> Vector2:
	var d := tb - ta
	if absf(d) < 1.0e-9:
		return b
	return a.lerp(b, clampf((t - ta) / d, 0.0, 1.0))

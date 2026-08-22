class_name BreakerCrossSection
extends RefCounted
## Prototipo aislado: sección transversal EXPLÍCITA de una ola rompiente
## (plunging breaker). La silueta viene de PUNTOS DE CONTROL 2D interpolados por
## stage y suavizados con Catmull-Rom. Sin arco circular, sin espiral, sin rueda.
##
## Plano local: X = forward (hacia la costa), Y = up. s ∈ [0,1] recorre la curva
## desde el agua trasera hasta la salida delantera. La clave es que, en stages
## altos, la coordenada horizontal deja de ser monótona tras la punta (el labio
## pasa por delante y luego baja por dentro) => overhang real, sin cerrar círculo.

# Keyframes del stage (0..1). Entre ellos se interpola linealmente cada punto.
const _STAGE_KEYS: Array[float] = [0.0, 0.25, 0.5, 0.7, 1.0]

# Puntos de control por keyframe (misma cantidad y semántica, 10 puntos):
#   agua trasera, subida, media cara, shoulder, cresta, punta,
#   inner-lip superior, inner-lip inferior, base interior, salida delantera.
const _SHAPES: Array = [
	# 0.0 — swell casi plano.
	[
		Vector2(-7.0, 0.00), Vector2(-5.0, 0.03), Vector2(-3.0, 0.10),
		Vector2(-1.0, 0.20), Vector2(0.0, 0.25), Vector2(0.7, 0.22),
		Vector2(1.2, 0.15), Vector2(1.7, 0.08), Vector2(2.2, 0.03), Vector2(3.0, 0.00),
	],
	# 0.25 — cara baja, sin curl.
	[
		Vector2(-7.0, 0.00), Vector2(-5.0, 0.06), Vector2(-3.0, 0.22),
		Vector2(-1.2, 0.55), Vector2(0.0, 0.80), Vector2(0.7, 0.72),
		Vector2(1.1, 0.55), Vector2(1.5, 0.32), Vector2(2.0, 0.14), Vector2(3.0, 0.00),
	],
	# 0.5 — cara clara, cresta formada.
	[
		Vector2(-7.0, 0.00), Vector2(-5.0, 0.12), Vector2(-2.8, 0.50),
		Vector2(-1.2, 1.00), Vector2(0.0, 1.32), Vector2(0.9, 1.16),
		Vector2(1.2, 0.88), Vector2(1.4, 0.50), Vector2(1.9, 0.22), Vector2(3.0, 0.00),
	],
	# 0.7 — labio proyectándose hacia delante.
	[
		Vector2(-7.0, 0.00), Vector2(-5.0, 0.16), Vector2(-2.5, 0.62),
		Vector2(-1.0, 1.22), Vector2(0.0, 1.55), Vector2(1.2, 1.42),
		Vector2(1.15, 0.92), Vector2(1.05, 0.52), Vector2(1.5, 0.22), Vector2(3.0, 0.00),
	],
	# 1.0 — plunging breaker: punta adelantada, caída interior, sin círculo entero.
	[
		Vector2(-7.0, 0.00), Vector2(-5.0, 0.20), Vector2(-2.3, 0.72),
		Vector2(-0.8, 1.40), Vector2(0.0, 1.62), Vector2(1.28, 1.34),
		Vector2(0.80, 0.72), Vector2(0.55, 0.28), Vector2(1.15, 0.06), Vector2(3.0, 0.00),
	],
]


static func point(s: float, stage: float) -> Vector2:
	return _sample_spline(_interpolated_points(stage), s)


static func normal(s: float, stage: float) -> Vector2:
	## Normal 2D por diferencias finitas sobre la spline. Estable y suficiente
	## para leer la forma en LIT.
	var eps := 0.004
	var p0 := point(clampf(s - eps, 0.0, 1.0), stage)
	var p1 := point(clampf(s + eps, 0.0, 1.0), stage)
	var tangent := p1 - p0
	var n := Vector2(-tangent.y, tangent.x)
	return n.normalized() if n.length_squared() > 1.0e-8 else Vector2.UP


static func _interpolated_points(stage: float) -> Array:
	var t := clampf(stage, 0.0, 1.0)
	var idx := 0
	for i in _STAGE_KEYS.size() - 1:
		if t <= _STAGE_KEYS[i + 1]:
			idx = i
			break
	var a := _STAGE_KEYS[idx]
	var b := _STAGE_KEYS[idx + 1]
	var f := (t - a) / maxf(b - a, 1.0e-6)
	var a_pts: Array = _SHAPES[idx]
	var b_pts: Array = _SHAPES[idx + 1]
	var out: Array = []
	for i in a_pts.size():
		out.append((a_pts[i] as Vector2).lerp(b_pts[i] as Vector2, f))
	return out


static func _sample_spline(points: Array, s: float) -> Vector2:
	var n := points.size()
	var seg := clampf(s, 0.0, 1.0) * float(n - 1)
	var i := clampi(int(floor(seg)), 0, n - 2)
	var t := seg - float(i)
	var p0: Vector2 = points[clampi(i - 1, 0, n - 1)]
	var p1: Vector2 = points[i]
	var p2: Vector2 = points[i + 1]
	var p3: Vector2 = points[clampi(i + 2, 0, n - 1)]
	return _catmull_rom(p0, p1, p2, p3, t)


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)

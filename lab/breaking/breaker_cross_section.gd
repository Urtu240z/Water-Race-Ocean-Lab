class_name BreakerCrossSection
extends RefCounted
## Prototipo aislado: sección transversal de una ola rompiente tipo PLUNGING.
##
## La silueta es una curva abierta EXPLÍCITA formada por dos tramos:
##   - outer curve: cara visible (agua trasera → subida → cresta → punta).
##   - inner curve: interior del labio/tubo (punta → baja por dentro → base → salida).
## Ambas se unen en la punta y salen por delante casi a nivel del agua.
##
## Cada tramo se define por PUNTOS DE CONTROL por keyframe; entre keyframes se
## interpola por índice y se suaviza con Catmull-Rom CENTRÍPETO (sin overshoot).
## `point(s, stage)` recorre la curva remuestreada por LONGITUD DE ARCO, de modo
## que s ∈ [0,1] avanza uniformemente. La coordenada x deja de ser monótona tras
## la punta (el labio pasa por delante y baja por dentro) => overhang real, sin
## cerrar un círculo ni formar espiral.
##
## Plano local: X = forward (hacia la costa), Y = up.

const _STAGE_KEYS: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]

# Puntos de control OUTER (7): agua trasera, subida1, subida2, media cara,
# shoulder, cresta, punta.
const _OUTER_SHAPES: Array = [
	# 0.0 — swell suave.
	[
		Vector2(-8.0, 0.00), Vector2(-6.0, 0.02), Vector2(-4.0, 0.08),
		Vector2(-2.0, 0.18), Vector2(-1.0, 0.24), Vector2(0.0, 0.26), Vector2(0.7, 0.22),
	],
	# 0.25 — cara baja, cresta redondeada.
	[
		Vector2(-8.0, 0.00), Vector2(-6.0, 0.05), Vector2(-4.0, 0.20),
		Vector2(-2.0, 0.50), Vector2(-0.8, 0.72), Vector2(0.0, 0.78), Vector2(0.7, 0.68),
	],
	# 0.5 — cara clara, cresta formada, inicio de proyección.
	[
		Vector2(-8.0, 0.00), Vector2(-6.0, 0.12), Vector2(-4.0, 0.42),
		Vector2(-2.0, 0.92), Vector2(-0.6, 1.28), Vector2(0.0, 1.34), Vector2(0.9, 1.12),
	],
	# 0.75 — labio proyectado, overhang claro, interior visible.
	[
		Vector2(-8.0, 0.00), Vector2(-6.0, 0.16), Vector2(-4.0, 0.55),
		Vector2(-2.0, 1.12), Vector2(-0.5, 1.45), Vector2(0.0, 1.52), Vector2(1.2, 1.38),
	],
	# 1.0 — plunging claro: cara larga, labio adelantado, interior que baja.
	[
		Vector2(-8.0, 0.00), Vector2(-6.0, 0.20), Vector2(-4.0, 0.65),
		Vector2(-2.0, 1.20), Vector2(-0.5, 1.52), Vector2(0.0, 1.60), Vector2(1.3, 1.32),
	],
]

# Puntos de control INNER (6): punta (compartida con outer), interior superior,
# interior medio, base interior, base exterior, salida delantera.
const _INNER_SHAPES: Array = [
	# 0.0 — interior casi degenerado (la ola aún no rompe).
	[
		Vector2(0.7, 0.22), Vector2(1.0, 0.16), Vector2(1.3, 0.10),
		Vector2(1.6, 0.05), Vector2(2.0, 0.02), Vector2(3.0, 0.00),
	],
	# 0.25
	[
		Vector2(0.7, 0.68), Vector2(0.9, 0.50), Vector2(1.1, 0.32),
		Vector2(1.4, 0.14), Vector2(1.9, 0.06), Vector2(3.0, 0.00),
	],
	# 0.5
	[
		Vector2(0.9, 1.12), Vector2(0.75, 0.75), Vector2(0.70, 0.40),
		Vector2(1.00, 0.15), Vector2(1.60, 0.08), Vector2(3.0, 0.00),
	],
	# 0.75
	[
		Vector2(1.2, 1.38), Vector2(0.85, 0.85), Vector2(0.60, 0.45),
		Vector2(0.75, 0.15), Vector2(1.40, 0.08), Vector2(3.0, 0.00),
	],
	# 1.0
	[
		Vector2(1.3, 1.32), Vector2(0.90, 0.72), Vector2(0.55, 0.28),
		Vector2(0.75, 0.08), Vector2(1.50, 0.05), Vector2(3.0, 0.00),
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

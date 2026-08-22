class_name BreakerCrossSection
extends RefCounted
## Prototipo aislado: sección transversal EXPLÍCITA de una ola rompiente.
##
## La forma vive en el plano local (forward=X, up=Y) y se parametriza con:
##   - s ∈ [0,1]: coordenada longitudinal (0 = seno/trasera, 1 = punta del labio).
##   - stage ∈ [0,1]: evolución 0 = swell → 1 = plunge.
##
## La clave es que la coordenada horizontal deja de ser monótona en el frente:
## el labio es un ARCO circular que, al crecer el stage, se proyecta hacia
## delante y luego retrocede por debajo de la punta (overhang real). No es una
## suma de offsets aditivos: cada vértice sale de esta curva paramétrica.

const FACE_LENGTH_M := 6.0
const CREST_S := 0.62
const CREST_HEIGHT_M := 1.6
const CURL_RADIUS_M := 1.1


static func crest_height(stage: float) -> float:
	return CREST_HEIGHT_M * _smooth(0.0, 0.45, stage)


static func curl_radius(stage: float) -> float:
	return CURL_RADIUS_M * _smooth(0.30, 1.0, stage)


static func curl_max_angle(stage: float) -> float:
	## 0 → 270° (1.5·π). Con >180° el arco retrocede bajo la cresta.
	return 1.5 * PI * _smooth(0.35, 1.0, stage)


static func point(s: float, stage: float) -> Vector2:
	## Devuelve (x_forward, y_up) en metros.
	var t := clampf(s, 0.0, 1.0)
	var height := crest_height(stage)
	var radius := curl_radius(stage)
	var psi_max := curl_max_angle(stage)
	if t <= CREST_S:
		# Cara de la ola: rampa desde el seno hasta la cresta (x=0, y=height),
		# con pendiente suave abajo y empinándose hacia la cresta.
		var f := t / CREST_S
		var shape := pow(f, 1.4)
		return Vector2(-FACE_LENGTH_M * (1.0 - f), height * shape)
	# Labio: arco circular centrado bajo la cresta. ψ=0 en la cresta, crece hacia
	# delante y, pasado 180°, retrocede (dx/ds < 0 => overhang).
	var psi := psi_max * _smooth(CREST_S, 1.0, t)
	return Vector2(radius * sin(psi), height - radius * (1.0 - cos(psi)))


static func normal(s: float, stage: float) -> Vector2:
	## Normal 2D coherente con la curva (perpendicular al tangente, orientada
	## hacia afuera). Aproximación por diferencias finitas; estable y local.
	var eps := 0.004
	var p0 := point(clampf(s - eps, 0.0, 1.0), stage)
	var p1 := point(clampf(s + eps, 0.0, 1.0), stage)
	var tangent := p1 - p0
	var n := Vector2(-tangent.y, tangent.x)
	return n.normalized() if n.length_squared() > 1.0e-8 else Vector2.UP


static func _smooth(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / maxf(b - a, 1.0e-6), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

class_name OceanQuerySample
extends RefCounted
## Contrato de una muestra de la superficie oceánica (Fase 2A.1).
##
## Semántica estable desde 2A.1:
## - `height` = ALTURA Y ABSOLUTA en mundo (sea_level + desplazamiento vertical).
## - `displacement` = desplazamiento PARAMÉTRICO relativo: Vector3(Dx, H, Dz),
##   donde H es el desplazamiento vertical respecto al nivel medio. La
##   superficie mundial es Vector3(q.x + Dx, sea_level + H, q.z + Dz).
## - `normal` y `surface_velocity` se evalúan en el punto paramétrico q que
##   corresponde a la posición mundial consultada.
## - `surface_velocity` = derivada temporal del campo espectral en ese q
##   (movimiento orbital/local del agua); NO es velocidad de la intersección a
##   XZ fijo.
## - `jacobian_det` = detJ de la parametrización horizontal. `foldover_risk`
##   es true cuando detJ <= 0 (la superficie tiende a plegarse; diagnóstico
##   futuro para breaking, no afecta a la validez del sample).
## - `query_residual_m` / `query_iterations`: diagnóstico de la inversión
##   world_xz -> q (Newton). `valid` es false si la query no convergió o el
##   resultado no es finito.

var valid := true
var height := 0.0
var displacement := Vector3.ZERO
var normal := Vector3.UP
var surface_velocity := Vector3.ZERO
var turbulence := 0.0
var whitewater := 0.0
var jacobian_det := 1.0
var foldover_risk := false
var query_residual_m := 0.0
var query_iterations := 0


static func flat(sea_level := 0.0):
	## Superficie plana definida (usada cuando el océano está desactivado por
	## debug o cuando no hay espectro configurado).
	var sample := OceanQuerySample.new()
	sample.valid = true
	sample.height = sea_level
	sample.displacement = Vector3.ZERO
	sample.normal = Vector3.UP
	sample.surface_velocity = Vector3.ZERO
	sample.jacobian_det = 1.0
	sample.foldover_risk = false
	sample.query_residual_m = 0.0
	sample.query_iterations = 0
	return sample


static func invalid():
	var sample := OceanQuerySample.new()
	sample.valid = false
	sample.height = 0.0
	sample.displacement = Vector3.ZERO
	sample.normal = Vector3.UP
	sample.surface_velocity = Vector3.ZERO
	sample.jacobian_det = 1.0
	sample.foldover_risk = false
	sample.query_residual_m = 0.0
	sample.query_iterations = 0
	return sample

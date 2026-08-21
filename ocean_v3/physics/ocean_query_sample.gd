class_name OceanQuerySample
extends RefCounted
## Contrato de una muestra de la superficie oceánica.
##
## Fase 2A: `turbulence` y `whitewater` llegan en fases posteriores y por ahora
## son siempre 0, pero la API queda preparada. `valid` es false si el backend
## no pudo producir un resultado finito.

var valid := true
var height := 0.0
var displacement := Vector3.ZERO
var normal := Vector3.UP
var surface_velocity := Vector3.ZERO
var turbulence := 0.0
var whitewater := 0.0


static func flat(sea_level := 0.0):
	## Superficie plana definida (usada cuando el océano está desactivado por
	## debug o cuando no hay espectro configurado).
	var sample := OceanQuerySample.new()
	sample.valid = true
	sample.height = sea_level
	sample.displacement = Vector3.ZERO
	sample.normal = Vector3.UP
	sample.surface_velocity = Vector3.ZERO
	return sample


static func invalid():
	var sample := OceanQuerySample.new()
	sample.valid = false
	sample.height = 0.0
	sample.displacement = Vector3.ZERO
	sample.normal = Vector3.UP
	sample.surface_velocity = Vector3.ZERO
	return sample

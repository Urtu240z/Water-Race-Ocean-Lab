# Ocean Lab — Fase 3B.1: 2D Refraction / Eikonal Phase Field

## Alcance cerrado

3B.1 conserva las relaciones de dispersión, `k(h)`, `c`, `Cg` y shoaling de
3B. Añade únicamente un bake bidimensional de fase para el instrumento
monocromático. **No modifica H0, no regenera FFT y no warpea el FFT LONG.**
No hay reflexión, difracción, breaking, foam ni focusing de amplitud.

## Formulación y solver

Se resuelve el tiempo de viaje:

```text
|grad(T)| = 1 / c_phase(h)
phi = omega_ref * T
local_direction = normalize(grad(phi))
```

Se eligió `T` porque el término derecho es slowness positivo y el update
Godunov es directo. `CoastalEikonalBaker` aplica **Fast Sweeping Method**:
cuatro barridos ordenados por iteración, actualización cuadrática Godunov y
convergencia determinista a `1e-6 s`. `phase_gradient` se guarda como
gradiente Godunov upwind, consistente con el residual discreto Eikonal.

La frontera upstream se obtiene con `x - incoming_direction * cell` fuera del
grid. Sus valores son el frente plano profundo
`T=(dot(x,d)-min_s)/c_deep`; con fondo uniforme recupera rectas sin curvatura.

## Datos, GPU y sombra

`CoastalPropagationData` suma `phase_rad`, gradiente XY, dirección local y
`reached_mask`; mantiene los campos 3B para compatibilidad. El packing GPU es:

| Textura RGBA32F | Contenido |
|---|---|
| field | phase_offset, shoaling, local_k, valid |
| metrics | depth, wavelength, c, Cg |
| phase | phase, dir_x, dir_z, reached |

Son **48 B/nodo** de VRAM, actualizados sólo durante bake. Para tierra/shore
y para la zona de sombra incidente, `reached=0`. La sombra usa una prueba
upstream conservadora que no permite reinyectar una onda lateral alrededor de
una isla: es intencionalmente sin difracción.

## Integración visual limitada

`R` en `phase_3b_visual_demo` alterna STRAIGHT 3B / REFRACTED 3B.1. En el
segundo caso el shader MONO consume `phi(x,z)` y `local_direction`; las líneas
de cresta se doblan y las flechas sparse muestran dirección local. Si MONO se
desactiva, 3B.1 **no** transforma el FFT: se muestra el mar abierto original.
`H` incluye LOCAL_K y VALID/SHADOW.

## Validaciones

`tests/phase_3b_1_eikonal_validation.gd` valida:

1. flat: dirección <0.02° y error de módulo de gradiente <2.5e-6 rad/m;
2. beach oblicua: `sin(theta)/c` conserva el invariante de Snell;
3. banco gaussiano: frentes curvos, dirección cambia y solve determinista;
4. isla circular: tierra inválida, sombra detrás y agua lateral reached.

`lab/benchmark/phase_3b_1_eikonal_benchmark.gd` informa build, sweeps,
residual y memoria. Es offline/dev-time; no hay solve ni upload por frame.
En Windows Godot 4.7 headless, banco 129×97 a 1 m (mediana de 3):
**1718.999 ms**, 8 sweeps, residual 2.62e-6 rad/m, 625,650 B CPU y 600,624 B
de payload GPU.

## Límites y propuesta 3B.2

El campo de una frecuencia/dirección no puede aplicarse sin más a todos los
modos del FFT. Para 3B.2 se recomienda evaluar un **world→deep coordinate warp
por banda/dirección**: retrotrazar de forma estable coordenadas de frente hacia
mar profundo y samplear cada contribución direccional en ese espacio. Una
corrección escalar de fase con una única dirección local no conserva un
espectro direccional; el warp permite que cada banda tenga su propia omega y
dirección, con fallback claro fuera de la región reached. Antes de integrarlo
debe validarse energía, jacobiano/caústicas y presupuesto Steam Deck.

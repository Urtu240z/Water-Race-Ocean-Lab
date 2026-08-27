# Ocean V3 — Integration Guide

## Contrato de integración

Una escena o nivel sólo instancia `OceanV3` y, si necesita una costa, asigna
un `CoastalBakeAsset` en `OceanV3 -> Coastal -> Coastal Bake Asset`.
La escena no crea Bakers, no conoce `OpenOceanFFTModule` y no activa una
propagación interna. OceanV3 carga el asset, valida su compatibilidad y
configura internamente la superficie, propagación, warp y breakers.

El asset es opcional. Si falta, es inválido o pertenece a otro formato, OceanV3
emite un warning y continúa en open ocean; no hornea durante el arranque.

## Crear un asset costero

1. Activa el plugin `Ocean V3 Tools` en el editor.
2. Añade un nodo `CoastalBakeAuthoring` a una escena temporal de authoring.
3. Asigna `source_root` (o `source`) al modelo costero, define un `coast_id`
   estable y revisa los parámetros de Bathymetry, Eikonal y Warp.
4. Pulsa explícitamente `BAKE COASTAL ASSET` en el Inspector.
5. Revisa la salida y asigna el manifest generado a `OceanV3`.

El pipeline ejecuta, en este orden, Bathymetry → Eikonal 2D 3B.1 → Warp.
El botón es una herramienta de editor; no forma parte del camino de juego.

## Layout canónico

Cada costa vive en:

```text
res://ocean_v3/baked/coastal/<coast_id>/
  coastal_bake.tres   # manifest textual pequeño
  bathymetry.res      # Resource binario con depth_m
  propagation.res     # Resource binario con solve y debug
  warp.res            # Resource binario con backtrace/warp
```

El `.tres` contiene metadatos, versión y referencias a los tres `.res`; los
arrays grandes no deben quedar embebidos en el manifest. `CoastalBakeAsset.is_valid()`
comprueba versión, recursos, grid, origen, celda, k0, omega, dirección y que
la propagación sea Eikonal.

## Runtime

Durante `_ready`, OceanV3 carga el `Resource` ya horneado. OpenOceanFFT sólo
construye las texturas GPU y publica el estado a la superficie. El coste de
runtime no incluye BathymetryBaker, CoastalEikonalBaker ni CoastalWarpBaker.

La costa puede controlarse mediante la API pública de OceanV3:

```gdscript
ocean_v3.set_coastal_enabled(false)
ocean_v3.set_coastal_enabled(true)
ocean_v3.cycle_coastal_composition_debug()
```

El modo de composición es FULL o LONG_COASTAL_ONLY. Estos cambios son de
composición/debug y no regeneran datos.

## Cuándo rebakear

| Cambio | Rebake |
|---|---:|
| Geometría costera, transform, escala o bounds | Sí |
| Nivel del mar, celda o profundidad sintética | Sí |
| Dirección entrante, longitud de onda, gravedad o profundidad mínima | Sí |
| Solver Eikonal, sombra, cut locus o regularización de fase | Sí |
| Parámetros de Warp o umbral de `detJ` | Sí |
| Materiales, foam, iluminación, cámara o HUD | No |
| Sea state, amplitud visual o preset de oleaje | No |
| Breaker tuning que no cambie la geometría horneada | No |

Tras un rebake, conserva el mismo `coast_id` para reemplazar el asset que usa
el nivel. Cambiarlo crea una variante independiente.

## Migrar a Water Race

Integra `ocean_v3/` y sus dependencias canónicas, instala el plugin de tools
sólo en el proyecto que hornea y copia el directorio
`ocean_v3/baked/coastal/<coast_id>/`. En el nivel de producción instancia
`OceanV3` y asigna `coastal_bake.tres` en el Inspector. No copies la escena de
lab, sus Bakers temporales, probes de diagnóstico ni wiring específico de la
demo. Water Race original permanece sin modificar.

La escena local del lab conserva sus cambios de usuario; si el manifest no
está asignado todavía, asígnalo manualmente al recurso generado. El código del
lab ya usa únicamente la API pública de OceanV3 para el control costero.

## Responsabilidades

- **Nivel/escena:** instancia OceanV3 y asigna recursos.
- **OceanV3:** carga, valida, activa/desactiva y publica el estado costero.
- **CoastalBakeAuthoring:** ejecuta el bake explícito y escribe el layout
  canónico.
- **Bakers:** siguen disponibles para tests y authoring; no son dependencias
  del arranque normal.

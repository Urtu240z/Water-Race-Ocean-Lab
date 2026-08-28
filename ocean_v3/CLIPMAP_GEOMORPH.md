# Ocean V3 — LOD geomorph

## Alcance

Ocean V3 conserva los anillos cuadrados y el stitching 2:1 existentes. Este
cambio sólo corrige la transición geométrica de cada nivel hacia el siguiente;
no modifica FFT, foam, SSPR/reflections, breaking, bandas, TAA ni la topología
CPU.

## Causa aislada en `e602e1a`

El primer intento calculaba `world_xz` morfado y lo usaba como coordenada de
FFT, normales, shoreline y datos asociados. Sin embargo, al final de
`vertex()` construía el resultado como `VERTEX + displacement`, conservando la
base XZ fina. La ola se evaluaba en una posición y se dibujaba en otra. Esa
incoherencia aparece como shimmer/flicker aunque la simulación esté pausada.

La máscara no era el origen temporal: `_process()` coloca el clipmap
continuamente en XZ de cámara, y `lod_alpha` se calcula desde coordenadas
locales del mesh, no desde un origen mundial redondeado. `floor()` sólo define
el vértice objetivo de la rejilla padre; no es un sample nearest de una textura.

## Contrato A/B

`OceanClipmapSurface.lod_geomorph_enabled` es exportado y vale `true` por
defecto. El uniform llega a los shaders de superficie y wireframe.

Con `false`:

- `lod_alpha` sigue calculándose y `Shift+L` sigue mostrando la banda de
  transición.
- `world_xz` vuelve exactamente a `fine_world_xz`.
- no se aplica el desplazamiento XZ de geomorph ni el ajuste de stitching.

Esto permite comparar alpha-only contra la geometría base sin cambiar cámara,
simulación ni debug. El método `set_lod_geomorph_enabled()` permite hacer la
misma A/B desde una prueba runtime.

## Coordenadas y evaluación corregida

La máscara usa la métrica Chebyshev en coordenadas locales estables:

```glsl
float lod_alpha = clipmap_lod_morph_factor(clipmap_local_xz);
vec2 coarse_local_xz = floor(clipmap_local_xz / coarse_spacing + vec2(0.5))
    * coarse_spacing;
vec2 morphed_local_xz = mix(clipmap_local_xz, coarse_local_xz, lod_alpha);
vec2 world_xz = clipmap_origin_xz + morphed_local_xz;
```

El `floor()` sólo alinea la base con el parent grid del clipmap. El sample de
la superficie sigue siendo `world_xz`, la posición continua interpolada por
`lod_alpha`; no se añade un sample nearest ni se hacen 3–4 evaluaciones FFT
adicionales. La corrección importante es que la base geométrica usa esa misma
posición:

```glsl
vec3 base_vertex = VERTEX;
if (lod_geomorph_enabled) {
    base_vertex.xz = morphed_local_xz;
}
vec3 displaced_vertex = base_vertex + displacement;
```

Así XZ, Y/choppiness, normales, shoreline y foam reciben una sola fase de
superficie. El stitching CPU permanece sin cambios; los vértices de borde
interior conservan su coordenada fina porque el `middle` está a medio coarse
spacing; las cuatro esquinas conservan el cierre existente.

## Coste

El coste adicional permanece en el vertex shader: `abs/max`, `smoothstep`,
`floor` y `mix`. No añade dispatches, readbacks, asignaciones CPU por frame ni
fetches FFT adicionales. El modo A/B sólo cambia un branch y conserva el
debug de alpha.

## Validación

La matriz de comprobación para el caso corregido es:

1. Simulación pausada, geomorph OFF: baseline exacta y alpha visible con
   `Shift+L`.
2. Pausada, alpha-only: OFF + debug activo; la banda de alpha no debe mover la
   silueta.
3. Pausada, geomorph ON: sin shimmer nuevo al cruzar la banda lentamente.
4. Movimiento lateral: sin fase distinta entre anillos.
5. Recentrado continuo: sin salto al cambiar la posición de cámara.
6. Cuatro esquinas: sin crack en el stitching 2:1.
7. Simulación activa: la corrección no altera el tiempo/seed FFT.
8. Rendimiento: cero evaluaciones FFT nuevas y triángulos sin cambios.

La validación CPU cubre niveles, winding, stitching, esquinas y contrato A/B.
El smoke runtime headless cubre carga de escena y APIs. El arranque gráfico
verificado usa Godot 4.7, Forward+, D3D12 y la GPU NVIDIA del equipo. Los dos
RID inválidos emitidos al apagar desde
`surface_foam_mid_history_solver.gd:95` ya existían antes de este cambio y no
son parte del geomorph.

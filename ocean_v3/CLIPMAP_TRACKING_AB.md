# Ocean V3 — clipmap tracking A/B

## Baseline inspeccionado

Antes de esta instrumentación, `OceanClipmapSurface._process()` asignaba en
cada frame:

```gdscript
global_position = Vector3(camera.global_position.x, sea_level, camera.global_position.z)
```

La misma función enviaba siempre `camera_world_xz` con la posición continua real
de la cámara a los materiales. Los dos vertex shaders calculaban `world_xz`
desde `MODEL_MATRIX * VERTEX`; por eso mover la cámara movía continuamente la
lattice mundial que alimenta los `textureLod` de LONG/MID/SHORT, incluso con la
simulación pausada. Esta hipótesis queda instrumentada, no confirmada por este
hecho.

## Modos

`clipmap_tracking_debug_mode` es un enum exportado temporal:

- `CONTINUOUS`: comportamiento baseline, siguiendo XZ de cámara cada frame.
- `FROZEN`: captura la posición XZ actual al entrar y deja de mover la lattice.
  Y continúa en `sea_level`.
- `SNAPPED`: cuantiza el root completo a una rejilla world-space estable. El
  tamaño se controla con `clipmap_tracking_snap_m` (por defecto `0.25 m`).

En los tres modos `camera_world_xz` se actualiza con la cámara real en cada frame.
No se toca SimulationClock, FFT, texturas, fades, normals, foam, reflections,
coastal, breaking ni stitching. `Shift+F` cicla en runtime
`CONTINUOUS → FROZEN → SNAPPED → CONTINUOUS` y el HUD muestra el modo y el
tamaño de snap.

En `SNAPPED`, cada celda se calcula directamente desde la cámara:

```gdscript
cell = Vector2i(roundi(camera_world_xz.x / snap_m), roundi(camera_world_xz.y / snap_m))
clipmap_xz = Vector2(cell.x * snap_m, cell.y * snap_m)
```

La cuantización usa coordenadas absolutas world-space y origen `(0, 0)`, sin
acumular deltas. Sólo el `OceanClipmapSurface` cambia de transform; todos los
LOD son hijos del mismo root. `camera_world_xz` conserva la posición continua
real de cámara para los shaders.

El smoke `res://tests/clipmap_tracking_snapped_runtime.gd` cubre los tamaños
`0.25 m`, `0.50 m` y `1.00 m`, además de comprobar que el material recibe la
posición continua de cámara.

## Protocolo visual manual

Con Sea State RACE, `P` pausado y normal VERTEX, repetir la misma trayectoria
lenta hacia delante y lateralmente:

| Caso | Tracking | Tamaño |
|---|---|---|
| A | CONTINUOUS | — |
| B | FROZEN | — |
| C | SNAPPED | 0.25 m |
| D | SNAPPED | 0.50 m |
| E | SNAPPED | 1.00 m |

Comparar flicker, boiling, popping, pequeños saltos periódicos y estabilidad de
crestas. Repetir con `V` en WIREFRAME y `L` en LOD debug. No concluir desde una
captura fija ni afirmar qué tamaño es mejor sin movimiento continuo real.

## Resultado observado en esta ejecución

La ejecución gráfica usó Godot 4.7 Forward+ sobre D3D12, con `Sea State: RACE`,
simulación pausada, misma referencia visual y `Seed: 20260820`. El HUD confirmó
los cuatro estados A–D y el cambio de tracking `CONTINUOUS/FROZEN`; el agua y el
LOD debug renderizaron en los cuatro cambios de modo. La captura de wireframe
mostró la malla de los clipmaps y `L` mostró las bandas de nivel LOD.

No fue posible completar el tramo WASD de 20–40 m: el controlador de escritorio
disponible sólo envía pulsaciones instantáneas, mientras `FreeCamera` requiere
que W/A/S/D permanezca presionada durante varios frames. Por tanto, esta
ejecución permite confirmar el cambio de modo, el render y los dos debug views,
pero no permite afirmar si FROZEN reduce flicker, popping, boiling o cambios de
silueta durante traslación. No se extrae una conclusión causal de las capturas
fijas.

## Interpretación

- FROZEN mejora wireframe y material: la lattice continua contribuye.
- FROZEN mejora wireframe pero no material: la geometría contribuye y
  normal/specular amplifica o domina.
- FROZEN no cambia: descartar esta hipótesis como causa principal.
- FRAGMENT mejora en ambos tracking: normal/specular domina.
- Sólo fronteras LOD en FROZEN: investigar en una fase posterior.

Esta tarea sólo aporta el diagnóstico de tracking y el modo `SNAPPED`. No
implementa geomorph, spectral band limiting ni ninguna solución de normals,
filtering, stitching o FFT.

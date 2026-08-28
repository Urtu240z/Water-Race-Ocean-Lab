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

En ambos modos `camera_world_xz` se actualiza con la cámara real en cada frame.
No se toca SimulationClock, FFT, texturas, fades, normals, foam, reflections,
coastal, breaking ni stitching. `Shift+F` cambia el modo en runtime y el HUD
muestra una sola línea `Clipmap Tracking: CONTINUOUS/FROZEN`.

## Protocolo visual

Con Sea State RACE y `P` pausado, repetir la misma trayectoria lenta de 20–40 m:

| Caso | Tracking | Vista |
|---|---|---|
| A | CONTINUOUS | producción + VERTEX |
| B | CONTINUOUS | producción + FRAGMENT |
| C | FROZEN | producción + VERTEX |
| D | FROZEN | producción + FRAGMENT |

Repetir A/B con `V` en WIREFRAME y opcionalmente `L` en LOD debug. Registrar en
movimiento flicker, popping, boiling, crestas que aparecen/desaparecen y cambio
de silueta. No concluir desde una captura fija.

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

Esta tarea sólo aporta evidencia A/B. No implementa snapping, geomorph,
spectral band limiting ni ninguna solución permanente.

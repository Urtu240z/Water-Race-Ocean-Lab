# Ocean Lab — Fase 1C: clipmap, LOD y horizonte

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Fase 1C sustituye la malla finita de inspección por un renderer clipmap centrado en cámara. No modifica Stockham, H0, Parseval, band-pass, semillas, dispersión ni los 54 dispatches de Fase 1B. Las tres cascadas siguen siendo el único campo oceánico; el clipmap sólo decide dónde se dibujan vértices.

## Warnings corregidos

Se revisaron los avisos propios existentes en Godot y se corrigieron sus causas:

- parámetros `seed` renombrados a `simulation_seed`, para no sombrear la función integrada;
- la división entera de índices espectrales se expresó en coma flotante;
- las variables de modos debug se tiparon como `int` para no convertir implícitamente a enums;
- el formato de `RDTextureFormat` se convierte explícitamente a `RenderingDevice.DataFormat`;
- `FreeCamera` desactiva sólo su interpolación física porque su transform se actualiza desde `_process()` y es una herramienta visual. La interpolación global permanece activa.

## Arquitectura y niveles

```text
OpenOceanFFTModule
 ├─ LONG / MID / SHORT → GPUStockhamFFT
 └─ OceanClipmapSurface
     ├─ L0: grid completo
     └─ L1–L9: anillos con stitch 2:1
```

| Nivel | Spacing | Anchura exterior |
|---|---:|---:|
| L0 | 0,25 m | 32 m |
| L1 | 0,50 m | 64 m |
| L2 | 1 m | 128 m |
| L3 | 2 m | 256 m |
| L4 | 4 m | 512 m |
| L5 | 8 m | 1.024 m |
| L6 | 16 m | 2.048 m |
| L7 | 32 m | 4.096 m |
| L8 | 64 m | 8.192 m |
| L9 | 128 m | 16.384 m |

La semiextensión final es 8.192 m y las cámaras del laboratorio usan far clip de 7.000 m. La topología contiene 256.256 triángulos: L0 aporta 32.768 y cada anillo 24.832. No hay diez grids completos superpuestos.

`OceanClipmapMeshBuilder` genera la geometría una vez. Cada celda de frontera de un anillo reemplaza su quad grueso por tres triángulos que conectan la fila fina interior `A–M–B` con la fila gruesa exterior `C–D`. Los cuatro lados y las esquinas se validan; no se usan skirts ni z-fighting.

## Seguimiento, campo mundial y LOD

`OceanClipmapSurface` usa genéricamente la cámara activa del viewport (u opcionalmente `set_tracking_camera`). Cada frame mueve sólo su transform horizontal a `camera.xz`; la Y permanece en el nivel del mar. No reconstruye mallas ni asigna recursos al moverse o teletransportarse.

El shader calcula siempre las consultas espectrales mediante `MODEL_MATRIX * VERTEX`, es decir, posición mundial. LONG, MID y SHORT se consultan en sus dominios 512/128/32 m originales. Por ello una cresta conserva seed, fase y tiempo al cambiar de LOD.

Los fades son continuos por distancia a cámara y se aplican igual en vértices coincidentes de ambas caras de una costura:

| Banda | 100 % | Fade a 0 % |
|---|---:|---:|
| SHORT | 24 m | 80 m |
| MID | 96 m | 320 m |
| LONG | 768 m | 2.500 m |

Esto es LOD visual: no altera Hs, seed ni las FFT. El L9 es muy grueso para el extremo corto de LONG; se apaga antes de 2.500 m. No se añadieron mips espectrales, ruido ni nuevas cascadas. La periodicidad de 512/128/32 m puede inspeccionarse con una cuadrícula de depuración; si resulta obvia desde la cámara de carrera debe tratarse en Gate 1, no esconderse.

## Recursos, culling y controles

Los diez `MeshInstance3D` no generan sombras. Cada uno usa un margen de culling de 4 m: margen seguro de laboratorio sobre Hs combinada 0,646 m y desplazamiento horizontal actual, sin extenderse arbitrariamente. Materiales y meshes son persistentes.

- `O`: activa/desactiva el módulo entero.
- `B`: ALL/LONG/MID/SHORT.
- `V`: displacement, altura, normales y wireframe.
- `L`: colores por nivel clipmap.
- `T`: cuadrícula de periodos espectrales 512/128/32 m para inspección.

El HUD muestra niveles, spacing cercano, semiextensión y triángulos, además de los estados de LOD y periodicidad.

## Validación y limitaciones

`tests/phase_1c_validation.gd` comprueba relaciones de spacing/extensión/huecos, índices, áreas, winding, posiciones de stitches y esquinas, extensión de horizonte, anclaje mundial y conservación de APIs de Fase 1B. `tests/phase_1c_runtime_smoke.gd` mueve la cámara libre, alterna B/V/L/T/O y pause/reset por API. Ambos pasaron; el resultado geométrico fue 10 niveles y 256.256 triángulos.

Una captura básica normal en Forward+/D3D12 sobre RTX 4070 Laptop (180 frames warm-up + 180 muestra) obtuvo 148,52 FPS, 15,661 ms de proceso, 57 draw calls, 258.344 primitives y 89,68 MiB estáticos con el módulo ON. Con el módulo OFF obtuvo 162,52 FPS, 16,482 ms, 47 draw calls, 2.084 primitives y la misma memoria estática. No es un benchmark profundo ni aísla GPU.

La validación headless no puede sustituir una inspección visual prolongada al cruzar costuras a gran velocidad. Un arranque normal D3D12 de 180 frames no emitió errores ni warnings propios. La inspección manual recomendada para Gate 1 sigue siendo mover la cámara libre rápidamente, alternar cámaras y usar `V`, `L` y `T` para revisar costuras y periodicidad.

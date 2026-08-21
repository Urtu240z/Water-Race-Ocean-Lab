# Ocean Lab — Fase 1D: estados de mar, tuning y Gate 1

Fase 1D cierra el aspecto físico del mar abierto: añade tres estados estáticos (CALM / RACE / ROUGH) y un shading de diagnóstico legible, sin tocar Stockham, el clipmap ni los 54 dispatches. No incluye material final, costa, física del jetski ni viento dinámico.

## Arquitectura SeaState

```text
SeaStateConfig (ocean_v3/core/sea_state_config.gd)
  ├─ enum State { CALM, RACE, ROUGH }
  └─ build_cascades(state) -> Array[OpenOceanFFTConfig]
        ↓
OpenOceanFFTModule.set_sea_state(state)
  ├─ conserva simulation_seed y simulation_time
  ├─ regenera H0 por cascada (CPU, una vez)
  ├─ update_config() + upload_h0() en el worker (render thread)
  └─ continúa evaluando el nuevo estado
```

`SeaStateConfig` es una capa pequeña, estática y pura. No crea nodos, no conoce a `lab/` y no mezcla estados de mar con perfiles de calidad. Los parámetros invariantes por banda (resolución 256², dominio 512/128/32 m, band-pass, amortiguación corta) viven en `_apply_invariant`; sólo cambian los parámetros macro físicos.

`OpenOceanFFTConfig.reference_cascades()` ahora delega en `SeaStateConfig.build_cascades(RACE)`: RACE sigue siendo el estado principal y conserva la identidad de Fase 1B. La fuente única de verdad de los tres estados es `SeaStateConfig`.

`GPUStockhamFFT` recibe `update_config(config)`: al cambiar de estado sólo muta choppiness/dirección/dispersión/viento/Hs, por lo que las texturas, pipelines y uniform sets existentes siguen siendo válidos. No se recrea el worker ni se reasigna memoria por cambio de preset. El módulo sigue registrado una única vez; `Ocean modules` permanece en 1 tras cambiar CALM→RACE→ROUGH.

## Parámetros finales

### CALM — tranquilo pero vivo
| Banda | Hs (m) | Choppiness | Dirección | Spread | 
|---|---:|---:|---|---:|
| LONG | 0.18 | 0.45 | (1.0, 0.10) | 8.0 |
| MID | 0.12 | 0.55 | (1.0, 0.18) | 6.0 |
| SHORT | 0.05 | 0.45 | (1.0, 0.25) | 4.0 |

Viento global: **6 m/s**. Hs combinada `sqrt(0.18² + 0.12² + 0.05²) ≈ 0.222 m`.

### RACE — estado principal de Water Race
| Banda | Hs (m) | Choppiness | Dirección | Spread |
|---|---:|---:|---|---:|
| LONG | 0.50 | 0.75 | (1.0, 0.15) | 7.0 |
| MID | 0.38 | 1.00 | (1.0, 0.30) | 5.0 |
| SHORT | 0.15 | 0.90 | (1.0, 0.45) | 4.0 |

Viento global: **12 m/s**. Hs combinada `sqrt(0.50² + 0.38² + 0.15²) ≈ 0.646 m` (dentro del rango físico de diseño 0.4–0.8 m).

### ROUGH — fuerte, no tsunami
| Banda | Hs (m) | Choppiness | Dirección | Spread |
|---|---:|---:|---|---:|
| LONG | 0.85 | 0.90 | (1.0, 0.10) | 5.0 |
| MID | 0.65 | 1.15 | (1.0, 0.38) | 3.5 |
| SHORT | 0.30 | 1.05 | (1.0, 0.62) | 3.0 |

Viento global: **18 m/s**. Hs combinada `sqrt(0.85² + 0.65² + 0.30²) ≈ 1.111 m`.

### Notas de tuning
- **Directional spread** usa `pow(k_dot_w, spread)`: valor mayor → dirección más estrecha/coherente. CALM es el más coherente (8/6/4), ROUGH el más cruzado (5/3.5/3). RACE usa 7/5/4 (antes todas las bandas usaban el default 4.0).
- **Wind speed** sólo modifica la forma espectral (pico/distribución), no duplica Hs: `target_hs_m` normaliza la amplitud final por Parseval.
- No se infló Hs para "que se vea bonito". RACE se mantiene en 0.646 m.

## Shading de diagnóstico

`ocean_surface.gdshader` quedó limpio (se eliminaron los hacks temporales magenta/blanco). Dos familias:

- **Modo normal simple (0 FULL, 1 HEIGHT ONLY):** agua opaca azul/gris, roughness/specular simples, iluminada. `base_color` es un azul pizarra neutro `(0.18, 0.34, 0.44)`.
- **Modos de diagnóstico unlit/emission** (independientes del sol del laboratorio y de la exposición):
  - **2 NORMALS:** normal real mapeada a color.
  - **3 SLOPE / GEOMETRY:** `dot(normal, luz_fija)` → gradiente claro/oscuro vía emission. Lee crestas y valles con contraste estable. Dirección fija `(0.55, 0.65, -0.55)`, sin depender del sol.

Los overlays `CLIPMAP LOD` (L) y `PERIODICITY` (T) también se emiten unlit para que la iluminación real no los oscurezca. El ciclo `V` ahora recorre `FULL → HEIGHT → NORMALS → SLOPE → WIREFRAME`.

## Controles

Se mantienen O/B/V/L/T/P/R/N y se añade el cambio de estado:

- **4 → CALM**
- **5 → RACE**
- **6 → ROUGH**

El HUD muestra `Sea State: CALM/RACE/ROUGH`, la Hs combinada medida y el modo de superficie. Cambiar de estado conserva seed y tiempo y regenera H0 de forma determinista: mismo estado + seed + tiempo → mismo océano. Reset (R) preservando seed reproduce exactamente la simulación; N cambia la seed.

## Cámara de evaluación

`RaceReferenceCamera` se ajustó a `(0, 2.5, 7.5)` mirando a `(0, 1, -60)`: ~2.5 m sobre la superficie media, FOV 78, mirada ligeramente descendente hacia el horizonte. Es la cámara de referencia para Gate 1 (no la cámara aérea).

## Validación automática

`tests/phase_1d_validation.gd` cubre los puntos A–M de la especificación:

- A. Identidad/enum de los tres estados.
- B. Hs por banda de cada estado.
- C. Hs combinada coherente con la tabla.
- D/E. Determinismo por seed y por estado (mismo H0).
- F. Estados distintos = configuración distinta.
- G. Los sea states no alteran `OceanQualitySettings`.
- H. Los perfiles de calidad no alteran los parámetros macro físicos.
- I/J/K. CALM ≈ 0.22, RACE ≈ 0.65, ROUGH ≈ 1.11.
- L. `register_module` sólo en `_ready`; en runtime `Ocean modules` sigue == 1 tras cambiar preset.
- M. Sin `texture_get_data`/`buffer_get_data`/`sync`/`submit` (sin readback por frame).

Todos pasaron en Godot 4.7.1 headless. Se re-ejecutaron `phase_1a/1b/1c_validation` sin regresiones (1B confirma fuga de banda ≤ 0.3 % y Hs combinada 0.646 m). Un arranque D3D12 de 120+ frames compiló shaders y escena sin errores ni warnings propios.

## Benchmark Gate 1

Comando reproducible (VSync OFF, FPS sin límite, misma cámara/seed/perfil/calentamiento):

```text
godot --path . --script res://lab/benchmark/phase_1d_capture.gd -- off|calm|race|rough
```

`phase_1d_capture.gd` mide FPS por tiempo de pared sobre una ventana de 2 s tras 120 frames de calentamiento; no declara GPU ms (usar RenderDoc/Nsight/RGP). Captura en RTX 4070 Laptop, 1920×1080, escala 3D 0.7, STANDARD:

| Modo | FPS | Frame ms | Draw calls | Primitives | Static memory |
|---|---:|---:|---:|---:|---:|
| OFF | ~1455 | ~0.69 | 39 | 2.090 | ~89.5 MiB |
| CALM | ~1120 | ~0.89 | 49 | 258.350 | ~89.5 MiB |
| RACE | ~1126 | ~0.89 | 49 | 258.350 | ~89.5 MiB |
| ROUGH | ~1000 | ~0.99 | 49 | 258.352 | ~89.5 MiB |

Interpretación: los tres estados ON comparten el mismo coste (3 FFT + 54 dispatches + clipmap + rasterización); las diferencias entre CALM/RACE/ROUGH están dentro del ruido de ejecución. OFF recupera el margen esperado al ocultar el océano. El monitor `TIME_PROCESS` resultó inestable entre ejecuciones (ya señalado en Fases 1A/1C), por lo que se reporta FPS por tiempo de pared como métrica fiable. No se optimiza en esta fase: hay reserva de sobra.

## Pruebas visuales pendientes (aprobación del usuario)

No se auto-aprueba la calidad visual. Queda pendiente la inspección humana en la `RaceReferenceCamera`:

1. **CALM** debe verse tranquilo pero vivo, con swell legible, no un plano con noise.
2. **RACE** debe mostrar frentes grandes identificables + mar medio + detalle corto, sin parecer suma de tres noises; una cresta LONG debe poder seguirse al acercarse.
3. **ROUGH** debe ser claramente más difícil (interferencia, pendientes, más mar corto) pero conservar estructura de ola, no sopa aleatoria.
4. **SLOPE / GEOMETRY** (V ×3) debe leer crestas/valles con contraste estable.
5. **Periodicidad** (T): comprobar si 512/128/32 m se perciben desde la cámara de carrera. Si no se aprecia → PASS; si se aprecia → documentar qué banda es culpable. No se añadió noise para ocultarla.
6. **Costuras LOD** (V/WIREFRAME + L): atravesar fronteras y mover cámara lateralmente rápido; no debe haber cracks, z-fighting, popping ni discontinuidades.
7. **Identidad de cresta**: con el reloj corriendo, una cresta LONG lejana debe conservar identidad al acercarse (no regenerarse ni cambiar de fase por LOD).
8. **Determinismo**: misma seed + estado + reset debe reproducir exactamente la simulación.

## Limitaciones

- Sin transición temporal CALM→ROUGH ni memoria oceánica (corresponde a viento dinámico, Fase 12). El cambio de preset regenera H0 inmediatamente; es una herramienta de laboratorio.
- Los perfiles DECK/STANDARD/DEV_HIGH siguen siendo prácticamente idénticos en gráficos; sólo se protege la arquitectura (los perfiles no mutan Hs/direcciones/seed/fase/estado).
- Los dominios espectrales (512/128/32 m) no cambian en esta fase; la periodicidad queda pendiente de juicio visual.
- El benchmark CLI abre la ventana sin foco; los FPS por tiempo de pared son representativos, pero una medición con ventana enfocada y profiler externo es la referencia definitiva.
- No se implementa nada de Fase 2 (sample_water, buoyancy, hull physics) ni fases posteriores.

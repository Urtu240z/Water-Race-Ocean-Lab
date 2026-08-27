# Ocean Lab — Fase 1D.1: cleanup pre-Gate 1

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Tarea quirúrgica previa a la aprobación visual de Gate 1. No cambia el aspecto físico del mar (Hs, direcciones, spread, wind y choppiness de CALM/RACE/ROUGH intactos), no toca Stockham, ni el clipmap, ni implementa Fase 2.

## Cambios manuales locales del usuario preservados

Los cambios manuales del usuario (commiteados en `958c80a`) se integraron y **no se sobrescribieron**:

- Escala de tiempo en `,` (×0.5, mín 0.125) y `.` (×2, máx 8.0) en `lab/lab_main.gd`.
- Tecla `M` muestra/oculta `MetricReferences`; se mantiene manual, no se oculta al cambiar de cámara.
- Texto de controles actualizado: `,/.: escala de tiempo` y `M: referencias métricas`.
- `lab/lab_main.tscn` re-saveado en formato con uids por el editor (preservado tal cual).
- Modo SLOPE/GEOMETRY del shader reescrito para usar la pendiente real: `slope = -n.xz / max(n.y, 0.05)`, `slope_dir = normalize(vec2(0.7, -0.7))`, `shade = clamp(0.5 + signed_slope * 5.0, 0.0, 1.0)`. Superficie plana ≈ mitad del gradiente; pendientes opuestas → oscuro/claro. Se eliminó el uniform `slope_light_direction` sin usar.
- `periodic_grid()` corregido en el shader de superficie (`1.0 - smoothstep` → `smoothstep`): ahora dibuja líneas en las fronteras periódicas, no pinta toda la superficie amarilla. **En esta tarea se aplicó la misma corrección al shader wireframe**, que aún conservaba la versión invertida.

## Periodicidad espectral — dominios 512 / 137 / 37

El problema: con LONG=512, MID=128 y SHORT=32 m se cumplía `512 = 4×128` y `128 = 4×32`, por lo que las tres cascadas volvían a alinearse exactamente cada 512 m — una propiedad mala para un océano de kilómetros.

Solución (sólo dominios invariantes en `SeaStateConfig._apply_invariant`):

| Banda | Antes | Después | Resolución | Band-pass |
|---|---:|---:|---:|---|
| LONG | 512 m | 512 m | 256² | 16–128 m |
| MID | 128 m | **137 m** | 256² | 4–20 m |
| SHORT | 32 m | **37 m** | 256² | 0.5–5 m |

137 y 37 son primos: ya no existen múltiplos simples entre dominios (512/137 ≈ 3.74, 137/37 ≈ 3.70, ambos no enteros). El patrón combinado exacto tardaría conceptualmente `LCM(512,137,37) = 2.595.328 m` en realinear las tres periodicidades en un eje; ese número es sólo la justificación, no se usa en runtime. Cada cascada sigue siendo periódica individualmente (inherente al FFT); lo que se evita es que las tres repitan juntas cada 512 m.

Resolución espectral validada: MID 137/256 ≈ 0.535 m por sample (Nyquist 1.07 m, muy por debajo de λ=4 m); SHORT 37/256 ≈ 0.145 m (Nyquist 0.289 m, por debajo de λ=0.5 m). Sin cambios de resolución, memoria ni dispatches.

## Dependencia circular eliminada

Antes existía una dependencia conceptual doble:

```text
SeaStateConfig → OpenOceanFFTConfig   (crea)
OpenOceanFFTConfig → SeaStateConfig   (reference_cascades llamaba)
```

Se eliminó `OpenOceanFFTConfig.reference_cascades()`. `OpenOceanFFTConfig` vuelve a ser un Resource de datos puro que no conoce CALM/RACE/ROUGH. Los callers (`tests/phase_1b_validation.gd`) ahora usan `SeaStateConfig.build_cascades(SeaStateConfig.State.RACE)`. Dirección única resultante:

```text
SeaStateConfig → OpenOceanFFTConfig
```

## Tests de Hs real (measured), no sólo target

`tests/phase_1d_validation.gd` ahora valida, además de la tabla, el resultado real de generar H0 con `TessendorfSpectrum.build_h0_rgba32f()`:

- `config.measured_hs_m` ≈ target (tolerancia 0.005 m) para las 9 combinaciones estado/banda.
- Hs combinada calculada con los `measured_hs_m`, no con los target.

Resultados medidos:

| Estado | LONG | MID | SHORT | Combinada (measured) |
|---|---:|---:|---:|---:|
| CALM | 0.180 | 0.120 | 0.050 | **0.222 m** |
| RACE | 0.500 | 0.380 | 0.150 | **0.646 m** |
| ROUGH | 0.850 | 0.650 | 0.300 | **1.111 m** |

Nuevos checks añadidos al test 1D: dominios 512/137/37, no múltiplos enteros obvios, bandas caben en su dominio, Nyquist suficiente, y dirección de dependencia arquitectónica (E: `OpenOceanFFTConfig` no contiene `SeaStateConfig`; `SeaStateConfig` sí crea `OpenOceanFFTConfig`).

## Benchmark mejorado

`lab/benchmark/phase_1d_capture.gd` pasó de 120 frames de warmup + 2 s de muestra a tiempo real:

- `WARMUP_SECONDS = 3.0`
- `SAMPLE_SECONDS = 5.0` × `SAMPLE_COUNT = 3`
- Reporta la **mediana** de FPS/frame_ms más las 3 muestras individuales.
- CPU process y physics se registran como dato auxiliar; **no se declara GPU ms**.
- Misma cámara de referencia, seed, resolución, perfil de calidad, VSync OFF y FPS ilimitados.

Smoke test ejecutado en RACE (RTX 4070 Laptop, 1920×1080, STANDARD): muestras 1046 / 1085 / 919 FPS, **mediana 1046 FPS (0.956 ms frame)**, 49 draw calls, ~258.4k primitives, ~89.5 MiB. El usuario puede ejecutar los cuatro modos (`off|calm|race|rough`) después.

## Validación

- `phase_1a_validation`, `phase_1b_validation`, `phase_1c_validation`, `phase_1d_validation`: **PASS** (Godot 4.7.1 headless).
- Arranque D3D12 normal (90+ frames): sin errores de parser, sin errores de shader, sin warnings propios (sólo el aviso ambiental del sandbox `Failed to read the root certificate store`).

## Limitaciones / pendiente

- La periodicidad combinada ya no se alinea cada 512 m, pero la inspección visual con `T` sigue pendiente del usuario (Gate 1).
- No se toca el modelo LONG/swell (Phillips) en esta tarea; su evaluación como swell se decide después del Gate visual. No JONSWAP, no Pierson-Moskowitz.
- No se declara Gate 1 aprobado: queda pendiente la validación visual final del usuario.
- Fase 2 NO iniciada.

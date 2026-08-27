# Ocean Lab — Fase 2B: OceanQueryReduced (production evaluator)

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Evaluador de producción de OceanQuery: world-space correcto, determinista,
mismo H0 que la GPU, misma semántica que la Golden Reference (2A.1), con
compresión de pares ±k y selección por importancia. No implementa jetski,
buoyancy ni Fase 3.

## Convención temporal de propagación

`wind_direction`, `incoming_direction_xz`, `local_direction` y
`render_direction` significan la dirección HACIA LA QUE viaja la cresta. La
reconstrucción espacial usa `Re(H * e^(+i k·x))`, por lo que la evolución
temporal canónica es `H(k,t) = h0(k)e^(-iωt) + conj(h0(-k))e^(+iωt)`. Así,
`direction=(0,+1)` mueve la cresta hacia `+Z`. H0, lambda negativa y los
pesos Coastal no se regeneran ni reinterpretan por esta convención.

## ETAPA A: compresión EXACTA de pares +k / -k

La superficie real espectral tiene simetría conjugada: `h(-k,t) = conj(h(k,t))`.
En lugar de evaluar los N² texels de Golden, `OceanQueryReduced` construye una
**representación canónica de pares** y suma `2·σ·Re(F_c)` por par (media
contribución, misma matemática).

**Caso delicado encontrado y resuelto:** los modos "borde" (columna/fila Nyquist
negativa, `mx = -N/2` o `my = -N/2`) NO tienen pareja conjugada real en el
espectro discreto (su +N/2 no existe; la fase espacial no se invierte). Se
tratan como modos individuales con peso 1. Los pares interiores (mx, my ambos
no-Nyquist) usan peso 2. Un test A (FULL_PAIRS ≡ Golden) detectó el error
inicial y, tras corregirlo, la equivalencia es **exacta a 1e-16** en
height/displacement/normal/velocity/jacobian, incluyendo la inversión
world-space, en RACE real.

## FULL_PAIRS como test de seguridad

`MODE_FULL_PAIRS` conserva todos los pares canónicos y usa los mismos límites
de Newton que Golden (8 iteraciones, 1e-4). Verificado:
- sintético (N=16, varias q/t): diferencia 1e-17–1e-16;
- RACE real world-space (2 posiciones): diferencia < 1e-16.

## Almacenamiento plano (producción)

Nada de `_ModeData`/Dictionary por modo. `PackedFloat64Array` por campo, por
cascada: kx, ky, omega, a1, a2, c11..c22, parity, weight, h0s + arrays de
tiempo preparado (ev_h/ev_v). Los acumuladores de evaluación son miembros
reutilizados (sin allocations por query; el único objeto por query es el
`OceanQuerySample` del contrato). El sort de selección es nativo
(`PackedInt64Array.sort()` con clave empaquetada importancia+índice).

## Política de importancia (ETAPA B)

Por cada par, con E = energía del par:

```text
height power:  E
slope power:   k²·E
velocity power: ω²·E
jacobian power: λ²·k²·E
```

Normalizadas dentro de cada cascada y combinadas con
`importance = max(nh, ns, nv, nj)` (multiojetivo; NO sólo altura). Orden total
determinista (importancia DESC, índice ASC). La política está aislada en
`_compute_importance`, lista para una futura transición meteorológica (la
selección es estable por espectro; un crossfade futuro requerirá mantener el
conjunto seleccionado).

## Presupuesto elegido (calibración)

`tests/phase_2b_calibration.gd` construye un dataset Golden único
(3 estados × 2 seeds × 3 tiempos × 2 posiciones = 36 samples world) y barre
343 presupuestos contra los mismos samples.

**Resultado: LONG = 1024 | MID = 1024 | SHORT = 1024 | TOTAL = 3072 pares**
(el menor total que cumple TODOS los objetivos de precisión de RACE y ROUGH).

Energía conservada por banda a ese presupuesto:

| Banda | Height | Slope | Velocity | Jacobian |
|---|---:|---:|---:|---:|
| LONG | 99.9 % | 99.6 % | 99.8 % | 99.6 % |
| MID | 99.7 % | 99.0 % | 99.4 % | 99.0 % |
| SHORT | 99.2 % | 95.1 % | 98.0 % | 95.1 % |

## Precisión (Reduced vs Golden, mismo world_xz, dataset de 36 samples)

| Estado | H RMSE/P95/MAX (m) | N RMSE/P95/MAX (°) | V RMSE/P95 (m/s) | D RMSE (m) | detJ min red/golden |
|---|---:|---:|---:|---:|---:|
| CALM | 0.0037/0.0087/0.0087 | 0.53/0.89/0.89 | 0.014/0.030 | 0.0020 | 0.964/0.966 |
| RACE | 0.0069/0.0115/0.0115 | 1.22/2.11/2.11 | 0.038/0.063 | 0.0077 | 0.805/0.815 |
| ROUGH | 0.0138/0.0211/0.0211 | 2.39/4.80/4.80 | 0.097/0.164 | 0.0201 | 0.610/0.611 |

Cumple los objetivos de la sección 21 (RACE H≤0.015, N≤1.5°, V≤0.15, D≤0.020;
ROUGH H≤0.025, N≤2.5°, V≤0.25, D≤0.035). **0 invalid, 0 desacuerdos de signo
de detJ** en el dataset. ROUGH N RMSE 2.39° queda cerca del límite 2.5°.

## Newton (producción)

`MAX_ITERATIONS = 3`, `POSITION_TOLERANCE_M = 1e-3` (1 mm; suficiente para
gameplay) con jacobiano analítico. `q0 = world_xz`. Si no converge →
`valid = false` + contador diagnóstico (`diagnostic_non_converged`), sin spam
de warnings. Observado en el dataset: RACE 1–2 iteraciones, ROUGH 2;
residuales ≤ 1e-3; 0 invalid.

## prepare / batch

- `ensure_prepared(t)`: si `_prepared_time == t` no recalcula (ω·t una vez por
  tiempo físico). `sample_water_physics_time` del módulo garantiza el tiempo
  preparado sin depender del orden de `_physics_process`.
- `sample_water_batch_physics_time(positions)`: prepara una vez y evalúa todas
  las posiciones reutilizando buffers. API individual conservada.

## Benchmark (RTX 4070 Laptop, GDScript headless, CPU-bound)

| Medida | RACE | ROUGH |
|---|---:|---:|
| set_spectrum (rebuild + selección) | ~210 ms | ~610 ms |
| set_budget (re-selección) | ~3 ms | ~14 ms |
| prepare_time | ~3.2 ms | ~5.0 ms |
| 1 query world (preparada) | ~3.2–6 ms | ~10–15 ms |
| 16 queries | ~51 ms | ~158–186 ms |
| 32 queries | ~105 ms | ~376–403 ms |
| 64 queries | ~218–472 ms | ~763–821 ms |
| batch 16 | ~166–197 ms | ~171–197 ms |

**Los objetivos de rendimiento (16 ≤ 1 ms, 64 ≤ 3 ms) NO se alcanzan en
GDScript puro** al presupuesto exigido por precisión (3072 pares). El cuello es
el bucle por par (~3–13 ms por query world). No se baja el presupuesto por
debajo de los límites de precisión para "pasar" el benchmark.

## Memoria

- Pares canónicos completos (retenidos para re-selección): ~33.024
  pares/cascada × 3 ≈ 99k pares × 10 floats × 8 B ≈ **~8 MB**.
- Compacto seleccionado (3072 pares + preparado): **~1 MB**.
- Golden Reference: sólo se instancia con `enable_reference_query_debug = true`
  (objeto por modo, ~99k RefCounted); en producción no cuesta nada.

## Módulo

`OpenOceanFFTModule` usa **REDUCED por defecto** (`query_backend_name() =
"REDUCED"`). Golden sólo con `enable_reference_query_debug` (debug/test).
Mismo H0 (bytes idénticos) a GPU + REDUCED (+ Golden si debug). Probes de
laboratorio: REDUCED cyan (9) + Golden naranja (3, sólo debug).

## Tests

`tests/phase_2b_validation.gd` (rápido, A–N): FULL_PAIRS ≡ Golden (sintético y
RACE), single-wave ±k, plano, selección determinista, mismo H0 ⇒ mismos pares,
seed distinta, round-trip world, sea level, prepared caching, band debug,
quality profile, sin readback, sin allocations en el hot path, lambda
negativa. **PASS.**

Suite completa (1A/1B/1C/1D/2A/2A.1/2B + runtime smoke): **PASS**. Godot:
0 parser/shader errors, 0 warnings propios. Import limpio.

## Limitaciones / recomendación

- **Rendimiento GDScript insuficiente para los objetivos de 16≤1 ms / 64≤3 ms**
  al presupuesto que exige la precisión (3072 pares). El evaluador es
  matemáticamente correcto y preciso, pero el bucle por par en GDScript cuesta
  ~3–13 ms/query.
- **Recomendación para producción (futuro):** mover el bucle caliente a
  GDExtension/native (C++/Rust) manteniendo la misma estructura de pares
  canónicos (ahí 3072 pares ≈ decenas de µs/query), o un grid local
  pre-evaluado. NO se implementa en 2B por mandato de la tarea.
- El módulo queda configurado con 1024/1024/1024 (precisión). Para
  prototipado de gameplay CPU en GDScript se puede bajar temporalmente el
  presupuesto aceptando más error (curva documentada en calibración).
- Gate 2 NO se autoaprueba: requiere además probes visuales sobre la malla y
  revisión del usuario (el Reduced ≈ Golden no garantiza Physics ≈ píxeles
  exactos; el render usa 256² + bilinear + clipmap + fades).

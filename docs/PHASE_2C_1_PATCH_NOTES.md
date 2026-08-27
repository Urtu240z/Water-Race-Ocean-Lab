# Ocean Lab — Fase 2C.1A: LOCAL OCEAN QUERY PATCH (PROTOTIPO)

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Objetivo: eliminar la redundancia de OceanQuery al consultar 8-16 puntos
cercanos del mismo racer. En vez de recorrer 3072 pares × trig × Newton por
punto, evaluar UNA región local (patch) alrededor del racer una vez y
reutilizarla con interpolación. NO reemplaza el backend NATIVE DIRECT: es un
prototipo standalone para medir precisión y rendimiento antes de decidir.

## Estado: PROTOTIPO STANDALONE COMPLETADO — CONCLUSIÓN B (preciso pero demasiado caro)

La hipótesis se validó en precisión y se refutó en rendimiento:

- **Precisión PATCH ≈ DIRECT: EXCELENTE** (config A cumple todos los objetivos
  de la sección 14, holgadamente).
- **Rendimiento: el PATCH es 2.5× MÁS LENTO que DIRECT en el escenario real**
  (1 racer × 16 queries: PATCH 3.86 ms vs DIRECT 1.56 ms).
- **NO se integra en la GDExtension** (sección 22 exige accuracy PASS *y*
  speedup claro; la precisión pasa, el speedup no existe).
- **Conclusión B**: PATCH preciso pero demasiado caro → recomendar SIMD/direct
  u otra arquitectura. El core queda como prototipo aislado y medible.

## Arquitectura (nueva)

```text
OceanQueryPatchCore (C++, portátil, sin godot-cpp):
  ├─ core: OceanQueryCore  (espectro compacto + ev_h/ev_v, SÓLO preparación)
  ├─ specs: 1 grid por cascada (LONG/MID/SHORT), world-aligned
  ├─ build_patch(cx,cz): rejilla por cascada con recurrencia de fase
  │    └─ cada nodo acumula EXACTAMENTE las contribuciones REDUCED de
  │       OceanQueryCore::accumulate_() (mismos kx, ky, omega, a1/a2,
  │       c11..c22, parity, weight, inv_n2, ev_h/ev_v)
  ├─ evaluate_fields_: bilinear de los 12 campos sumando los 3 grids
  └─ sample_patch_prepared: Newton world_xz -> q CON INTERPOLACIÓN
       (MAX_ITERATIONS=3, tol 1e-3, eps 1e-6; igual que DIRECT)
```

- El patch NO rota con el jetski: world-aligned. Los increments X/Z dependen
  sólo de kx·spacing y ky·spacing y se precomputan.
- Los 12 campos por nodo: H, Dx, Dz, dH/dx, dH/dz, dDx/dx, dDx/dz, dDz/dx,
  dDz/dz, Vh, Vx, Vz (mismo orden que accumulate_). Layout node-major contiguo
  (12 doubles por nodo), double (no float32).
- Recurrencia de fase: por modo, 3 sin/cos (fase en el origen + step_x + step_z)
  y después avanzar por el grid con multiplicación compleja
  (phase(x+dx,z) = phase·exp(i·kx·dx), etc.). NO hay sin/cos por modo×nodo.

## Grids por banda (config A probada)

| Banda | spacing | nodos | extensión | campos | pasos |
|---|---|---|---:|---:|---:|
| LONG  | 1.0 m | 7×7   | 6×6 m | 4.6 KB | 32 KB |
| MID   | 0.5 m | 13×13 | 6×6 m | 15.8 KB | 32 KB |
| SHORT | 0.25 m| 25×25 | 6×6 m | 58.6 KB | 32 KB |
| TOTAL | — | 843 | — | 79 KB | 96 KB → **~175 KB por patch** |

Config B (SHORT 0.125 m → 49×49): campos ~230 KB → ~326 KB por patch.
Se probó B porque la sección 20 lo pide si A no cumple; A cumple, B sólo como
tradeoff documentado.

## Precisión PATCH vs DIRECT (config A)

Dataset: 2 seeds × 2 estados × 3 tiempos × 4 centros de patch; por centro:
casco 3.1×1.2 m (16 pts) + grid 6×6 + 40 aleatorios + 8 centrales + 8 bordes +
4 fuera; ~1100 queries por (estado, seed, config). Comparación de campos
height/displacement/normal/velocity/jacobian, Newton, fallback, invalid.

| Estado | seed | height RMSE | P95 | normal RMSE | P95 | vel RMSE | dHoriz RMSE | jacob RMSE |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| RACE | 20260820 | 0.0018 | 0.0035 | 0.31° | 0.57° | 0.012 | 0.0016 | 0.0049 |
| RACE | 20260821 | 0.0014 | 0.0030 | 0.27° | 0.55° | 0.010 | 0.0014 | 0.0042 |
| ROUGH | 20260820 | 0.0036 | 0.0071 | 0.60° | 1.14° | 0.026 | 0.0035 | 0.0118 |
| ROUGH | 20260821 | 0.0029 | 0.0059 | 0.52° | 1.04° | 0.021 | 0.0030 | 0.0103 |

- Casco (posición real del jetski) y centrales: mismo orden (HULL normal
  RMSE 0.28-0.60°; CENTER 0.29-0.70°).
- **Objetivos sección 14 cumplidos holgadamente**:
  height RMSE ≤0.005 ✓ (0.0014-0.0036), P95 ≤0.010 ✓; normal RMSE ≤0.75°
  ✓ (0.27-0.60°), P95 ≤1.5° ✓ (0.55-1.14°); vel RMSE ≤0.05 ✓ (0.010-0.026);
  dHoriz RMSE ≤0.005 ✓ (0.0014-0.0035); jacob sign mismatch 0 ✓;
  invalid 0% ✓; non-converged 0 ✓; residual world ~0.0002 m ✓ (≤0.001).
- **Config B (SHORT 0.125, ROUGH seed 1)**: normal RMSE 0.19°, height 0.0021
  — mejor precisión pero build SHORT 10.6 ms (ver tradeoff abajo). No necesario.

### Fallback por tipo (config A, RACE seed 1: queries=1344, fallback=240 = 17.9%)

| tipo | fallback | explicación |
|---|---:|---|
| 0 casco | 0/192 | siempre dentro ✓ |
| 1 grid | 190/432 | puntos en el BORDE EXACTO del patch (u=extent): caen fuera de la zona interpolable (bilinear necesita nodo ix+1) → fallback a DIRECT |
| 2 aleatorio | 2/480 | ~0 ✓ |
| 3 central | 0/96 | ✓ |
| 4 borde interior | 0/96 | ✓ |
| 5 fuera (a propósito) | 48/48 | fuera del patch → fallback esperado |

El fallback alto del dataset es un artefacto del grid 6×6 que toca el borde
exacto del patch; en posiciones reales de casco/centrales/bordes interiores el
fallback es **0%**. El fallback usa DIRECT (no miente), correcto por diseño.

### Recurrencia de fase vs trig directa

- Nodo exacto del grid vs OceanQueryCore::accumulate_ de UNA cascada:
  **error medio ~1e-16** (bit-exacto: la recurrencia reproduce cos/sin directos).
- Determinismo: dos builds del mismo centro → **max diff 0.0** (bit-exacto).

## Precisión PATCH vs GOLDEN (OceanQueryReference, todos los modos)

Dataset pequeño (sección 15): 24 queries (16 casco + 8 centrales), 2 centros,
t=3.5, config A. Comparación con el baseline DIRECT vs GOLDEN para aislar el
error del PATCH sobre el error inherente del Reduced (budget 1024).

| Estado | PATCH vs GOLDEN | DIRECT vs GOLDEN (baseline) | objetivo 2B |
|---|---:|---:|---|
| RACE | height 0.0050, normal 1.39°, vel 0.035 | height 0.0048, normal 1.16°, vel 0.034 | H ≤0.015, normal ≤1.5°, vel ≤0.15 |
| ROUGH | height 0.0171, normal 2.59°, vel 0.073 | height 0.0144, normal 2.15°, vel 0.061 | H ≤0.025, normal ≤2.5°, vel ≤0.25 |

- RACE: **cumple** todos los targets globales 2B.
- ROUGH: height/velocity/displacement cumplen; normal RMSE 2.59° **supera
  ligeramente** el 2.5° del recordatorio 2B — pero el baseline DIRECT ya daba
  2.15° en este dataset pequeño (concentrado en el centro (37.5,-12.25),
  zona de choppiness alta). El PATCH añade +0.44° sobre el error del Reduced.
  No se recalibran budgets (mandato). Es un margen marginal en un dataset
  adverso de 24 puntos; en el dataset grande PATCH vs DIRECT el error de
  interpolación es ≤0.6°.
- Los 3×N² modos del Golden tardan mucho en GDScript: dataset reducido a 24
  queries a propósito.

## Rendimiento (config A, RACE seed 1; mediana de 5, core standalone)

| Medida | DIRECT | PATCH | nota |
|---|---:|---:|---|
| prepare_time | 0.042 ms | 0.043 ms | mismo ensure_prepared (idéntico) |
| build LONG | — | 0.23 ms | 7×7 |
| build MID | — | 0.79 ms | 13×13 |
| build SHORT | — | 2.80 ms | 25×25 — **cuello** |
| build TOTAL | — | **3.83 ms** | por patch |
| 16 queries | 1.59 ms | **0.0016 ms** | interp ~1000× más rápida |
| 32 | 2.99 | 0.0031 | |
| 64 | 5.96 | 0.0062 | |

### Escenarios (sección 16/17) — el patch NO amortiza

| Escenario | DIRECT | PATCH | ratio |
|---|---:|---:|---|
| 1 racer × 16 (1 build + 16q) | 1.56 ms | **3.86 ms** | **x0.40 (¡2.5× MÁS LENTO!)** |
| 4 racers × 16 (4 builds + 64q) | 7.77 | 15.21 | x0.51 |
| 8 racers × 16 (8 builds + 128q) | 16.2 | 30.3 | x0.53 |

- **Target sección 17 NO cumplido**: 1 racer/16q ≤1.0 ms → 3.86 ms; 4 racers/64q
  ≤3.0 ms → 15.2 ms. No se falsea.
- **Target sección 18 NO cumplido**: 16 sigue >1.8 ms (3.86) y 64 >6 ms
  (escenario 4 racers 15.2). NO integrar como backend de producción. STOP.
- Config B empeora: build TOTAL 11.6 ms (SHORT 10.6 ms) → 1 racer 12.3 ms.

### Perf breakdown — dónde está el cuello

El build es **O(modos × nodos)**: 3072 pares × 843 nodos = 2.6M evaluaciones
modo-nodo por patch. SHORT (625 nodos = 74% del total) domina el build
(2.8 ms de 3.8 ms). La recurrencia ya elimina la trig por nodo; el coste
restante es la acumulación de 12 campos × 3072 modos por cada nodo, que es
irreductible en esta arquitectura: el patch "precomputa" evaluando 843 puntos
completos para servir 16 queries.

Punto de equilibrio: build 3.8 ms ≈ 39 queries DIRECT (1.59 ms/16). El patch
sólo gana con ~40+ queries por patch por racer; el jetski usa 8-16.

## Restricciones respetadas

std::sin/cos normales, double, sin AVX/SIMD manual, sin fast-math, sin LUT,
sin multithreading, sin float32, sin cambios de matemática/budget/espectro.
C++ portátil (nada Win32 en el algoritmo): la futura build Linux/Steam Deck
podría usar exactamente el mismo PatchCore. No se toca el backend NATIVE
DIRECT (intacto como referencia/fallback), no se cambia el default del juego.

## Decisiones de diseño documentadas

- **World-aligned, sin snap inicial**: el centro del patch se usa tal cual
  (x0 = cx − half_extent). No se snapnea al grid de nodos porque la rejilla
  por banda tiene spacing distinto y el snap no aporta (el error de fase por
  offset no exacto es ~1e-16). Documentado: el snap podría añadirse sin coste.
- **Bilinear de entrada** (mandato): no se implementó bicubic; la precisión
  ya cumple con bilinear.
- **Fallback a DIRECT** cuando Newton del patch sale de la zona interpolable:
  no se devuelve una mentira; se cuenta patch_fallback_count y se usa DIRECT.

## Archivos nuevos / modificados

- `native/ocean_query/src/ocean_query_patch_core.h/.cpp` — core del patch.
- `native/ocean_query/src/ocean_query_core.h` — +`accumulate_public` (diagnóstico).
- `native/ocean_query/bench/bench_patch_main.cpp` — benchmark standalone
  (precisión + rendimiento + golden).
- `native/ocean_query/bench/dump_data_patch.gd` — data files 2 seeds.
- `native/ocean_query/bench/dump_golden_patch.gd` — ref GOLDEN (24 queries).
- `native/ocean_query/bench/build_bench_patch.bat` — build del bench.
- `native/ocean_query/bench/test_node/test_phase/test_fb/test_fb2.cpp` —
  sondas de depuración (fase de desarrollo).
- Datos regenerables (gitignored): `bench/data_*_2*.txt`, `queries_*`,
  `ref_golden_*`, `bin/bench_patch_main.exe`.

## Comandos

```
godot --headless --script res://native/ocean_query/bench/dump_data_patch.gd
bench\build_bench_patch.bat
bin\bench_patch_main.exe bench\data_race_20260820.txt A
bin\bench_patch_main.exe bench\data_rough_20260820.txt B        # tradeoff
bin\bench_patch_main.exe bench\data_race_20260820.txt A --dump-queries bench\queries_small_race_20260820.txt small
godot --headless --script res://native/ocean_query/bench/dump_golden_patch.gd -- race_20260820 ... ref
bin\bench_patch_main.exe bench\data_race_20260820.txt A --golden bench\ref_golden_race_20260820.txt small
```

## Decisión final

**B) PATCH preciso pero demasiado caro.** La interpolación espacial local
conserva world-space y cumple precisión con holgura (PATCH≈DIRECT ~1e-3 m /
0.3-0.6°; PATCH vs GOLDEN dentro de targets 2B salvo normal ROUGH marginal
2.59° vs 2.5° en dataset adverso), pero el build del patch cuesta O(modos×nodos)
≈ 3.8 ms por racer, 2.5× más que las 16 queries DIRECT que reemplaza. El
backend de producción NO cambia; NATIVE DIRECT sigue siendo la referencia.
Gate 2 sigue pendiente de revisión del usuario (16 ≤1 ms / 64 ≤3 ms NO se
cumplen ni con DIRECT ni con PATCH). Próximo paso natural si se quiere
perseguir el target: SIMD/fast-math sobre el core DIRECT (Fase 2C.1B) o grid
local — NO el patch de esta fase.

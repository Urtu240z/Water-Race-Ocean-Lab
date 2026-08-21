# Ocean Lab — Fase 2C.1B: TRUE NATIVE BATCH + NEWTON WARM START

## Estado: completada y medida — recomendación D

`OceanQueryPatchCore` continúa siendo un **prototipo standalone**. No se ha
modificado ni integrado: `SConstruct` enumera de forma explícita sólo
`ocean_query_core.cpp`, `ocean_query_native.cpp` y `register_types.cpp`, por
lo que PatchCore no entra en la DLL de producción.

Esta fase añade dos rutas opt-in a `OceanQueryCore`; la ruta existente
`sample_batch_prepared` se conserva como `DIRECT_SCALAR` de referencia y el
juego no cambia de backend ni de default.

## Diseño

- `sample_batch_true_prepared`: batch frío SoA, recorre `cascada → modo →
  puntos activos`. Cada cascada mantiene acumuladores locales por punto y los
  reduce con el mismo orden de modo/cascada del scalar antes de sumar al total.
- `sample_batch_warm_prepared`: recibe `qx,qz` de la consulta anterior y
  devuelve los 15 campos normales más `qx,qz` resueltos (stride 17). Una
  semilla no finita vuelve a `world_xz`.
- Workspace reutilizable: posiciones, q, 12 campos, campos locales de
  cascada, residual, iteraciones e índices activos son `std::vector<double>`
  SoA que sólo crecen cuando aumenta la capacidad.
- Newton sigue usando double, `MAX_ITERATIONS=3`, `tol=1e-3` y
  `epsilon=1e-6`; no hay fast-math, LUT, SIMD/intrinsics, hilos, float32 ni
  cambios de espectro/budget (1024 por cascada).
- Diagnósticos: evaluaciones espectrales completas de puntos activos y
  histograma `0/1/2/3/no-conv` de la última ejecución TRUE_BATCH.

La GDExtension expone `sample_batch_true_prepared`,
`sample_batch_warm_prepared`, `get_diag_last_spectral_point_evaluations` y
`get_diag_last_newton_histogram`. La segunda API usa sólo PackedArrays; no
crea objetos de muestra.

## Exactitud y determinismo

`tests/phase_2c_1b_true_batch_validation.gd` pasa con RACE y ROUGH:

- batch frío vs DIRECT_SCALAR: N=1/4/8/16/64, 15 campos, diferencia máxima
  ≤ `1e-11`, misma validez/foldover/iteraciones, determinista;
- sea level absoluto: PASS;
- warm temporal: huella 3.1×1.2 m, 16 puntos, 120 ticks a 60 Hz,
  predictor `q_prev + (world_t - world_prev)`, sin diferencias de valid/fold
  ni residuales por encima de `1e-3`.

El warm no es idéntico numéricamente a DIRECT en todos los ticks: al partir
de otra semilla puede cruzar el mismo umbral de convergencia `1e-3` una
iteración antes. En la secuencia medida, el máximo de los campos físicos
(height/displacement/normal/velocity/det) frente a cold DIRECT fue `8.34e-4`
en RACE y `2.26e-3` en ROUGH; `iterations` también puede diferir. Es el efecto
del criterio de parada finito, no una segunda solución ni un cambio de suma.
Por ello WARM permanece experimental y no es candidato a sustituir DIRECT
hasta definir una política de canonicalización que conserve precisión y coste.

## Rendimiento standalone (MSVC /O2, mediana de 7)

Datos compactos 1024/1024/1024, t=3.5, ms. `evals` cuenta evaluaciones
completas de espectro por punto, no pares individuales.

| Estado/ruta | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| RACE DIRECT_SCALAR | 0.153 | 0.481 | 0.921 | 1.805 | 3.805 | 7.926 |
| RACE TRUE_BATCH_COLD | 0.187 | 0.542 | 0.998 | 1.873 | 3.803 | 7.883 |
| ROUGH DIRECT_SCALAR | 0.142 | 0.562 | 1.129 | 2.276 | 4.593 | 9.369 |
| ROUGH TRUE_BATCH_COLD | 0.185 | 0.672 | 1.246 | 2.426 | 4.800 | 9.486 |

Frío N=64: RACE `163 evals`, hist `0/29/35/0/0`; ROUGH `188 evals`, hist
`0/6/56/2/0`; no hubo no-convergentes.

Secuencia temporal de 600 ticks, 60 Hz, p50/p95 ms:

| Estado | Racers × 16 | p50 | p95 | evals/tick | hist 0/1/2/3/no-conv |
|---|---:|---:|---:|---:|---|
| RACE | 1 | 1.559 | 1.772 | 31.89 | 76/9514/10/0/0 |
| RACE | 4 | 14.416 | 16.037 | 127.49 | 366/37976/58/0/0 |
| RACE | 8 | 29.457 | 33.051 | 255.02 | 700/75986/114/0/0 |
| ROUGH | 1 | 1.663 | 1.947 | 32.92 | 22/9006/572/0/0 |
| ROUGH | 4 | 6.803 | 16.592 | 131.24 | 81/36307/2002/10/0 |
| ROUGH | 8 | 31.603 | 42.454 | 262.53 | 152/72599/4030/19/0 |

El warm baja el caso temporal de 16 puntos respecto al cold/direct de la
rejilla (RACE ~1.80→1.56 ms, ROUGH ~2.28→1.66 ms), pero no alcanza el gate
de 1 ms para 16 ni 3 ms para 64.

## Medición end-to-end GDExtension (mediana de 5, ms)

| Estado/ruta | N=16 | N=64 |
|---|---:|---:|
| RACE DIRECT / COLD / WARM | 1.880 / 1.924 / 1.826 | 8.846 / 8.485 / 9.325 |
| ROUGH DIRECT / COLD / WARM | 2.431 / 2.373 / 2.303 | 9.556 / 9.904 / 9.963 |

La frontera de PackedArrays sigue siendo visible. El benchmark controlado es
`lab/benchmark/phase_2c_1b_true_batch_benchmark.gd`; el standalone ampliado
es `native/ocean_query/bench/bench_main.cpp`.

## Validación/build

- `native/ocean_query/bench/build_bench.bat` detecta VS 2019/2022 igual que
  el build de la DLL y compila el benchmark portátil;
- `native/ocean_query/build_windows_release.bat`: PASS;
- `tests/phase_2c_validation.gd`: PASS (regresión 2C);
- `tests/phase_2c_1b_true_batch_validation.gd`: PASS.

## Recomendación

**D) No hay ganancia suficiente para aprobar el gate.** TRUE_BATCH_COLD es
prácticamente neutro y WARM mejora el caso temporal de 16 puntos, pero no
cumple los gates absolutos ni la equivalencia numérica requerida para cambiar
la ruta de producción. Se mantiene como instrumentación/API experimental;
NATIVE DIRECT sigue siendo la referencia/default. No se implementa ninguna
fase posterior en este cambio.

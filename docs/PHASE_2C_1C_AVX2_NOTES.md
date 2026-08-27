# Ocean Lab — Fase 2C.1C: Production AVX2 SIMD

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

## Resultado: éxito para producción

AVX2 resuelve suficientemente OceanQuery en esta máquina: precisión PASS,
16 queries por debajo de 1 ms y 64 por debajo de 3 ms en standalone y en la
frontera GDExtension. NATIVE DIRECT conserva un fallback scalar real y la
selección es runtime; no existe requisito AVX2 para cargar la DLL.

## Dispatch y aislamiento de compilación

```text
OceanQueryCore scalar (sin /arch:AVX2)
  └─ CPUID: AVX + OSXSAVE + XGETBV(XMM|YMM) + AVX2
       ├─ force_scalar=true / CPU no compatible → SCALAR_DIRECT
       └─ compatible                         → AVX2 cold batch
                                                      └─ ocean_query_simd_avx2.cpp
                                                         (única TU /arch:AVX2)
```

`SConstruct` crea un `Object` desde `ocean_query_simd_avx2.cpp` con
`/arch:AVX2` en Windows (`-mavx2` previsto para GCC/Clang). Core, wrapper y
registro se compilan con las flags base. PatchCore sigue fuera de `sources`.
El detector CPUID/XGETBV vive en `ocean_query_core.cpp`, compilado scalar, así
que no se ejecutan instrucciones AVX2 antes de decidir el dispatch.

La API de depuración expone:

- `get_cpu_supports_avx2()`;
- `get_query_execution_backend()` → `"AVX2"` o `"SCALAR"`;
- `set_force_scalar(bool)`;
- `sample_batch_scalar_prepared()` y
  `sample_batch_avx2_scalar_trig_prepared()` para comparación medida.

`sample_batch_prepared()` conserva su contrato y ahora elige AVX2 de forma
automática si está disponible. `force_scalar` mantiene vivo el fallback y es
el mecanismo usado por la validación.

## Kernel

El kernel opera sobre cuatro puntos `double` simultáneos. Mantiene SoA y
procesa cada cascada por grupos de cuatro puntos; los acumuladores de los 12
campos permanecen en registros durante los modos de ese grupo. Los tails y
conjuntos activos de Newton menores de cuatro caen a scalar. Newton sigue
siendo cold/canónico (`q=world`, 3 iteraciones, `tol=1e-3`, `eps=1e-6`).

No hay AVX-512, FMA requerida, fast-math global, float32, LUT, cambios de
FFT/espectro/budget ni threading.

## Trigonometría

El subtest `AVX2 arithmetic + std::sin/cos por lane` confirmó que la trig es
el cuello: para 64 puntos sólo mejora RACE `7.341→5.999 ms` (1.22×) y ROUGH
`8.821→7.171 ms` (1.23×). No se microoptimizó esa variante.

Se implementó `sincos_pd_avx2`: reducción por múltiplos de π/2 con constante
split y polinomios Taylor/minimax-equivalentes de double en `[-π/4, π/4]`, con
recomposición de cuadrante. No usa fast-math ni una dependencia externa. En
el rango real de `phi` (todos los modos de las cascadas RACE/ROUGH × 64
posiciones, 196 608 muestras):

| métrica | sin | cos |
|---|---:|---:|
| error abs máximo | 2.043e-14 | 2.043e-14 |
| RMSE RACE | 2.727e-15 | 2.420e-15 |
| RMSE ROUGH | 2.729e-15 | 2.425e-15 |

## Core standalone (MSVC /O2, mediana de 9, ms)

| Estado | Ruta | N=16 | N=64 | speedup 16 / 64 |
|---|---|---:|---:|---:|
| RACE | SCALAR_DIRECT | 1.915 | 7.341 | — |
| RACE | AVX2 arithmetic + scalar trig | 1.611 | 5.999 | 1.19× / 1.22× |
| RACE | AVX2 full sincos | **0.425** | **1.580** | **4.51× / 4.65×** |
| ROUGH | SCALAR_DIRECT | 2.252 | 8.821 | — |
| ROUGH | AVX2 arithmetic + scalar trig | 1.844 | 7.171 | 1.22× / 1.23× |
| ROUGH | AVX2 full sincos | **0.496** | **1.753** | **4.54× / 5.03×** |

Full AVX2: RACE 26.5 / 24.7 µs/query y ROUGH 31.0 / 27.4 µs/query para
N=16 / N=64 respectivamente. En N=1 el dispatch conserva scalar (AVX2 no
amortiza su setup); N=4 ya obtiene ~5.4–5.6×.

## Precisión OceanQuery

`tests/phase_2c_1c_avx2_validation.gd` cubre RACE y ROUGH, tiempos 0/1.3/3.5,
N=1/4/8/16/32/64, sea level, determinismo y fallback. AVX2 vs scalar:

- máxima diferencia registrada por el benchmark: `2.887e-15` RACE y
  `5.662e-15` ROUGH en el buffer de 15 campos;
- por tanto queda ampliamente dentro de height/horizontal ≤0.001 m, normal
  ≤0.10°, velocity ≤0.01 m/s y detJ ≤0.002;
- residual ≤0.001 m, 0 mismatches de `valid` y 0 de signo foldover.

## GDExtension end-to-end (mediana de 7, ms)

Instancias separadas por estado/modo para evitar contaminación térmica o del
asignador:

| Estado | N | scalar | AVX2 | speedup |
|---|---:|---:|---:|---:|
| RACE | 16 | 1.905 | **0.491** | 3.88× |
| RACE | 64 | 8.128 | **2.136** | 3.81× |
| ROUGH | 16 | 2.359 | **0.621** | 3.80× |
| ROUGH | 64 | 9.330 | **2.437** | 3.83× |

CPU detectada durante tests: AVX2 disponible; backend seleccionado `AVX2`.
Con `set_force_scalar(true)` el backend reporta `SCALAR` y todas las consultas
siguen pasando, demostrando el fallback vivo.

## Validación

- `native/ocean_query/build_windows_release.bat`: PASS;
- standalone `bench/build_bench.bat` + `bench_main.exe ... --avx`: PASS;
- `tests/phase_2c_validation.gd`: PASS;
- `tests/phase_2c_1b_true_batch_validation.gd`: PASS;
- `tests/phase_2c_1c_avx2_validation.gd`: PASS.

## Decisión

**Producción AVX2 aprobada.** Gate 16≤1 ms: **sí**. Gate 64≤3 ms: **sí**.
No se implementa threading: ya no es necesario para los gates de un racer y
esta fase no autoriza paralelización multi-racer. Si una carga futura de
muchos racers lo exige, la siguiente unidad natural de paralelismo es por
racer, no más deformación de la matemática SIMD.

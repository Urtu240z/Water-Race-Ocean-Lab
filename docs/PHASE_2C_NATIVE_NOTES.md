# Ocean Lab — Fase 2C: OceanQuery NATIVE (GDExtension)

Objetivo: mover el HOT PATH de OceanQueryReduced a C++ nativo SIN cambiar la
matemática ni reducir precisión, y medir cuánto gana exactamente el mismo
algoritmo.

## Estado: COMPLETADO — DLL real compilada, integrada y validada (offline)

- **Compilador C++:** MSVC 19.29 (VS 2019 Build Tools, vcvars64.bat).
- **godot-cpp:** offline en `native/godot-cpp/` (zip `godot-cpp-master.zip`
  proporcionado por el usuario; NO se clonó ni se descargó nada).
- **scons:** 4.11.0 offline, extraído del wheel
  `native/godot-cpp/deps/scons-4.11.0-py3-none-any.whl` a
  `native/deps/scons_site/` (pip no puede escribir en AppData con el sandbox).
- **Build:** `native/ocean_query/build_windows_release.bat` (o
  `python -m SCons platform=windows target=template_release` con
  `PYTHONPATH=native/deps/scons_site`).
- **DLL generada:** `bin/water_race_ocean_query.windows.template_release.x86_64.dll`
  (~359 KB) + descriptor activo `water_race_ocean_query.gdextension`
  (gitignored; se regenera SÓLO si el build tiene éxito, copiando el template).
- **Integración:** Godot 4.7.1 Standard carga la extensión al arrancar
  (`ClassDB.class_exists(&"OceanQueryNative") == true`, backend = NATIVE).
  Si la DLL no existe, fallback silencioso REDUCED_GDSCRIPT (sin ruido).
- Linux x86_64: documentado en el descriptor (`.so`), NO compilado.

## Arquitectura

```text
GDScript (selección, sin cambios de 2B):
  OceanQueryReduced
    ├─ pares canónicos / Nyquist / importance / budgets 1024/1024/1024
    ├─ get_cascades_compact()  → arrays compactos
    └─ configure_native_backend(native)  → empuja arrays a C++ al cambiar
                                           H0/seed/state/budget

C++ (hot path):
  OceanQueryCore (std::vector<double>, portable)
    ├─ ensure_prepared          (ωt, cos/sin, ev_h/ev_v)
    ├─ accumulate               (bucle por par: height/Dx/Dz/derivadas/velocity)
    ├─ Newton world_xz -> q     (3 iter, 1e-3, epsilon 1e-6)
    └─ batch                    (sample_batch_prepared)

GDExtension wrapper (compilado):
  OceanQueryNative (RefCounted) — delega en OceanQueryCore.
  Contrato batch: PackedFloat64Array plana, stride 15:
    0 valid | 1 height | 2..4 displacement | 5..7 normal | 8..10 velocity |
    11 jacobian_det | 12 foldover | 13 residual | 14 iterations
```

Lo que quedó en GDScript (por decisión de la tarea): construcción de pares,
tratamiento Nyquist, importance ranking, selección, captured energy y
calibración. Lo que pasa a C++: almacenamiento compacto, prepare_time,
evaluación paramétrica, derivadas, velocity, Jacobiano, Newton y batch.

Los datos se transfieren a C++ SÓLO al cambiar H0/seed/state/budget (una vez);
durante los physics ticks sólo viajan tiempo + posiciones.

## Equivalencia numérica (Native vs Reduced GDScript)

`tests/phase_2c_validation.gd` — mismo H0, mismo presupuesto 1024/1024/1024,
mismas posiciones y tiempos, world-space, batch==individual, sea level:

| Estado | max Δheight | max Δdisp | max Δnormal | max Δvel | max ΔdetJ | Δiter/Δvalid |
|---|---:|---:|---:|---:|---:|---:|
| RACE | ~1e-7 | ~1e-7 | ~3e-7 | ~4e-7 | ~6e-7 | 0 / 0 |
| ROUGH | ~2e-6 | ~2e-6 | ~3e-6 | ~2e-6 | ~2e-6 | 0 / 0 |

- RACE: diferencias ~1e-7 (ruido libm/orden de suma).
- ROUGH: diferencias hasta ~2e-6 (ruido libm REAL amplificado por Newton en
  puntos de choppiness alta). La tolerancia del test se fijó en 1e-5 (2C PASS).
  **No es un cambio de fórmula**: el core C++ ejecuta exactamente la misma
  matemática; la magnitud es la del punto (37.5,-12.25) t=0 con choppiness 1.15.
- Suite completa: 1A/1B/1C/1D/2A/2A.1/2B/2C PASS + smoke runtime 9/9.

## Benchmark end-to-end (Godot 4.7.1, mediana de 5, misma ejecución GDS vs NATIVE)

`lab/benchmark/phase_2c_native_benchmark.gd` — grid 8×8 (20×20 m), t=3.5.
**Metodología v3 (importante):** los counts NATIVE de ambos estados se miden
PRIMERO y los GDS después. Se detectó y corrigió un artefacto de medición:
medir el backend nativo DESPUÉS de una fase GDScript pesada en el mismo
proceso lo degradaba ~2-4× (estado térmico/asignador; ROUGH 16 pasaba de
2.4 ms a 9.3 ms). Aislado (proceso limpio) y con este orden, el e2e
reproduce el core standalone.

| Medida | RACE NATIVE | RACE GDScript | ROUGH NATIVE | ROUGH GDScript |
|---|---:|---:|---:|---:|
| prepare_time | 0.04 ms | 0.80 ms | 0.10 ms | 1.95 ms |
| 1 query | 0.15 | 4.03 | 0.15 | 12.85 |
| 4 | 0.59 | 13.5 | 0.58 | 48.6 |
| 8 | 1.13 | 25.9 | 1.16 | 92.4 |
| 16 | **2.43** | 50.1 | **2.42** | 200.0 |
| 32 | 4.75 | 105.5 | 4.75 | 401.4 |
| 64 | **9.67** | 220.3* | **9.68** | 819.5 |

*El GDS 64 de RACE en esta ejecución dio 500-640 ms (GC/térmico puntual);
el valor estable de RACE GDS 64 es ~220 ms (bench 2B / dump_data).

**Speedup end-to-end: prepare ~19-20×; queries RACE ~21-27×; ROUGH ~80-85×**
(el GDS ROUGH es mucho más caro por query que RACE — más iteraciones de
Newton en choppiness alta — mientras el nativo casi no varía).

### Contraste con el core independiente (bench_main.exe, MSVC /O2)

| Medida | RACE standalone | RACE e2e | ROUGH standalone | ROUGH e2e |
|---|---:|---:|---:|---:|
| 16 queries | 1.87 ms | 2.43 ms | 2.29 ms | 2.42 ms |
| 64 queries | 8.19 ms | 9.67 ms | 9.07 ms | 9.68 ms |
| batch 16 / 64 | 1.85 / 8.00 | — | 2.30 / 9.46 | — |

El e2e añade ~20-30% sobre el standalone en RACE (frontera GDExtension +
variación de medición) y ~5% en ROUGH. El core nativo es el mismo código en
ambos caminos. `diag_non_converged = 0` (Newton 1-2 iteraciones).

## ¿Cumple los targets de Gate 2?

**NO todavía** (con matemática exacta escalar):
- 16 queries: RACE **2.43 ms**, ROUGH **2.42 ms** (target ≤ 1 ms).
- 64 queries: RACE **9.67 ms**, ROUGH **9.68 ms** (target ≤ 3 ms).

Mejora enorme (~20-85× vs GDScript) pero no suficiente para los objetivos.
El cuello es el número de pares (3072) × trig espacial × Newton. Las opciones
para alcanzarlo (sincos, fast-math, AVX, LUT, multithreading) están
**excluidas de 2C** por mandato → corresponden a una **Fase 2C.1** (NO
implementada por ahora). No se falsea aprobación: Gate 2 sigue pendiente de
revisión del usuario.

## Memoria / transferencia

- Core: `std::vector<double>` compactos (~3072 pares × 16 arrays ≈ ~1 MB).
- Transferencia GDScript→C++: una vez por rebuild (~210-610 ms en GDScript,
  aceptado: seed/state no cambian por frame).

## Tests / integración

- `OceanQueryReduced.configure_native_backend(native)` + `get_cascades_compact()`:
  el reduced empuja los arrays compactos al backend nativo al reconstruir
  selección (sin acceso privado cruzado).
- `OpenOceanFFTModule`: backend **NATIVE** si la DLL existe; fallback
  **REDUCED_GDSCRIPT** silencioso si no (no crashea ni ensucia consola).
  `query_backend_name()` → `NATIVE` / `REDUCED_GDSCRIPT`. API pública sin
  cambios (sample_water, sample_water_physics_time, batch).
- `tests/phase_2c_validation.gd`: equivalencia native vs GDScript — **PASS**
  (tolerancia 1e-5; ROUGH ruido libm real ~2e-6 documentado arriba).
- `lab/benchmark/phase_2c_native_benchmark.gd`: comparación en la misma
  ejecución con metodología v3 (native primero; ver nota de artefacto).
- Suite previa (1A..2B + smoke): **PASS** con backend nativo activo.

## Notas de build / troubleshooting

- **Descriptor:** formato Godot ConfigFile — comentarios con `;`, NUNCA `#`
  dentro de `[libraries]` (un `#` rompe el parseo y Godot reporta "No
  GDExtension library found for current OS and architecture").
- **`.godot/extension_list.cfg`:** cachea las extensiones descubiertas; si
  queda una entrada stale tras renombrar el descriptor, borrar `.godot/` una
  vez (no se versiona) o dejar que el editor lo regenere.
- **Modo headless `--script`:** Godot puede no cargar GDExtensions en scripts
  puros; los tests 2C cargan escena (`change_scene_to_file`) para forzar la
  carga del módulo — por eso la validación 2C funciona en headless.
- **Sandbox:** pip no puede escribir en AppData ni usar temp del sistema;
  SCons se ejecuta con `PYTHONPATH=native/deps/scons_site` + `python -m SCons`.
- **`build_windows_release.bat`:** localiza vcvars64.bat (VS 2019/2022),
  configura PYTHONPATH al SCons offline y compila template_release; regenera
  el descriptor activo sólo si compila.

## Comandos comprobados

- `python -m SCons -Q platform=windows target=template_release` (con
  PYTHONPATH a scons_site) → OK, DLL + descriptor.
- `native\ocean_query\build_windows_release.bat` → OK (rebuild completo
  verificado: DLL 359 KB + descriptor regenerado).
- `bench\build_bench.bat` + `bench_main.exe` → core independiente (RACE
  16=1.87 / 64=8.19; ROUGH 16=2.29 / 64=9.07).
- `tests/phase_2c_validation.gd` → PASS.
- `lab/benchmark/phase_2c_native_benchmark.gd` → ver tabla e2e.

## Recomendación

1. 2C cerrado: DLL real integrada, equivalencia validada, speedup medido
   end-to-end. Pendiente sólo la revisión del usuario (Gate 2).
2. Si Gate 2 exige 16≤1 ms / 64≤3 ms: **Fase 2C.1** (sincos/MSVC intrinsics,
   fast-math evaluado con cuidado, posible AVX, multithreading) o evaluar
   **grid local** como arquitectura alternativa. La matemática exacta actual
   ya está validada.

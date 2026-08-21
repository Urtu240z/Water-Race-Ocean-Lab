# Ocean Lab — Fase 2C: OceanQuery NATIVE (GDExtension)

Objetivo: mover el HOT PATH de OceanQueryReduced a C++ nativo SIN cambiar la
matemática ni reducir precisión, y medir cuánto gana exactamente el mismo
algoritmo.

## Estado: parcialmente compilable (toolchain nativa limitada)

- **Compilador C++:** presente — MSVC 19.29 (VS 2019 Build Tools,
  `C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat`).
- **godot-cpp:** AUSENTE y sin red para clonarlo (github y pypi bloqueados;
  `git ls-remote https://github.com/godotengine/godot-cpp.git` falló con
  `SEC_E_NO_CREDENTIALS`; `Invoke-WebRequest` a github/pypi: conexión reset).
- **scons:** AUSENTE y sin red para instalarlo (`pip install scons` imposible).
- **Windows SDK 10.0.26100:** presente.

Consecuencia: **el wrapper GDExtension está escrito pero NO compilado**. Para
no quedarnos sin datos reales, se portó el CORE (el bucle caliente exacto) a
C++ plano independiente (sin godot-cpp), **compilado y benchmarkeado** con
MSVC /O2. Ese core es la base del wrapper; ambos comparten el mismo código
(`native/ocean_query/src/ocean_query_core.{h,cpp}`).

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

GDExtension wrapper (NO compilado aún):
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

## Equivalencia numérica (C++ core vs Reduced GDScript)

Mismo H0, mismo presupuesto 1024/1024/1024, mismas posiciones y tiempos
(16 posiciones × t=3.5, RACE y ROUGH):

| Estado | max Δheight | max Δdisp | max Δnormal | max Δvel | max ΔdetJ | Δiter/Δvalid |
|---|---:|---:|---:|---:|---:|---:|
| RACE | 1.03e-7 | 1.07e-7 | 2.56e-7 | 4.43e-7 | 5.56e-7 | 0 / 0 |
| ROUGH | 1.21e-7 | 1.14e-7 | 1.37e-7 | 5.40e-7 | 4.30e-7 | 0 / 0 |

Diferencias ~1e-7 = ruido libm/orden de suma (tolerancia 1e-9..1e-7 de la
tarea). **La matemática es idéntica**; el C++ no reinventa el pairing.

## Benchmark REAL (MSVC /O2, std::sin/cos, sin fast-math, sin AVX/LUT)

`native/ocean_query/bench/` — core C++ independiente, mediana de 5:

| Medida | RACE C++ | RACE GDScript | ROUGH C++ | ROUGH GDScript |
|---|---:|---:|---:|---:|
| prepare_time | 0.044 ms | 1.60 ms | 0.040 ms | 4.97 ms |
| 1 query | 0.15 ms | 3.94 ms | 0.16 ms | 12.0 ms |
| 4 | 0.51 | 13.2 | 0.57 | 52.9 |
| 8 | 0.98 | 25.0 | 1.14 | 102.6 |
| 16 | 1.87 | 48.9 | 2.39 | 163.4 |
| 32 | 3.91 | 95.2 | 4.66 | 384.8 |
| 64 | 8.19 | 190.2 | 9.41 | 730.0 |
| batch 16 / 64 | 1.85 / 8.00 | — | 2.30 / 9.46 | — |

**Speedup: prepare 36–124×; queries 23–78×** (RACE 16 ≈ 26×, ROUGH 16 ≈ 68×).
`diag_non_converged = 0` (Newton 1–2 iteraciones, como GDScript).

## ¿Cumple los targets de Gate 2?

**NO todavía** (con matemática exacta escalar):
- 16 queries: RACE **1.87 ms**, ROUGH **2.39 ms** (target ≤ 1 ms).
- 64 queries: RACE **8.19 ms**, ROUGH **9.41 ms** (target ≤ 3 ms).

Es una mejora enorme (23–78×) pero no suficiente para los objetivos. El cuello
es el número de pares (3072) × trig espacial × Newton. Las opciones para
alcanzarlo (sincos, fast-math, AVX, LUT) están **excluidas de 2C** por mandato
→ corresponden a una **Fase 2C.1** o al grid local. No se falsea aprobación.

## Memoria / transferencia

- Core: `std::vector<double>` compactos (~3072 pares × 16 arrays ≈ ~1 MB).
- Transferencia GDScript→C++: una vez por rebuild (~210–610 ms en GDScript,
  aceptado: seed/state no cambian por frame).

## Tests / integración

- `OceanQueryReduced.configure_native_backend(native)` + `get_cascades_compact()`:
  el reduced empuja los arrays compactos al backend nativo al reconstruir
  selección (sin acceso privado cruzado).
- `OpenOceanFFTModule`: backend **NATIVE** si la DLL existe; fallback
  **REDUCED_GDSCRIPT** silencioso si no (no crashea ni ensucia consola).
  `query_backend_name()` → `NATIVE` / `REDUCED_GDSCRIPT`. API pública sin
  cambios (sample_water, sample_water_physics_time, batch).
- `tests/phase_2c_validation.gd`: equivalencia native vs GDScript (sintético,
  RACE/ROUGH world-space, batch==individual, sea level). **SKIP** cuando la
  DLL no está construida (estado actual).
- `lab/benchmark/phase_2c_native_benchmark.gd`: comparación en la misma
  ejecución (SKIP sin DLL).
- Suite previa (1A..2B + smoke): **PASS** con fallback GDScript.

## Plataformas realmente compiladas

- **Windows x86_64**: el CORE independiente se compiló y ejecutó (MSVC /O2).
- El **wrapper GDExtension NO se compiló** (falta godot-cpp/scons).
- Linux x86_64: documentado en el descriptor (`.so`), sin compilar.

## Cómo completar el build (pasos mínimos para el usuario)

1. Conectar red y clonar godot-cpp (rama 4.7) en `native/godot-cpp`:
   `git clone -b 4.7 --depth 1 https://github.com/godotengine/godot-cpp.git native/godot-cpp`
2. Instalar scons: `python -m pip install scons`
3. Compilar: `cd native/ocean_query && scons platform=windows target=template_release`
   - El SConstruct genera `bin/water_race_ocean_query.dll` y, SÓLO si el build
     tiene éxito, copia `water_race_ocean_query.gdextension.template` →
     `water_race_ocean_query.gdextension` (descriptor activo, gitignored).
   - Si el build falla, NO se crea el descriptor activo y Godot no intenta
     cargar ninguna DLL (arranque limpio con fallback REDUCED_GDSCRIPT).
4. Re-ejecutar `tests/phase_2c_validation.gd` y
   `lab/benchmark/phase_2c_native_benchmark.gd` (pasan de SKIP a validación
   real) y comparar contra el core independiente ya medido.

> **Nota para checkouts existentes:** si Godot arrancó antes con el descriptor
> activo, `.godot/extension_list.cfg` puede conservar una referencia stale.
> Borrarlo una vez (`.godot/` no se versiona) o dejar que el editor lo
> regenere al abrir el proyecto tras este cambio.

## Comandos comprobados que fallaron

- `git ls-remote https://github.com/godotengine/godot-cpp.git HEAD` → `fatal:
  unable to access ... schannel: SEC_E_NO_CREDENTIALS`.
- `Invoke-WebRequest https://github.com` y `https://pypi.org` → conexión
  reset (sin red).
- `python -m scons --version` → `No module named scons`.
- `python -m pip cache list` → sin scons en caché.

## Recomendación

1. Completar el build GDExtension con los pasos anteriores (necesita red).
2. Medir el speedup real end-to-end (benchmark 2C) — se espera cercano al core
   independiente (23–78×) salvo overhead de frontera (reducido con batch).
3. Si Gate 2 exige 16≤1 ms / 64≤3 ms: **Fase 2C.1** (sincos/MSVC intrinsics,
   fast-math evaluado con cuidado, posible AVX) o evaluar **grid local** como
   arquitectura alternativa. La matemática exacta actual ya está validada.

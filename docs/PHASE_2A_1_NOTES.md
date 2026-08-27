# Ocean Lab — Fase 2A.1: OceanQueryReference WORLD-SPACE (Golden Reference)

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Tarea quirúrgica: OceanQueryReference pasa a ser una **golden reference en
coordenadas mundiales** antes de construir el evaluator rápido de Fase 2B.
No se implementa 2B ni física del jetski.

## Problema conceptual corregido

La superficie Tessendorf con choppiness NO es `Y = H(world_xz)`: es una
superficie **paramétrica**:

```text
P(q,t).xz = q + Dxz(q,t)
P(q,t).y  = sea_level + H(q,t)
```

Antes, `sample_water(world_position)` evaluaba directamente `q = world_xz`,
incorrecto con desplazamiento horizontal (ahora más relevante con lambda
negativa comprimiendo crestas).

## Arquitectura

```text
evaluate paramétrico:  _parametric_accumulators(q, t) -> {D, H, derivadas, velocity, detJ}
sample_parametric(q,t)           -> evalúa en q directo (helper tests/debug)
sample_water(world_xz, t)        -> Newton world_xz -> q  ->  evalúa en q
```

`sample_water(...)` significa desde ahora **"muestra la superficie que existe
bajo este XZ mundial"**. Semántica estable, no cambia después.

## Inversión world_xz -> q (Newton-Raphson 2D)

Resolver `F(q) = q + Dxz(q,t) - target_xz = 0` con las derivadas analíticas ya
disponibles:

```text
J = [[1 + dDx/dx,   dDx/dz  ],
     [  dDz/dx,   1 + dDz/dz]]
```

- `MAX_ITERATIONS = 8`
- `POSITION_TOLERANCE_M = 1e-4`
- `JACOBIAN_EPSILON = 1e-6` (detJ por debajo => singular; se detiene)
- `q0 = target_xz` (desplazamiento pequeño frente a la escala de la ola)
- `delta = J⁻¹ · F`, `q_next = q - delta`

Si no converge tras 8 iteraciones: el sample devuelve `valid = false` con
diagnóstico explícito (`query_residual_m`, `query_iterations`, `jacobian_det`)
— nunca una altura falsa como si fuera correcta.

## Jacobiano / foldover

`detJ = (1+dDx/dx)(1+dDz/dz) - (dDx/dz)(dDz/dx)` se expone en el sample
(`jacobian_det`). Cuando `detJ <= 0` la parametrización tiende a plegarse
(`foldover_risk = true`): es diagnóstico para breaking/whitecaps futuros, no
modifica las olas ni invalida el sample por sí mismo.

## Sea level absoluto (bug de contrato corregido)

`sample.height` = **altura Y absoluta en mundo**; `sample.displacement.y` =
**desplazamiento vertical relativo al nivel medio**.

```text
sea_level = 3.5, H = +0.4  =>  height = 3.9,  displacement.y = 0.4
```

La referencia recibe `set_sea_level(...)`; `OpenOceanFFTModule` lo sincroniza
con `surface.clipmap_config.sea_level_y`. Con ocean OFF: `height = sea_level`,
`normal = UP`, `velocity = 0`, `valid = true`.

## Semántica de displacement

`sample.displacement = Vector3(Dx, H, Dz)` es el desplazamiento PARAMÉTRICO
relativo. La superficie mundial es `Vector3(q.x + Dx, sea_level + H, q.z + Dz)`
y su XZ coincide con el target dentro de la tolerancia (verificado en tests).

## Semántica de surface_velocity

`sample.surface_velocity = dD(q,t)/dt` evaluada en el q resuelto (movimiento
orbital/local del agua, útil para hidrodinámica futura). **NO** es "velocidad
de la intersección a XZ fijo" y **NO** se fuerza la velocidad horizontal a
cero. No se construye todavía una simulación Lagrangiana exacta.

## Prepared time con invalidación

- `set_spectrum(...)` → `_prepared_valid = false`
- `prepare_time(t)` → `_prepared_valid = true`
- `sample_prepared(w)` sin estado válido → devuelve sample **inválido** + warning
  en contexto debug (no devuelve datos antiguos silenciosamente).
- `sample_water(w,t)` prepara internamente el espectro UNA VEZ y ejecuta las
  iteraciones Newton sobre el estado preparado (optimización interna permitida;
  sigue siendo REFERENCE: sin top-K, sin LUT, sin FFT CPU, sin GPU).

## Probes corregidos

`lab/debug/query_probe_snapshot.gd` usa la query WORLD-SPACE: la esfera se
coloca en `Vector3(world.x, sample.height, world.z)` (altura de la superficie
en ese XZ mundial). Los probes se mantienen a ±8 m de la cámara, dentro del
radio donde LONG/MID/SHORT tienen peso visual 1.0 y donde la malla L0 es densa
(evita confundir la query completa con los fades visuales lejanos). Los
samples inválidos se omiten. Snapshot bajo tecla `Y`; no se actualiza a 60 Hz.

## Validación (tests/phase_2a_1_validation.gd)

- **Round-trip forward → inverse** (RACE y ROUGH, 3 puntos cada uno):
  1. `parametric(q)` → D(q), H, normal, velocity;
  2. `world_xz = q + Dxz(q)`;
  3. `sample_water(world_xz, t)`;
  4. verifica residual XZ, height, displacement, normal, velocity y q
     recuperado (q ≈ world_xz − displacement.xz).
- **Inversión analítica de una sola onda** (N=8, modo kx): height/Dx/normal/
  velocity contra forma cerrada + q recuperado. Detecta lambda errónea,
  jacobiano erróneo, inversión incorrecta y normal incorrecta.
- **Sea level** (7.25 m): height == 7.25 + displacement.y; OFF → flat 7.25.
- **Prepared invalidation**: tras `set_spectrum`, `sample_prepared` devuelve
  inválido; tras nuevo `prepare_time`, vuelve a funcionar.
- **Jacobiano**: plano → detJ == 1; onda única → detJ ≈ 1 + kx/16 (analítico).
- **Coste orientativo**: 1 world query RACE y 1 ROUGH (iteraciones, residual,
  tiempo).

Resultados observados:

| Prueba | Iteraciones | Residual | detJ |
|---|---:|---:|---:|
| Onda única (world) | 0–1 | ~1e-5–1e-6 | 0.98–1.02 |
| RACE round-trip | 1–2 | ~1e-6–3e-5 | 0.87–1.14 |
| ROUGH round-trip | 2 | ~1e-6 | 0.72–1.33 |

Coste world query: **RACE ≈ 1.24 s (1 iter)**, **ROUGH ≈ 1.70 s (2 iter)**.
Lento por diseño (Newton sobre full-spectrum); esperable y documentado.

## Nota: referencia continua vs render exacto

OceanQueryReference evalúa la superficie espectral CONTINUA. El renderer usa
texturas 256², sampling bilineal, malla clipmap y fades por distancia; puede
existir un pequeño error visual entre la golden reference y la malla renderizada
(del orden del espaciado espectral). Eso no significa que la query esté mal.
Los probes se usan en la zona cercana (bandas al 100 %, L0 denso) para esa
comparación.

## Por qué es GOLDEN REFERENCE para 2B

- Reutiliza exactamente el mismo H0 que la GPU (misma seed/configs/tiempo).
- Inversión world_xz → q matemáticamente correcta (Newton con jacobiano
  analítico), no un heightfield aproximado.
- Normal y velocity analíticas en el q correcto.
- Fallo explícito (valid=false + diagnóstico) si no converge o hay NaN/Inf.
- determinismo y contrato de height/displacement estables.

Fase 2B construirá un evaluador reduced/production comparado contra esta
referencia como verdad. Gate 2 sigue pendiente.

## Archivos

- `ocean_v3/physics/ocean_query_reference.gd` (paramétrico + world, Newton,
  sea level, prepared valid, diagnóstico)
- `ocean_v3/physics/ocean_query_sample.gd` (jacobian_det, foldover_risk,
  query_residual_m, query_iterations; height absoluta)
- `ocean_v3/open_ocean_fft_module.gd` (sincroniza sea_level con clipmap)
- `lab/debug/query_probe_snapshot.gd` (world-space, omite inválidos)
- `tests/phase_2a_1_validation.gd` (nuevo)
- `tests/phase_2a_validation.gd` (F/G pasa a `sample_parametric`)

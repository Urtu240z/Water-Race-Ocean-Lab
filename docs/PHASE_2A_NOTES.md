# Ocean Lab — Fase 2A: OceanQueryReference (referencia CPU)

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Referencia CPU matemáticamente coherente con el océano FFT GPU. No es para
gameplay (es lenta); es la verdad contra la que se validará la implementación
reducida/rápida de Fase 2B. No implementa física del jetski, buoyancy ni la
versión production de OceanQuery.

## Contrato de query

```text
sample_water(world_position: Vector3, simulation_time: float) -> OceanQuerySample
sample_water_physics_time(world_position)   # usa SimulationClock.simulation_time
prepare_query_time(t) + sample_water_prepared(world_position)  # snapshot multi-probe
```

`OceanQuerySample` (ocean_v3/physics/ocean_query_sample.gd):

- `valid` (false si el backend no produjo resultado finito)
- `height` (m)
- `displacement` = `Vector3(Dx, Height, Dz)` (m)
- `normal` (unidad, normal.y > 0 en superficie normal)
- `surface_velocity` = `Vector3(dDx/dt, dHeight/dt, dDz/dt)` (m/s)
- `turbulence` = 0, `whitewater` = 0 (campos reservados para fases posteriores)

Con el módulo desactivado (`O`): `height = sea_level`, `displacement = 0`,
`normal = UP`, `velocity = 0`, `valid = true`. Sin basura.

## Reutilización exacta de H0

El MISMO `PackedByteArray h0_data` que sube a `GPUStockhamFFT.upload_h0()` se
entrega a `OceanQueryReference.set_spectrum(configs, h0_datas)`. Un único
punto de regeneración (`_rebuild_h0_all` en el módulo) alimenta GPU + CPU al
cambiar seed o CALM/RACE/ROUGH. No hay dos RNG/generadores separados. No hay
readback GPU→CPU por frame: la referencia decodifica los bytes RGBA32F de H0
una vez (al cambiar espectro) y cachea la representación por modo.

## Fórmula temporal (idéntica a GPU)

```text
h(k,t) = h0(k)·e^(+i·ω·t) + conj(h0(-k))·e^(-i·ω·t)
ω = sqrt(g·|k|),  k = (c - N/2)·2π/domain   [índice centrado]
```

Contribución espacial con k físico y world_xz (anclado al mundo, sin UV del
clipmap, sin posición relativa a cámara, sin fades de renderer). La query
física evalúa SIEMPRE las tres bandas: `B` (band debug) y los fades
SHORT/MID/LONG son exclusivamente visuales; los perfiles de calidad tampoco
alteran la query.

## Normalización (derivada del pipeline)

- `tessendorf_spectrum.gd`: H0 se construye con `discrete_scale = Δk·N²` y se
  normaliza por Parseval a `target_hs_m`.
- `stockham_ifft.glsl`: IFFT sin normalizar.
- `assemble_maps.glsl`: multiplica por `1/(N·N)` y corrige el checkerboard.

La referencia suma directamente con `1/N²` sobre índices centrados. El
checkerboard del assemble cancela algebraico al usar `k = (c - N/2)·Δk`;
queda el factor `σ = (-1)^(mx+my)` de la convención de origen (el mundo x=0
cae en el texel N/2), que la referencia incluye para que la misma seed
produzca exactamente la misma superficie. Los probes visuales y el test
`L` (módulo ≡ construcción canónica) lo confirman.

## Lambda negativa

`lambda = -config.choppiness` (misma convención corregida del GPU, ver
`docs/GATE_1_NOTES.md`). Para cada k:

```text
D_horizontal(k,t) = lambda · (-i·h(k,t)) · k/|k|
```

`choppiness` sigue siendo positivo en configuración (0–1.5) y
`OpenOceanFFTConfig.is_valid()` exige `choppiness >= 0`.

## Normal analítica

Sin 4 queries extra: se derivan las derivadas espaciales del espectro
(`d/dx → i·kx`, `d/dz → i·ky`) y se construyen las tangentes equivalentes al
assemble GPU:

```text
tangent_x = (1,0,0) + d(displacement)/dwx
tangent_z = (0,0,1) + d(displacement)/dwz
normal = normalize(cross(tangent_z, tangent_x))   # normal.y > 0
```

## Velocidad analítica

```text
dh/dt = i·ω·h0·e^(iωt) - i·ω·conj(h0(-k))·e^(-iωt)
surface_velocity = (dDx/dt, dHeight/dt, dDz/dt)   # sin diferencias temporales
```

## Coste del backend REFERENCE (medido, GDScript, headless)

- 1 sample: **~0.5–0.8 s**
- 4 samples: **~2–3 s**
- 9 samples preparados (`prepare_time` + `sample_prepared`): **~3.8–5.1 s**

Lento por diseño: 3 cascadas × 256² = ~197k modos complejos por query.
Esperable; NO se optimiza en 2A. Los probes usan el path preparado y se
disparan bajo tecla (Y), no por frame.

## Probes de laboratorio (lab/, no ocean_v3)

`lab/debug/query_probe_snapshot.gd` (tecla `Y`): snapshot de 9 probes en
cuadrícula alrededor de la cámara; la Y de cada probe es la altura CPU
(`sample_water_prepared` con `SimulationClock.get_render_time()`; pausa con
`P` para comparación exacta con la superficie GPU). Otra `Y` limpia. El HUD
muestra `Query probes: ON/OFF | Query backend: REFERENCE`.

## Tests

`tests/phase_2a_validation.gd` (headless, sin readback):

- A. misma entrada ⇒ mismo sample;
- B. seed distinta ⇒ sample distinto;
- C. CALM/RACE/ROUGH producen samples distintos;
- D. samples finitos (sin NaN/Inf);
- E. espectro plano ⇒ height 0, normal UP, velocity 0;
- F. test analítico de una sola onda (height, Dx, Dz, velocity, normal contra
  forma cerrada);
- G. lambda negativa comprime la cresta en el sentido esperado;
- H. band debug visual no altera la query;
- I. perfil de calidad no altera la query reference;
- J. reset con misma seed reproduce el sample;
- K. cambiar sea state actualiza el H0 CPU de la query;
- L. el módulo usa exactamente el mismo H0 que la referencia canónica;
- regression del signo de lambda en `evolve_spectrum.glsl`;
- choppiness negativo rechazado;
- sin readback en los ficheros nuevos.

También pasan `phase_1a/1b/1c/1d_validation` y el runtime smoke (sin
regresiones). Arranque D3D12 normal sin errores de parser/shader ni warnings
propios; smoke de probes: 9 probes colocados sin errores.

## Limitaciones

- Coste de ~0.5–0.8 s por sample: sólo debug/snapshot, nunca physics per-frame.
- La referencia usa los valores de texel exactos (factor σ); el GPU interpola
  bilinealmente entre texels, por lo que en posiciones arbitrarias hay un error
  de interpolación esperado (del orden del espaciado espectral).
- `turbulence`/`whitewater` son 0 (fases posteriores).
- Sin readback one-shot GPU en runtime; la comparación numérica puntual
  GPU↔CPU se deja para herramientas test-only si se necesita (no se añadió
  nada que contamine runtime).

## Siguiente paso esperado

**Fase 2B:** evaluador reduced/production (selección de modos dominantes o
subconjunto espectral, posible LUT trigonométrica o estructura de datos más
rápida) comparado contra esta referencia como verdad matemática. Gate 2:
error visual/físico no perceptible, sin stalls, determinismo y coste estable
con múltiples consultas.

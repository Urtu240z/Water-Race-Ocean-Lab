# Ocean Lab — Fase 3B.2A: World→Deep Coordinate Warp (VALIDACIÓN)

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

## Pregunta que responde esta fase

¿Podemos construir un mapping 2D estable

    world_xz → deep_xz

que permita después samplear el LONG FFT en coordenadas de mar profundo sin
folds, discontinuidades ni una aproximación físicamente incoherente?

3B.1 aporta T, phi, grad(phi), local_direction y sus campos de presentación
`render_phase_rad`/`render_direction` (Eikonal/Fast Sweeping, Snell, shadow).
3B.2A construye las DOS coordenadas del mapping (longitudinal + transversal) y
valida el resultado. El warp final consume la presentación cuando está
disponible; los campos RAW siguen siendo diagnóstico y fallback de
compatibilidad.

## Mapping por defecto: PHASE_TRANSVERSE_IDENTITY

```text
d0 = incoming_direction (unitario)
n0 = perpendicular(d0) = (-d0.y, d0.x)
s_deep = render_phi / k0             (coordenada longitudinal: fase de presentación / k0)
r_deep = dot(world_xz, n0)            (identidad transversal, sin cambio de rama)
deep_xz = deep_origin + d0*s_deep + n0*r_deep
deep_origin = d0 * min_s   (min_s = min dot(world, d0) en el grid)
```

- Con `deep_origin = d0*min_s`, en fondo plano el mapping es **la identidad**
  (deep_xz ≈ world_xz), verificado.
- `s_deep = render_phi/k0` por construcción reproduce la fase que llega al
  renderer: `k0 * dot(deep_xz - deep_origin, d0) == render_phase_rad`
  (sólo redondeo). En una banda sin regularización coincide con `phase_rad`.
- NO se usa `world + direction*phase_offset/k0` como mapping 2D: eso sólo
  fija la fase longitudinal y no preserva la identidad transversal del rayo.

El modo `LEGACY_CHARACTERISTIC_BACKTRACE` conserva el mapping anterior para
A/B y diagnóstico:

```text
r_deep = dot(p_frontera_upstream, n0)
```

La opción de authoring por defecto es `PHASE_TRANSVERSE_IDENTITY`. Los assets
ya horneados no se modifican automáticamente: Paradise Island requiere un
rebake manual para incorporar este mapping.

## Backtrace legacy de characteristics (RK2)

`CoastalWarpBaker._backtrace` integra `p' = -render_direction(p)` desde cada
nodo reached hacia aguas arriba:

- paso inicial = `backtrace_step_cells` (celdas, no metros); RK2/Heun (k2 =
  dir en el punto medio; si el punto medio sale del grid se degrada a Euler
  para intersectar el borde correctamente).
- `render_direction` interpolada **bilinealmente** en cada paso, con fallback a
  `local_direction` para recursos legacy sin el campo de presentación.
- Termina al cruzar la frontera del grid; el cruce se clasifica:
  - `UPSTREAM` (el punto `cross - d0` queda fuera del grid): r_deep válido;
  - `LATERAL`: el characteristic salió por un borde lateral (no se puede
    etiquetar desde la frontera de entrada) → warp inválido;
  - `LAND_OR_SHADOW`: el backtrace tocó tierra/shadow → inválido (NO se
    atraviesa tierra);
  - `STEPS_EXCEEDED`: no convergió en el límite → inválido.
- NO se hacen forward rays: el backward mapping denso es más robusto.

El modo por defecto no ejecuta este backtrace. Así, una discontinuidad o
branch-switch de la etiqueta transversal no puede crear una costura en la
fase longitudinal ya regularizada.

## Validación Phase Authority (fix)

`tests/coastal_warp_phase_authority_validation.gd` mide ambos modos con los
mismos campos sintéticos. Resultados observados en la ejecución local:

| caso / métrica | legacy | PHASE_TRANSVERSE_IDENTITY |
|---|---:|---:|
| flat `max |deep-world|` | — | 0.000009537 m |
| reconstrucción de fase máxima | — | 0.000003815 rad |
| rampa: ángulo medio / P95 / máximo vs `render_direction` | — | 0.002420° / 0.019782° / 0.027976° |
| isla: área válida | 5883/6561 | 6244/6561 |
| isla: salto vecino máximo `deep_x/deep_z/r_deep` | 1.0000/4.9788/4.9788 m | 1.0000/1.0000/1.0000 m |
| isla, línea central detrás: muestras válidas | 0 | 27 |
| isla `detJ` min / P01 / mean / P99 / max | 0.000000 / 0.284965 / 0.805825 / 1.043922 / 4.978844 | 1.000000 / 1.000000 / 1.000000 / 1.000000 / 1.000000 |

Las clases del modo nuevo en la isla fueron SAFE 95.17%, NEAR_CAUSTIC 0%,
FOLDED 0% e INVALID 4.83%; el INVALID corresponde a la máscara de tierra,
no a la energía de shadow. En el canal y con múltiples rocas la validez del
warp coincide exactamente con `valid_mask && reached_mask`, sin NaN/Inf.
La prueba de unidades usa celda de 2 m y paso 0.5: el centro legacy integra
65 pasos, confirmando que el backtrace recibe celdas.

### Hot path: sampler directo (optimización de coste)

El primer prototipo tardaba ~50 s en 129×97 @1m porque `_sample_direction`
usaba `sample_propagation()` (interpola 10 campos: depth, k, λ, c, Cg,
shoaling, phase, gradiente, dirección). El backtrace sólo necesita dirección +
reached/valid. Se reescribió como interpolación bilineal DIRECTA de
`render_direction_x/z` + máscaras `reached_mask/valid_mask` (sin objetos
temporales por paso salvo un Dictionary de retorno). Verificado contra el
sampler antiguo: **0 mismatches de máscara y diferencia angular 0.00000000°**
(bit-idéntico; un falso 0.028° inicial era artefacto de `Vector2.normalized()`
float32 en el propio test, no del sampler).

## Coste (129×97 @1m, gaussian bank, mediana estable)

| Medida | valor |
|---|---:|
| bake Eikonal | ~0.95 s (8 sweeps, residual 2.6e-6 rad/m) |
| bake warp/backtrace | **~7.1–7.4 s** (antes ~50 s → **speedup ≈ 7×**) |
| total | ~8.1 s |
| memoria warp CPU | 287,799 B (~2.3 KB/nodo × 12,513) |
| memoria propagation CPU | 625,650 B |
| backtrace steps totales | 1,589,179 (~129 steps/nodo válido) |
| coste medio por step | ~4.5 µs |

### Perfil del warp (caso C → perfilado obligatorio)

| fase | % tiempo |
|---|---:|
| `_sample_direction` (Dictionary + bilinear) | **77.0 %** |
| integración/backtrace (RK2 + intersección) | 22.3 % |
| jacobiano/finalización | 0.3 % |

El cuello restante es la creación de Dictionary por llamada en GDScript
(~3 llamadas por step). No se aplicó más optimización: con 7.1 s está en el
rango aceptable para un bake offline (deuda de tooling documentada). El warp
**0.5m completo (258×194) NO se ejecutó**: estimación ~55–60 s (>30 s → regla
de parada). La estabilidad de resolución se validó con el Eikonal (sólo
dirección, sin warp): 1m max 59.04° / 0.5m max 61.60° (ver abajo).

## Resultados de validación (tests/phase_3b_2a_warp_validation.gd — PASS)

### A. FLAT (81×81, dirección (0.8,0.6))

| métrica | valor |
|---|---:|
| error posicional warp vs identidad | 0.000167 m (<< cell) |
| detJ | 1.000000 ± 3.1e-5 |
| phase consistency (`k0*dot(deep-origin,d0)` vs Eikonal) | 6.6e-6 rad |
| r_deep lineal (= dot(world, n0)) | 0.000165 m |
| nodos interiores válidos | 5329/5329 |
| mapping continuo entre celdas | ≤ 1.0000 m |

### B. OBLIQUE BEACH (101×61, dirección (0.8,0.6))

- Snell conservado: sin(theta)/c igual en profundo y somero (error 0.000000).
- Warp suave: dirección del grid warpeado ≤ 8.8° respecto a d0.
- Sin tears: salto máximo entre celdas adyacentes 1.006 m (~1 celda).

### C. GAUSSIAN BANK (129×97 @1m, d0=+X)

| métrica | valor |
|---|---:|
| nodos válidos | 12065 / 12513 (96.4 %) |
| detJ min / P5 / mediana / max | 0.2000 / 0.2963 / 0.9998 / 19.29 |
| **SAFE** (detJ > 0.5) | **10486 = 83.8 %** |
| **NEAR_CAUSTIC** (0 < detJ ≤ 0.5) | **1833 = 14.7 %** |
| **FOLDED** (detJ ≤ 0) | **0 = 0.0 %** |
| phase consistency | 3e-6 rad |
| dirección max | 59.04° (refracción real) |

- **0 folds en el banco gaussiano suave** (tras corregir el jacobiano para
  excluir vecinos inválidos: los -47 iniciales eran artefactos de borde donde
  el vecino tiene deep=0).
- Stretching/compression conocidos: detJ max 19 (focusing fuerte) y min 0.2
  (stretching) — NO se ocultan con clamp, se reportan.

### D. ISLAND (101×81)

- Tierra: warp INVALID (0).
- Sombra incidente: warp INVALID (0).
- Agua lateral: warp válido (1).
- **Ningún backtrace atraviesa tierra** (0 bloqueados por tierra de 6513).

### Giro de dirección 1m vs 0.5m (sección 10)

| resolución | max | P95 | posición max |
|---|---:|---:|---|
| 1.0 m | 59.04° | 26.13° | (12, 0) |
| 0.5 m | 61.60° | 26.03° | (11, 0) |

El giro de 59° NO es un artefacto de discretización: al duplicar la resolución
el max cambia sólo +2.6° y el P95 -0.1°. La refracción fuerte es estable.

### Synthetic narrow-band (sección 13)

Patrón deep-space de 5 ondas cercanas (λ≈16 m ± 6 %, dirección ±0.18 rad)
evaluado en `deep_xz(world)`:

- salto espacial máximo entre celdas: 0.337 m, **ratio vs cota de derivada
  local = 0.91** (< 3 → sin tears; el salto es la pendiente natural del patrón
  de λ=16 m, no una discontinuidad).
- continuidad temporal (dt=0.1 s): 0.077 m — el patrón anima sin romperse.
- El warp refracciona suavemente el patrón narrow-band: representativo de lo
  que hará un FFT LONG direccional, sin tocar el FFT.

## Energía angular del espectro LONG actual (sección 17)

| estado | dirección dominante | ±10° | ±20° | ±30° |
|---|---:|---:|---:|---:|
| RACE | 22.6° respecto al viento | **20.1 %** | 31.9 % | 39.9 % |
| ROUGH | 19.8° | **14.2 %** | 28.4 % | 34.6 % |

El LONG actual es **muy ancho angularmente** (sólo 14–20 % de la energía dentro
de ±10° de la dirección dominante). Implicación para 3B.2B: **un único warp
dominante NO representa bien todo el espectro LONG**; si se integra, debe
hacerse con validity mask + fallback a mar profundo en zonas problemáticas, y
a medio plazo evaluar división por sectores direccionales (NO implementada).

## Jacobiano / caustics (diagnóstico explícito)

- `J = d(deep_xz)/d(world_xz)` por diferencias finitas centrales sobre el
  campo deep_xz (one-sided en bordes), excluyendo vecinos inválidos.
- Clasificación por nodo: SAFE (detJ > 0.5), NEAR_CAUSTIC (0 < detJ ≤ 0.5),
  FOLDED (detJ ≤ 0), INVALID (sin warp).
- No se clampea nada: los folds se reportan. En el banco actual: 0 folds.
- Límite documentado: un único inverse warp es single-valued; si characteristics
  se cruzan (múltiples arrivals) el warp no puede representarlas con una sola
  coordenada → detectar/marcar, no arreglar. El banco actual NO genera caustics.

## Archivos

- `ocean_v3/coastal/coastal_warp_data.gd` — Resource: deep_x/z, jacobian_det,
  valid, r_deep, backtrace_steps, boundary_hit, jacobian_class + sample_warp().
- `ocean_v3/coastal/coastal_warp_sample.gd` — resultado de sample_warp().
- `ocean_v3/coastal/coastal_warp_baker.gd` — bake del warp (mapping
  `PHASE_TRANSVERSE_IDENTITY` por defecto, backtrace RK2 legacy, sampler
  directo, jacobiano, clasificación; incluye contadores de perfilado).
- `tests/phase_3b_2a_warp_validation.gd` — validación A–D + resolución +
  narrow-band + LONG energy.
- `tests/coastal_warp_phase_authority_validation.gd` — A/B cuantitativo de
  phase authority, unidades del backtrace y casos flat/rampa/isla/canal/rocas.
- `lab/benchmark/phase_3b_2a_warp_benchmark.gd` — coste Eikonal+warp+memoria
  y perfilado.
- `lab/coastal/phase_3b_2a_sampler_check.gd` — validación sampler directo vs
  antiguo (0 mismatches, 0°).
- `lab/coastal/phase_3b_visual_demo.gd` / `.tscn` — **W = WARP DEBUG**:
  grid de coordenadas profundas warpeado (isolíneas de s_deep cada 16 m y
  r_deep cada 8 m) + heatmap detJ por celda (SAFE verde, NEAR amarillo,
  FOLDED rojo, INVALID gris). Bake único ~7 s sobre subgrid 129×97 al activar.

## Límites y decisiones

- El warp es **offline/dev-time**: 7.1 s por bake en 129×97 @1m es aceptable
  para un recurso precalculado; deuda de tooling: ~77 % del tiempo es la
  creación de Dictionary en el hot path GDScript (C++ lo resolvería, pero NO
  se porta: mandato).
- El warp 0.5m completo NO se ejecutó (estimación >30 s; regla de parada).
  La estabilidad de resolución queda cubierta por el test de dirección 1m/0.5m.
- Esta nota valida el baker offline; la integración del warp en el FFT real se
  realiza en 3B.2B mediante la textura existente y sólo para LONG_COASTAL.
  No se modifica H0, no se añade amplitud por detJ, ni se integran
  breaking/reflection/diffraction/whitewater o shoaling nuevo.

## Decisión / recomendación (3B.2B)

**B — el warp es estable y preciso en zonas sin caustics; integrar con
validity mask + fallback a mar profundo en zonas problemáticas.**

- Flat identidad (1.7e-4 m), fase reproduce el Eikonal (1e-5 rad), sin tears,
  r_deep continuo, 0 folds en el banco, isla/shadow correctos, coste conocido
  (~7 s offline), giro 59° estable con la resolución.
- El LONG actual es demasiado ancho angularmente (14–20 % en ±10°) para un
  único warp dominante fiel al espectro completo: el warp de 3B.2B debe
  aplicarse como transformación direccional con validity mask + fallback deep,
  y considerar sectores direccionales más adelante (NO ahora).
- Gate/puerta a 3B.2B: integrar LONG FFT con sampleo en deep_xz + mask, NO
  como sustituto ciego del espectro.

## Comandos

```
godot --headless --path . --script res://tests/phase_3b_2a_warp_validation.gd
godot --headless --path . --script res://lab/benchmark/phase_3b_2a_warp_benchmark.gd
godot --headless --path . --script res://lab/coastal/phase_3b_2a_sampler_check.gd
# Demo: tecla W (WARP DEBUG), bake ~7 s sobre subgrid 129x97.
```

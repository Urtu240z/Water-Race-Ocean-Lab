# Phase 4B — Local breaker geometry takeover

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

**Estado:** implementada, pendiente de validación visual manual (Windows / D3D12). Sin push.

## Alcance cerrado

Phase 4B añade el primer takeover geométrico del labio de la ola detectada por
el campo PREBREAK de 4A. No crea espuma, spray, tubo completo, whitewater,
impacto/reflexión costera, interacción con jetski ni ocultación del océano base
(todo eso queda explícitamente para Phase 4C+).

Reglas de la fase:

- No se modifica la función base del `OceanClipmapSurface`: sus niveles, la
  cámara y la retessalación son exactamente iguales. No se retessela nada en
  runtime.
- La geometría breaker es local, limitada y reutilizable (pool de slots).
- Sólo LONG_COASTAL (con LONG_REMAINDER, como define el campo 4A) origina el
  labio. MID/SHORT pueden integrar visualmente la superficie base del ribetón,
  pero jamás deciden dónde nace un breaker.
- El campo PREBREAK y la geometría siguen en GPU. El detector de eventos CPU
  usa una consulta coastal LONG especializada y acotada; no hace readback
  GPU→CPU por frame ni consultas de la superficie completa. Los anchors se
  colocan una vez desde los datos horneados (CoastalPropagationData es CPU).
- Coastal OFF, fuera de batimetría o PREBREAK inválido => ningún breaker.
- Pausa/determinismo intactos: el ribetón es una función pura de los datos
  horneados + el reloj (vía texturas FFT); no hay estado temporal acumulado.
- Los debug existentes (B, P, V, J y el resto de la demo 3B.2B) no cambian.

## Arquitectura

```
OpenOceanFFTModule (open_ocean_fft_module.gd)
└─ OceanClipmapSurface (ocean_clipmap_surface.gd)  -> ocean_surface.gdshader
└─ BreakerRibbonPool (breaker_ribbon_pool.gd)      -> breaker_lip.gdshader
                                                    ├─ ocean_breaking_common.gdshaderinc
                                                    └─ ocean_breaker_lip_common.gdshaderinc
```

El detector GPU de 4A (warp world→deep, shoaling, LONG_COASTAL +
LONG_REMAINDER, dirección local, lambda/16, índices continuos) se extrajo a
`ocean_breaking_common.gdshaderinc`, incluido por ambos shaders: el clipmap
sigue evaluando exactamente el mismo campo (comportamiento idéntico, verificado
por `tests/phase_4a_prebreak_validation.gd`) y el ribetón reutiliza el mismo
código sin duplicarlo. Las funciones de integración de superficie y de alpha
del ribbon viven en `ocean_breaker_lip_common.gdshaderinc`, incluido sólo por
`breaker_lip.gdshader`.

`BreakerRibbonPool` (hijo del módulo, creado en `_ready`) gestiona un pool
fijo de slots `MeshInstance3D` que comparten una malla plantilla unitaria
(u×v en [0,1]) y un `ShaderMaterial` único (`breaker_lip.gdshader`). El pool:

1. Coloca anchors deterministas (eventos raros: rebuild coastal / cambio de
   sea state) desde `CoastalPropagationData`: celdas válidas y alcanzadas cuya
   presión de profundidad estimada `H_local/(gamma·h)` cae en la zona de
   pre-break, con separación mínima y tope `max_breakers`.
2. Copia cada frame los uniforms compartidos desde el material del clipmap
   (`get_surface_material()`), de modo que el ribetón usa exactamente las
   mismas texturas FFT/coastal/warp, fades, band_mask y composición.

## Cómo se genera y sigue el breaker

Todo el cálculo vive en el vertex shader del ribetón (`breaker_lip.gdshader`):

- Cada vértice evalúa `prebreak_indices_at(P0, ...)` — el MISMO campo 4A —
  en su posición `P0` dentro del ribetón (longitud ≈ 1.15·λ local, ancho 5 m,
  orientado según la dirección eikonal local).
- La envolvente `breaker_envelope(prebreak)` (smoothstep continuo, sin
  histéresis) es la intensidad de takeover.
- La superficie base se muestrea con `surface_displacement_break` /
  `surface_slope_break` (mismas 4 cascadas, warp, shoaling, fades y
  composición que el clipmap): con envolvente 0 el ribetón queda pegado a la
  ola visible y su alpha cae a 0 (sin stain ni z-fighting).
- La cross-section aprobada se obtiene de la LUT: su posición, altura y
  derivadas controlan el levantamiento, el avance y la normal del labio. No hay
  perfiles paramétricos legacy de lift/advance/curl en runtime.
- Al crecer el campo PREBREAK (la cresta LONG pasa por el slot) el labio sube y
  se adelanta; al decrecer, vuelve a integrarse. Como el campo es continuo en
  espacio y tiempo, el labio "cabalga" la misma cresta sin popping: no hay
  búsqueda de cresta con saltos, ni estado entre frames, ni cambio de ola.

El alpha final = envolvente · `edge_fade(u,v)` (fade suave en los 4 bordes del
ribetón) · fade de distancia. Con `coastal_monochromatic_debug` o módulo
apagado, alpha = 0.

## Parámetros/export nuevos

`OpenOceanFFTModule`:

- `breaker_enabled` (bool, ON): master del pool; `set_breakers_enabled()`.

`BreakerRibbonPool` (el módulo lo crea; ajustables en el pool):

- `max_breakers` (8): tope estricto de slots simultáneos.
- `ribbon_u_segments` (36) / `ribbon_v_segments` (5): resolución del ribetón.
- `ribbon_width_m` (5.0) y `ribbon_length_lambda` (1.15): extensión local.
- `anchor_min_depth_m` (0.35), `anchor_min_depth_pressure` (0.35),
  `anchor_max_depth_pressure` (1.35): ventana física de colocación; los
  candidatos se ordenan por cercanía a la presión objetivo de prebreak, no por
  menor profundidad.
- `anchor_min_spacing_m` (9.0): separación mínima entre slots.
- `breaker_fade_range_m` (6..200): fade de distancia.

`breaker_lip.gdshader`: la geometría de producción usa
`breaker_profile_lut`; los controles activos son `breaker_profile_height_hs`,
`breaker_profile_length_scale` y `breaker_profile_forward_sign`. La convención
de producción es `direction_xz = viaje físico de la cresta` y la LUT tiene
`x_norm` creciente en `u`, por lo que `forward_sign = +1`; el espejo `-1` es
sólo diagnóstico.

El handoff S5 sigue PREBREAK → SPAWN → ACTIVE → TAKEOVER → terminal
near-shore. Run-up/swash quedan fuera de esta fase.

## Controles de debug

En `lab/coastal/phase_3b_2b_fft_demo.tscn` (demo 3B.2B/4A):

- `K`: breakers on/off.
- `N`: ciclo de debug del ribetón:
  - `LIP`: geometría normal (agua + cresta del labio resaltada);
  - `TAKEOVER`: calor por intensidad de takeover (azul→cian→amarillo→rojo);
  - `REGION`: color estable por slot + nariz blanca hacia la costa (dirección);
  - `OFF`: oculta la geometría.
- HUD: `Breakers (K): ON | debug (N): LIP | slots N/8` + lista por slot:
  posición (x,z), dirección, profundidad y λ local (datos CPU deterministas).

## Handoff de producción 4C-S5

El pool conserva `render_direction` como dirección física de viaje (con fallback
a `local_direction`). Los anchors se eligen por cercanía a la presión objetivo
de onset/mid prebreak y no por el candidato más shallow. Un slot ACTIVE integra
RK2 en pasos fijos sobre `CoastalPropagationData.sample_propagation`; no usa
OceanQuery ni readback.

La superficie publica hasta ocho footprints ACTIVE en arrays fijos. Cada máscara
usa center, dirección, longitud, ancho, stage y alpha propios; se aplica después
del envelope shoreline como submerge vertical suave. FORCE_LIP conserva su
máscara debug individual separada del camino de producción.

Los debug de 4A/3B.2B (B, P, V, J, M, F, G, O, D) se conservan intactos.

## Validación

`tests/phase_4b_breaker_validation.gd` (headless, sin render) comprueba:

- contrato de shaders: el inc comparte el detector, el trigger es LONG-only
  (long_height_at no toca MID/SHORT), el ribetón usa el campo PREBREAK, no hay
  OceanQuery ni readbacks en shader/pool, y los uniforms copiados del clipmap
  están declarados en `breaker_lip.gdshader`;
- mirrors CPU de perfiles: lift máximo en la cresta, advance pico delante de la
  cresta (adelantamiento horizontal), edge fade 0 en bordes, envolvente
  monótona continua, presión de profundidad réplica del shader;
- pool: anchors > 0 en banco, ≤ max_breakers, deterministas (misma
  batimetría/modelo → misma disposición), dirección normalizada, separación
  mínima, Hs mínima → 0 slots, disable → 0 slots y oculto.

`tests/phase_4c_s5_production_handoff_validation.gd` añade orientación de LUT,
+X/-X/+Z/-Z, trayectoria determinista, ramps gentle/steep, Hs pequeño/grande,
lifecycle, pausa y arrays multi-breaker 4/8.

`tests/phase_4a_prebreak_validation.gd` sigue pasando tras el refactor del inc.

## Coste

El pool añade ≈ `max_breakers × 37×6` vértices con ~30 fetches/vertex en la
ruta opt-in del labio (sólo cuando Coastal está activo y el pool configurado).
Frente al clipmap (≥10⁶ vértices) es <1% de fetches; sin Coastal no se crea
nada. ACTIVE sólo hace hasta 24 pasos RK2 por slot y el detector mantiene su
presupuesto 20 Hz/2 slots. El coste CPU del detector se valida offline con
`tests/phase_breaker_specialized_query_validation.gd` y con el profiler runtime
de la fase; la geometría GPU permanece fuera de esta optimización.

## Breaker Specialized Query

La fase de optimización posterior mantiene intactos los anchors, score,
scheduler de 20 Hz (máximo 2 slots y 14 puntos por tick), lifecycle y controles
de debug. Sólo cambia la fuente interna de muestras del pool:

```text
DETECT -> Coastal LONG height-only (q XZ directo, Warp lookup)
candidate    -> Coastal LONG slope-only (1 punto por candidato)
physics/etc. -> OceanQuery general (sin cambio)
```

El sampler prepara el mismo H0, seed, transición y selección compacta que
`OceanQueryReduced`, pero sólo prepara LONG. En cada punto evalúa la composición
coastal LONG con el warp y shoaling ya horneados, aplica la amplitud/gradiente de
Sea State Zone y devuelve altura absoluta; no calcula inversión Newton,
desplazamiento horizontal, Jacobiano, velocidad, sharpen, MID ni SHORT. El XZ
del detector se interpreta como `q` directo porque coincide con el dominio
paramétrico que usa el renderer para aplicar CoastalWarp.

Cuando está disponible una DLL Native compatible, el módulo usa el mismo
contrato LONG-only en C++ (incluida una preparación temporal sólo de LONG).
El gate Native del breaker es independiente del gate de la query física
completa: una Sea State Zone sólo añade un postprocess barato de amplitud y
gradiente en GDScript, sin repetir la evaluación espectral. Durante una
transición global se suspenden temporalmente el DETECT y el crest tracking
pendiente; los ribbons existentes siguen procedurales y la query Reduced de
30 ms no entra en el frame.

Antes, cada slot DETECT consumía siete muestras de la batch completa; con el
scheduler actual eran hasta 14 puntos por tick y cada punto podía recorrer las
tres bandas, composición coastal, Newton e inversión de Jacobiano. Después,
los mismos 14 puntos recorren sólo LONG height-only y como máximo dos puntos
adicionales calculan slope para `break_score`. No se crea un H0 ni un presupuesto
nuevo y F2 continúa siendo sólo visibilidad; C OFF/ON conserva el mismo control.

## Limitaciones expresas para Phase 4C

- El labio es una superficie simple levantada/adelantada: no hay curvatura de
  overturn real (el tubo), ni espuma/spray/whitewater, ni impacto/reflexión.
- El ribetón se superpone al clipmap: no se oculta el océano base (ni agujeros).
- La envolvente usa el campo 4A tal cual: sin histéresis temporal ni memoria;
  un crestado intermitente enciende/apaga suavemente el labio.
- Los slots se colocan por profundidad/presión estimada; la dirección por slot
  es la eikonal local en el anchor (fija), no se re-refracta por frame.
- No hay interacción con el jetski ni con la física de OceanQuery.
- MID/SHORT integran la superficie base del ribetón pero no el trigger; si en
  4C se quiere un labio "sólo LONG" estricto, basta conmutar una uniform.

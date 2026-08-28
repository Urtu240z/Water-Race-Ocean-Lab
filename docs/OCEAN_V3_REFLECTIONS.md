# Ocean V3 — Reflection Production Baseline and Performance Audit

## Estado

Reflection Phase 1, Phase 1C, SSPR Phase 2, Reflection Phase 3 y Near SSR
Phase 4A/4A.3 están integradas. La implementación actual no inicia Phase 4C.
Los valores de producción son los defaults de `OceanV3`; una escena de Lab
puede sobrescribirlos deliberadamente para experimentos.

## Arquitectura final

```text
Environment / Godot PBR
        ↓
SSPR planar base
        ↓
Facet gating geométrico (sólo con source SSPR válido)
        ↓
Near SSR correction (prioridad cuando encuentra hit válido)
        ↓
Roughness + distance-aware filtering por texture LOD
```

SSPR genera una textura RGBA16F con mips y una textura R16F de reflection
depth. La depth es la misma salida de `RESOLVE` que usa el temporal; no se
crea una segunda depth. El manager la publica como `Texture2DRD` sólo después
de que el RID actual sea válido. En resize, rebuild y teardown se desacopla la
view anterior y se conserva en la lista de retired RIDs hasta que el material
deja de usarla.

## Production baseline

| Control | Default |
|---|---:|
| `reflection_sspr_enabled` | `true` |
| `reflection_sspr_resolution_scale` | `0.50` |
| `reflection_sspr_temporal_enabled` | `true` |
| `reflection_sspr_facet_gate_enabled` | `true` |
| `reflection_sspr_facet_gate_strength` | `1.0` |
| `reflection_distance_blur_enabled` | `true` |
| `reflection_distance_blur_strength` | `1.0` |
| `reflection_distance_blur_reference_m` | `50.0` |
| `reflection_sspr_kawase_enabled` | `false` |
| `reflection_near_ssr_enabled` | `true` |
| `reflection_near_ssr_quality` | `MEDIUM` |
| `reflection_near_ssr_distance_m` | `35.0` |
| `reflection_near_ssr_ray_length_m` | `200.0` |
| `reflection_near_ssr_thickness` | `0.35` |

Near SSR presets remain: LOW = 8 coarse + 2 refinement, MEDIUM = 12 + 2,
HIGH = 16 + 3. No default was recalibrated during this audit.

## Exports y debug

Los controles visuales nuevos viven en el grupo `Reflection` de `OceanV3`:

- `reflection_sspr_facet_gate_enabled`
- `reflection_sspr_facet_gate_strength`
- `reflection_distance_blur_enabled`
- `reflection_distance_blur_strength`
- `reflection_distance_blur_reference_m`

El modo `SSPR_FACET_CONFIDENCE` es el debug 21. Los modos Near SSR existentes
incluyen `NEAR_SSR_COLOR` y `NEAR_SSR_STEP_USAGE`. El debug no añade varyings.

## Coste por feature

### SSPR

Con SSPR activo, el compositor ejecuta:

1. `PROJECT`: depth de escena → projection hash.
2. `RESOLVE`: color y reflection depth R16F.
3. `TEMPORAL`: estabilización y actualización de histories.
4. Cadena de mips de RGBA16F.
5. `KAWASE_DOWN` / `KAWASE_UP` sólo cuando Kawase está activo.

Con `perf_enable_sspr` o `reflection_sspr_enabled` OFF, el callback del
`CompositorEffect` retorna antes de asegurar pipelines/recursos y no hace
dispatch SSPR. El material conserva PBR/environment como fallback.

El temporal sigue teniendo un dispatch de copia/resolve cuando el efecto SSPR
está activo, aunque el blend temporal esté desactivado; esa decisión mantiene
una salida válida común para el pipeline actual. No se añadió una optimización
de temporal en esta fase.

### Near SSR

Near SSR conserva sus early-outs antes de cualquier lectura de `depth_texture`:
disabled, distancia, roughness, desviación insuficiente, rayo que no entra en
pantalla y gate de confianza potencial. El loop coarse usa distribución t²,
sale en el primer crossing y sólo refina si existe bracket. Los máximos
nominales son 10, 14 y 19 lecturas de depth para LOW, MEDIUM y HIGH.

### Facet gate

Cuando existe una depth publicada válida, añade un sample R16F, reconstrucción
WORLD y operaciones vectoriales. No multiplica el RGB: sólo modifica
`sspr_confidence`. Si depth, alpha o `W` son inválidos, conserva el camino
anterior sin gating agresivo.

Si Facet Gate y Distance Blur están ambos OFF, no se samplea ni reconstruye la
reflection depth en el material.

### Distance-aware LOD

No añade passes. Sólo cambia el `textureLod` local. Kawase continúa siendo un
blur global opcional y no se conecta automáticamente a este LOD.

La función común es:

```text
safe_roughness = clamp(roughness, 0, 1)
base_lod = safe_roughness * mip_max
roughness_weight = pow(safe_roughness, 1.25)
distance_ratio = max(source_distance_m, 0) / max(reference_m, 0.001)
distance_lod = strength * roughness_weight * log2(1 + distance_ratio)
lod = clamp(base_lod + distance_lod, 0, mip_max)
```

SSPR usa la distancia agua → source reconstruido. Near SSR usa `hit_distance`
y obtiene `mip_max` de `textureSize(screen_texture, 0)`. Si Distance Blur está
OFF, sólo se conserva el LOD base por roughness.

## Memoria aproximada

Estimación para viewport interno 1920×1080, sin overhead del driver. El target
SSPR usa `ceil(viewport * resolution_scale)` y los mips RGBA16F usan una suma
aproximada de 4/3 del nivel base.

| Scale | Target | Candidate | Reflection mips | Raw + temporal + histories | Depth + depth histories | Kawase temp | Total aprox. |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.25 | 480×270 | 0.52 MB | 1.38 MB | 4.15 MB | 0.78 MB | 0.26 MB | 7.1 MB |
| 0.50 | 960×540 | 2.07 MB | 5.53 MB | 16.59 MB | 3.11 MB | 1.04 MB | 28.3 MB |
| 0.75 | 1440×810 | 4.67 MB | 12.44 MB | 37.32 MB | 7.00 MB | 2.33 MB | 63.8 MB |
| 1.00 | 1920×1080 | 8.29 MB | 22.12 MB | 66.36 MB | 12.44 MB | 4.15 MB | 113.4 MB |

La columna `Kawase temp` está reservada por la implementación actual aunque
Kawase esté OFF; OFF evita sus dispatches, pero no elimina esa reserva. Las
estimaciones incluyen candidate, RGBA16F reflection/mips, raw, temporal, dos
histories de color, reflection depth R16F, dos histories de depth y temporal
Kawase.

## Audit y profiling

El overlay muestra ahora la configuración capturada:

```text
Reflection SSPR 0.50 | NearSSR MEDIUM | Facet ON | DistBlur ON | Kawase OFF
```

El benchmark existente mide frame delta y monitores CPU sin `RenderingDevice`
sync ni readback. Esos valores no son GPU ms. Para medir GPU de forma fiable
en D3D12, usar una captura externa con RenderDoc, NVIDIA Nsight Graphics o PIX:

1. fijar 1920×1080, misma escena, cámara, seed y recorrido;
2. esperar a que FFT, foam y SSPR estén listos;
3. capturar varios frames después del warm-up;
4. comparar GPU duration de los dispatches `OceanSSPR.*` y del pass de agua;
5. repetir por separado los estados SSPR OFF, Facet OFF/ON, Distance Blur
   OFF/ON, Near SSR LOW/MEDIUM/HIGH y Kawase OFF/ON.

No usar FPS como sustituto de GPU timing y no llamar `rd.sync()` por frame.
No se midieron GPU ms internos en esta fase.

Como referencia, una ejecución gráfica corta del benchmark existente en la
RTX 4070 Laptop (D3D12, 1920×1080, 30 frames de warm-up, 120 medidos, una
repetición) registró `FULL` = 3.3244 ms de frame delta y `NO_SSPR` = 2.9018 ms.
La diferencia de 0.4226 ms es sólo un proxy de frame/CPU con una repetición;
no es un coste GPU de SSPR y no separa Facet Gate, Distance Blur o Near SSR.
Los avisos de invalid RID al cerrar pertenecen al teardown preexistente de
Surface Foam Mid History y no aparecieron durante la captura.

## Fallbacks y limitaciones

- Sin SSPR válido, el environment/PBR sigue siendo el fallback.
- Sin reflection depth válida, Facet Gate y source-distance blur no fuerzan
  agujeros; se conserva la confianza previa y el LOD base.
- El contenido es screen-space: un objeto menor de un píxel puede aparecer o
  desaparecer porque no existe de forma estable en scene color/depth. Eso no
  es un bug del sistema de reflection.
- SSPR puede perder cobertura fuera de pantalla y Near SSR sólo corrige el
  rango definido por sus early-outs.
- No se ha añadido acumulación temporal para Near SSR. Phase 4C sólo tiene
  sentido si aparece shimmering visible durante gameplay real.

# PERF-A — Ocean Surface Shader Audit

Date: 2026-08-31  
Scope: `ocean_surface_option_a.gdshader` only. Baseline, Options B/C, and the production shader remain frozen.

## A. Flow found

`vertex()` evaluates coastal context, LONG_COASTAL/LONG_REMAINDER/MID/SHORT displacement and slope, shore stabilization, then publishes the displaced world coordinate and packed existing varyings. `fragment()` evaluates the high-resolution Crest Foam composition, Surface Foam's temporal field and Direct-J topology, builds the final visual normal, and then feeds shared wave slopes to reflection, SSPR, refraction, water optics, foam compositing, and final PBR output.

The key existing sharing point is `pixel_ocean_slope_components()`: when fragment normals are enabled it supplies the exact filtered LONG/MID/SHORT slope components both to the shading normal and Refraction V2. No new varying was added; the established packed Forward+ budget is untouched.

## B. Duplications found

| Data / calculation | Original locations | Consumers | Cost | Result |
| --- | --- | --- | --- | --- |
| Sea-state zone state at `ocean_base_xz` | `fragment()` and `pixel_ocean_crest_foam()` | Crest Foam, Direct-J/SF zone attenuation, reflection amplitude | Up to 8 SDF zone iterations twice | **Shared in A1**: calculate once in fragment and pass `zone_foam_activity` to Crest Foam. |
| Surface-Foam temporal field | Unconditionally before its presentation consumers | Direct-J macro / Crest Filigree; debug mode 2 | 3 stochastic field reads (or 1 non-stochastic) plus lattice/hash/transform work | **Gated in A3** when no visible consumer and not debug mode 2. |
| Stochastic triangle / transforms | Direct-J topology uses `ocean_base_xz`; temporal field uses `surface_foam_world_xz` | Topology and temporal field | Two potentially similar lattice builds | **Rejected**: the coordinates are intentionally different and cannot be shared without altering the physical/presentation coordinate policy. |
| Pixel FFT slopes | `pixel_ocean_slope_components()` | Fragment normal and Refraction V2 | 11 base to 19 filtered fetches, plus coastal/warp context | Already shared; retained. |
| Coast field/metrics in vertex and fragment | Different stages / interpolation policies | Geometry, pixel normal, diagnostics | Several reads | Not merged: fragment normal requires local fragment sampling while geometry needs vertex data; no varying budget is available. |
| Camera distances | `ocean_base_xz`, `ocean_world_xz`, and `surface_foam_world_xz` forms | Foam, normal/LOD, reflection | Scalar ALU | Not merged: coordinate pairs differ materially. |

## C. Approximate fetch audit (normal production route)

This is a structural count of explicit texture operations, not ISA disassembly. Conditional branches and driver common-subexpression elimination can change the final hardware count.

| Route | Approximate explicit reads | Notes |
| --- | ---: | --- |
| Base ocean vertex | 13 plus 0–2 warp reads; shoreline/crest debug can add more | 3 coastal context, 5 displacement, 5 normal-band reads before optional branches. |
| Ocean normal in fragment | 11 base; up to 19 with MID/SHORT 4-tap filters; plus 2 coastal and 0–2 warp reads | The filtered slopes are reused by Refraction V2. |
| Crest Foam | 6 plus 0–1 warp read | 1 coastal field and 5 foam-band reads. |
| Surface Foam field | 3 stochastic / 1 periodic | This was formerly run even with no presentation consumer. |
| Direct-J topology | 3 stochastic / 1 periodic | One shared topology pass supplies Surface Foam and Crest Filigree thresholds. |
| Surface Foam micro detail | Near: 2; Mid: 1; Far: 0 | `textureGrad`; derivatives reconstruct micro normal without an extra read. |
| MID fold history | 1 when enabled | Only after Surface Foam presentation is active. |
| Surface detail | 2 normal maps plus 1 optional warp | Quality-gated. |
| SSPR / reflection presentation | 1 SSPR color, optional 1 SSPR depth; Near SSR adds its adaptive depth-raymarch budget plus 1 color at hit | Near SSR is separately gated before raymarching. |
| Refraction / water optics | At least screen/depth reads; R2 adds one candidate depth and one refracted screen sample when valid | Debug views can issue diagnostic-only reads. |

The chief hot spots remain the optional filtered pixel normal/roughness paths, stochastic foam paths, and Near SSR. They are intentionally not reduced in PERF-A because that would change filtering, taps, or architecture.

## D. Changes made in OPTION A

### A1 — shared zone context

`fragment()` now evaluates `sea_state_zone_state(ocean_base_xz, ...)` once, derives `zone_foam_activity` once, and passes that scalar to `pixel_ocean_crest_foam()`. The callee previously repeated the same zone loop at exactly the same coordinate. All wave and foam formulas are unchanged.

### A3 — safe Surface Foam field gating

`pixel_ocean_surface_foam_field_unweighted(surface_foam_world_xz)` is called only when Surface Foam or Crest Filigree can consume it, or when explicit Foam debug mode 2 displays it. The existing temporal-field, stochastic, and non-stochastic algorithms are unchanged. This removes up to three field fetches and its associated stochastic setup only in configurations where the result was dead.

## E. Investigated and rejected

- Sharing topology and field stochastic transforms: unsafe because `ocean_base_xz` and `surface_foam_world_xz` are distinct by design.
- Passing wave/foam state through new varyings: rejected due to the known Forward+ 32-location budget and no demonstrated need.
- Merging distance values across base, displaced ocean, and surface-foam coordinates: unsafe coordinate substitution.
- Changing taps, filters, LOD, texture resolution/Hertz, trigonometry, or FFT: out of scope for PERF-A.
- Moving derivatives across control flow: rejected to preserve derivative coherence.

## F. Visual result

The Lab was started successfully with fixed seed `20260820`; OPTION A compiled and the shared simulation reached ready state. A visual fullscreen A/B capture was attempted in frozen and play states, but this local Lab session rendered an all-white target with no visible Foam geometry. It cannot therefore establish the requested foam-silhouette equivalence. No visual equivalence claim is made pending a valid Foam-visible capture.

## G. Benchmark

No GPU timing was exposed by the Lab (its HUD explicitly reports GPU as unavailable). The all-white interactive session also makes an FPS comparison non-representative. Consequently, no BASELINE/OPTION A pairs, mean, median, or range are recorded, and no performance win is claimed. A valid session needs a Foam-visible scene, thermally stable controls, and the requested adjacent `BASELINE → OPTION A` pairs.

## H. Next opportunities (not implemented)

- Conservative: look for other exact same-coordinate scalar context reuse only after validating the active visual configuration.
- Architectural: Wave Feature Map and Foam Presentation Map.
- Presentation: tileable visual foam.
- Simulation-quality tradeoffs: Hz/resolution/tap reductions (outside PERF-A).


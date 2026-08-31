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

Validation run: Godot 4.7.1 graphical Lab, fixed seed `20260820`.

- **Freeze/grid:** at `TIME 13.983 s`, BASELINE and OPTION A showed the same wave geometry, crest locations, choppiness, whitecap distribution and foam streaks. No localized difference in Surface Foam, Crest Foam, filigree, normal, roughness, reflection or refraction was observed. Classification: **perceptually identical in the simultaneous grid comparison**.
- **Freeze/fullscreen:** the first BASELINE/OPTION A toggles exhibited a whole-frame exposure mismatch, not a foam-localized difference. The Lab creates deep `Environment` and `CameraAttributes` duplicates for each `World3D`; fullscreen disables updates for inactive SubViewports. Any temporal auto-exposure state can therefore diverge between worlds. This is not evidence of an OPTION A shader regression and prevents a pixel-identical fullscreen claim from these captures.
- **Play:** the simultaneous four-panel grid remained coherent while running. A1 is scalar reuse and A3 reads an already-published texture, so neither has temporal side effects. No foam-cell transition, shimmer or history regression was attributable to OPTION A in the observed run.

The optional image-difference capture was not performed: fullscreen captures with divergent exposure state would produce a misleading RGB metric. No temporary images were retained.

## G. A1 validation

In BASELINE, `pixel_ocean_crest_foam(world_xz)` evaluates `sea_state_zone_state(world_xz, ...)` and derives `zone_foam_activity`. In OPTION A, `fragment()` performs the same state evaluation at `ocean_base_xz` and passes that scalar into `pixel_ocean_crest_foam(ocean_base_xz, zone_foam_activity)`. The coordinates, uniforms and arithmetic of `sea_state_zone_foam_activity()` are identical; only evaluation order changed. **Decision: KEEP.**

## H. A3 validation

`pixel_ocean_surface_foam_field_unweighted()` is a pure texture-read helper: it selects the stochastic three-read field path or periodic one-read path from `surface_foam_short`. It does not update history, dispatch compute, publish resources, mutate state, or drive solver scheduling.

Its complete in-shader consumers are:

1. `surface_foam_macro_from_topology(surface_foam_raw_topology, field.x)`.
2. `surface_foam_macro_from_topology(crest_filigree_raw_topology, field.x)`.
3. `foam_debug_mode == 2`.

Consumers 1 and 2 are active exactly under `foam_enabled && perf_surface_foam_solver_enabled && perf_surface_foam_render_enabled && (surface_foam_enabled || crest_filigree_enabled)`. A3 includes that condition and separately retains debug mode 2. MID-fold history is sampled later and independently; it is not controlled by this helper. **Decision: KEEP** as dead-presentation-work elimination, with no claimed gain for the normal FULL configuration where the field remains required.

## I. Benchmark

The existing graphical performance runner was audited before measurement. `ocean_performance_benchmark.gd` samples `_process` delta and CPU monitors, and records `gpu_ms` as unavailable. Its README explicitly says not to infer GPU cost from FPS/frame delta. It cannot compare BASELINE versus OPTION A, which are Lab shader variants rather than runner profiles.

Therefore no `BASELINE -> OPTION A` timing pairs, mean, median, range, standard deviation, percentage, A1-only, or A3-only result is recorded. This is **inconclusive for GPU performance**, not a claim of no benefit. No new benchmark/profiler was introduced and no further shader optimization was made.

## J. Known teardown warning

`surface_foam_mid_history_solver.gd:95` may report two `Attempted to free invalid ID` messages only during scene shutdown. This is a known pre-existing teardown warning, is outside PERF-A, and was not changed.

## K. Next opportunities (not implemented)

- Conservative: look for other exact same-coordinate scalar context reuse only after validating the active visual configuration.
- Architectural: Wave Feature Map and Foam Presentation Map.
- Presentation: tileable visual foam.
- Simulation-quality tradeoffs: Hz/resolution/tap reductions (outside PERF-A).

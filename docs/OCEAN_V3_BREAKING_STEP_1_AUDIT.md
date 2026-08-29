# Ocean V3 — Breaking rework, Step 1 audit

Date: 2026-08-30
Scope: current implementation only. No onset, strength, spectrum, geometry, or
visual behaviour changes are made by this step.

## Frozen contract

The current breaker system remains a **coastal LONG-only system**. `MID` and
`SHORT` continue to contribute only to the rendered base surface; neither is a
breaker birth signal. A running breaker uses the state captured at spawn and is
not a physics collider.

The dedicated breaker query is intentionally bounded and CPU-side over the
baked coastal data. It is not a GPU readback and it is not on the general
OceanQuery hot path.

## Current pipeline

```text
SeaStateConfig
  |
  +-- LONG spectrum split --------------------------+
  |       |                                         |
  |       +-- LONG_COASTAL -> coastal warp/shoaling |
  |       +-- LONG_REMAINDER -> open component      |
  |                                                 |
  +-- MID / SHORT -> base ocean surface only        |
                                                    v
CoastalPropagationData (depth, valid/reached, k, lambda, C, shoaling, dir)
  -> BreakerRibbonPool._place_anchors_for_energy()
  -> _evaluate_breaking_corridor() / depth pressure
  -> coastal anchors (max 8)
  -> 20 Hz bounded specialised LONG height/slope batch
  -> crest candidate -> _break_score_details() -> _run_detector()
  -> deterministic spawn decision -> _spawn_breaker()
  -> captured strength/Hs + lifecycle -> BreakerRibbonPool uniforms
  -> breaker_lip.gdshader LUT profile and surface takeover
```

The GPU-side `PREBREAK` field is a parallel, opt-in visual/debug computation.
It has the same coastal LONG model but is not the runtime spawn query. It feeds
the old diagnostic/force-lip paths; production LIP/TAKEOVER uses the values
captured by the CPU detector at spawn.

## PREBREAK inputs and coordinate spaces

`ocean_breaking_common.gdshaderinc:prebreak_indices_at()` returns
`(depth_pressure, steepness_pressure, crestness, prebreak)` in `[0, 1]`.

| Input | Source / space | Normalisation and coastal dependency | Bands |
| --- | --- | --- | --- |
| Local Hs and amplitude | `breaking_long_hs_m`, coastal split fraction and shoaling; world XZ | `Hs_local = Hs_LONG * sqrt((1-f)+f*shoaling^2)`, then `a=0.5*Hs_local`; exists as a number offshore but cannot yield PREBREAK without valid coastal data | LONG only |
| Local k / wavelength | baked `coastal_field` at coastal UV; world XZ -> coastal UV | `k` is rad/m; `lambda=TAU/k` | LONG only |
| Depth pressure | baked depth in `coastal_metrics`; metres | `smoothstep(0.55, 1.0, Hs_local/(0.78*depth_m))` | LONG energy + depth |
| Steepness pressure | local `k*a` and zone choppiness | `smoothstep(0.28, 0.42, k*a*choppiness)` | LONG only |
| Crestness | `long_height_at()` at world-XZ neighbour samples along propagation | multiscale max over lambda/16, /8, /4; each rise/curvature test is normalised by local amplitude | `LONG_COASTAL` + `LONG_REMAINDER` |
| Zone activity | sea-state-zone SDF in world XZ | `[0,1]`: LONG-amplitude and choppiness multiplier | LONG controls only |

The final expression is `crestness * depth_pressure * mix(0.35, 1.0,
steepness_pressure) * zone_activity`.

### Explicit coastal gates

There are multiple intentional gates; the shoreline concentration is therefore
both explicit policy and a consequence of the data source:

1. `OpenOceanFFTModule._configure_breaker_pool()` disables the entire pool
   unless spectral, Coastal, runtime, and valid `CoastalPropagationData` are
   all enabled.
2. `prebreak_indices_at()` immediately returns zero when `has_coastal_data()`
   is false. Thus debug PREBREAK is zero outside valid bathymetry/propagation.
3. `_place_anchors_for_energy()` iterates only propagation cells whose
   `valid_mask` and `reached_mask` are set, then requires a bounded
   depth-pressure interval.
4. `_evaluate_breaking_corridor()` requires a valid shallow pressure ramp and
   usable shallow development distance. `_run_detector()` refuses candidates
   with `NO_SURF_CORRIDOR`.
5. Both Native and reduced CPU specialised samplers require a coastal runtime;
   their only accumulated spectrum is cascade 0 (`LONG_COASTAL`).

`LONG_REMAINDER` is present in the **GPU visual PREBREAK crest samples**, but
not in the CPU detector query used for production spawns. `MID` and `SHORT` do
not enter either trigger. This explains why current visible breakers are
overwhelmingly close to islands: anchors cannot even be created outside the
coastal propagation/bathymetry support.

## Runtime detector and sizing

The detector samples seven offsets from `-0.45` to `+0.45 lambda`, at 20 Hz,
two slots per tick. It records the best candidate inside `[-0.28,-0.06] lambda`
and spawns at most once per wrapped wave, subject to the coastal corridor,
cooldown, and deterministic marginal roll. The physical strength thresholds are
0.30 (marginal) and 0.55 (guaranteed).

The score is depth pressure (45%), crest prominence (35%), and LONG slope along
travel (20%), then anchor/zone eligibility. Spawn captures:

- position, direction, wavelength and phase speed;
- `spawn_strength = lerp(0.70, 1.0, score)`;
- local LONG `Hs` derived from global LONG Hs, coastal energy fraction, and
  shoaling;
- duration/cooldown from wavelength divided by phase speed, clamped to 1–3 s
  and 2–3 s respectively.

The ribbon is a fixed unit mesh (96x5 by default) mapped in the shader to
`1.1 * wavelength` longitudinally. Its **transverse width is a fixed export of
6 m**, while the takeover length is `1.55 * wavelength * profile scale`; LUT
height is `2.35 * spawn_Hs`. Consequently width has no parent-wave scaling and
the height uses Hs rather than the instantaneous parent amplitude. Those two
choices are the direct reason a small parent wave can receive a visually
disproportionate ribbon. This is documented only; it is intentionally unchanged
in Step 1.

## Parent-wave information available today

| Information | Availability at a candidate | Notes |
| --- | --- | --- |
| Coastal LONG height and directional slope | Already available, bounded batch | Native/reduced dedicated query; current production source |
| LONG_COASTAL + LONG_REMAINDER height | Available in GPU PREBREAK helper | Not exposed to production CPU detector |
| MID height/slope/phase | Available in render FFT | Not exposed to breaker candidate path |
| SHORT height/slope/phase | Available in render FFT | Deliberately excluded from main breaker triggering |
| Hs, local k/lambda, direction, phase speed, depth, shoaling | Already available on coastal anchors | Baked `CoastalPropagationData` |
| Crest candidate / prominence / longitudinal steepness | Already available | Seven-sample detector stencil, LONG-only |
| Crest tangent / coherent segment extent | Not available | Would need crest segmentation, deferred to Step 2+ |
| Surface velocity | Not in specialised breaker contract | General query can provide other fields, but adding it here would expand cost/contract |
| Open-water LONG/MID candidate data | Not available to production breaker code | Requires a new bounded, camera-local candidate source; do not use GPU readback |

## Existing debug support

No new pass is required for Step 1. `OceanClipmapSurface.BreakingDebug` already
provides opt-in `DEPTH`, `STEEPNESS`, `CRESTNESS`, and `PREBREAK` heatmaps; the
shader performs the extra fetches only while that mode is active. Coastal debug
fields separately expose bathymetric validity/depth/shore weights. The breaker
pool diagnostics expose per-slot pressure, prominence, steepness, corridor
reason, and detector gate reason. Together they distinguish “crest signal but
no coastal validity” (PREBREAK zero plus invalid coastal field) from “valid
coastal data but weak signal” (low indices/score).

## Step 2 recommendation (not implemented)

Keep the current coastal path intact as `DEPTH_BREAK` and introduce a separate,
bounded camera-local `OPEN_BREAK` candidate producer. It should publish a common
candidate record (position, parent LONG/MID contribution, wavelength, direction,
crest metric, and optional local depth data) to a neutral `BREAK_ONSET` combiner.
`DEPTH_BREAK` supplies the existing pressure/corridor signal; `OPEN_BREAK`
supplies no bathymetry requirement. Preserve the current deterministic scheduler
and pool, but postpone `BREAK_STRENGTH`, crest segmentation, lateral propagation,
and all size laws until the common candidate contract is in place.

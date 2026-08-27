# Ocean V3 — Current Architecture

This is the current system reference for the code at HEAD. It describes the
runtime composition, not the chronological development phases.

## Global data flow

```text
OceanWavePreset
        |
        v
OceanV3 editable exports (global + LONG/MID/SHORT)
        |
        v
Three physical OpenOceanFFTConfig objects
        |
        v
Canonical H0 for LONG, MID and SHORT
        |                         \
        |                          +--> OceanQuery Reduced / optional Native
        v
LONG directional split for rendering
  +--> LONG_COASTAL
  +--> LONG_REMAINDER
        |
        v
Optional Bathymetry -> Coastal propagation/Eikonal -> world-to-deep warp
        |
        v
Four render cascades -> OceanClipmapSurface -> ocean_surface.gdshader
        |
        +--> Sea State Zone field composition
        +--> Crest Foam / Surface Foam / Crest Filigree presentation
        +--> Optional PREBREAK and BreakerRibbonPool representation
```

The physical query still owns three source bands. The renderer owns four
cascades because LONG is split into two complementary render datasets. The
split is made from the same LONG H0 and the two render parts reconstruct LONG;
it does not create a fourth physical band.

`OceanSeaStateZone3D` descriptors are composed into both the shader and the
Reduced evaluator. Coastal data is an optional baked side path: it affects
`LONG_COASTAL` in rendering and configures the matching Reduced coastal
evaluation when a valid warp exists. MID and SHORT remain open-ocean.

## Open-ocean rendering

`ocean_v3/ocean_v3.tscn` contains the required stable hierarchy:

```text
OceanV3 (Node3D, OceanV3)
└── OpenOceanFFT (OpenOceanFFTModule)
    └── OceanClipmapSurface (OceanClipmapSurface)
```

Do not rename those internal nodes: `OceanV3` and the module address them by
path. `OceanClipmapSurface` follows the active `Camera3D` and places its
origin at `clipmap_config.sea_level_y`. The default clipmap resource is 128
cells per side, 0.25 m near spacing, 10 levels, and a 7000 m horizon. Its
default fade ranges are SHORT 24–80 m, MID 96–320 m, and LONG 768–2500 m.
These are renderer settings, not changes to the physical spectrum.

`GPUStockhamFFT` evolves each physical source config and publishes persistent
displacement, normal, and foam textures through `Texture2DRD`. The renderer
samples the four render datasets in this order: LONG_COASTAL,
LONG_REMAINDER, MID, SHORT. The visible SHORT geometry has its own reduced
`short_geometry_strength`; this visual choice does not remove SHORT from
OceanQuery.

## Physical bands versus render cascades

| Physical band | Default wavelength range | Render role |
|---|---:|---|
| LONG | 16–128 m | Split into LONG_COASTAL and LONG_REMAINDER |
| MID | 4–20 m | One MID render cascade |
| SHORT | 0.5–5 m | One SHORT render cascade, with reduced visible geometry contribution |

The defaults above come from the current base presets' technical invariants.
Each physical band uses a 256² FFT, with domains LONG 512 m, MID 137 m, and
SHORT 37 m. `OpenOceanFFTConfig` also carries gravity, wind, fetch, swell,
directional spread, JONSWAP spread, detail, choppiness, target Hs and the
band-pass transition/damping values.

## Global wave state

`OceanWavePreset` is a resource containing global wind speed, three
`OceanWaveBandSettings`, and `short_geometry_strength`. The shipped current
presets are:

| Preset | Wind | LONG Hs / chop | MID Hs / chop | SHORT Hs / chop | Short geometry |
|---|---:|---:|---:|---:|---:|
| CALM | 6 m/s | 0.20 / 0.55 | 0.09 / 0.45 | 0.03 / 0.25 | 0.25 (default) |
| RACE | 12 m/s (root default) | 0.59 / 1.00 | 0.25 / 0.70 | 0.05 / 0.35 | 0.25 (default) |
| ROUGH | 18 m/s | 2.50 / 2.00 | 0.60 / 1.25 | 0.12 / 0.40 | 0.25 (default) |

`marejadilla.tres` also exists as a reusable resource with its own values; it
is not one of the three `SeaStateConfig` states. The complete preset values
remain in the `.tres` resources and are the authority for future edits.

Applying a preset copies its values into the editable `OceanV3` exports and
rebuilds the three canonical H0 datasets. Later export edits are authoritative
and are coalesced for 150 ms when `auto_apply_wave_changes` is enabled.
H0 is persistent for the active seed; it is not regenerated every frame.

`transition_to_wave_preset(target, duration_seconds)` prepares target H0 and
Reduced-query data, then transitions GPU and query state together. It
interpolates the exported spectrum parameters, including choppiness and
short-geometry strength. A transition keeps the existing histories and
supports retargeting while a previous transition is active. A duration of
zero (or incompatible FFT topology) applies the target immediately. Changing
the global preset does not reset foam history.

## Time, seed, and quality

`SimulationClock` is an autoload. It advances in physics ticks, applies
`time_scale`, exposes deterministic `simulation_time` and `simulation_seed`,
and supplies an interpolated render time while not paused. `R`-style reset
preserves the seed by default; starting with a new seed rebuilds H0 once.

`OceanQualitySettings` exposes DECK, STANDARD, and DEV_HIGH and emits
`profile_changed`. In the current source it is infrastructure only: no
OceanV3 runtime consumer changes the FFT, clipmap, query, or foam settings
when the profile changes. Do not document the three profiles as active
quality tiers yet.

## Surface Detail

Surface Detail is an optical, fragment-only layer. It samples the assigned
normal/warp textures in the water shader and can follow the macro wave field
through `surface_detail_wave_follow`. It does not alter clipmap vertices,
physical displacement, H0, or OceanQuery. It is separate from the physical
SHORT FFT band: microdetail is not a fifth band and is not a replacement for
SHORT.

## OceanQuery

The stable public entry point is `OceanV3`:

- `sample_water(world_position, simulation_time)` — one sample at explicit time.
- `sample_water_physics_time(world_position)` — one sample at the current
  deterministic physics time.
- `sample_water_batch_physics_time(positions)` — batch at physics time.
- `sample_water_batch_at_time(positions, simulation_time)` — batch at explicit
  time, used by deterministic visual tracking.
- `prepare_query_time(simulation_time)` and `sample_water_prepared(position)`
  — explicit prepare/sample route.

The returned `OceanQuerySample` contains `valid`, absolute `height`, relative
parametric `displacement` (`Dx`, `H`, `Dz`), unit `normal`,
`surface_velocity`, `jacobian_det`, `foldover_risk`, `query_residual_m`, and
`query_iterations`. `turbulence` and `whitewater` exist on the sample type but
are not populated by the current production evaluator and therefore remain at
their default value.

The surface is a parametric function `P(q,t)`. World XZ is inverted to `q`
with Newton iteration, then height, derivatives, normal, velocity, and
Jacobian are evaluated at the solved `q`. Therefore any future physical
geometry change must be represented in both renderer and query.

The backend policy is exact and intentional:

1. Native is used when the Windows GDExtension is registered, there is no
   active global transition, there are no active local zones, and the native
   object can represent the current Coastal path.
2. Reduced GDScript is used for the full physical query during global
   transitions and whenever local zones are active. It is also the fallback
   when Native is unavailable.
3. Golden Reference is opt-in debug/test only (`enable_reference_query_debug`).

Breaker detection has its own Native capability gate and must not inherit
fallback restrictions from the full physical OceanQuery. Its LONG-only
height/slope batch remains Native when zones are active; zones apply a cheap
GDScript amplitude/gradient postprocess and must not force spectral breaker
evaluation back to GDScript. During a global transition, breaker sampling is
temporarily suspended while the prepared endpoint is pending, so the old
ribbons remain procedural and the Reduced 30 ms path is not scheduled on a
frame.

The `band_debug` view, clipmap fades, and quality profile do not change the
three-band physical query. When OceanV3 is disabled, query methods return a
valid flat sample at the configured sea level.

## Coastal and Bathymetry

`BathymetryBaker` is an offline/dev-time `@tool` node. It rasterizes source
mesh faces into `BathymetryData` (depth, land/water mask, shore distance,
gradients, and world mapping). Runtime Coastal code consumes the baked
resource; it does not raycast the source mesh per frame.

`OpenOceanFFTModule.rebuild_coastal_propagation()` is explicit and not called
per query or per frame. With valid bathymetry it selects `CoastalEikonalBaker`
by default, or the straight propagation baker when `coastal_eikonal_enabled`
is false. `CoastalWarpBaker` then builds the world-to-deep mapping when
`coastal_warp_enabled` is true. Invalid or out-of-range cells fall back to
open-ocean behavior.

The current implementation is an optional V1 path for a representative LONG
component: finite-depth dispersion, phase/group velocity, shoaling,
Eikonal/refraction, shadow/reachability fields, and a localized render-phase
diagnostic correction are present. Only LONG_COASTAL is warped; LONG_REMAINDER,
MID, and SHORT remain open-ocean. This is not a multiband shallow-water
solver, runup, shoreline simulation, or a claim of full coastal energy
conservation. Treat Coastal as a feature to validate for the level's baked
data, not as a universal requirement.

The same valid warp is passed to Reduced Query, where it modifies the
parametric evaluation. Native full-query use requires its Coastal runtime
method, while Native breaker use additionally requires
`prepare_breaker_time` and `sample_coastal_breaker_batch_prepared`.

## Near-shore base FFT stabilization

The base FFT is not a swash or run-up solver. When Coastal is enabled, the
rendering clipmap applies a final, world-space geometry envelope from the
baked `depth_m` stored in `coastal_metrics_texture.r`. Horizontal
displacement/choppiness fades first, followed by vertical displacement, so
the FFT remains a stable base as the shoreline is approached. Both `ocean_surface`
and its wireframe diagnostic use the same metres-based weights; they do not
depend on camera position, clipmap level, vertex index, screen UV, or frame.

The defaults are `shore_vertical_depth_range_m = (0.25, 6.0)` and
`shore_horizontal_depth_range_m = (0.75, 12.0)`. The lower bound follows the
current minimum valid Coastal depth and the upper bounds are conservative
world-space transition widths relative to the current baked grid and the
existing shallow-water authoring range. `shore_stabilization_enabled` is the
single runtime opt-out. The normal path applies the product rule
`grad(W * height) = W * grad(height) + height * grad(W)`.

Propagation validity (`field_texture.a` / `phase_texture.a`) remains separate
from water presence and shoreline depth. Propagation-invalid water therefore
still receives the depth envelope when positive depth is present; dry cells
fade to a continuous sea-level displacement without vertex/fragment discard,
holes, or shoreline mesh generation. Breaker detection continues to consume
the pre-stabilized physical wave, and beach/run-up/foam presentation remain
later layers.

## Foam

### Crest Foam

Crest Foam is the per-FFT-cascade persistent RG16F field maintained by the
`GPUStockhamFFT` scheduler. It has fresh and residual/history behavior,
transport/advection controls, and a configurable 30/45/60 Hz update rate.
Preset transitions update the source/targets while the scheduler and history
continue; do not reset histories merely because the preset or a zone changed.

### Surface Foam

Surface Foam owns a separate technical spectrum and persistent fields. Its
technical FFT/source/field/topology resolutions and domains do not enter the
three physical wave configs or OceanQuery. The current near topology uses
direct Jacobian-derived sampling; the larger field supplies temporal envelope
and coarse fallback at distance. See the linked Surface Foam notes in the
index for the exact current sampling decisions.

### Crest Filigree

Crest Filigree is a presentation mask derived from crest foam and the current
Surface Foam macro topology. It does not own the crest accumulator and does
not add another physical simulation. Keep it conceptually separate from both
Crest Foam history and Surface Foam history.

## Breaking

`PREBREAK` is a shader diagnostic/field derived from coastal validity, LONG
energy, depth, steepness, and crest-related signals. It does not itself create
geometry. `BreakerRibbonPool` is the optional local geometry representation:
it detects/anchors candidate breakers, tracks active crests with a specialized
Coastal LONG height/slope query, and renders a bounded set of ribbon/lip
instances. The general full `OceanQuery` batch remains available to physics,
probes, and other consumers; breaker DETECT/ACTIVE does not use that hot path.

The pool is configured only when breakers are enabled, Coastal runtime is on,
and valid propagation data exists. Coastal disabled, missing/invalid
bathymetry, or disabled runtime means no active breaker ribbons. Global wave
transitions update the pool's energy model and preserve matching anchors where
possible; a Sea State Zone affects eligibility through the registered zone
descriptors. This is a local breaker representation, not a complete
shoreline/whitewater/spray system.

For runtime diagnosis, `BreakerRibbonPool` stores the detector values already
used by the decision (`candidate_s`, previous position, advancing/window gates,
pressure/prominence/steepness contributions, raw/final score, eligibility,
probability, deterministic roll, cooldown, and wave serial) in its tracking
snapshot. The Lab's `J` detector mode renders the anchor, physical sample
line, spawn window, and current candidate without issuing extra queries;
`Shift+J` selects a slot and `Ctrl+J` force-spawns that slot only after a real
candidate exists, bypassing score/probability/roll for lifecycle isolation.

Anchor placement also evaluates a cached 16-sample CPU breaking corridor along
the signed baked render direction. It records onset/terminal positions, depth
and pressure endpoints, available versus required development distance, and
spawn depth/pressure plus shore vertical/horizontal weights. The spawn is
back-solved from the plunge stage; a steep wall or insufficient shallow run is
classified `NO_SURF_CORRIDOR` and does not create a beach breaker. A detector
stencil may use only a contiguous valid run containing candidate neighbours;
invalid samples are never extrapolated across land. During the spawn window the
detector keeps the best candidate for the wave: high scores are guaranteed,
marginal scores use one deterministic seeded roll after the window, and low
scores do not spawn. Normal HUD output stays compact; `Ctrl+Shift+J` enables
extra breaker diagnostics, while `DETECTOR` shows the selected slot (or a short
table for `ALL`).

## Sea State Zones

See the single canonical manual: [SEA_STATE_ZONES.md](../ocean_v3/SEA_STATE_ZONES.md).
The important runtime facts are:

- `OceanSeaStateZone3D` is a `Node3D`, not an `Area3D`.
- It is an oriented XZ field with core, feather, priority, strength, and
  absolute target values for LONG/MID/SHORT amplitude, choppiness, and foam
  generation.
- At most eight enabled zones are composed, ordered by priority and node path.
- `Node3D.scale` is non-authoritative; `box_size_m` is the physical extent.
- The root discovers zones through the `ocean_sea_state_zone` group, so they
  do not need to be children of OceanV3.
- Zone targets are absolute relative to the global state. Composition is a
  sequential smooth interpolation by priority, not an arbitrary cumulative
  multiplier product.

## Current implementation status and roadmap

Implemented systems are listed in [docs/README.md](README.md). The bounded
work that remains visible from the current source is:

- integrate `OceanQualitySettings` into real quality decisions after measuring
  the desired target hardware;
- build and validate the Native extension for non-Windows targets (the Linux
  descriptor convention exists, but is not validated here);
- extend Coastal beyond the current representative LONG V1 only when a
  concrete gameplay/render requirement and measurements justify it;
- add gameplay buoyancy/vehicle systems in the consuming project, not inside
  Ocean V3's query contract.

These are scope boundaries, not claims that every historical phase item is
still pending. Phase reports remain historical records.

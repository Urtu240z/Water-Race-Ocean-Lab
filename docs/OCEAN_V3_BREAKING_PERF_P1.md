# Ocean V3 — Breaking PERF P1

## Scope

P1 measures the **legacy** `BreakerRibbonPool` active-tracking path only. It
does not change RK2, sampling frequency, allocation strategy, active-count
policy, rendering, or Steps 2–4 breaking semantics. Step 5 is not started.

The test was run outside the Godot editor profiler on 2026-08-30 with Godot
4.7.1, D3D12 Forward+, RTX 4070 Laptop, 1920x1080, native `OceanQuery`, the
rough coastal benchmark scene, fixed seed `20260830`, debug off, 120 warm-up
frames and 600 measured frames per case. Steam Deck was not measured.

## Controlled fixture

`res://ocean_v3/tests/performance/breaker_ribbon_p1_scaling_benchmark.tscn`
uses the actual pool's `_tracking` records, `_update_tracking`, RK2 predictor,
velocity sampling and `CoastalPropagationData.sample_propagation` calls. It
uses `_spawn_breaker` once to initialize real records, then, before every pool
`_process`, only pins each selected record's `spawn_time` to an age of `0.700`
seconds. This holds `S = ceil(age / 0.125) = 6` for the whole window.

Inactive slots are held in ordinary cooldown. They continue through the same
active/cooldown scans, but cannot enter DETECT and introduce an unrelated
crest-query batch. The fixture is benchmark-only and is never enabled by
production gameplay.

For every active breaker in this fixture:

```text
S = 6
velocity calls = 2S = 12
Coastal calls = 2S + 1 = 13
```

## Results

Nested wall timers use `Time.get_ticks_usec()` only during the measured
window. A measured timer-pair cost of `0.15883 us` was subtracted from the
reported timer estimates. `tracking` contains `predicted`, `velocity` and
Coastal work; nested timings must not be added together.

The rendered frame column is included as requested, but is not used to infer a
marginal shipping cost: the benchmark's age-pinning fixture performs a small
O(active-count) set of dictionary writes before the pool runs. The direct pool
timers are the attribution source. They still include opt-in counter and cell
reuse bookkeeping; subtracting timer-pair cost removes the measured clock-pair
component, not every diagnostic branch. Thus P1 establishes scaling and a
measured order of magnitude without claiming profiler-free retail-frame
precision.

| Active | Mean age | ΣS | Velocity/frame | Coastal/frame | Tracking avg / median / P95 / P99 (ms) | Frame avg / P99 (ms) |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | — | 0 | 0 | 0 | 0.312 / 0.297 / 0.414 / 0.476 | 6.631 / 12.392 |
| 1 | 0.700 | 6 | 12 | 13 | 0.739 / 0.699 / 1.063 / 1.211 | 6.661 / 12.470 |
| 2 | 0.700 | 12 | 24 | 26 | 1.049 / 1.029 / 1.463 / 1.675 | 6.745 / 12.393 |
| 4 | 0.700 | 24 | 48 | 52 | 1.857 / 1.635 / 3.440 / 4.379 | 7.306 / 12.547 |
| 8 | 0.700 | 48 | 96 | 104 | 3.279 / 3.100 / 5.052 / 6.097 | 8.625 / 13.482 |

`Performance.TIME_PROCESS` was also sampled (0/1/2/4/8: 13.81/20.20/12.28/
12.42/14.14 ms). It did not track the direct frame deltas consistently, so it
is retained in the JSON for audit but is not used for attribution. The direct
pool timers and rendered `_process` deltas are the primary measurements.

## Timing attribution

At eight active breakers, the measured inclusive values per frame were:

```text
tracking                               3.279 ms
  predicted RK2 (inclusive)            2.465 ms
    _sample_velocity (inclusive)       2.151 ms = 22.41 us/call
      Coastal sample itself             1.753 ms = 16.86 us/call
```

The remaining `5.55 us` per velocity call is the velocity wrapper: dictionary
construction, validity/direction handling, and function overhead. The
predictor's measured non-velocity remainder was `0.314 ms/frame` at eight
breakers. Final host samples are included in the Coastal total; their measured
per-call time is in the same approximately `16–17 us` range.

Across the 1/2/4/8 cases, inclusive velocity time was `22.47`, `20.94`,
`22.53`, and `22.41 us/call`; Coastal sample time was `16.84`, `15.76`,
`16.92`, and `16.86 us/call`. This is approximately linear in sample count.
The direct tracking series is also approximately linear, with an empirical
least-squares fit for this age profile:

```text
tracking_ms/frame ≈ 0.34 + 0.031 * velocity_calls/frame
```

The fit embeds the fixture's one host sample per 12 velocity samples, so it is
not a general independent host-cost coefficient. It is a descriptive model,
not a replacement design.

## Repeated Coastal cells

The fixture recorded the interpolation cell (`x0,z0`) used by every velocity
sample. Each breaker made 12 velocity samples but touched only two unique
cells: 10 of 12 accesses (83.3%) reused an already visited four-neighbour
bilinear cell in the same frame. At eight breakers, 96 accesses touched 16
unique cells and repeated 80 accesses. The transform and propagation arrays
are also immutable across these calls. This is evidence for a later cache or
data-oriented reuse investigation, not authorization to implement one in P1.

## Allocation audit (static)

`CoastalPropagationData.sample_propagation` receives no reuse object from the
legacy path, so every Coastal call executes `SampleScript.new()`. It performs
scalar bilinear interpolation over its packed arrays (no temporary arrays):
depth, k, wavelength, phase/group speed, shoaling, phase fields, gradients,
directions, plus optional fields. It constructs local/render `Vector2` values;
these are value types, so P1 does not claim a separate heap allocation count
for them.

Per valid `_sample_velocity()` call, the legacy path creates one return
`Dictionary` and one `CoastalPropagationSample` object. Per final
`_sample_propagation()` host call, it creates one return `Dictionary` and one
sample object. `_predicted_breaker_xz()` itself creates no arrays or
dictionaries per RK2 step. `_update_active_breaker()` creates one `active_state`
dictionary through `_base_state`; cooldown slots create one state dictionary
per inactive slot, and `_sync_production_takeover()` allocates two fixed packed
arrays per pool frame.

With S=6, one active breaker per frame therefore has at least:

```text
12 velocity dictionaries + 1 host dictionary + 1 active-state dictionary = 14 dictionaries
12 velocity samples      + 1 host sample                              = 13 sample objects
```

| Active | Active-path dictionaries/frame | Sample objects/frame | Plus cooldown state dictionaries/frame |
|---:|---:|---:|---:|
| 1 | 14 | 13 | 7 |
| 2 | 28 | 26 | 6 |
| 4 | 56 | 52 | 4 |
| 8 | 112 | 104 | 0 |

The counters show no allocation/GC-specific spike counter exposed by Godot.
The tracking P99 rises from `1.21 ms` at one to `6.10 ms` at eight, which is
consistent with increasing transient allocation and CPU work, but does not by
itself isolate garbage collection as the cause. No allocation is removed here.

## Worst-case projection

The actual maximum legacy configuration is eight active breakers. At `S=24`:

```text
8 * 2 * 24 = 384 velocity samples/frame
8 final host samples/frame
392 Coastal samples/frame
```

This is not directly measured in P1. Applying the measured eight-breaker
velocity cost (`22.41 us`) plus the measured host-scale Coastal cost
(`~16.9 us`) gives about `8.74 ms/frame` for sampling alone. Adding the
measured non-sampling active tracking remainder at eight breakers gives a
rough `~9.7 ms/frame` legacy tracking projection. This is an extrapolation,
not a Steam Deck result and not a guarantee: longer RK2 paths can touch more
cells and alter cache locality.

## Architecture assessment

Classification: **YELLOW** for the legacy tracker.

It is acceptable as a tightly bounded near-camera geometric-breaker path on
the measured RTX system: one or two active breakers are low-risk; four needs a
hard budget; eight already consumes `3.28 ms` tracking average and `6.10 ms`
tracking P99 at only S=6. A future system should not inherit its per-frame
per-breaker RK2 plus dictionary/sample-object architecture.

The intended bounded GPU-first event architecture remains the appropriate
direction: data-oriented active state, camera-local count limits, and
occasional spectral/crest re-lock rather than a full CPU Coastal query for
every active event every frame. P1 does not decide whether the legacy tracker
is retained for physics, re-lock only, or replaced; it supplies the measured
cost basis for that later decision.

Steam Deck not measured. The only valid Deck statement is risk projection:
the work scales approximately with velocity samples and transient containers,
so an unbounded or S=24 legacy path is high risk on a lower-power CPU.

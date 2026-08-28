# Ocean V3 PERF-1B / PERF-2A / PERF-2B benchmark

Run the graphical benchmark with:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://ocean_v3/tests/performance/ocean_performance_benchmark.tscn --resolution 1920x1080
```

The scene locally requests a 1920x1080 window and disables VSync. The command
line `--resolution 1920x1080` is recommended as the external enforcement point;
the runner re-applies the same size after startup and records both the requested
resolution and actual viewport in the result header. Project-wide settings are
not rewritten.

Defaults are 300 warm-up frames, 1200 measured frames, 60 stabilization frames
after each profile switch, 3 repetitions, and an 1800-frame readiness timeout.
Results are written to unique
timestamped files under `user://ocean_v3_benchmarks/` as CSV and TXT.
The directory is created from the globalized `user://` path and the runner
reports an error if either result file cannot be opened.
After writing results, the runner drains 120 rendered frames before requesting
process exit so queued render-thread work can complete.

The default sequential mode includes the six PERF-1A presets plus valid
isolated profiles for refraction, PREBREAK, Surface Foam Solver, and Surface
Foam Render. PERF-2A adds a paired mode for foam decomposition:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://ocean_v3/tests/performance/ocean_performance_benchmark.tscn --resolution 1920x1080 --ocean-benchmark-paired --ocean-benchmark-paired-repetitions=7
```

Paired mode runs `FULL -> TEST` for each of `NO_FOAM`, `NO_CREST_FOAM`,
`NO_SURFACE_FOAM_SOLVER`, `NO_MID_FOLD_HISTORY`, and
`NO_SURFACE_FOAM_RENDER`, repeating each pair seven times by default. Every
side gets the same 60-frame stabilization, 300-frame warm-up, and 1200-frame
measurement window. It writes the raw per-run CSV, a separate paired-delta
CSV, and a TXT summary containing mean/median/stdev/range per test plus the
additive interaction residual against `NO_FOAM`.

PERF-2A treats Crest Foam generation, the dedicated Surface Foam solver, MID
Fold History, and Surface Foam rendering as separate runtime gates. `NO_FOAM`
is the explicit all-foam-off control. `NO_SURFACE_FOAM_SOLVER` leaves MID Fold
History enabled so its compute cost is not silently included; disabling MID
history uses a deterministic neutral shader value and does not alter the
authored wave spectrum or any resolution.

Foam path decomposition in the current implementation is:

```text
physical FFT cascades
  ├─ Crest Foam temporal update (per cascade; GPUStockham dispatch)
  ├─ Surface Foam J-only solver
  │    ├─ evolve -> IFFT -> assemble Jacobian -> update field
  │    └─ topology build/downsample
  └─ MID fold-history compute (independent persistent eligibility)
       └─ fragment sampling/composition with Surface Foam
```

The Surface Foam solver gate disables its J-only work and makes its render
inputs unavailable; the MID gate independently stops its fixed-rate compute and
forces the fragment history factor to neutral zero. The render gate stops the
Surface Foam sampling/composition path while keeping compute resident. These
are profiling switches only; FULL keeps the authored behavior unchanged.

## PERF-2B Surface Foam Solver architecture

PERF-2B targets only the persistent Surface Foam J-only solver. The current
runtime configuration is FFT resolution 512, field resolution 1024, topology
resolution 1024, and a 30 Hz solver update. The solver keeps two ping-pong
instances for Jacobian, surface foam, and topology; it does not share or alter
the physical-ocean FFT, Crest Foam, or MID Fold History resources.

One solver job has 21 logical pass credits:

```text
1 evolve J
18 Stockham IFFT passes (9 stages on each axis)
1 assemble Jacobian
1 update Surface Foam
```

The final logical pass also performs topology publication: one 1024² topology
build plus ten compute downsample passes for the 1024, 512, 256, 128, 64, 32,
16, 8, 4, 2, and 1 mip levels. Therefore the current job emits 32 actual
dispatches: 1 + 18 + 1 + 1 + 1 + 10. All shaders use 8x8x1 workgroups. The
512² passes dispatch 64x64 groups, the 1024² field/topology passes dispatch
128x128 groups, and the downsample passes dispatch 64x64, 32x32, 16x16,
8x8, 4x4, 2x2, 1x1, 1x1, 1x1, and 1x1 groups. At 60 FPS the pass-credit
scheduler normally supplies about 12 credits per rendered frame, so one job
spans about two frames without changing the 30 Hz simulation rate.

The persistent resources are:

```text
H0                         512²  R32G32B32A32_SFLOAT
Derivative ping-pong       2x2 512²  R32G32B32A32_SFLOAT
Jacobian ping-pong         2x  512²  R16_SFLOAT
Surface Foam ping-pong     2x 1024²  RG16_SFLOAT
Topology ping-pong         2x 1024²  RG16_SFLOAT + 11 mip levels
```

Bindings follow the resource topology: EVOLVE uses H0/output payload A/output
payload B/16-byte parameters at bindings 0..3; IFFT uses two input images/two
output images/16-byte integer parameters at 0..4; ASSEMBLE uses the two
payloads/Jacobian/16-byte parameters at 0..3; UPDATE uses sampled Jacobian,
sampled previous foam, next foam image, and a 48-byte parameter block at 0..3;
TOPOLOGY uses sampled Jacobian, topology mip 0, and a 16-byte parameter block
at 0..2; DOWNSAMPLE uses sampled source mip and destination image at 0..1.
Each logical pass is submitted as a compute list with a RenderingDevice
barrier before list completion. Topology and every mip transition also have an
explicit barrier inside the final list before the next dependent dispatch.
Publication swaps the Jacobian and foam read indices only after the complete
job; topology remains paired with its corresponding index.

The render-thread CPU overhead is the per-frame `advance()` scheduling,
compute-list begin/bind/dispatch/end work, barriers, and small uniform-buffer
uploads. PERF-2B removed repeated temporary `PackedFloat32Array`/
`PackedInt32Array` allocations, reuses fixed byte buffers, and defers the
EVOLVE and UPDATE parameter uploads until their owning pass is dispatched. The
UPDATE shader also computes one shared deperiodized warp per texel and reuses
it for both Jacobian samples; it still performs both samples and preserves all
selection, hysteresis, temporal, and RG16F publication behavior.

The immediate before/after paired runs used D3D12 Forward+, NVIDIA RTX 4070
Laptop, 1920x1080, seed 20260820, 300 warm-up frames, 60 stabilization frames,
1200 measured frames, and seven repetitions. GPU milliseconds remain
unavailable because the benchmark does not synchronize or read back the GPU.

```text
                              before       after        change
FULL average frame            3.8054 ms    3.6263 ms    -0.1791 ms (-4.7%)
NO_SURFACE_FOAM_SOLVER pair   0.7746 ms    0.6611 ms    -0.1135 ms (-14.7%)
```

The after run reported paired solver delta median 0.6856 ms, stdev 0.1733 ms,
and range 0.3290..0.9600 ms. The A-only parameter-traffic run was noisy, so
the final claim is based on the complete before/after protocol after both
low-risk changes, not on that intermediate run alone. No resolution, update
rate, lifetime, dissipation, advection, topology, precision, domain, render
path, Crest Foam, or MID behavior was changed.

Opportunity disposition:

```text
Implemented     fixed-byte parameter reuse/deferred uploads; shared UPDATE warp
Measured/rejected none; no other candidate met the low-risk PERF-2B bar
Not implemented topology/downsample redesigns, precision/resolution/rate changes,
                 or any Crest/MID/render optimization (out of scope)
```

Frame timing is measured from rendered `_process` delta and CPU timing uses
Godot's `Performance.TIME_PROCESS` and `Performance.TIME_PHYSICS_PROCESS`
monitors. GPU timing is explicitly unavailable in this instrumentation: the
benchmark does not call `RenderingDevice.sync()`, perform GPU readbacks, or
derive GPU milliseconds from FPS.

Headless mode is supported only for parser/runtime smoke validation. If GPU
solver readiness is not reached within the timeout, the runner exits with an
error instead of producing misleading timings.

In the current project runtime, process shutdown may still print two invalid
RID messages from the pre-existing `SurfaceFoamMidHistorySolver` teardown. No
RID errors were observed while switching profiles or recording samples; the
messages occur only after results are written during process exit and are not
used as timing data. PERF-2A does not change the solver lifecycle because the
warning is outside the measured interval and a safe ownership fix is not
isolated enough for this profiling phase.

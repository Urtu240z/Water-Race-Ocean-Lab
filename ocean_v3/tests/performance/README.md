# Ocean V3 PERF-1B / PERF-2A benchmark

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

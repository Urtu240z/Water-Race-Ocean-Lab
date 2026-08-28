# Ocean V3 PERF-1B benchmark

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

The benchmark includes the six PERF-1A presets plus valid isolated profiles for
refraction, PREBREAK, Surface Foam Solver, and Surface Foam Render. A separate
`NO_MID_FOLD_HISTORY` configuration is intentionally not included because
PERF-1A couples MID Fold History to the Surface Foam Solver gate.

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
used as timing data. PERF-1B does not change the solver lifecycle.

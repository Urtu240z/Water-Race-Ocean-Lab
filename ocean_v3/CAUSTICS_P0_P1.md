# Ocean V3 shallow caustics P0/P1

## Scope

This is an opt-in prototype for real, shallow-water caustics. It deliberately
does not add underwater rendering, volumetrics, particles, a second FFT, GPU to
CPU readbacks, deep-water caustics, or receiver support for arbitrary scene
objects.

## Reused Ocean V3 data

`ShallowCausticsSolver` samples the four normal maps already assembled by the
Ocean V3 FFT pipeline: LONG coastal, LONG remainder, MID and SHORT. The field
is therefore animated by the existing spectrum and time without rebuilding H0
or dispatching another IFFT.

`OceanV3._sync_sun_direction()` remains the single source of the active
`DirectionalLight3D` direction. `BathymetryData` and the existing water-optics
path remain the depth authority: a caustic is never invented when there is no
valid real seabed coverage.

## Field generation

The P0 field is a 256 by 256 `RGBA16F` compute texture. In normal operation
RGB contains the final focused-light value; during a diagnostic mode it contains
the selected diagnostic visualization. At this resolution the persistent
allocation is 512 KiB.

For each field texel, the compute shader combines slopes recovered from the
already assembled normal maps, refracts the sun ray with a fixed air/water IOR
approximation, and projects the ray to a configurable shallow receiver plane.
It then forms the local Jacobian of that surface-to-landing map using two
neighbouring samples. Compression is the inverse local landing area:

```text
compression = 1 / abs(det(d landing / d surface))
focus = clamp(max(compression - (1 + threshold), 0) * focus_gain, 0, focus_clamp)
```

This replaces the original direction-divergence approximation, which could
produce broad moving blobs because it did not measure where neighbouring rays
actually landed. It remains a cheap focusing approximation, not photon mapping
or a physically complete optical solution. LONG is conservative, MID holds the
main structure and SHORT contributes limited detail.

The field follows a camera-centred 96 m square by default (0.375 m per texel at
256). Its origin is snapped to one field texel in world coordinates, which
prevents camera-relative swimming and keeps the field compatible with Ocean V3
world recentering. It is scheduled at 30 Hz by default and can be tested at
full rate (60 Hz).

## P1 receiver and shallow gate

P1 is integrated at the existing validated seabed contribution inside
`ocean_surface.gdshader`. It reuses the already available fragment bathymetry,
real-seabed coverage, seabed confidence, world reconstruction and refraction
classification. It does not add a screen/depth sample.

```text
shallow = 1 - smoothstep(fade_start_depth, max_depth, local_bathymetry_depth)
caustic = field.r * shallow * real_seabed_coverage * seabed_confidence
```

The sample uses the reconstructed seabed world position, so it is a light
contribution on the visible bottom rather than a camera-space overlay. Missing
or invalid bathymetry produces zero. Defaults start the fade at 4 m and remove
the effect at 6 m.

## Controls and diagnostics

All controls live under `OceanV3 > Caustics P0/P1`: enable, strength, fade
depths, 128/256/512 resolution, 1--60 Hz update rate, field extent, projection
depth, focus gain, threshold, response power, focus clamp and the following
debug views:

`CAUSTICS_OFF`, `CAUSTICS_ON`, `DEBUG_CAUSTICS_SHALLOW_MASK`,
`DEBUG_CAUSTICS_RAY_DIR`, `DEBUG_CAUSTICS_LANDING`,
`DEBUG_CAUSTICS_FOCUS`, `DEBUG_CAUSTICS_FINAL`.

The default is disabled, preserving the previous Ocean V3 visual baseline.

## Benchmark protocol

The graphical benchmark accepts an explicit paired mode:

```text
Godot_v4.7.1-stable_win64_console.exe --path . --scene res://ocean_v3/tests/performance/ocean_performance_benchmark.tscn --resolution 1920x1080 -- --ocean-benchmark-caustics-paired
```

It runs `FULL` (caustics enabled) against `NO_CAUSTICS` with the existing
warm-up, stabilization, average, P95 and P99 reporting. It does not synchronize
the GPU or read textures back, so GPU milliseconds remain unavailable by
design. The target is an observed cost near or below +0.20 ms; it is not a
claim until a successful graphical run is recorded.

### Recorded focusing run

On 2026-08-31, after successful creation of the caustics compute shader, the
paired test completed at 1920x1080, Forward+, D3D12, render scale 0.70, on the
RTX 4070 Laptop GPU. Seven `FULL` / `NO_CAUSTICS` pairs measured a mean
CPU-frame delta of `+0.0304 ms`, with `0.0703 ms` standard deviation and range
`-0.0856..+0.1197 ms`. `FULL` averaged `4.3806 ms` (P95 `5.8509 ms`) and
`NO_CAUSTICS` averaged `4.3502 ms` (P95 `5.8417 ms`). This is below the
`+0.20 ms` CPU-frame target for that configuration; it is not a GPU-time claim
because the benchmark intentionally performs no GPU synchronization or readback.

## Current limitations and next checks

The prototype has only the water-optics seabed receiver; it does not yet light
boats, rocks, props or arbitrary terrain materials. The caustic projection uses
a single approximate water column rather than per-pixel physical ray paths.
Before expanding it, validate stationary and moving cameras, coast-to-deep
fade, sun motion, world recentering and a graphical paired benchmark on the
target GPU.

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

The P0 field is a 256 by 256 `RGBA16F` compute texture. R is the final
convergence value; G and B retain source-slope and refraction/convergence views
for diagnostics. At this resolution the persistent allocation is 512 KiB.

For each field texel, the compute shader combines slopes recovered from the
already assembled normal maps, refracts the sun ray with a fixed air/water IOR
approximation, and estimates the divergence of the refracted horizontal ray
with two neighbouring samples. Negative divergence is light compression:

```text
focus = clamp(max(-divergence * focus_gain, 0), 0, focus_clamp)
```

This is a cheap focusing approximation, not photon mapping or a physically
complete optical solution. LONG is given a conservative warp weight, MID holds
the main structure and SHORT contributes limited detail.

The field follows a camera-centred 128 m square by default. Its origin is
snapped to one field texel in world coordinates, which prevents camera-relative
swimming and keeps the field compatible with Ocean V3 world recentering. It is
scheduled at 30 Hz by default and can be tested at full rate (60 Hz).

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
depths, 128/256/512 resolution, 1--60 Hz update rate, field extent, focus gain,
focus clamp and the following debug views:

`CAUSTICS_OFF`, `CAUSTICS_ON`, `DEBUG_CAUSTICS_SHALLOW_MASK`,
`DEBUG_CAUSTICS_SOURCE`, `DEBUG_CAUSTICS_REFRACTION`,
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

## Current limitations and next checks

The prototype has only the water-optics seabed receiver; it does not yet light
boats, rocks, props or arbitrary terrain materials. The caustic projection uses
a single approximate water column rather than per-pixel physical ray paths.
Before expanding it, validate stationary and moving cameras, coast-to-deep
fade, sun motion, world recentering and a graphical paired benchmark on the
target GPU.

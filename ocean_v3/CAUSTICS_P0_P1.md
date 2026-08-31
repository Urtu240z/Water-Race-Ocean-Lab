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

## Texture-driven field generation

The P0 field remains a 256 by 256 `RGBA16F` compute texture (512 KiB). It now
stores only a low-frequency FFT activity modulation. The visible filament
structure comes from one tileable, project-owned PNG texture sampled by the
surface shader; the old Jacobian/focusing generator is gone.

The receiver uses two samples of that tile, with different scale/sign and slow
opposed panning, then combines them with `min()` as in the reference shader.
LONG and MID slopes deform both UV layers; SHORT is limited to the cheap field
activity and cannot turn the pattern into sparkle. The real sun direction
selects the projection basis and attenuates the effect below the horizon.
The current tile is an Ocean V3-owned PNG (`caustics_filament_tile.png`), so it
does not inherit an undocumented third-party image license and can be replaced
without touching the shader.

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
the effect at 6 m. The finite activity field is only a soft modulation window;
the filament texture itself is world-anchored and tileable, so no rectangle is
visible and camera recentering does not move the pattern.

## Controls and diagnostics

All controls live under `OceanV3 > Caustics P0/P1`: enable, strength, fade
depths, 128/256/512 resolution, 1--60 Hz update rate, field extent, texture,
texture scale, FFT warp strength, animation speed and the following debug
views:

`CAUSTICS_OFF`, `CAUSTICS_ON`, `DEBUG_CAUSTICS_TEXTURE`,
`DEBUG_CAUSTICS_FFT_WARP`, `DEBUG_CAUSTICS_SHALLOW_MASK`, `DEBUG_CAUSTICS_FINAL`.

The texture and FFT-warp views are emitted before seabed colour and foam can
hide them. Depth, real coverage and seabed confidence still gate production
output; deep water remains zero.

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

### Current paired run

On 2026-08-31, the texture-driven receiver completed seven `FULL` /
`NO_CAUSTICS` pairs at 1920x1080, Forward+, D3D12, render scale 0.70, on an
RTX 4070 Laptop GPU. `FULL` averaged `4.4327 ms` (P95 `5.9429 ms`, P99
`6.0980 ms`) and `NO_CAUSTICS` averaged `4.3611 ms` (P95 `5.8700 ms`, P99
`6.0136 ms`). The paired mean delta was `+0.0716 ms` (range
`-0.0212..+0.1603 ms`), below the initial `+0.20 ms` budget. GPU milliseconds
remain unavailable because the benchmark intentionally performs no GPU
synchronization or readback. The benchmark could not write its optional
`user://` CSV on this machine, but printed all aggregate statistics above.

## Current limitations and next checks

The prototype has only the water-optics seabed receiver; it does not yet light
boats, rocks, props or arbitrary terrain materials. The caustic projection uses
a single approximate water column rather than per-pixel physical ray paths.
Before expanding it, validate stationary and moving cameras, coast-to-deep
fade, sun motion, world recentering and a graphical paired benchmark on the
target GPU.

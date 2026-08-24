# Ocean V3: persistent FFT whitecaps

Whitecaps in Ocean V3 are derived from horizontal FFT displacement compression,
not from height, slope, Surface Detail normals, or breaker state.

## GPU path

The evolution pass preserves the existing field convention and adds spectral
horizontal derivatives before the same Stockham IFFT passes:

- `spectrum_a`: `H`, `Dx`
- `spectrum_b`: `Dz`, `dDx/dx`
- `spectrum_c`: `dDz/dz`, `dDz/dx`

`dDx/dz == dDz/dx` for the current irrotational Tessendorf displacement, so
the cross term needs only one spectral field. After IFFT and checkerboard
unshift, `assemble_maps.glsl` uses:

```text
J = (1 + dHx/dx) * (1 + dHz/dz) - (dHz/dx)^2
foam_source = max(0, foam_whitecap - J)
```

The old central difference is retained only by the `COMPRESSION` A/B debug. The
production Jacobian is stored in `displacement_map.a` for GPU-only diagnostics.

`normal_map.a` preserves the former 256² persistent value strictly for
`OLD_RAW_FOAM_256` diagnostic A/B. Production state lives in a dedicated,
high-resolution `R16F` foam field per render cascade. After `assemble_maps`
has written its current `J`, `update_foam.glsl` samples `displacement_map.a`
with repeat + hardware-linear filtering at each foam cell and applies a
bounded, FPS-independent birth/residual rule:

```text
residual = previous_foam * exp(-decay_rate * delta_seconds)
target = saturate(foam_source * source_gain * cascade_weight)
birth = 1 - exp(-growth_rate * delta_seconds)
foam = max(residual, mix(residual, target, birth))
```

Each field is ping-ponged (`read previous`, `write next`) so no compute dispatch
reads and writes the same image. `delta_seconds` is the actual module frame
delta, so the update is independent of a fixed 60 Hz rate. There is no
GPU-to-CPU readback.

The additional derivative packing needs one extra ping-pong RGBA32F pair per
cascade (two textures). The foam architecture adds one R16F ping-pong pair and
one compute dispatch after assemble per render cascade; it does not modify the
spectrum, H0, FFT resolution or FFT domains.

## Cascade policy

The physical controls live in `OpenOceanFFTConfig` and are populated by
`SeaStateConfig`:

- LONG_COASTAL and LONG_REMAINDER use the LONG settings and weight `1.0`.
- MID physical weights are CALM `0.20`, RACE `0.50`, ROUGH `0.65`.
- SHORT is CALM `0.0`, RACE `0.05`, ROUGH `0.10`; it can provide foam detail
  without affecting short visual geometry.

CALM uses a low compression threshold and low growth, RACE is occasional, and
ROUGH raises the threshold and increases growth while retaining exponential
decay. Since `foam_source = max(foam_whitecap - J, 0)`, a higher threshold is
more permissive and a lower threshold is more restrictive. The two LONG split
cascades remain part of the FFT path; breakers do not
participate in this mask.

## Material and debug

`ocean_base_xz` is now explicitly the undisplaced FFT/material coordinate and
`ocean_world_xz` the final displaced world coordinate. FFT displacement,
normals and foam sample `ocean_base_xz`, so the persistent alpha stays attached
to the same material parcel as it moves. No additional backtrace/advection is
needed; adding it would double-transport this Lagrangian representation.

`OceanV3` exposes the `Whitecaps Foam` group for color, intensity, visual
threshold/contrast, roughness, alpha boost, distance fade, enable, breakup, and
debug mode. `OpenOceanFFTModule.foam_resolution` is an independent technical
setting with choices 256, 512 and 1024 (default). It rebuilds only the foam
ping-pong images, not H0 or the FFT. `ocean_surface.gdshader` samples the four
R16F fields using the same band/coastal composition weights and adds
contributions without dividing by a total weight. Foam mixes into ALBEDO,
increases roughness and opacity, and never writes emission or changes the base
Fresnel path.

Debug modes are `OFF`, `OLD_RAW_FOAM_256`, `SHAPED_FOAM`, `COMPRESSION`,
`SPECTRAL_JACOBIAN`, `FOAM_SOURCE`, `FILTERED_OLD_RAW_256`,
`HIRES_RAW_FOAM` and `FOAM_SOURCE_HIRES`. The first/filtered pair exposes the
legacy alpha only. `HIRES_RAW_FOAM` is the production field before visual
shaping. `FOAM_SOURCE_HIRES` evaluates the same bilinear `J` source used at
high-resolution field cell centers, without allocating a debug-only texture.

Breakup samples the existing `surface_warp_texture` in base coordinates and
multiplies the shaped mask: it cuts small holes and irregular edges but cannot
create foam where RAW is zero. `foam_edge_softness` controls its transition.

## High-resolution field and spatial reconstruction

The foam field is deliberately independent from the 256² FFT maps. At the
default 1024² it costs 2 MiB per R16F texture; the two-image ping-pong pair is
4 MiB per cascade and 16 MiB for LONG_COASTAL, LONG_REMAINDER, MID and SHORT.
The corresponding totals are 4 MiB at 512² and 1 MiB at 256². This independent
grid is what removes the blocky *birth* quantization; the source `J` itself is
interpolated before threshold/growth/decay, rather than merely filtering a
coarse stored alpha after the fact.

The material may additionally reconstruct the R16F field with a positive cubic
B-spline close to the camera. It uses four hardware-bilinear taps (not sixteen
direct texel fetches), derives resolution from `textureSize()`, and relies on
the existing repeat sampler for periodic FFT wrapping. It is a presentation
quality layer only, not the source of the increased simulation resolution.

LONG_COASTAL (both open and warped coordinates), LONG_REMAINDER and MID use the
adaptive bicubic path close to camera. It transitions continuously to the
existing bilinear sample using both `fwidth(ocean_base_xz)` against each
cascade's real texel size and `foam_filter_fade_start/end`. SHORT remains
bilinear because it has the lowest physical foam weight and finer texels.

`OLD_RAW_FOAM_256` remains the original bilinear reconstruction.
`FILTERED_OLD_RAW_256` shows the legacy adaptive reconstruction for A/B.
`HIRES_RAW_FOAM` shows the production high-resolution field. Breakup defaults to zero speed and
is anchored to `ocean_base_xz`; its remap retains a non-zero floor, preventing
the noise from becoming a binary moving threshold. Final visual shaping is:

```text
thresholded = smoothstep(foam_threshold, 1, raw)
shaped = pow(thresholded, 1 / max(foam_contrast, 0.1))
final = shaped * breakup * foam_intensity * distance_fade
```

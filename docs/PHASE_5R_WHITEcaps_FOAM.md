# Ocean V3: persistent FFT whitecaps

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

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
high-resolution `RG16F` foam field per render cascade: `R` is residual/history
and `G` is fresh whitecap. After `assemble_maps` has written current `J`,
`update_foam.glsl` samples `displacement_map.a` with repeat + hardware-linear
filtering at each foam cell.

```text
fresh_target = saturate(foam_source * cascade_weight)
fresh = fresh_target * (1 - exp(-growth_rate * delta_seconds))
advected_residual = sample(previous_R, backtraced_uv)
residual = advected_residual * exp(-residual_decay * delta_seconds)
residual = max(residual, fresh * deposit_strength)
```

Each field is ping-ponged (`read previous`, `write next`) so no compute dispatch
reads and writes the same image. `G` is not persistent: it only represents
current compression. `R` is backtraced in spectral/base UV using
`velocity_xz = (current_displacement.xz - previous_displacement.xz) / delta`
and `backtraced_uv = uv - velocity_xz * delta / domain_size`. There is no
GPU-to-CPU readback.

The additional derivative packing needs one extra ping-pong RGBA32F pair per
cascade (two textures). The foam architecture adds one RG16F ping-pong pair
and a compact three-image RG16F horizontal-displacement snapshot ring. The
copy runs after foam update, so advection always reads the prior frame while a
third entry preserves the exact motion for debug; it does not modify spectrum,
H0, FFT resolution or FFT domains.

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
normals and foam sample `ocean_base_xz`. Fresh remains attached to current
compression; residual deliberately applies exactly one semi-Lagrangian
backtrace in this base domain. The coastal material path then still selects
open/deep warped coordinates exactly as before, so there is no second coastal
transport and no geometry displacement change.

`OceanV3` exposes the `Whitecaps Foam` group for color, intensity, visual
threshold/contrast, roughness, alpha boost, distance fade, enable, breakup, and
debug mode. `OpenOceanFFTModule.foam_resolution` is an independent technical
setting with choices 256, 512 and 1024 (default). It rebuilds only the foam
and snapshot resources, not H0 or the FFT. `ocean_surface.gdshader` samples the
four RG16F fields using the same band/coastal composition weights. It combines
them with `total = 1 - (1 - residual) * (1 - fresh)`: fresh is whiter, rougher,
more opaque and has a stronger shape-normal weight; residual is softer and more
transparent. Foam never writes emission or changes the base Fresnel path.

Debug modes are `OFF`, `OLD_RAW_FOAM_256`, `SHAPED_FOAM`, `COMPRESSION`,
`SPECTRAL_JACOBIAN`, `FOAM_SOURCE`, `FILTERED_OLD_RAW_256`,
`HIRES_RAW_FOAM`, `FOAM_SOURCE_HIRES`, `HIRES_FRESH`, `HIRES_RESIDUAL`,
`HIRES_TOTAL`, `FOAM_VELOCITY` and `FOAM_NORMAL`. The first/filtered pair
exposes legacy alpha only. The new modes isolate fresh, residual, composition,
the actual backtrace motion and the derivative-based foam shape normal.

Breakup samples the existing `surface_warp_texture` in base coordinates and
multiplies the shaped mask: it cuts small holes and irregular edges but cannot
create foam where RAW is zero. `foam_edge_softness` controls its transition.

## High-resolution field and spatial reconstruction

The foam field is deliberately independent from the 256² FFT maps. At the
default 1024² each RG16F texture costs 4 MiB; the two-image foam pair is 8 MiB
per cascade and exactly 32 MiB across the four render cascades. The two 256²
RG16F displacement snapshots cost another 768 KiB per cascade, exactly 3 MiB
total. This phase moves the foam subsystem from 16 MiB R16F to 35 MiB: 32 MiB
foam + 3 MiB snapshots. The foam-pair totals are 8 MiB at 512² and 2 MiB at
256². J is interpolated before threshold/growth/decay, not merely filtered
after a coarse state is stored.

The material may additionally reconstruct the RG16F field with a positive cubic
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
`HIRES_RAW_FOAM` shows production total; `HIRES_FRESH` and `HIRES_RESIDUAL`
show its independent channels. Breakup defaults to zero speed and
is anchored to `ocean_base_xz`; its remap retains a non-zero floor, preventing
the noise from becoming a binary moving threshold. Final visual shaping is:

```text
thresholded = smoothstep(foam_threshold, 1, raw)
shaped = pow(thresholded, 1 / max(foam_contrast, 0.1))
final = shaped * breakup * foam_intensity * distance_fade
```

The foam shape normal solves a protected 2×2 system from `dFdx/dFdy(total)`
and `dFdx/dFdy(ocean_world_xz)`. It adds no foam texture samples; the existing
Surface Detail normal is only reused as a small masked gain.

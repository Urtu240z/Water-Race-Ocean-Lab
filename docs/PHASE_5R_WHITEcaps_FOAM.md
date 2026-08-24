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

The persistent value is stored in `normal_map.a`. Each assemble dispatch reads
the previous alpha and applies a bounded, FPS-independent birth/residual rule:

```text
residual = previous_foam * exp(-decay_rate * delta_seconds)
target = saturate(foam_source * source_gain * cascade_weight)
birth = 1 - exp(-growth_rate * delta_seconds)
foam = max(residual, mix(residual, target, birth))
```

The normal RGB and foam alpha share the existing persistent normal texture; no
GPU-to-CPU readback or extra foam texture is introduced. `delta_seconds` is the
actual module frame delta, so the update is independent of a fixed 60 Hz rate.

The additional derivative packing needs one extra ping-pong RGBA32F pair per
cascade (two textures). It does not add another complete FFT dispatch sequence.

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
debug mode. `ocean_surface.gdshader` samples alpha from all four normal maps
using the same band/coastal composition weights and adds contributions without
dividing by a total weight. Foam mixes into ALBEDO, increases roughness and
opacity, and never writes emission or changes the base Fresnel path.

Debug modes are `OFF`, `RAW_FOAM`, `SHAPED_FOAM`, `COMPRESSION`,
`SPECTRAL_JACOBIAN` and `FOAM_SOURCE`. RAW reads persistent alpha before visual
shaping; COMPRESSION is the old central-difference A/B; SPECTRAL_JACOBIAN reads
the production `J`; FOAM_SOURCE is black for `J >= whitecap` and bright for
positive source.

Breakup samples the existing `surface_warp_texture` in base coordinates and
multiplies the shaped mask: it cuts small holes and irregular edges but cannot
create foam where RAW is zero. `foam_edge_softness` controls its transition.

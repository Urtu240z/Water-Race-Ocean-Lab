# Ocean V3: persistent FFT whitecaps

Whitecaps in Ocean V3 are derived from horizontal FFT displacement compression,
not from height, slope, Surface Detail normals, or breaker state.

## GPU path

`assemble_maps.glsl` reconstructs the displaced horizontal derivatives using
the existing displacement convention (`X = spatial_a.z`, `Z = spatial_b.x`):

```text
J = (1 + dX/dx) * (1 + dZ/dz) - (dZ/dx) * (dX/dz)
foam_source = max(0, foam_whitecap - J)
```

The persistent value is stored in `normal_map.a`. Each assemble dispatch reads
the previous alpha and applies:

```text
foam *= exp(-delta_seconds * max(foam_decay, 0.5) * 1.15)
foam += foam_source * delta_seconds * foam_amount * 7.5 * foam_cascade_weight
foam = clamp(foam, 0, 1)
```

The normal RGB and foam alpha share the existing persistent normal texture; no
GPU-to-CPU readback or extra foam texture is introduced. `delta_seconds` is the
actual module frame delta, so the update is independent of a fixed 60 Hz rate.

## Cascade policy

The physical controls live in `OpenOceanFFTConfig` and are populated by
`SeaStateConfig`:

- LONG_COASTAL and LONG_REMAINDER use the LONG settings and weight `1.0`.
- MID contributes with physical weight `0.35`.
- SHORT is disabled with weight `0.0`.

CALM uses a high compression threshold and low growth, RACE is occasional, and
ROUGH lowers the threshold and increases growth while retaining exponential
decay. The two LONG split cascades remain part of the FFT path; breakers do not
participate in this mask.

## Material and debug

`OceanV3` exposes the `Whitecaps Foam` group for color, intensity, visual
threshold/contrast, roughness, alpha boost, distance fade, enable, and debug
mode. `ocean_surface.gdshader` samples alpha from all four normal maps using
the same band/coastal composition weights and adds contributions without
dividing by a total weight. Foam mixes into ALBEDO, increases roughness and
opacity, and never writes emission or changes the base Fresnel path.

Debug modes are `OFF`, `RAW_FOAM`, `SHAPED_FOAM` and `COMPRESSION`. RAW reads
the persistent alpha composition before visual shaping. COMPRESSION computes a
diagnostic central-difference Jacobian from the existing displacement maps:
gray means `J≈1`, brighter means lower J, and red marks positive current source
(`J < foam_whitecap`).

The current Jacobian remains a deliberate first approximation. If RAW_FOAM and
COMPRESSION remain too broad at LONG's 2 m texel spacing, the next phase is to
generate horizontal derivatives spectrally during FFT/IFFT, following the
GodotOceanWaves approach. No blur or noise is used to conceal that limitation.

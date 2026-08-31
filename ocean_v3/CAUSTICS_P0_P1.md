# Ocean V3 projected reference-style caustics

## Pipeline

Caustics run as a `CompositorEffect` at `POST_SKY`: after opaque color/depth
and sky resolve, but before Ocean V3's transparent surface samples its manual
screen-texture refraction/transmission background.

```text
opaque scene + depth -> sky -> projected caustics -> Ocean V3 water -> camera
```

The pass reconstructs world position from resolved depth, projects it along the
active `DirectionalLight3D`, and writes its additive contribution in place.
`ocean_surface.gdshader` intentionally has no caustics addition and retains its
manual optics path with `ALPHA = 1.0`.

## Reference adaptation

The implementation keeps the practical Paddy/Ameye pieces: one selectable
caustics texture sampled as two independently panned layers, per-layer `pow()`,
`min()` combination, optional chromatic split, a scene-luminance gradient mask,
sun attenuation and Ocean V3 shallow-depth fade. With chroma split enabled the
pattern costs six reads (three RGB-offset reads for each layer); setting it to
zero uses one read per layer.

When no texture is assigned, Ocean V3 first tries
`reference_assets/caustics-generator.png`, then the temporary root-level
reference asset, then the existing project tile. The luma gradient follows the
same reference-assets then root-level fallback order. `caustics-generator2.png`
is deliberately an Inspector-selectable alternative, not an additional layer.

The full-screen compositor has no local receiver volume, so `caustics_fade_radius`
and `caustics_fade_strength` are reserved Inspector controls rather than a false
world-distance fade. The active spatial boundary is the coherent shallow-depth
mask, controlled by `caustics_fade_start_depth` and `caustics_max_depth` (up to
50 m).

## Controls

Inspector groups expose main scale/speed/strength/power, chroma split, both
layer panners, luma gradient/mask strength/sun strength, depth limits, reserved
spatial fade controls, and OFF/ON/final debug. Former compute-field controls
remain storage-only compatibility properties so existing scenes load, but are
hidden and have no runtime effect.

## Validation

This phase needs only a Lab Main startup/compute-shader smoke check and an
OFF/ON error check. Visual tuning and performance benchmarking are intentionally
left to the next user-directed pass.

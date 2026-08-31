# Ocean V3 projected reference-style caustics

## Pipeline

Caustics run as a `CompositorEffect` at `PRE_TRANSPARENT`, after opaque scene
color/depth resolve and before the transparent Ocean V3 surface:

```text
opaque scene + depth -> projected caustics pass -> Ocean V3 transparent water
```

The pass reads the resolved depth, reconstructs world position with the active
camera matrices, and writes the additive light contribution directly into the
resolved opaque color image. Ocean V3's surface shader no longer adds a second
caustics term to `optical_scene`.

## Reference adaptation

The implementation follows the useful parts of the Ameye/Paddy approach:
light-oriented world-space projection, two differently scaled animated layers,
`pow()` per layer, `min()` combination and soft depth/solar fades. It does not
use FFT warp, Jacobian/focusing, chromatic aberration, extra noise or a second
simulation. The project-owned `caustics_filament_tile.png` is sampled twice.

Opaque geometry below the sea level receives the pattern, so seabed, sand,
walls, rocks and submerged props can all receive it without material changes.
The smooth shallow mask uses `caustics_fade_start_depth` and
`caustics_max_depth` (default 4--6 m, configurable to 50 m). Invalid/sky depth,
above-water geometry and a low sun contribution produce no caustic.

## Controls

`CAUSTICS_OFF`, `CAUSTICS_ON` and `DEBUG_CAUSTICS_FINAL` are exposed on
`OceanV3`. Texture scale, strength, power, animation speed, fade start and
maximum depth remain configurable. The compositor is isolated from the FFT
module and does not allocate or update a caustics field.

## Validation

Only the requested smoke validation is required for this phase: start
`res://lab/lab_main.tscn`, confirm the compositor shader loads, and toggle the
feature. No benchmark or extended visual tuning is part of this phase.

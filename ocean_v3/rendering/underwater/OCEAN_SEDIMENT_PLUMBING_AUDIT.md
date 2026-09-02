# Ocean V3 — Sediment Plumbing Audit

## Diagnostic stages

`OceanSedimentSystem` has four intentionally separate runtime modes:

1. `SEDIMENT_FIELD_UNDERWATER` projects the published `Texture2DRD` directly
   on a temporary GPU-only plane at the last test injection. Black is zero,
   blue is low, yellow is medium, and magenta/white is high concentration.
2. `SEDIMENT_CANDIDATES` renders every process-shader-valid water/bathymetry
   candidate in bright green. It bypasses the field, density, and production
   alpha. Its temporary large AABB isolates visibility culling.
3. `SEDIMENT_FIELD_PARTICLE_MATCH` renders the same candidates red below the
   field threshold and green at/above it, without production alpha.
4. Normal mode retains the restrained production cloud/wisp alpha.

All modes are GPU-only. The test is started with `Inject Test Sediment`, F8,
or `--INJECT_SEDIMENT_TEST`; command-line debug selection accepts the mode
names above with or without the `SEDIMENT_DEBUG_` prefix.

## Field contract

The compute shader, particle process shader, particle render shader, surface
shader, and debug plane use the same contract:

```glsl
uv = (world_xz - sediment_field_origin_xz) / sediment_field_extent_m;
```

`origin_xz` and `extent_m` come from the immutable bathymetry bake. No system
uses clipmap-local coordinates or swaps axes.

## Publication contract

The compute pass is submitted as `READ -> WRITE -> barrier`. The completed
write becomes the next read index. On the next main-thread publication,
`Texture2DRD.texture_rd_rid` is set to that completed RID before both the
surface and particles are updated. An injected pass prints one `SEDIMENT
DISPATCH` line with read/write indexes, serials, published index, and RID ID.
No GPU-to-CPU field readback or synchronization is used.

## Test injection

The test selects a valid seabed cell no farther than 15 m from the camera that
is in front of the full Camera3D forward vector and inside its viewport. It
prints the target position, horizontal and 3D distance, forward dot, frustum
result, exact field UV, and particle preview-height diagnostic. A bright
magenta 1.5–1.8 m ring plus 5 m pillar marks the test center for 9 seconds.

The particle bathymetry preview packs `R = depth_m / 32` and `G = water`. The
one-shot height diagnostic reports the quantized decoded seabed and expected
cloud/wisp height ranges for the injected cell.

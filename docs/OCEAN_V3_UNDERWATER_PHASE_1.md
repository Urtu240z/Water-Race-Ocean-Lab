# Ocean V3 — Underwater V2 / Water Interface Buffer

## Authority and cost

`OceanUnderwaterManager` owns exactly one `WaterInterfaceBuffer` `SubViewport`.
It shares the main `World3D`, synchronizes its camera transform, projection,
FOV, near/far planes, aspect policy and frustum offsets with the active camera,
and renders only the dedicated interface layer. The main camera explicitly
excludes that layer.

`OceanClipmapSurface` creates proxy `MeshInstance3D`s that share the production
clipmap meshes and a duplicate of the production material. The proxy material
sets `water_interface_buffer_render`; the shared shader therefore executes the
identical FFT/coastal/shore/breaker vertex displacement as the visible ocean,
then exits at the first fragment instructions. Its HDR color target packs:

- `RG`: octahedral world macro normal;
- `B`: positive view-space interface depth;
- `A`: valid interface coverage.

No second FFT simulation, full-screen raymarch, GPU-to-CPU readback, or second
air/water scene render is introduced. The buffer is allocated at the main
render-target size (not a 1×1 probe).

## Viewer and pixel media

`OceanV3` calls the existing `OpenOceanFFT.sample_water()` exactly once per
render frame at the camera XZ and render time. Its displaced height and normal
produce hysteretic `AIR`, `WATER`, or `CROSSING` state. This is only a local
viewer-side decision; it is never the screen-wide waterline authority.

The compositor samples the interface `ViewportTexture`. `AIR` stays air,
`WATER` stays water even when a seabed fills the depth buffer, and `CROSSING`
uses the local query side plus the actual per-pixel interface coverage. Optical
path estimates use the buffer interface depth and scene depth; no path is
intersected with mean sea level.

The former pre/post transparent-depth comparison and the old cached FFT RID
probe were removed. Before a compute uniform set is created, the color image,
scene depth, and current `ViewportTexture` RD RID are all validated; unavailable
first-frame input deterministically skips the pass, producing no
`RenderingDevice` calls with null/stale resources.

## Snell / TIR diagnostics

The compositor decodes the buffer macro normal and classifies each view ray
with `eta = 1.333 / 1.0003` and:

```text
cos_i = abs(dot(view_ray, macro_normal))
k = 1 - eta² * (1 - cos_i²)
TIR = k < 0
```

This is angular, not a screen-UV rectangle, so its geometry is independent of
viewport aspect ratio. Debug choices are `INTERFACE_VALID`, `INTERFACE_DEPTH`,
`INTERFACE_NORMAL`, `VIEWER_MEDIUM`, `PIXEL_MEDIUM`, `SNELL_K`, `TIR`, and
`WATERLINE`.

## Validation still required

Automated validation checks shader/script loading and RenderingDevice silence.
Visual acceptance remains required for above, below, calm crossing, steep FFT
crossing, strongly tilted surface, multiple aspect ratios, and every buffer /
Snell debug view. Do not commit or push until that report is accepted.

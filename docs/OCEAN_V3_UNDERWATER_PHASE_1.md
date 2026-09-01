# Ocean V3 — Underwater Phase 1

## Scope

Underwater optics are split into two deliberately separate responsibilities:

- `OceanUnderwaterEffect` is a `POST_TRANSPARENT` compositor effect.  It
  reconstructs the per-pixel scene ray and applies Beer-Lambert absorption and
  single-pass scattering only to its underwater segment.
- `ocean_surface.gdshader` remains the visual interface authority.  When the
  camera state is underwater, it uses its already-evaluated FFT slope data to
  construct the water-to-air Snell/TIR branch.  No FFT textures are sampled
  again for this purpose.

The compositor is installed while Ocean V3 is active, rather than being
enabled only for an underwater camera.  Pixels with no water segment retain
their original color.

## Camera state

`OceanV3` calls the existing `OpenOceanFFT.sample_water(camera_position,
SimulationClock.get_render_time())` once per frame.  Its sample height is used
only for camera state, hysteresis and the smooth interface factor.  Entering
requires the camera to be 0.05 m below that sampled surface; exiting requires
it to be 0.05 m above it.

This is not a GPU readback and does not launch new FFT work.

## Per-pixel medium approximation

Phase 1 intersects the reconstructed ray with the horizontal
`y = sea_level` plane.  For valid scene depth it handles the four camera/scene
above/below combinations analytically.  For an invalid sky depth from an
underwater camera it reconstructs a ray direction, intersects that ray with
the plane, and uses only that intersection distance; it never uses the far
plane as an optical length.  Parallel or invalid rays use a finite,
configurable conservative fallback.

The rendered ocean surface continues to use the actual displaced FFT geometry.
At an exact partial-submersion boundary, the plane-based medium boundary can
therefore differ slightly from the visible FFT crest.  Resolving that mismatch
would require a future, explicitly requested FFT-surface intersection step.

## Surface interface

The underwater branch derives its normal from existing LONG + MID slopes and a
configurable, bounded SHORT contribution.  It flips the normal toward the
incident underwater ray, uses `refract(incident, normal, water_ior)`, and
treats a zero or non-finite refracted vector as total internal reflection.

For Phase 1, refracted and reflected directions are projected to the available
screen background.  A failed reflected projection falls back to the already
computed reflection radiance; no second SSR raymarch is added.

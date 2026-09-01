# Ocean V3 — Underwater Phase 1

## Scope

Underwater optics are split into two deliberately separate responsibilities:

- `OceanUnderwaterDepthCaptureEffect` snapshots resolved depth at
  `PRE_TRANSPARENT`. `OceanUnderwaterEffect` runs at `POST_TRANSPARENT`,
  compares that snapshot with final depth, then reconstructs the per-pixel
  scene ray and applies Beer-Lambert absorption and single-pass scattering.
- `ocean_surface.gdshader` remains the visual interface authority.  When the
  actual displaced FFT surface puts a fragment on the water-to-air side, it
  uses its already-evaluated FFT slope data to construct the Snell/TIR branch.
  The branch is classified per fragment on GPU; the CPU camera state is not an
  optical authority and no FFT textures are sampled again for this purpose.

The compositor is installed while Ocean V3 is active. A camera clearly above
`sea_level + underwater_transition_width_m` returns the resolved 3D image
unchanged; above-water transmission remains solely the responsibility of the
ocean surface shader.

## Camera state

`OceanV3` uses its existing `_surface_sea_level()` only for camera state,
hysteresis and the smooth interface factor. Entering requires the camera to be
0.05 m below that level; exiting requires it to be 0.05 m above it.

No OceanQuery is run from `_process()` for underwater state. The retained
transition factor only selects the clearly-above and clearly-below fast paths.
Inside the crossing band it cannot classify the whole frame: the depth-derived
water mask decides every pixel.

## Per-pixel medium approximation

The compositor no longer consumes cached FFT `RID`s. Those resources are
published and replaced on the render thread, so caching them across solver
initialization/rebuilds can bind a stale non-null RID. The depth pair is owned
by the same renderer callbacks and is checked before any uniform set or
dispatch is created.

For a camera clearly above the interface, the medium mask is zero; clearly
below it is one. In the crossing band, a pixel belongs to water only when the
post-transparent reversed-Z depth is nearer than the pre-transparent snapshot.
The surface has already written its real displaced FFT/coastal depth, so this
preserves the visible waterline without a full-screen FFT raymarch, CPU
readback, OceanQuery-per-pixel, or second ocean simulation. The pre-transparent
depth remains the opaque-scene endpoint behind water for optical distance.

`DEBUG_OCEAN_DEPTH_WRITE` shows pixels where transparent depth changed and
`DEBUG_WATERLINE_MASK` shows the final medium mask.

## Surface interface

The underwater branch derives its normal from existing LONG + MID slopes and a
configurable, bounded SHORT contribution. It classifies the view direction by
the physical critical cone: `sin(theta_i) <= n_air / n_water`. The debug
`SNELL_CRITICAL_ANGLE` is only that scalar angular classification. Projected
screen UV bounds can choose a color fallback but never classify Snell/TIR, so
the cone cannot become viewport-shaped.

For Phase 1, refracted and reflected directions are projected to the available
screen background.  A failed reflected projection falls back to the already
computed reflection radiance; no second SSR raymarch is added.

# Ocean V3 — Underwater Phase 1

## Scope

Underwater optics are split into two deliberately separate responsibilities:

- `OceanUnderwaterEffect` is a `POST_TRANSPARENT` compositor effect.  It
  reconstructs the per-pixel scene ray and applies Beer-Lambert absorption and
  single-pass scattering only to its underwater segment.
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
camera state is compatibility/debug telemetry only; it never decides the
surface Snell/TIR branch or which pixels receive medium attenuation.

## Per-pixel medium approximation

At render time a 1x1 compute probe samples the already-published LONG coastal,
LONG remainder and MID displacement/normal maps at the camera XZ. It writes
height and slope to a GPU-only texture; there is no CPU query, CPU readback,
per-pixel FFT sampling, or new ocean solver. The compositor converts that
sample into a local tangent plane and uses it for the three visual camera
ranges: above, underwater, and crossing.

In the crossing band, it reconstructs each pixel view ray and classifies a
fixed point along it against the tangent plane, producing a feathered,
slope-following waterline. Where the mask permits the effect, the compositor
uses the same plane to intersect the reconstructed ray. Valid scene depth uses
the four camera/scene-side combinations analytically; invalid sky depth from an
underwater camera uses only ray direction and never far-plane length. Invalid
probe data falls back deterministically to `y = sea_level` with an up normal.

`DEBUG_LOCAL_SURFACE_PLANE` shows the signed local-plane division and
`DEBUG_WATERLINE_MASK` shows the final attenuation mask. They let the local
interface be checked independently of the medium shading.

## Surface interface

The underwater branch derives its normal from existing LONG + MID slopes and a
configurable, bounded SHORT contribution. It classifies the camera against the
local displaced surface at each fragment, flips the normal toward the incident
underwater ray, uses `refract(incident, normal, water_ior)`, and treats a zero
or non-finite refracted vector as total internal reflection.

For Phase 1, refracted and reflected directions are projected to the available
screen background.  A failed reflected projection falls back to the already
computed reflection radiance; no second SSR raymarch is added.

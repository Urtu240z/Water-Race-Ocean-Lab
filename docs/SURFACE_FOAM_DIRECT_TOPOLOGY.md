# Surface Foam: direct topology and temporal envelope

## Decision

The near visible topology is sampled directly from the completed 512² Surface
Foam Jacobian texture. It is not rasterized through the 88 m RG16F field before
presentation.

The direct source uses two deterministic, world-space mappings. A is warped
with non-commensurate 53/71/89/97 m waves. B rotates and scales the complete
world position before applying its independent 59/79/109/113 m warp and phase
offset. The raw values are formed independently as `max(0, whitecap - J)` and
then regionally selected; Jacobians are never blended before that threshold.

## Responsibilities

- Direct J samples: visible filament topology near the camera.
- Field R: temporal envelope only, using `smoothstep(0.015, 0.32, R)` and a
  `0.46..1.0` multiplier.
- Field G: coarse fallback only after the mid/far transition; it is not the
  near silhouette.
- Microdetail and edge fade: strictly multiplicative erosion after macro.
  They cannot create coverage outside the macro mask.

## LOD and cost

- Near, through 80 m: two direct J samples and regional selection.
- 72–90 m: smooth transition to one direct A sample.
- Mid, through 160 m: one direct A sample.
- 150–170 m: smooth transition to field coarse support.
- Far: field coarse support only.

No FFT, persistent buffer, scheduler, source domain, or field resolution is
added or changed by this route.

# Surface Foam: scale and LOD

This note supersedes the prior field-as-topology design.

Production keeps the existing 8 m / 512² Surface Foam Jacobian as the near
visible topology source. It samples the two seam-safe world-space warped raw
signals directly, applies the whitecap threshold before regional selection,
and uses the 88 m RG16F field only as temporal envelope/history (R) and a
coarse fallback (G) at distance. The field must not carry the fine silhouette.

The near path uses two direct J samples, mid fades through one direct sample,
and far uses the existing field. No extra FFT, persistent texture, or buffer is
introduced. Microdetail and edge fade remain subtractive presentation stages:
they can erode an existing macro silhouette but cannot create coverage.

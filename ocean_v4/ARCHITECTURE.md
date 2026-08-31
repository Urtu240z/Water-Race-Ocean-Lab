# Ocean V4 coastal geometry (Phase 1)

V4 owns the runtime path in `ocean_v4/coastal/ocean_coastal_v4.gd`,
`ocean_v4/simulation/open_ocean_fft_v4.gd`, and the V4 surface shader.
The only V3 inputs retained are audited, immutable low-level resources:
the generic Tessendorf spectrum utility and the baked coastal asset's
propagation/warp data. V4 does not create or call an Ocean V3 controller,
surface, query, foam, breaker, reflection, optics, or benchmark system.

The physical composition is `LONG_COASTAL + LONG_REMAINDER + MID + SHORT`.
Only LONG is angularly split (20–35 degrees around its deterministic wind
direction). The coastal component samples world-to-deep warp data and the
associated shoaling scale; the remainder, MID, and SHORT remain open ocean.
The final depth envelope stabilizes horizontal and vertical displacement near
the baked shoreline while preserving the open-ocean solution outside the bake.

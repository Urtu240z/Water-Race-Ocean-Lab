# Ocean V3 — Breaking rework, Step 3

## Purpose and boundary

Step 3 adds a local, GPU-debug-only **parent crest descriptor** and
`BREAK_STRENGTH`. It is intentionally a descriptor of the crest at one world
position, not a made-up persistent parent-wave ID. It does not create a
candidate buffer, propagation history, segmentation, or offshore ribbons.

The established Coastal-only ribbon pool remains the production path. Its
fixed width, height, lip LUT, foam, lifetime and geometry are unchanged.

```text
actual LONG FFT ── measured local crest ──┐
                                           ├─ parent descriptor ── BREAK_STRENGTH
actual MID FFT  ── measured local crest ──┘                         ▲
                                                                      │
OPEN_BREAK + DEPTH_BREAK ───────────── BREAK_ONSET ─────────────────┘
```

## Local parent descriptor

`parent_crest_descriptor_at()` reuses real local LONG and MID height samples.
For each band it samples the centre and the `+/- lambda/8` and
`+/- lambda/4` neighbourhoods along the configured propagation direction.
Its local crest elevation is:

```text
crest_elevation = max_scales(eta_center - 0.5 * (eta_minus + eta_plus), 0)
```

Measured crest support (`crestness * crest_elevation`) gives continuous LONG
and MID attribution weights. From them the descriptor derives:

- `crest_scale_m`: local elevation above its two-sided neighbourhood;
- `effective_height_m = 2 * crest_scale_m`;
- weighted effective wavelength and dominant direction;
- weighted local steepness;
- reserved, parent-derived safety values: `0.75 * effective_height_m` as
  maximum lip height and `0.20 * effective_wavelength_m` as maximum forward
  projection.

The safety values are descriptive only in this step. No geometry consumes
them. `SHORT` is deliberately absent; depth is not an input to the descriptor.
Thus Coastal may alter the actual LONG field where it already exists, but
Coastal validity is never required for the open-water descriptor to exist.

## BREAK_STRENGTH

Onset and strength answer different questions:

```text
BREAK_ONSET:     may this crest break?
BREAK_STRENGTH:  if it may, how much local parent scale is available?
```

```text
height_capacity     = smoothstep(0.10 m, 1.25 m, effective_height_m)
wavelength_capacity = smoothstep(3 m, 32 m, effective_wavelength_m)
steepness_capacity  = smoothstep(0.08, 0.30, effective_steepness)
parent_scale        = sqrt(height_capacity * wavelength_capacity)

BREAK_STRENGTH = clamp(
  BREAK_ONSET * parent_scale * mix(0.60, 1.0, steepness_capacity), 0, 1)
```

The inputs are physical metres and local slope; the `smoothstep` ranges are
explicit artistic normalisation for a future geometry policy. A small crest
can therefore have high onset but low strength, while a large stable wave has
zero strength because onset is zero. Coastal depth can influence strength only
through the already defined `BREAK_ONSET` union; it does not replace the local
parent scale.

## Debug and cost

Breaking debug now provides `BREAK_STRENGTH`, `PARENT_HEIGHT`,
`PARENT_CREST_SCALE` and `BAND_ATTRIBUTION` in addition to Step 2's onset
views. The attribution view is red for LONG and blue for MID.

These modes stay opt-in. Normal rendering has no additional fetch, pass,
readback, CPU grid, or node allocation. Step 3 modes re-evaluate the existing
five-position LONG and five-position MID local crest measurement in the
fragment debug path; modes also requesting onset retain Step 2's bounded depth
evaluation when valid Coastal data exists. This is diagnostic cost only, not a
production geometry cost.

## Deferred work

- camera-local candidate storage and temporal parent tracking;
- crest segmentation/lateral propagation;
- applying safety values to lip dimensions or spawn density;
- replacing the legacy Coastal-only fixed-width ribbon representation.

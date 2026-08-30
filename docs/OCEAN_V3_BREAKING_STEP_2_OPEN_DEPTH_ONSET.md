# Ocean V3 — Breaking rework, Step 2

## Purpose and scope

Step 2 adds a GPU eligibility contract only. It does not change the legacy
Coastal production detector, the ribbon pool, lip LUT, sizing, lifetime, foam,
or physics. Consequently no offshore ribbons are spawned by this step.

```text
LONG FFT ───┐
            ├─ OPEN_BREAK ──┐
MID FFT ────┘               │
                            ├─ BREAK_ONSET
Coastal depth/warp ─ DEPTH_BREAK ─┘
```

## OPEN_BREAK

`open_break_components_at(world_xz)` evaluates actual FFT height samples from
`LONG_COASTAL + LONG_REMAINDER` and `MID`. It samples each band at the point and
at +/- lambda/8 and +/- lambda/4 along that band's configured wind direction.

For each band:

```text
crest = max_scales(
  smoothstep(0.016a, 0.10a, min(eta0-eta-, eta0-eta+))
  * smoothstep(0.030a, 0.20a, 2eta0-eta--eta+)
)

slope = max(abs(eta+ - eta-) / (2 spacing), k a)
signal = crest * smoothstep(threshold_lo, threshold_hi, slope)
```

`a = 0.5 * Hs_band`; wavelengths are the geometric mean of the existing band
limits. The LONG thresholds are 0.10–0.30; the smaller MID band uses 0.08–0.24.
Both signals are clamped to `[0,1]`.

```text
OPEN_BREAK = LONG_SIGNAL + MID_SIGNAL - LONG_SIGNAL * MID_SIGNAL
```

This bounded union means either band can qualify, and MID strengthens a LONG
crest when both are unstable. It uses no coast distance, propagation texture,
bathymetry, random mask, or noise. `SHORT` has no sample or term in this path.

## DEPTH_BREAK

`depth_break_at()` is the former coastal PREBREAK calculation, kept intact as a
separate signal. It requires valid Coastal data and returns zero otherwise.

```text
DEPTH_BREAK = crest_LONG * depth_pressure
              * mix(0.35, 1.0, steepness_pressure) * zone_activity
```

`depth_pressure` retains `smoothstep(0.55, 1.0, Hs_local/(0.78*depth_m))`;
the crest uses real warped/shoaled `LONG_COASTAL + LONG_REMAINDER`. It remains
the legacy production-breaker eligibility source for this step.

## BREAK_ONSET

```text
BREAK_ONSET = OPEN_BREAK + DEPTH_BREAK - OPEN_BREAK * DEPTH_BREAK
```

This is a monotonic bounded union: it is never greater than one, preserves an
independent open-water candidate when depth is absent, and lets depth reinforce
an already unstable crest. It is not `BREAK_STRENGTH` and is not used to scale
any ribbon dimension.

## Debug and performance

The existing breaking debug enum now adds `OPEN_BREAK`, `DEPTH_BREAK`, and
`BREAK_ONSET`; the coastal demo's B cycle exposes them. Legacy depth, steepness,
crestness, and PREBREAK modes remain available.

Normal rendering performs no new texture fetches or passes: the new signal is
evaluated only in debug modes 5–7. In those modes OPEN_BREAK evaluates five
height positions for LONG and five for MID; valid Coastal data additionally
retains the legacy seven-position LONG DEPTH_BREAK evaluation. There is no
GPU-to-CPU readback, no CPU grid, and no new Node3D allocation.

## Limitations deferred to later steps

- No camera-local production candidate buffer yet.
- No crest segmentation, lateral propagation, or parent-wave response scale.
- No `BREAK_STRENGTH`; onset does not choose lip width, height, or lifetime.
- The production ribbon pool remains intentionally Coastal-only until its
  oversized fixed-width representation is replaced.

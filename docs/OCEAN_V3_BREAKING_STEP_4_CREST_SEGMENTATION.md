# Ocean V3 — Breaking rework, Step 4

## Purpose and boundary

Step 4 provides a spatial, instant-only **crest segment descriptor** for a
local breaking seed. It has no persistent wave identity, temporal state,
lateral propagation, candidate storage, or production geometry effect. The
legacy Coastal-only ribbon pool and its fixed six-metre width are untouched.

```text
BREAK_ONSET + Step 3 parent descriptor
                 |
                 v
  local crest frame (forward, tangent)
                 |
                 v
  three bounded probes to each tangent side
                 |
                 v
  asymmetric crest segment descriptor
```

## Crest frame and seed

The seed is the current `world_xz` point. Step 3 supplies the dominant parent
direction as `forward_direction`; the lateral frame is
`crest_tangent = (-forward.y, forward.x)`. It therefore has no world-X/Z
assumption and introduces no direction solver.

The seed is active only when both conditions hold:

```text
BREAK_ONSET >= 0.60
BREAK_STRENGTH >= 0.08
```

These are robustness heuristics over the already normalised Step 2/3 fields,
not changes to spectral physics. Requiring strength as well as onset rejects a
tiny high-onset crest from starting a large segment.

## Sampling and bounds

Each side has exactly three local probes. The parent supplies a scale reference:

```text
search_radius = clamp_max(0.40 * effective_wavelength + 2 * effective_height, 12 m)
search_radius = max(search_radius, 0.75 m)
spacing       = clamp(search_radius / 3, 0.25 m, 4 m)
```

The effective wavelength only chooses a bounded search and sampling scale; it
does not prescribe the final span. `left_extent` and `right_extent` advance
only when actual adjacent samples remain coherent, and may be different.

## Continuity and hysteresis

A lateral probe continues a segment when all of these hold:

```text
onset >= 0.42
strength >= max(0.04, 0.30 * seed_strength)
height ratio to seed >= 0.30
LONG/MID attribution dot product >= 0.55
forward-direction dot product >= 0.82
```

The last two prevent a local lobe with a materially different parent mixture or
direction from being merged. The scale and strength gates prevent mere onset
noise from extending a segment.

One non-extending bridge sample is allowed when onset is at least `0.26`,
strength at least `max(0.02, 0.15 * seed_strength)`, attribution coherence is
at least `0.45`, and direction coherence at least `0.70`. A second weak sample
stops that side. This bounded hysteresis holds together a small local dip but
does not cross a multi-sample valley into a separate event.

## Descriptor

`crest_segment_descriptor_at()` returns:

- segment centre, forward direction, and crest tangent;
- left extent, right extent, and total span;
- mean/peak onset and mean/peak strength;
- effective parent height/wavelength and LONG/MID weights;
- mean lateral onset on each side, lateral extent bias, and minimum accepted
  coherence;
- the derived bounded search radius.

No value animates or grows in Step 4. Step 5 can consume the directional frame,
asymmetric extents, side onset means, bias, and peak/mean fields to select a
lateral evolution direction without redesigning this descriptor.

## Debug views

`SEGMENT_SPAN` maps realised span relative to the current bounded search.
`SEGMENT_ASYMMETRY` maps left extent to blue and right extent to red.
`SEGMENT_COHERENCE` uses the normal heat scale. They reuse the existing breaking
debug path and add no pass.

## Performance accounting

The descriptor is debug-only in Step 4. One seed plus at most six lateral
probes are evaluated: **7 probes maximum**. Each probe performs one shared
LONG/MID parent/open evaluation (five LONG and five MID height positions) and
the existing local depth evaluation (seven LONG height positions only when
Coastal data is valid). Step 3's parent calculation is reused from the same
open evaluation rather than re-sampling it.

This is bounded but intentionally expensive diagnostic work: at most 70
LONG/MID height evaluations for the shared open/parent portion, plus up to 49
legacy LONG depth positions in valid Coastal coverage. A LONG height may itself
read Coastal state and the two LONG displacement fields; a MID height reads its
single displacement field. Each probe also takes the existing three Coastal
field/metrics/phase reads for depth. The remainder is fixed-loop ALU (unions,
normalisation, dot products, min/max) and no dynamic allocation.

There is no global scan, readback, CPU grid, flood fill, Node allocation, or
production cost. A future camera-local production pass must benchmark this
first; it should not execute the Step 4 fragment diagnostic across the whole
screen unchanged.

## Limitations

- The descriptor is an approximation over real FFT samples, not segmentation
  of an immutable FFT wave object.
- Three samples per side trade resolution for a fixed Steam-Deck-compatible
  upper bound; short irregular spans can quantise to the local spacing.
- No temporal continuity, propagation, collapse, ribbons, foam, spray, or
  physics is introduced.

# Phase 3B.3 — OceanQuery coastal parity

OceanQuery evaluates the coastal modification inside its parametric surface,
not as a post-process over a world-space water query:

```text
P_coastal(q,t).xz = q + D_effective_xz(q,t)
```

Newton therefore solves the same conceptual surface that the renderer deforms.
The coastal sampler is queried at the current `q` on every Newton iteration.

## LONG correction

The query retains the original three-band evaluator and adds only the
`LONG_COASTAL` correction. With `C` the angular LONG component, `F(q)` the
world/parametric-to-deep warp, `c` its confidence, and `S_eff` bounded
shoaling, it evaluates:

```text
C_eff(q) = S_eff * ((1 - c) * C(q) + c * C(F(q)))
LONG_eff(q) = LONG_original(q) + C_eff(q) - C(q)
S_eff = mix(1, shoaling, c)
```

At `c = 0`, outside the grid, or on invalid/folded data, `S_eff = 1` and the
correction cancels exactly, preserving the open-ocean query path.

Each canonical pair stores `w_pos = w(k)` and `w_neg = w(-k)` separately.
They weight the independently evolved A/+k and B/-k H0 contributions before
the normal canonical-pair multiplicity/parity reconstruction. This is the
same split convention used by `TessendorfSpectrum.build_h0_split_rgba32f`.

## Derivatives and normals

The local derivative approximation keeps confidence and shoaling constant at
the current `q`, while position remsamples them at every Newton iteration.
For the deep sample, height gradients use `J^T grad_deep`; horizontal
displacement derivatives use `dD/deep * J`. The resulting derivatives build
the normal from the existing physical 3D tangents.

The CPU runtime and native runtime both bilinearly sample deep coordinates,
detJ, J, shoaling, and validity alpha. No Eikonal solve, bake, raycast, GPU
readback, allocation, or dictionary occurs per query.

## Scope

The native implementation preserves the AVX2 base LONG/MID/SHORT evaluator.
The additional coastal component is evaluated only for in-field query points;
its spectral component is a separate scalar correction after the SIMD base
kernel. A future SIMD extension for the two `C` evaluations is a performance
optimization, not a separate solver.

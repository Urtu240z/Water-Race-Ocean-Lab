# Phase 3B.2B Render Closure

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

## Render-space warp and normals

`CoastalWarpBaker` recibe `CoastalPropagationData` y usa los campos de
presentación `render_phase_rad` y `render_direction` para construir el mapping
final de `LONG_COASTAL`. Si un recurso legacy no los contiene, hace fallback a
`phase_rad` y `local_direction`. La fase permanece desenrollada: la coordenada
longitudinal es `s_deep = render_phase_rad / k0`. El cut locus y su regularización
no existen en el shader; llegan resueltos dentro de `CoastalWarpData`.

Los campos RAW (`phase_rad`, `phase_gradient_x/z` y `local_direction`) siguen
siendo la verdad física/diagnóstica y no se sobrescriben. `build_gpu_textures()`
de `CoastalPropagationData` mantiene su textura RAW compartida.

`CoastalWarpData` stores the complete world-to-deep Jacobian

```text
J = d(deep_xz) / d(world_xz)
  = [ J00 J01 ]
    [ J10 J11 ]
```

using exactly the finite differences already used for `detJ`.  The existing
RGBA32F warp texture remains `(deep_x, deep_z, detJ, valid)`; a separate
RGBA32F texture stores `(J00, J01, J10, J11)`.  This costs one additional
16 bytes per coastal grid texel on GPU.

The renderer applies the Jacobian only to the `LONG_COASTAL` slope:

```text
slope_world ~= transpose(J) * slope_deep
```

This is intentionally a heightfield/choppy approximation.  The FFT normal
comes from a 3D displacement field, so this is not an exact transformation of
its two full 3D tangents.  It keeps the shader path inexpensive and leaves an
exact tangent reconstruction as a separate, evidence-driven future decision.

`detJ` remains a validity/confidence diagnostic.  It does not focus or
defocus amplitudes; the only amplitude control is the existing bounded
shoaling factor.

## Open-ocean fallback

In normal `WARP_AND_SHOALING` mode, confidence controls deep sampling,
transformed slope, and shoaling together.  At confidence zero, the result is
exactly the original open-ocean `LONG_COASTAL` sample and shoaling is one.
`SHOALING_ONLY` deliberately remains a separate debug mode and may apply
shoaling without a warp.

## Scope boundary

Visual coastal rendering and CPU physics are not yet equivalent:

```text
VISUAL COASTAL != PHYSICS QUERY COASTAL
```

`OceanQuery` still evaluates the original open-ocean LONG component.  Query
parity is intentionally deferred to the next task; therefore this change can
close the render coastal gate but cannot close the full physics Gate 3.

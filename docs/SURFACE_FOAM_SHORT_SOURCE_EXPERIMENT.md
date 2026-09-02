# Surface Foam source experiment: MAIN FFT SHORT

`OceanV3.perf_surface_foam_source_mode` is a reversible A/B selector under
**Performance Profiling**:

- `Legacy Auxiliary FFT` retains the independent 8 m TMA/JONSWAP Surface Foam
  spectrum and its packed J-only FFT.
- `Main FFT SHORT` uses the exact Jacobian stored in alpha by the main SHORT
  cascade (`256²`, `37 m` in the current sea-state configuration).

The SHORT option does not use the main surface shader's camera-distance fade:
that fade is applied only while rendering the visible SHORT contribution, after
sampling the texture. A compact compute adapter copies `displacement.a` into
the established R16 Jacobian contract. The existing temporal Surface Foam
field, birth/erosion/decay response, topology, mip chain, rendering and MID
history stay unchanged.

The SHORT source is periodic over its physical 37 m domain. This is a source
comparison, not a visual-quality claim: inspect for a possible 37 m repeating
motif in the Lab before treating it as a production replacement.

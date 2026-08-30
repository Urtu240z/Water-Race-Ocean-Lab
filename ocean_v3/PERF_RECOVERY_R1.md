# Ocean V3 Performance Recovery R1

## Production material ownership

`OceanClipmapSurface` owns one production surface material and one wireframe
material. Per-level LOD diagnostic materials are now created only when the
user explicitly enables LOD debug. They are duplicated from the fully
configured production material once, then receive their level override. Normal
updates never enumerate a shader property list or touch an inactive LOD cache.

The per-frame camera and coastal-time publications target surface materials
only. The wireframe material is not updated for values it does not consume.

## Breaking diagnostic shader variant

`ocean_surface.gdshader` is the production variant. The expensive Breaking
Steps 2–4 functions in `ocean_breaking_common.gdshaderinc` are compiled only
when `OCEAN_BREAKING_DIAGNOSTICS` is defined. The opt-in wrapper
`ocean_surface_debug.gdshader` defines that symbol and includes the shared
surface implementation; it therefore shares all ocean rendering math and
uniform declarations rather than maintaining a fork.

Modes `OPEN_BREAK` through `SEGMENT_COHERENCE` create a duplicate material
using that diagnostic variant on first use. `OFF` and the normal lab scene
continue to use the production variant.

## Startup and benchmark instrumentation

One-shot startup reports use `Time.get_ticks_usec()` in the FFT module,
clipmap surface, and root node. The root report stops after the third stable
process frame. The performance benchmark records P95 in addition to its
existing average, median, and P99 frame statistics.

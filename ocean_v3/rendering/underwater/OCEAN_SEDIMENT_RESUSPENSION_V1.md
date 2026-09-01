# Ocean V3 — Seabed Sediment / Resuspension V1

This subsystem is independent from the existing suspended-particle medium.

## Architecture

`OceanSedimentField` owns one persistent, world-anchored 256² R16F concentration
field. It uses a pair of ping-pong GPU images and a bounded 16-entry GPU
injection buffer. The compute pass samples a one-time GPU upload of the existing
`BathymetryData` depth/water mask; it does not query the CPU or read back GPU
data per frame.

The field evolves by backtraced advection, four-tap diffusion, bathymetric
shallow-water resuspension, bounded injections, and exponential settling. The
flow is a base current plus a low-frequency orbital wave term and broad slow
variation. Its simulation time advances deterministically from the render
delta, with a 20 Hz underwater rate and a 5 Hz AIR rate by default.

`OceanSedimentSystem` owns only presentation and scheduling. `SedimentClouds`
and `SedimentWisps` are separate world-space `GPUParticles3D` layers. Their
procedural materials sample the same field and disable visibility where the
concentration is negligible. The original `OceanUnderwaterParticles` node is
untouched.

## Above-water integration

`OceanClipmapSurface.set_sediment_field()` binds the same `Texture2DRD` to the
Ocean V3 surface material. The surface shader uses the concentration locally
inside the existing Beer-Lambert/transmission/scattering/turbidity/bathymetry
path: it adds bounded extinction, increases scattering density, applies a
subtle sediment tint, and suppresses transmitted seabed visibility. It does
not render underwater billboards through the transparent surface and does not
depend on transparent-object sorting.

The field remains resident and available when the camera is AIR. Only the 3D
cloud/wisp layers are disabled in AIR; the field continues at its reduced rate.

## Debug and validation API

The system exposes `inject_sediment(world_position, radius_m, strength)` and an
Inspector `Inject Test Sediment` action. Debug modes are OFF, FIELD, SOURCE,
CLOUDS, and WISPS. `get_debug_state()` reports resource identity, mapping,
dispatch count, pending injections, and particle counts without a GPU readback.

The intended manual persistence check is:

```text
inject a strong patch while UNDERWATER
-> observe SedimentClouds and SedimentWisps
-> move the camera above the water surface
-> the same world location becomes locally turbid through the Ocean V3 optics
-> return UNDERWATER
-> the patch remains at the same world position
```

This V1 fully implements the above-water integration and the clean GPU binding;
it is not a binding-only placeholder. AIR disables only the 3D presentation
layers. The field is neither cleared nor automatically stopped in AIR, and its
default AIR update rate is reduced to 5 Hz. The field simulation can therefore
be consumed by the surface shader while the camera is in AIR and resumes at
the same persistent state when returning UNDERWATER.

For reproducible frame-time measurements use
`res://ocean_v3/tests/performance/ocean_sediment_benchmark.tscn`. It runs:

```text
A_OFF
B_FIELD_ONLY
C_FIELD_CLOUDS
D_FIELD_CLOUDS_WISPS
```

Each result records average frame time, FPS, P95 frame time, CPU process time,
field dispatches, field resolution, update rate, and both particle counts.
GPU milliseconds are intentionally not reported because the benchmark avoids
GPU synchronization and readback.

No authored texture asset is required.

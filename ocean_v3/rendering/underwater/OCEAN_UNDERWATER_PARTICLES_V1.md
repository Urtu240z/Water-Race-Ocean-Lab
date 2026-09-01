# OceanUnderwaterParticles V1

`OceanUnderwaterParticles` is a camera-local presentation layer owned by
Ocean V3. It consumes only Ocean V3's existing binary camera state:

```text
AIR          -> emitting=false, visible=false
UNDERWATER   -> both GPU layers enabled
```

The component is independent of `lab/`, FFT, OceanQuery, bathymetry, water
height, physics, compositors, SubViewports, and compute shaders. It creates two
`GPUParticles3D` nodes with one-quad procedural spatial material each:

| layer | default amount | size range | role |
| --- | ---: | ---: | --- |
| Fine | 1000 | 0.005–0.025 m | quiet suspended atmosphere |
| Near | 140 | 0.020–0.070 m | stronger depth/parallax cue |

The particle process shader initializes positions in a 24×12×24 m volume and
combines per-particle drift, low-frequency vertical variation, a small current,
and bounded `-camera_velocity * velocity_influence`. Existing particles remain
in world space (`local_coords=false`) while only the emitter translation follows
the active camera. The component never calls `restart()`, so following the
camera does not reseed or reset the visible population each frame.

The draw shader is unshaded, transparent, billboarded in the vertex path, has
procedural soft irregular alpha, no texture dependency, no shadows, and near/far
distance fades. Its depth test remains available while it does not write depth.

## A/B/C measurement protocol

Use the same stationary underwater camera, resolution, seed, warm-up, and
measurement window for all cases:

```text
A  underwater_particles_enabled=false
B  enabled=true, set_benchmark_layers(true, false)
C  enabled=true, set_benchmark_layers(true, true)
```

Record average frame ms, FPS (`1000 / average_ms`), P95 frame ms, and CPU
process time. GPU milliseconds require an external synchronized GPU timer and
are not inferred from FPS. The target is an artistic budget of approximately
0.15–0.25 ms total GPU/frame impact.

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

The particle process shader initializes positions in a forward frustum starting
4 m in front of the camera and reaching 50 m by default, widening to 60 m at
the far end. It combines per-particle drift, low-frequency vertical variation, a small current,
and bounded `-camera_velocity * velocity_influence`. The random position is
emitter-local and is converted with Godot's `EMISSION_TRANSFORM` before it is
written to the world-space particle transform. Existing particles remain in
world space (`local_coords=false`) while only the emitter translation follows
the active camera. The component never calls `restart()`, so following the
camera does not reseed or reset the visible population each frame.

Both layers use native `GPUParticles3D.preprocess = 22 s` so the initial
underwater activation is already populated-looking instead of waiting for the
normal emission rate. The conservative visibility AABB is 36×20×36 m around
the moving emitter, covering the 24×12×24 m spawn volume plus drift margin.

The Inspector exposes artist-facing appearance controls under
`Underwater / Suspended Particles / Appearance`:

- `underwater_particles_fine_color` and `underwater_particles_near_color` set
  the tint of each layer.
- `underwater_particles_fine_amount` and `underwater_particles_near_amount`
  accept up to 10000 GPU particles per layer.
- `underwater_particles_fine_strength` and
  `underwater_particles_near_strength` control visibility up to 8x.
- `underwater_particles_fine_size_scale` and
  `underwater_particles_near_size_scale` enlarge or reduce the particle
  sprites without changing the GPU simulation or particle counts.
- `underwater_particles_lifetime_fade_seconds` controls the GPU fade-in and
  fade-out duration for each particle; the default is 2 seconds at both ends
  of its lifetime.

The spawn controls are also exposed in the Inspector: near/far distance,
near/far width and height, plus `underwater_particles_cull_distance_m` (72 m by
default). The emitter follows the camera position and orientation for new
emissions only. Existing particles remain in world space, and the particle
process shader marks them inactive once they are farther than the cull
distance, allowing the GPU emitter to recycle those slots.

`particles_position_debug` is a persistent developer switch. It enlarges and
brightens both layers, makes Fine/Near sizes visibly different, exposes
`get_position_diagnostic()` and `get_particle_debug_state()`, and prints one
position report on each AIR→UNDERWATER entry without per-frame logging.

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

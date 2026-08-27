# Ocean V3 planar reflection clipping investigation

Status: 2026-08-27, Godot 4.7 stable.

## Decision

**OBLIQUE CLIPPING: BLOCKED BY GODOT 4.7 PUBLIC RENDER API**

Reflection 2D keeps its shared `World3D`, mirrored `Camera3D`, `SubViewport`,
`UPDATE_ONCE` scheduler, and `RenderingServer.frame_post_draw` matrix/texture
synchronization. This checkpoint only extends the public overscan range to
`1.0..2.0`; the default remains `1.15`.

## APIs and engine source reviewed

- `Camera3D` documentation and Godot 4.7 source
  [`scene/3d/camera_3d.cpp`](https://github.com/godotengine/godot/blob/4.7-stable/scene/3d/camera_3d.cpp).
  `_get_camera_projection()` builds a `Projection` from the camera mode and
  viewport aspect. The public setters are perspective, orthogonal, and
  frustum; `get_camera_projection()` returns the generated projection and
  `get_camera_rid()` exposes the camera RID.
- `Projection` documentation:
  [`class_projection.html`](https://docs.godotengine.org/en/4.7/classes/class_projection.html).
  It supports construction and matrix operations as a value type, but does
  not provide a way to install an arbitrary projection into a `Camera3D`.
- `RenderingServer` documentation and Godot 4.7 source
  [`servers/rendering/rendering_server_default.h`](https://github.com/godotengine/godot/blob/4.7-stable/servers/rendering/rendering_server_default.h).
  The camera RID API contains `camera_set_perspective`,
  `camera_set_orthogonal`, `camera_set_frustum`, transform, cull mask,
  environment, and aspect calls. There is no `camera_set_projection` or
  camera clip-plane setter in 4.7.
- `RenderingServer` implementation
  [`servers/rendering/rendering_server.cpp`](https://github.com/godotengine/godot/blob/4.7-stable/servers/rendering/rendering_server.cpp)
  was checked for the bound camera methods, `frame_post_draw`, and
  `call_on_render_thread`. A render-thread callback does not add a public
  camera projection override; it only changes where code executes.
- The renderer scene interface
  [`servers/rendering/renderer_scene_render.h`](https://github.com/godotengine/godot/blob/4.7-stable/servers/rendering/renderer_scene_render.h)
  exposes compositor-effect plumbing, not a supported per-camera arbitrary
  projection or renderer-side user clip plane.
- `SubViewport` keeps the documented `UPDATE_ONCE` behavior:
  [`class_subviewport.html`](https://docs.godotengine.org/en/4.7/classes/class_subviewport.html).

## Oblique projection assessment

The required safe algorithm was reviewed: transform the authoritative
world-space plane from `_sea_plane_world_y()` into reflection-camera space,
apply the clip bias, then modify the correct projection row using Godot's
renderer convention. Godot Forward+ uses reverse-Z, and Vulkan NDC depth is
`0..1` rather than the old OpenGL `-1..1` range; this is documented in the
[internal rendering architecture](https://docs.godotengine.org/en/4.7/engine_details/architecture/internal_rendering_architecture.html)
and [spatial shader reference](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html).

That mathematics is not installed in runtime code because the final modified
`Projection` cannot be passed to the actual `Camera3D`/RID renderer path using
the supported Godot 4.7 API. A hand-written OpenGL-style matrix would risk
wrong reverse-Z depth, handedness, culling, and near/far behavior.

The authoritative sea plane remains the existing `_sea_plane_world_y()` datum;
no `Y = 0` assumption or clip bias was added. Therefore:

- oblique clipping: not implemented;
- clip bias control: not applicable, no `planar_reflection_clip_bias_m` added;
- discarded half-space: not applicable;
- current fallback: reflection cull mask for whole-object exclusions plus the
  existing `planar_reflection_max_distance_m` far-plane limit.

## Alternatives

| Alternative | Cuts a mesh crossing water | Materials | Duplicate geometry | Arbitrary GLB | Cost / complexity / risk |
|---|---:|---:|---:|---:|---|
| RenderingServer camera RID custom projection | No | No | No | Yes | Low apparent cost, but unavailable API; unsafe to fake |
| CompositorEffect/custom render path | Potentially, with renderer control | Usually no | No | Potentially yes | High / high / high; not a stock per-camera clip-plane hook |
| Reflection-specific geometry layers | No, only whole objects | No | No | Yes | Low / low / low; current safe fallback |
| Reflection proxy meshes above water | No for the original crossing mesh | No | Yes | No | Medium / medium / medium; asset authoring burden |
| Localized reflection material clip plane | Yes | Yes, participating materials | No | No, unless materials opt in | Medium-high / high / medium-high |
| Engine module/custom renderer extension | Yes | No | No | Yes | Very high / very high / high; only exact arbitrary-asset route |

Do not apply a global `discard` to all project materials, duplicate the world,
or toggle visibility around rendering. For the current public API, keep cull
layers for coarse exclusions. If exact clipping of arbitrary crossing GLB
meshes becomes a hard requirement, the concrete long-term route is a small
renderer/engine extension with an explicit per-camera clip-plane input; that is
outside this Ocean V3 checkpoint and should be benchmarked and isolated first.

## Compatibility notes

- Perspective overscan remains `2 * atan(tan(FOV / 2) * overscan)` with the
  existing radians/degrees conversion; orthographic/frustum behavior is
  unchanged.
- Overscan `1.0`, `1.5`, and `2.0` remains compatible with the existing
  scheduler and the actual reflection-camera projection.
- `frame_post_draw` synchronization is unchanged and remains the protected
  matrix/texture pairing mechanism.
- Reflection distortion, including the intended approximate `0.20` Lab value,
  is independent of this investigation.

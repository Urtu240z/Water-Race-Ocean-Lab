# Ocean V3 planar reflection clipping investigation

Status: 2026-08-27, custom Godot Water Race 4.7.2 integration.

## Decision

**TRUE OBLIQUE: AVAILABLE WITH THE CUSTOM GODOT WATER RACE ENGINE**

Reflection 2D keeps its shared `World3D`, mirrored `Camera3D`, `SubViewport`,
`UPDATE_ONCE` scheduler, and `RenderingServer.frame_post_draw` matrix/texture
synchronization. The production default remains mirrored perspective. Off-axis
frustum and true oblique are selectable LAB A/B/C modes; neither replaces the
default and neither requires changes to the shader.

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
- Custom Godot Water Race 4.7.2 (`2ff0e6450a24185ef9dbfcfd265ae5601304faa8`)
  adds `Camera3D.set_use_oblique_near_plane()`,
  `set_oblique_plane_normal()`, `set_oblique_plane_position()`, and
  `set_oblique_plane_offset()`, plus matching getters. Ocean V3 detects these
  methods dynamically so stock Godot remains loadable.
- The renderer scene interface
  [`servers/rendering/renderer_scene_render.h`](https://github.com/godotengine/godot/blob/4.7-stable/servers/rendering/renderer_scene_render.h)
  exposes compositor-effect plumbing, not a supported per-camera arbitrary
  projection or renderer-side user clip plane.
- `SubViewport` keeps the documented `UPDATE_ONCE` behavior:
  [`class_subviewport.html`](https://docs.godotengine.org/en/4.7/classes/class_subviewport.html).

## TRUE OBLIQUE — Custom Godot 4.7.2

The required safe algorithm was reviewed: transform the authoritative
world-space plane from `_sea_plane_world_y()` into reflection-camera space,
apply the clip bias, then modify the correct projection row using Godot's
renderer convention. Godot Forward+ uses reverse-Z, and Vulkan NDC depth is
`0..1` rather than the old OpenGL `-1..1` range; this is documented in the
[internal rendering architecture](https://docs.godotengine.org/en/4.7/engine_details/architecture/internal_rendering_architecture.html)
and [spatial shader reference](https://docs.godotengine.org/en/4.7/tutorials/shaders/shader_reference/spatial_shader.html).

The custom engine installs the oblique near plane in the actual camera
projection while retaining the regular perspective projection for lighting and
shadow culling. Ocean V3 therefore keeps the original mirrored perspective
camera transform, perspective FOV/overscan, near/far values, environment, and
cull mask, then configures the authoritative sea datum as the camera's
world-space oblique plane.

The capture matrix remains the direct
`reflection_camera.get_camera_projection() * Projection(reflection_camera.get_camera_transform().affine_inverse())`
value. With the custom engine, `get_camera_projection()` includes the oblique
projection that was used for the capture; no second matrix is constructed.

The authoritative sea plane remains the existing `_sea_plane_world_y()` datum;
no `Y = 0` assumption is made. Therefore:

- oblique clipping: implemented only when the custom Camera3D API is present;
- plane normal: `Vector3.UP`;
- plane position: `(main_camera.x, _sea_plane_world_y(), main_camera.z)`;
- clip bias: Ocean V3 passes `+planar_reflection_clip_bias_m`. The custom
  engine clips the camera side and keeps the opposite half-space; with the
  mirrored camera below the datum, this places the effective boundary slightly
  below the datum and prevents below-water geometry leakage;
- stock fallback: if any required method is absent, the requested mode falls
  back to mirrored perspective and the HUD reports
  `TRUE OBLIQUE (UNAVAILABLE -> PERSPECTIVE)`.

## Off-Axis Frustum Workaround

The LAB-only `Off-Axis Frustum` mode addresses the common horizontal sea-plane
case without pretending to provide arbitrary oblique clipping. When the main
camera is perspective and above the authoritative `_sea_plane_world_y()` datum,
the auxiliary camera uses the mirrored eye position, looks perpendicular to the
sea plane along `Vector3.UP`, and places its optical axis through the vertical
projection of the main-camera eye. Its tangential basis comes from the main
camera right vector projected onto XZ, with world right as a deterministic
fallback; no Euler angles are used.

The reflection footprint is derived from the four main-camera viewport corner
rays (`project_ray_origin()` / `project_ray_normal()`) intersected with the
horizontal sea plane. Invalid, upward-facing, or too-distant intersections are
made finite and projected onto the plane, then the rectangle is fitted to the
reflection viewport aspect, scaled by the public overscan range (`1.0..2.0`),
and clamped by `planar_reflection_max_distance_m`. The result is installed with
the supported `Camera3D.set_frustum()` API. In Godot 4.7, the frustum `size` is
the vertical extent when `flip_fov=false` and the horizontal extent is
`size * viewport_aspect`; the implementation therefore passes the final
near-rectangle height and does not use `KEEP_WIDTH` to reinterpret the
frustum. The near plane is based on the camera height minus
`planar_reflection_clip_bias_m`. The complete water-plane center and extents
are scaled by `z_near / height_m` before deriving `frustum_offset`, so the
offset is also expressed at the near plane. A projection sanity check maps
that final near-plane center to the viewport center; invalid values or
excessive `abs(offset) / size` ratios fall back before accepting the frustum.

This footprint construction is inspired by the older
[Godot Planar Reflection Plugin](https://github.com/SIsilicon/Godot-Planar-Reflection-Plugin/blob/master/addons/Silicon.vfx.planar_reflection/planar_reflector.gd),
but it is implemented against Godot 4.7's current `Camera3D` API and the
Ocean V3 distance/plane rules. The published shader matrix is still the actual
`reflection_camera.get_camera_projection() *
Projection(reflection_camera.get_camera_transform().affine_inverse())`,
published through the existing `frame_post_draw` synchronization.

This is not a true oblique projection or a renderer clip plane. It is limited to
perspective cameras and a horizontal water datum. It gives the reflection
camera a finite, water-plane-derived capture footprint, but it cannot exactly
discard arbitrary triangles that cross the sea plane; geometry crossing or
appearing outside the fitted frustum may still require asset/layer handling.
Orthographic and custom-frustum main cameras, cameras at/below the water, and
invalid ray footprints use the safe mirrored fallback. K in the Ocean Lab cycles
the three modes and the HUD reports the active mode, engine availability, and
clip-bias value.

## Alternatives

| Alternative | Cuts a mesh crossing water | Materials | Duplicate geometry | Arbitrary GLB | Cost / complexity / risk |
|---|---:|---:|---:|---:|---|
| RenderingServer camera RID custom projection | No | No | No | Yes | Low apparent cost, but unavailable API; unsafe to fake |
| Custom Camera3D oblique near plane | Yes | No | No | Yes | Available only in the pinned Water Race engine |
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
  existing radians/degrees conversion in mirrored perspective mode. Off-axis
  mode uses the ray-derived frustum footprint instead; orthographic/frustum
  behavior remains on the safe mirrored fallback.
- Overscan `1.0`, `1.5`, and `2.0` remains compatible with the existing
  scheduler and the actual reflection-camera projection. Off-axis overscan is
  applied to the fitted footprint and is independently clamped by maximum
  distance.
- `frame_post_draw` synchronization is unchanged and remains the protected
  matrix/texture pairing mechanism.
- The off-axis mode is selectable through
  `planar_reflection_projection_mode` and defaults to `Mirrored Perspective`;
  it is an experiment, not a production default.
- Reflection distortion, including the intended approximate `0.20` Lab value,
  is independent of this investigation.

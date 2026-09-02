# Ocean V3 — Sunrays V3 and Sediment V2 Hotfix

## Sunrays V3

The underwater compositor no longer binds or samples the caustics texture for
sunrays. It keeps the existing four-tap, per-tap light-entry, Beer–Lambert and
Henyey–Greenstein integration architecture, but the per-tap beam field is now
procedural in light space.

For `L = normalize(light_into_water)`, the shader selects a nonparallel
reference axis and constructs `U = normalize(cross(reference, L))` and
`V = normalize(cross(L, U))`. Every tap uses
`beam_coord = vec2(dot(P, U), dot(P, V))`. Therefore `P + L * d` retains the
same beam coordinate: field geometry is world anchored and extruded in the
physical light direction, not in camera or screen space.

The procedural field combines meter-space ridges with approximately 8.7 m,
2.9 m, and 1.8 m spacing, plus a very slow transverse warp. Animation defaults
to zero; no coordinate translation is performed. `SUNRAYS_BEAM_COORD` exposes
the transverse coordinate and `SUNRAYS_BEAM_FIELD` exposes its shaped ridge
field. Existing vector, tap-validity, depth, integral, final, and exaggerated
diagnostics remain available.

Sunrays V3.1 integrates only the intervals where a camera ray crosses fixed
14 m light-space slabs. A slab is identified by
`floor(dot(P, light_into_water) / 14 m)` and therefore cannot move with the
camera. Each of the at-most-four samples is the midpoint of one ray/slab
overlap and is weighted by that overlap length. Adjacent slab intervals meet
with zero length at their boundary, so their contribution transitions
continuously instead of popping. `SUNRAYS_WORLD_SLICE_ID` visualizes the
weighted slab identity.

## Sunrays V3.2 — wave-driven life

The compositor does not bind an Ocean V3 FFT/slope texture, so V3.2 uses a
cheap coherent procedural surface proxy instead of adding an FFT sampling path.
It combines three low-frequency wave terms evaluated only from `light_entry.xz`
and `SimulationClock` render time. Thus the surface-response phase is world
anchored and differs naturally between shafts; it has no camera, screen-UV, or
tap-index phase input.

The stable light-space beam coordinate and world-slice ID remain unchanged.
The proxy only modulates per-slice energy (default 0.65–1.35 near the surface)
and ridge exponents for width (default 0.90–1.10), with both effects fading
smoothly to zero over the default 15 m depth envelope. V3.2A separates the
living-wave clock from the earlier sunray control: use
`underwater_sunrays_wave_animation_speed` (default 1.5, configurable through
10.0) for its rate and
`underwater_sunrays_wave_freeze` for an explicit static world-space debug
state. The `SUNRAYS_WAVE_FOCUS`, `SUNRAYS_WAVE_WIDTH`, and
`SUNRAYS_WAVE_MODULATION` diagnostics expose the three resulting signals;
`SUNRAYS_WAVE_EXAGGERATED` uses 1.0 intensity strength, 0.40 width strength,
and no practical depth fade to make the plumbing unambiguous.

## Sunrays V3.3 — light-direction invariant

`DirectionalLight3D.global_transform.basis.z` is the world-space direction
from water toward the sun. Physical photon travel is always `light_into_water
= -basis.z`. Each reconstructed `light_entry` is formed by tracing from a
sample toward the surface (`-light_into_water`), and every sample verifies that
`normalize(sample_point - light_entry)` aligns with `light_into_water` by at
least 0.99 before it contributes. `SUNRAYS_DIRECTION_ALIGNMENT` exposes this
invariant (green is +1), while `SUNRAYS_LIGHT_TRAVEL_VECTOR` encodes the
physical into-water vector. The light transform itself is never modified by
these diagnostics.

## Sunrays V3.4 — independent world-space direction proof

`underwater_sunrays_direction_proof_enabled` creates ordinary scene geometry
outside the compositor: a yellow origin at the sea surface near the active
camera, a 30 m green cylinder along `-DirectionalLight3D.basis.z`, and a red
cylinder along `+DirectionalLight3D.basis.z`. These are sampled directly from
the live light transform and deliberately do not read `light_entry`, slabs,
beam coordinates, or shader parameters. The one-shot runtime log prints all
three vectors whenever the light direction changes.

`underwater_sunrays_phase_debug_constant` is an explicit A/B diagnostic. When
enabled it forces the sunray phase response to one, leaving geometry, slab
selection, attenuation, and all normal settings unchanged; its default is off.
The beam field is axial: its U/V coordinate is transverse to
`light_into_water`, so `B(P + light_into_water*d)` equals
`B(P - light_into_water*d)` and cannot itself encode photon travel direction.

The final integration intentionally has no camera-ray depth build-up. Its
former `1 - exp(-density * sunray_segment_m)` gain followed `view_ray_world`
and could make an axial beam read as travelling opposite to the independent
green reference. Directional appearance is now governed only by each slice's
Beer-Lambert transport from `light_entry` into the water along
`light_into_water`.

The independent guide separated a visual direction issue from camera-ray
reconstruction. `get_view_projection()` already includes Godot's backend
depth/Y correction, so `reconstruct_world()` maps the current color UV directly
with `uv * 2 - 1`; it does not mirror NDC Y. This keeps pitch changes as normal
projection changes rather than rebuilding world slabs around a reflected ray.
`SUNRAYS_RECONSTRUCTED_WORLD` and `SUNRAYS_VIEW_RAY` expose the two inputs for
fixed-position pitch diagnosis. Scene-depth texel orientation remains separate
from NDC orientation and is currently read without a flip.

## Sunrays V3.6 — single physical light authority

The underwater UBO receives `params.light.xyz` directly as `L =
light_into_water = -DirectionalLight3D.basis.z`. `L` means photon travel from
sun to water everywhere: beam basis, world-slab coordinate and slice interval
all use `L` directly (the world-slab coordinate is retained only for the
legacy A/B mode). Only light-entry reconstruction declares the local
opposite `toward_surface = -L`. HG explicitly uses `L` as incoming light and
the sample-to-camera vector as outgoing direction. No shader path receives an
ambiguous `sun_direction` or negates a `params.sun` vector.

## Sunrays V3.7 — transverse world-space quadrature

Production sunrays now sample a maximum of four deterministic intersections
with fixed world planes `dot(P, A) = k * 3.2 m`, where `A` is the dominant
transverse axis (`U` or `V`) from one shared `build_light_basis(L)` helper.
The basis is orthonormal to the physical photon travel vector `L`, so moving
along `L` leaves `beam_coord(P)` invariant. Near the U/V dominance boundary,
two samples per axis are blended smoothly; away from it, four samples use the
dominant axis. Sample weights are local Voronoi intervals and wave/Beer-Lambert
evaluation still occurs at the exact world-plane point. The legacy 14 m
longitudinal slabs remain available only through
`SUNRAYS_LEGACY_LONGITUDINAL_SLABS`; `SUNRAYS_TRANSVERSE_LATTICE` is the
production A/B mode. New diagnostics expose axis choice, lattice identity,
blend, and world-anchored sample points.

## Sunrays V3.7A — continuous transverse sample sets

The transverse selector no longer derives a subset from segment `first/last`
IDs. It anchors four consecutive IDs to a continuous world coordinate at the
segment reference point (`base_id = floor(coord / 3.2 m)`) and uses cubic
B-spline weights that sum to one as the fractional coordinate crosses lattice
boundaries. Samples outside the finite segment are retained as slots and enter
or leave through smooth endpoint gates; their intersections are clamped only
for the harmless zero-weight evaluation. U/V dominance is now correctly
mapped (`u_mix = u_blend`, `v_mix = 1-u_blend`). Modes 39–41 expose sample-set
ID, four continuous weights (RGB plus alpha), and effective sample count.

## Sunrays V3.7B — analytic surface segment

Sunray integration no longer inherits the OceanClipmap surface depth for rays
that point upward from an underwater camera. Those pixels use the analytic
intersection with the flat `sea_level` plane, capped by the configured maximum
distance. Rays pointing downward continue to use scene depth so seabed and
geometry still clip the volume. The same analytic path is applied to the
upward medium path, preventing the clipmap's below-sea-level wave vertices
from reintroducing a rectangular transmittance region before sunray limiting.
The camera ray used for this classification comes from the inverse projection
at the pixel, never from the clipmap's depth point, so a surface triangle cannot
rotate or facet the analytic test.
Mode 42 reports the selected source (green
analytic plane, red scene depth, blue max distance); modes 43 and 44 provide
explicit depth-driven and analytic A/B paths.

## Sunrays V3.8 — explicit segment authority

`underwater_sunrays_segment_mode` is now the production switch: `0` keeps the
old depth-driven path for A/B comparison, while `1` (default) uses the analytic
flat sea-plane intersection for the upper bound and scene depth only for rays
that continue into lower geometry. The selected mode is carried in the
underwater UBO, so the OceanClipmap depth cannot silently become the sunray
ceiling. Debug modes 42–44 remain available for source visualization and
explicit overrides.

`SUNRAYS_SEGMENT_LENGTH` (mode 46) exposes the selected segment length
normalized by the configured maximum, making any remaining spatial step or
patch directly inspectable without changing the beam field.


## Sediment V2 test path

Sediment source remains a continuous, delta-time-scaled rate. Queued test
injections are concentration impulses and are deliberately not scaled by
delta-time. The diagnostic action chooses a valid water/seabed cell within
20 m, preferring one about 8 m ahead of the camera, queues a 9 m / 0.90
impulse, validates field and bathymetry constraints, and may be repeated.

The test action prints deterministic field-center proxy information without a
GPU readback and shows a temporary orange world-space marker for six seconds.
This separates target/field injection diagnosis from the particle cloud and
wisp render paths while preserving the persistent GPU simulation and its
world-space field.

## Sediment V2.1 — POST_TRANSPARENT optical compensation

The underwater medium runs after transparent particles and multiplies the
resolved pixel by the transmittance of the scene depth behind them. The
sediment shader therefore computes `T_particle = exp(-absorption_rgb *
absorption_scale * camera_to_particle_water_path)` and `T_background` from the
same screen depth used by the medium. It writes
`particle_color * clamp(T_particle / max(T_background, 0.02), 0,
compensation_max)`. The compositor then applies `T_background`, leaving the
particle contribution approximately at `T_particle` instead of
`T_particle * T_background`. Alpha, background color and scattering are not
compensated. `SEDIMENT OPTICAL COMPENSATION OFF/ON` provide the A/B; the
`SEDIMENT OPTICS ...` and depth modes expose the intermediate values. Medium
debug mode `UNDERWATER MEDIUM TRANSMITTANCE BYPASS` disables only the
compositor's background transmittance for the root-cause test; scattering and
sunrays remain active.

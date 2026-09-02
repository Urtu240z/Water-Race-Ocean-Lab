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
from water toward the sun. The compositor receives that vector as
`toward_sun`; physical photon travel is always `light_into_water =
-toward_sun`. Each reconstructed `light_entry` is formed by tracing from a
sample toward `toward_sun`, and every sample now verifies that
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

The independent guide also exposed the compositor's actual orientation fault:
the render-target V coordinate was passed to the camera inverse projection as
if it were NDC Y. `reconstruct_world()` now converts it with `1 - 2*uv.y`.
This restores the same vertical convention as the live scene geometry before
any light-space field, slab, entry, or attenuation calculation is performed.


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

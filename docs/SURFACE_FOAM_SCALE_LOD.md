# Surface Foam: scale, distance and microdetail

The production Surface Foam route is the dedicated `surface_foam_spectrum_solver.gd`.
It keeps its persistent R16F history, temporal J interpolation, 30 Hz scheduler,
birth attack, lifetime, selectivity, evolution speed, ocean coupling and edge
controls from the previous phase.

## Spectral scale

`surface_foam_domain_m` is 88 m in production (64 m is an A/B value). The
presentation-only `surface_foam_max_feature_wavelength_m` applies a one-octave
soft high-pass to the dedicated Surface Foam H0:

```text
k_cut = 2*pi / max_feature_wavelength_m
feature_weight = smoothstep(0.5*k_cut, k_cut, |k|)
amplitude *= sqrt(feature_weight)
```

The JONSWAP/TMA spectrum, physical displacement spectra and crest foam are not
changed by this control. Sea-state wind presets are 6, 10 and 20 m/s for CALM,
RACE and ROUGH; Amount, Selectivity and Lifetime remain independent controls.

## Shading LOD

The shader samples the persistent history once and uses an independent Surface
Foam distance fade (200–600 m by default). Near is 0–45 m with coarse and fine
micro samples; Mid is 45–150 m with one coarse RG sample; Far is beyond 150 m
with history and scalar shaping only. J interpolation is skipped in Far.

The RGBA8 tile `surface_foam_micro_detail.png` is deterministic and tileable:
R is organic breakup and G is a bubble distance-like field. Near uses at most
two RG samples, Mid one, and Far none. `fwidth` provides boundary AA and G's
derivatives provide the subtle bubble normal without a third fetch. All visible
coverage remains multiplied by the physical persistent mask.

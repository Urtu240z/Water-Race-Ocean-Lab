# Surface Foam: scale, distance and microdetail

The production Surface Foam route is the dedicated `surface_foam_spectrum_solver.gd`.
It keeps its persistent R16F history, temporal J interpolation, 30 Hz scheduler,
birth attack, lifetime, selectivity, evolution speed, ocean coupling and edge
controls from the previous phase.

## Spectral scale

`surface_foam_domain_m` is the real FFT period and remains 88 m in production.
`surface_foam_feature_domain_m` is a virtual spectral scale (4-32 m, default
8 m). It changes feature density without changing the real output tile or its
periodicity. The remap is:

```text
compression = max(real_domain / feature_domain, 1)
k_out = FFT grid vector, dk_out = 2*pi / real_domain
k_eval = k_out / compression
dk_eval = dk_out / compression
w_norm = domega_dk(k_eval) / |k_eval| * dk_eval^2
amplitude = sqrt(2*TMA(k_eval)*D(k_eval, direction)*w_norm)
```

There is no artistic high-pass, target Hs, band-pass or second FFT. Temporal
dispersion uses `k_eval`, while Jacobian derivatives use `k_out`, preserving the
real 88 m periodicity. The JONSWAP/TMA spectrum, physical displacement spectra
and crest foam are not changed by this control. Sea-state wind presets are 6,
10 and 20 m/s for CALM, RACE and ROUGH; Amount, Selectivity and Lifetime remain
independent controls.

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

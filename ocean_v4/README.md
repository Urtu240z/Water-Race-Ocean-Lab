# Ocean V4 — Phase 0

Ocean V4 is a clean parallel foundation for Water Race. Its scene is `OceanV4`
with two children: `OpenOceanFFT` and `OceanClipmapSurface`.

`OpenOceanFFTV4` builds deterministic LONG, MID and SHORT JONSWAP/Hasselmann
H0 fields and evolves each with an inverse Stockham FFT. It publishes one
displacement map and one physical-normal map for every band.

`OceanClipmapSurfaceV4` builds camera-snapped concentric mesh levels and gives
the V4 base shader only those maps plus simple base-water material settings.

Phase 0 is open ocean only. Coastal deformation, foam, reflections,
refraction, optics and breakers are deliberately absent. Instance
`res://ocean_v4/ocean_v4.tscn` and assign a camera (or place it in the Lab,
where it discovers `lab_camera`).

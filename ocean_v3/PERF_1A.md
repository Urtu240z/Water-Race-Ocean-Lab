# Ocean V3 — PERF-1A

## Alcance

PERF-1A añade instrumentación y puertas de trabajo para medir el coste marginal
de Ocean V3. No cambia resoluciones, algoritmos ni calidad authored en `FULL`.

## Puntos de trabajo

- `perf_enable_spectral`: evita los cuatro dispatches de cascada FFT por frame y
  activa el camino geométrico plano del shader; no libera recursos.
- `perf_enable_coastal`: desactiva la composición costera runtime (warp,
  shoaling, campos de batimetría y estabilización de orilla) mediante uniforms.
  Los bakes residentes no se destruyen.
- `perf_enable_crest_foam_solver`: evita las actualizaciones de crest foam que
  forman parte de los dispatches de cada cascada.
- `perf_enable_surface_foam_solver`: evita el avance del solver Surface Foam y
  MID Fold History. Implica una salida neutral para su render.
- `perf_enable_surface_foam_render`: evita los muestreos y la composición
  visual de Surface Foam; no detiene el solver si éste sigue habilitado.
- `perf_enable_prebreak`: evita los fetches extra del campo PREBREAK en el
  vertex shader cuando el modo de breaking debug está activo.
- `perf_enable_breakers`: desactiva el scheduler/detector CPU y la geometría de
  ribbons; al cambiar a OFF el pool se limpia de forma controlada.
- `perf_enable_sspr`: desactiva el `CompositorEffect` SSPR y su cadena de
  compute; la reflexión PBR/fallback sigue disponible.
- `perf_enable_refraction`: evita el muestreo screen-space de refracción; la
  transparencia y el resto de Water Optics permanecen activos.

## Dependencias

`BASE` conserva la superficie espectral válida y desactiva Coastal, foam,
PREBREAK, breakers, SSPR y refracción. Surface Foam Solver depende de Spectral;
Breakers dependen de Spectral + Coastal. Si el solver de Surface Foam está OFF,
Surface Foam Render se fuerza a una salida neutral aunque su propio flag siga ON.

Los switches son seguros para cambiar en runtime. Se conservan los RIDs y los
recursos persistentes; sólo se cambian dispatches, uniforms y la visibilidad
controlada del pool de breakers. No se añade timing GPU inventado: el overlay
usa FPS, frame ms, `TIME_PROCESS` y `TIME_PHYSICS_PROCESS` de Godot.

## Presets

`apply_performance_preset()` acepta `FULL`, `BASE`, `NO_SSPR`, `NO_FOAM`,
`NO_COASTAL` y `NO_BREAKERS`. El overlay es opcional (`perf_overlay_enabled`)
y comienza apagado para no afectar escenas existentes.

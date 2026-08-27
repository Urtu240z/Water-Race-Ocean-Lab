# Ocean Lab — Fase 1B: océano espectral multibanda

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

Fase 1B mantiene un único módulo `open_ocean_fft` y compone internamente tres cascadas Tessendorf/Stockham independientes. No añade clipmap, horizonte, costa, batimetría, espuma, whitecaps, perturbaciones, jetski, óptica ni presets finales.

## Arquitectura

```text
OpenOceanFFTModule
 ├─ LONG  → GPUStockhamFFT
 ├─ MID   → GPUStockhamFFT
 └─ SHORT → GPUStockhamFFT
```

`GPUStockhamFFT` continúa siendo el worker de una única cascada: evolución física, 2D Stockham IFFT y ensamblado. Se instancian tres workers persistentes; no existe código FFT duplicado. Los recursos se nombran `Ocean1B.LONG.*`, `Ocean1B.MID.*` y `Ocean1B.SHORT.*` para su inspección en RenderDoc.

| Banda | Resolución | Dominio | Rango de longitud de onda | Hs objetivo | Hs CPU estimado | Choppiness |
|---|---:|---:|---:|---:|---:|---:|
| LONG | 256² | 512 m | 16–128 m | 0,500 m | 0,500 m | 0,75 |
| MID | 256² | 128 m | 4–20 m | 0,380 m | 0,380 m | 1,00 |
| SHORT | 256² | 32 m | 0,5–5 m | 0,150 m | 0,150 m | 0,90 |

Las direcciones iniciales son respectivamente `(1, 0,15)`, `(1, 0,30)` y `(1, 0,45)`, normalizadas. La Hs combinada esperada por suma de varianzas es `sqrt(0,50² + 0,38² + 0,15²) = 0,646 m`.

## H0, semillas y band-pass

Cada H0 aplica Phillips direccional y una ventana suave por longitud de onda: `smoothstep` al entrar y salir de cada banda, usando una anchura de transición de 4,0 m (LONG), 0,75 m (MID) y 0,15 m (SHORT). La ventana evita cortes duros y limita el solapamiento. Para la seed global `20260820`, la energía fuera del rango nominal medida durante la construcción fue LONG 0,120 %, MID 0,242 % y SHORT 0,281 %.

Tras formar y filtrar H0, se estima su Hs a tiempo cero por Parseval con la misma normalización de IFFT. H0 se escala una vez por `target_hs / measured_hs`; nunca se normaliza por frame. Un objetivo Hs de cero crea H0 completamente nulo.

La seed de cada banda se obtiene de un hash estable de `simulation_seed` e ID (`LONG`, `MID`, `SHORT`), no de un RNG global ni de la posición en un array. Por ello reordenar cascadas no altera ninguna de ellas.

## Render y tiempo

La superficie finita de instrumentación ahora mide 256×256 m con 256×256 vértices. Cada mapa se consulta con `world_xz / domain_size_m` y wrapping periódico propios. El desplazamiento final suma `Dx`, `Y` y `Dz` de las bandas activas.

Las normales no se suman directamente: el material recupera la pendiente de cada normal (`-N.xz / max(N.y, epsilon)`), suma pendientes y reconstruye una sola normal. Cada worker conserva además las normales derivadas de su desplazamiento completo, por lo que no se introduce ruido de normal ni una FFT adicional.

Las tres cascadas reciben exactamente `SimulationClock.get_render_time()`. Pausa, reset y escala temporal afectan al mismo reloj; no hay multiplicadores visuales de tiempo por banda.

## Recursos y coste de referencia

Cada cascada conserva H0, cuatro ping-pong RGBA32F, displacement RGBA32F y normal RGBA16F. La asignación nominal es 6,50 MiB por cascada, aproximadamente 19,50 MiB para tres, sin metadatos ni pipelines. Cada cascada 256² realiza 18 dispatches: 54 dispatches por actualización cuando está en `ALL`. No hay `rd.sync()`, readback, `texture_get_data()` ni reallocations por frame.

## Controles y validación

- `B`: `ALL → LONG → MID → SHORT → ALL`. Las bandas no visibles dejan de hacer dispatch; al volver a `ALL` se evalúan directamente en el tiempo absoluto actual.
- `O`: activa/desactiva el módulo completo y, por tanto, los tres workers.
- `V`: conserva las vistas de displacement, altura, normales y wireframe de Fase 1A.

`tests/phase_1b_validation.gd` valida determinismo multibanda, independencia, seed estable al reordenar, band-pass, Hs individual y combinada, objetivos cero, reloj común y que el aislamiento visual no muta H0. Se ejecutó con Godot 4.7.1 en modo headless y pasó. La carga de escena headless también terminó sin errores de parser, shader o RenderingDevice. La captura diagnóstica headless de 180+180 frames dio 133,53 FPS / 57,267 ms de proceso con FFT ON y 131,95 FPS / 67,798 ms OFF; ambos tuvieron 0 draw calls/primitivas por ser headless, así que no son una medición de rendimiento gráfico ni GPU. No se realizó benchmark profundo en esta fase.

## Limitaciones conocidas

- La superficie finita no resuelve horizonte ni LOD; corresponde a Fase 1C.
- La malla tiene 1 m de separación: la parte de 0,5 m de SHORT no puede representarse geométricamente de forma fiable en toda la superficie. Se conserva para inspeccionar el sistema espectral; no se aumenta densidad antes del clipmap.
- Las bandas usan una separación suave, no una partition of unity complementaria perfecta.
- No hay consulta CPU de altura ni validación GPU byte a byte.

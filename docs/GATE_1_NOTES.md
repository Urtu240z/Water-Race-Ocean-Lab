# Gate 1 — Cierre formal

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

## Estado

**Gate 1 APROBADO** por inspección visual del usuario (Fase 1 completada).

La validación visual humana confirmó:

- CALM/RACE/ROUGH son claramente distintos;
- LONG existe y muestra swell de baja pendiente;
- RACE mantiene estructura de frentes;
- ROUGH muestra crestas más comprimidas;
- clipmap sin grietas estáticas evidentes;
- la periodicidad combinada 512/137/37 ya no se realinea cada 512 m;
- rendimiento con amplio margen;
- la base es suficientemente buena para continuar.

## Descubrimiento: signo de lambda en el desplazamiento horizontal

Durante la inspección se descubrió visualmente que el signo del desplazamiento
horizontal Tessendorf estaba invertido en `ocean_v3/rendering/fft/shaders/evolve_spectrum.glsl`.

**Antes:** `dx = minus_i_h * (k.x / k_length) * params.values.z;`

**Formalizado en 2A:**

```glsl
float lambda = -params.values.z;
// Config choppiness is positive; Tessendorf horizontal displacement uses
// negative lambda so crests compress instead of valleys.
dx = minus_i_h * (k.x / k_length) * lambda;
dz = minus_i_h * (k.y / k_length) * lambda;
```

### Por qué la configuración sigue siendo positiva

`choppiness` en `OpenOceanFFTConfig` es un parámetro público de configuración
(0–1.5) y **permanece positivo**. La convención física de Tessendorf aplica
lambda NEGATIVA internamente para que el desplazamiento horizontal comprima
las crestas (en lugar de comprimir los valles). Invertirlo era el bug visual:
las crestas se ensanchaban y los valles se apretaban.

La configuración ahora **exige `choppiness >= 0`** en `is_valid()`; no se usa
`-abs()` para esconder configuraciones inválidas. El shader aplica
`lambda = -choppiness` explícitamente con comentario.

Un regression check en `tests/phase_2a_validation.gd` verifica que el shader
contiene la forma formalizada y no reintroduce el signo positivo ni el inline
temporal negativo. El test analítico de una sola onda (F/G) además detecta el
signo por física: con lambda negativa, en una pendiente creciente el agua fluye
hacia la cresta.

## Hs intacta

El cambio de signo no altera Hs: `target_hs_m` normaliza la amplitud por
Parseval y la magnitud de los desplazamientos horizontales depende de
`|choppiness|`, no de su signo. CALM ≈ 0.222 m, RACE ≈ 0.646 m, ROUGH ≈ 1.111 m
(sin cambios).

## No existe breaking todavía

El overturning/breaking es geometría local de fases posteriores (Fase 4). Este
Gate no introduce espuma, whitecaps ni rompientes; el océano base es un
heightfield FFT con compresión de crestas correcta.

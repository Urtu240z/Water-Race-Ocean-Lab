# Phase 4A — Breaking detection / pre-break field

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

**Estado:** PASS técnico (Windows / D3D12). Sin push.

## Alcance cerrado

Esta fase sólo añade un campo de diagnóstico GPU de pre-break. No crea geometría overturning, pools de breakers, espuma, whitewater, spray, entidades persistentes ni readbacks GPU→CPU. OceanQuery no participa en esta detección.

El campo se activa con `OpenOceanFFT.set_breaking_debug(mode)` y está apagado por defecto. `B` en `lab/coastal/phase_3b_2b_fft_demo.tscn` cicla:

| Valor | Campo |
|---:|---|
| 0 | OFF |
| 1 | DEPTH |
| 2 | STEEPNESS |
| 3 | CRESTNESS |
| 4 | PREBREAK |

El seabed overlay existente (`J`) se conserva. `P` pausa `SimulationClock` y `V` alterna top/grazing.

## Datos y fórmula

La ruta de cresta samplea **solamente** la macroestructura LONG real:

`LONG_COASTAL(world -> deep warp, confidence, shoaling) + LONG_REMAINDER(world)`.

MID/SHORT no entran en ningún índice de 4A y no pueden disparar el detector.

`Hs_LONG_local` es una proxy de energía, no `eta` instantánea:

```text
Hs_LONG_local = Hs_LONG_deep * sqrt((1 - f_coastal) + f_coastal * shoaling²)
a_long = Hs_LONG_local / 2
```

`Hs_LONG_deep` procede del `target_hs_m` del LONG del sea state. `f_coastal` procede de la fracción positiva de varianza reconstruida de `LONG_COASTAL` en el split H0. Es una aproximación inicial documentada: expresa energía esperada del mar LONG local y evita tratar la altura instantánea de una cresta como altura completa de ola.

Los índices continuos son:

```text
depth_pressure     = smoothstep(0.55, 1.00, Hs_LONG_local / (0.78 * depth))
k_local            = mix(k_deep, k_coastal, f_coastal * warp_confidence)
steepness_pressure = smoothstep(0.28, 0.42, k_local * a_long)
crestness          = rise(eta0 - eta-, eta0 - eta+) * curvature(2*eta0 - eta- - eta+)
prebreak           = crestness * depth_pressure * mix(0.35, 1.0, steepness_pressure)
```

Para `crestness`, `eta-`, `eta0`, y `eta+` se toman del FFT LONG real en la dirección de propagación eikonal local. La separación es `lambda_local / 16`, acotada a 0.25–2.0 m. El máximo local y la curvatura hacia abajo se suavizan; no hay un booleano de cresta ni una clasificación persistente.

Los rangos configurables están visibles en `ocean_surface.gdshader`: gamma 0.78 como referencia física inicial, zona crítica `ka` 0.28–0.42, y umbral de profundidad expresado como proporción de `H/(gamma*h)`. Ninguno es un umbral binario oculto.

En 4A la profundidad sigue siendo condición necesaria: una ola LONG muy empinada de mar profundo puede mostrar steepness, pero no se convierte en whitecap/pre-break. Esto respeta el alcance de rompiente costera y evita colorear una gran región de mar profundo.

## Determinismo, coste y datos para 4B

El shader usa sólo textura FFT, datos horneados y `SimulationClock`; no contiene estado temporal. Con el reloj pausado, los samples y por tanto los cuatro índices no cambian al mover cámara. No se añadió histéresis: el producto continuo ya evita ON/OFF binario y todavía no existen entidades de breaker.

La evaluación extra se ejecuta bajo `breaking_debug_mode > 0`; con OFF no se evalúan los samples vecinos. No hay compute global ni coste permanente en el path normal.

El mismo punto de shader ya permite derivar para 4B: posición world de cresta, dirección local, tangente (`perpendicular(direction)`), lambda, profundidad, potencial y una futura hint spilling/plunging. Esta fase no materializa dichos datos en una textura/pool porque no hay consumidor 4B aún.

## Medición

Windows, Godot 4.7.1, D3D12 Forward+, RTX 4070 Laptop, ventana 1920×1080 y buffer 3D forzado a 1.0, RACE / banco actual:

| Modo | Mediana frame | P95 frame |
|---|---:|---:|
| BREAK DEBUG OFF | 1.337 ms | 1.844 ms |
| PREBREAK | 1.286 ms | 1.361 ms |
| Diferencia | -0.051 ms | -0.483 ms |

La diferencia negativa está dentro de la variación normal de esta medición. Es frame time presentado (CPU+GPU), no un timestamp GPU aislado; por tanto no atribuye falsamente la diferencia sólo a GPU. No se observa una regresión cercana al guardrail de +0.5 ms; antes de cerrar una optimización futura se debe repetir con GPU profiler en el hardware objetivo, incluido Steam Deck.

El benchmark reproducible es `lab/benchmark/phase_4a_prebreak_benchmark.tscn`.

## Validación realizada

`tests/phase_4a_prebreak_validation.gd` pasa y comprueba:

- el contrato de shader usa LONG_COASTAL + LONG_REMAINDER, warp/shoaling, dirección local y lambda/16;
- flat deep: depth pressure y prebreak ~0;
- bank: suben depth y steepness, pero sólo la cresta tiene prebreak;
- valle y hombro no se convierten en cresta;
- las mismas entradas producen exactamente el mismo valor tras pausa/movimiento de cámara.

El shader compiló y ejecutó sin crash en D3D12 Forward+. La inspección visual manual sigue disponible con la demo: B=1..4, J, P y V; no altera Phase 3B.

## Archivos

- `ocean_v3/rendering/shaders/ocean_surface.gdshader`
- `ocean_v3/rendering/ocean_clipmap_surface.gd`
- `ocean_v3/open_ocean_fft_module.gd`
- `lab/coastal/phase_3b_2b_fft_demo.gd`
- `lab/benchmark/phase_4a_prebreak_benchmark.gd`
- `lab/benchmark/phase_4a_prebreak_benchmark.tscn`
- `tests/phase_4a_prebreak_validation.gd`

Siguiente acción aprobada: **Phase 4B — Local breaker geometry takeover**.

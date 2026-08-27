# Ocean Lab — Fase 1A: núcleo espectral de mar abierto

> **Historical implementation record.** Some architecture/details may have evolved. See [current architecture](OCEAN_V3_ARCHITECTURE.md) and [usage/integration documentation](OCEAN_V3_USAGE_GUIDE.md) for production use.

## Estado y alcance

Fase 1A implementa una sola cascada Tessendorf/FFT GPU sobre una malla finita. No contiene cascadas adicionales, clipmap, horizonte, costa, espuma, whitecaps, óptica, interacción ni física del jetski.

El módulo se registra como `open_ocean_fft`. `O` lo activa/desactiva; al desactivarlo deja de enviar compute y oculta la superficie para comparar con el laboratorio base. `V` recorre desplazamiento completo, sólo altura, normals y wireframe. Pausa, reset, seed y escala temporal conservan los controles de Fase 0.

## Arquitectura

```text
OpenOceanFFTConfig
        ↓
TessendorfSpectrum (H0 CPU, una vez por seed/configuración)
        ↓
GPUStockhamFFT (RenderingDevice global, hilo de render)
        ↓
Texture2DRD displacement + normal
        ↓
OceanTestSurface (PlaneMesh finita)
```

`ocean_v3` no referencia ningún recurso de `lab`. El laboratorio instancia `ocean_v3.tscn`, controla el módulo y presenta sus métricas.

## Espectro y determinismo

El espectro inicial usa Phillips/Tessendorf direccional para agua profunda:

- gravedad: 9,81 m/s²;
- dirección de viento: `(1, 0.35)` normalizada;
- viento: 12 m/s;
- energía Phillips: 0,00016;
- exponente direccional: 4;
- amortiguación corta: 0,35 m;
- choppiness: 1,0.

Un hash entero de 32 bits derivado exclusivamente de `seed + índice` alimenta Box–Muller. No usa el RNG global ni estado acumulado. H0 contiene `h0(k)` y `conj(h0(-k))`. Cambiar la seed sólo vuelve a generar/subir H0 una vez; no hay transferencia CPU↔GPU recurrente.

La amplitud incluye el espaciado espectral y la compensación de normalización de la IFFT. Con defaults y seed `20260820`, Parseval estima Hs ≈ 0,659 m en `t=0`, dentro del rango Race Sea de diseño.

La evolución usa:

```text
h(k,t) = h0(k) exp(i·sqrt(g|k|)·t) + conj(h0(-k)) exp(-i·sqrt(g|k|)·t)
```

Los espectros horizontales se derivan de `-i·k/|k|·h(k,t)` y se multiplican por choppiness. Por construcción, choppiness cero produce Dx=Dz=0.

## IFFT y pases

Se usa Stockham autosort radix-2 con ping-pong. Cada etapa integra la permutación necesaria, sin bit-reversal CPU. La implementación procesa en paralelo dos complejos por RGBA y un tercero en otra RGBA.

Para 256²:

- 1 dispatch de evolución espectral;
- 8 dispatches Stockham horizontales;
- 8 dispatches Stockham verticales;
- 1 dispatch de ensamblado, normalización y normals;
- total: 18 dispatches por actualización.

Hay una barrera compute explícita tras cada productor que alimenta al siguiente pase. No se llama a `rd.sync()`.

## Formatos, memoria e interoperabilidad

| Recurso | Formato | Cantidad | Uso |
|---|---:|---:|---|
| H0 | RGBA32F | 1 | `h0(k)` + `conj(h0(-k))` |
| ping-pong A/B | RGBA32F | 4 | Height, Dx y Dz complejos |
| displacement | RGBA32F | 1 | R=Dx, G=Height, B=Dz |
| normal | RGBA16F | 1 | normal XYZ derivada del displacement |

La memoria nominal de estas texturas es aproximadamente 6,50 MiB a 256², sin contar metadatos/pipelines. Se prioriza FP32 en el solver; sólo el mapa final de normals usa FP16.

Todos los recursos se crean en `RenderingServer.get_rendering_device()` desde el hilo de render. Los RIDs finales se asignan a recursos `Texture2DRD` persistentes que el material muestrea directamente. No existe `texture_get_data`, `buffer_get_data`, `ImageTexture`, `submit`, `sync` ni readback por frame.

Shaders, pipelines y texturas reciben nombres `Ocean1A.*` para RenderDoc. Uniform sets, texturas, pipelines y shaders se liberan explícitamente al destruir el módulo. Los recursos no se recrean por frame.

## Superficie y normals

La prueba usa un `PlaneMesh` de 128×128 m y 256×256 vértices. Sus coordenadas espectrales se calculan desde XZ de mundo, por lo que mover la cámara no cambia la fase.

El pase final evalúa diferencias centrales periódicas del desplazamiento completo y forma las tangentes deformadas. La normal es el producto vectorial normalizado de ambas; no hay normal map de ruido ni FFT extra.

El material es opaco y deliberadamente sencillo: azul/gris neutro, iluminación estándar, roughness y specular moderados. No contiene óptica avanzada.

## Tiempo físico y visual

`simulation_time` continúa avanzando exclusivamente a ticks físicos fijos. Antes de cada avance se conserva `previous_simulation_time` y el render consulta:

```text
render_time = lerp(previous_simulation_time,
                   simulation_time,
                   Engine.get_physics_interpolation_fraction())
```

La fórmula sigue la semántica de interpolación física de Godot: el render representa un instante entre el estado físico previo y el actual. Pause detiene dispatches y conserva exactamente el último mapa; reset pone ambos tiempos en 0 y fuerza una actualización incluso pausado. `time_scale` sólo escala los incrementos del reloj autoritativo.

## Validación realizada

`tests/phase_1a_validation.gd` valida sin GPU readback:

- H0 idéntico para misma seed/parámetros;
- H0 diferente para otra seed;
- energía cero exactamente nula;
- amplitud default física y acotada;
- indexado Stockham contra IDFT directa (error máximo observado: `2.4e-7`);
- pause, reset y time scale del reloj.

Godot 4.7.1 abrió la escena con Forward+/D3D12 sobre una RTX 4070 Laptop. Los shaders compute y de superficie compilaron, los RIDs/uniform sets permanecieron válidos y una captura de 60 frames confirmó displacement visible. Dos ejecuciones sostenidas de 18.000 y 30.000 frames superaron cuatro minutos acumulados sin errores del océano; no hacen readback.

## Métricas observadas

Captura corta a 1920×1080, escala 3D 0,7, STANDARD, 180 frames de calentamiento + 180 de muestra:

| Modo | FPS medio | CPU process | Physics | Draw calls | Primitives | Static memory |
|---|---:|---:|---:|---:|---:|---:|
| FFT OFF, superficie oculta | 151,60 | 6,323 ms | 0,068 ms | 47 | 1.730 | 88,74 MiB |
| FFT ON | 153,25 | 14,288 ms | 0,062 ms | 54 | 657.106 | 88,74 MiB |

La variación de FPS entre ejecuciones supera la diferencia ON/OFF y `TIME_PROCESS` no resultó estable en esta muestra corta. Estos datos describen la ejecución, no aíslan coste GPU ni constituyen presupuesto. El HUD no inventa GPU ms; usar RenderDoc/Nsight/RGP o el profiler externo. El comando reproducible es `res://lab/benchmark/phase_1a_capture.gd`, con argumento opcional `-- fft-off`.

## Limitaciones y trabajo futuro no implementado

- Una sola banda de 128 m se repite periódicamente; no hay mitigación de tiling.
- La malla densa es sólo de inspección y domina las primitivas; no es el clipmap futuro.
- Phillips es una base validable, no el modelo espectral final de Fase 1B.
- Normals por diferencias centrales cuestan lecturas vecinas pero evitan FFT adicionales.
- No hay consulta física CPU ni prueba automática GPU byte-a-byte; pertenecen a fases/herramientas posteriores.
- El modo OFF conserva las asignaciones GPU para reactivación inmediata; detiene compute y oculta la malla, pero no libera memoria hasta destruir el módulo.
- La cámara libre de Fase 0 puede emitir una advertencia benigna de interpolación al moverse fuera del tick físico; no procede del océano.

Posibles optimizaciones para evaluar después, sin implementar aquí: radix mayor, transposición tiled para coalescencia vertical, packed finals más compactos, reducción de densidad de la malla y captura de timestamps GPU por pase. No se implementan cascadas ni clipmap en Fase 1A.

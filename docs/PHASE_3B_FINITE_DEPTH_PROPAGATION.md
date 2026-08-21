# Ocean Lab — Fase 3B: Finite-Depth Propagation V1

## Alcance cerrado

3B transforma un componente monocromático representativo de **LONG** al
cruzar `BathymetryData`: dispersión de profundidad finita, longitud de onda,
velocidades de fase/grupo, shoaling y fase acumulada. El componente elegido
por defecto es `lambda_ref = 16 m`, dentro del borde de la banda LONG, con
`omega_ref = sqrt(g*k0)`; es una representación V1 configurable, no un
cambio de H0 ni una reconstrucción del espectro.

No hay refracción 2D, curvatura de rayos, sombras por islas, breaking, runup,
shoreline dinámica, foam ni cambios a OceanQuery. MID y SHORT permanecen de
mar abierto. La física de vehículos continúa usando el backend de Fase 2C.

## Arquitectura y fuente única

```text
BathymetryData (3A; depth/mask horneados)
        │ bake explícito, nunca por frame
        ▼
CoastalPropagationBaker
        ▼
CoastalPropagationData
  ├─ CPU sample_propagation(world_xz)
  └─ dos RGBA32F GPU en 3B (mismo grid/mapping)
        │
OceanClipmapSurface: sólo LONG
  phase coordinate + shoaling; modo mono analítico opcional
```

`ocean_v3/coastal/` no importa `lab/`. `BathymetryData` es la única fuente de
fondo: no hay raycasts runtime, acceso a triángulos ni GDScript por vértice.
La textura GPU deriva de exactamente esos arrays CPU y usa:

```text
uv = (world_xz - origin_xz) / ((width-1, height-1) * cell_size_m)
```

Fuera de UV, la transformación se desactiva y LONG queda abierto. El payload
es campo `(phase_offset, shoaling, local_k, valid)` y métricas
`(depth, lambda, c, Cg)`: en 3B.1 se añade un tercer RGBA32F de
`(phase, dir_x, dir_z, reached)`, total 48 B/nodo de VRAM, sin mipmaps ni
readbacks.

## Modelo físico

Para cada nodo water con `depth >= min_valid_depth` (0.25 m por defecto):

```text
omega² = g k tanh(kh)       (Newton, 16 iteraciones máximo)
c = omega/k
Cg = 0.5 c (1 + 2kh/sinh(2kh))
lambda = 2pi/k
S = max(1, sqrt(Cg_deep/Cg_local))
```

El límite profundo de `Cg` usa `c/2` para evitar overflow. Nodos inválidos se
marcan explícitamente, mantienen factores neutros y no crean singularidades.
El clamp de `S` preserva el contrato visual de deep≈1; la rama de shoaling
crece sólo cuando el agua es realmente somera para la longitud elegida.

La fase se integra como `phase_offset = integral (k_local-k0) ds` desde la
frontera aguas arriba sobre la dirección de entrada fija. Un sweep estable
ordena nodos por `s=dot(x,d)` e interpola sólo vecinos ya procesados aguas
arriba; así admite direcciones no axiales, no curva los rayos y mantiene el
offset tras un banco. El shader aplica exactamente
`sample_offset = incoming_direction * phase_offset/k0` con signo positivo;
el modo mono valida que `k_local = k0 + d(phase_offset)/ds`, por tanto las
crestas se comprimen donde sube `k`.

El sweep cuesta `O(N log N)` por el orden determinista y no afecta el coste
por frame. Un orden por buckets podría justificar optimización posterior si
los bakes de producción lo necesitan, pero no es necesario para 3B.

## Visualización y debug

`OpenOceanFFTModule` expone parámetros de inspector:

- `coastal_bathymetry_data`, `coastal_propagation_enabled`, dirección,
  lambda y profundidad mínima;
- `coastal_monochromatic_debug` y amplitud para observar primero
  `A*S*cos(k0 dot(x,d)+phase_offset-omega*t)`;
- `set_coastal_debug_field()` para DEPTH, WAVELENGTH, PHASE_SPEED,
  GROUP_VELOCITY, SHOALING y PHASE_OFFSET.

En modo normal LONG conserva el FFT y se desplaza/multiplica de forma
coherente. Las normales LONG se escalan con el desplazamiento de muestra; la
regla de cadena completa para un `phase_offset` espacialmente variable es una
aproximación explícita en 3B, no una normal costeña final.

## Validación y medidas

`tests/phase_3b_coastal_propagation_validation.gd` comprueba:

1. residual de dispersión y límites profundo/somero;
2. RAMP: lambda/c/Cg/phase y shoaling;
3. BANK: incremento de amplitud y memoria de fase tras recuperar profundidad;
4. dirección diagonal, mapping con origen negativo, bounds y payload GPU;
5. determinismo byte a byte de campos derivados.

`lab/benchmark/phase_3b_coastal_propagation_benchmark.gd` mide build, sample
CPU y submit de texturas. No crea dispatches extra ni readbacks: OFF y ON
tienen cero compute passes adicionales al FFT/clipmap; 3B añade dos fetches
RGBA32F a LONG y 32 B/nodo. 3B.1 conserva ese camino y suma una tercera
textura (48 B/nodo) exclusivamente para su diagnóstico mono eikonal. El
benchmark headless informa ese incremento de GPU estructural, no pretende ser
un tiempo de GPU de Steam Deck; ese frame time requiere ejecutar el mismo
perfil de clipmap en hardware objetivo.

En Windows Godot 4.7 headless, grid 65×65 (mediana de 3): build **43.844 ms**,
submit CPU de texturas **0.523 ms**, y sample CPU **2.500–2.781 µs/query**
para N=64–1024. El payload de ese caso es 135,200 B de VRAM.

## Deuda explícita para una fase posterior solicitada

1. sweep por buckets O(N) / tiled bake para grids grandes, si los perfiles lo
   justifican;
2. ray bending/refracción 2D y zonas de sombra;
3. propagación multibanda/espectral y conservation energética más completa;
4. breaking, foam, costa y normales con regla de cadena completa;
5. integrar el mismo modelo a cualquier query física sólo cuando se encargue
   explícitamente (3B no toca NATIVE OceanQuery).

# Ocean Lab — Fase 3B: Finite-Depth Propagation V1

## Alcance cerrado

3B transforma un componente monocromático representativo de **LONG** al
cruzar `BathymetryData`: dispersión de profundidad finita, longitud de onda,
velocidades de fase/grupo, shoaling y fase acumulada. El componente elegido
por defecto es `lambda_ref = 16 m`, dentro del borde de la banda LONG, con
`omega_ref = sqrt(g*k0)`; es una representación V1 configurable, no un
cambio de H0 ni una reconstrucción del espectro.

3B.1 añade un solve Eikonal CPU offline para curvatura local alrededor de
obstáculos y una escala de sombra suave derivada de línea de vista y detour de
ruta. No hay breaking, runup, shoreline dinámica, foam ni cambios a
OceanQuery. MID y SHORT permanecen de mar abierto. La física de vehículos
continúa usando el backend de Fase 2C.

## Arquitectura y fuente única

```text
BathymetryData (3A; depth/mask horneados)
        │ bake explícito, nunca por frame
        ▼
CoastalPropagationBaker
        ▼
CoastalPropagationData
  ├─ CPU sample_propagation(world_xz)
  ├─ shadow_scale CPU (shadow energético; no se sube a GPU)
  ├─ local_direction CPU (raw normalizado de ∇T)
  ├─ render_direction CPU (suavizado adaptativo; no se sube a GPU)
  └─ tres RGBA32F GPU en 3B.1 (mismo grid/mapping)
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
`(depth, lambda, c, Cg)`: 3B.1 mantiene un tercer RGBA32F de
`(phase, dir_x, dir_z, reached)`, total 48 B/nodo de VRAM, sin mipmaps ni
readbacks. `shadow_scale` permanece en CPU para no alterar el contrato GPU de
esta fase.

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

El solve Fast Sweeping usa como máximo 16 ciclos de cuatro barridos
direccionales (64 barridos direccionales), con tolerancia de convergencia
`1e-4 s`; el resultado registra ciclos usados, barridos direccionales y cambio
máximo final. El bake es offline y no afecta al coste por frame.

En 3B.1, las celdas de agua válidas y finitas conservan `reached_mask` aunque
la línea directa quede bloqueada por tierra. `shadow_scale` vale 1 en línea de
vista, y en oclusión usa `0.70 * exp(-detour / 32 m)`, acotado por 0.15 y
suavizado en dos pasadas sobre vecinos 4-conectados alcanzados. Después, una
recuperación anisotrópica downstream mezcla la energía del slice upstream con
dos donantes laterales cuyo alcance crece según `tan(shadow_diffraction_angle)`;
sólo usa agua válida y reached, nunca LAND ni agua no alcanzada. El resultado
final es `max(geometric_shadow, recovered_energy)`, no una solución Helmholtz
completa sino una aproximación determinista coste/beneficio para videojuego.
El campo de tiempo se resuelve con Fast Sweeping. Straight Baker inicializa el
campo a 1 en agua y 0 en LAND; samples de recursos legacy sin el array aplican
el mismo fallback.

## Visualización y debug

`OpenOceanFFTModule` expone parámetros de inspector:

- `coastal_bathymetry_data`, `coastal_propagation_enabled`, dirección,
  lambda y profundidad mínima;
- `coastal_monochromatic_debug` y amplitud para observar primero
  `A*S*cos(k0 dot(x,d)+phase_offset-omega*t)`;
- `set_coastal_debug_field()` para DEPTH, WAVELENGTH, PHASE_SPEED,
  GROUP_VELOCITY, SHOALING y PHASE_OFFSET.
- `CoastalEikonalDebug` es un overlay aislado CPU con modos `REACHED`,
  `RAW_DIRECTION`, `RENDER_DIRECTION` y `SHADOW_SCALE`; `LOCAL_DIRECTION` es
  alias de `RAW_DIRECTION`. No toca shaders ni el render final. Su
  geometría es siempre un único `PlaneMesh` horizontal de dos triángulos y una
  `ImageTexture` RGBA8 de un píxel por celda; cambiar el modo sólo regenera esa
  textura.
- `CoastalEikonalPreviewBaker` es tooling `@tool` reutilizable: se asigna el
  `BathymetryBaker` existente, `BAKE COASTAL PREVIEW` ejecuta el bake real de
  bathymetry en el hilo principal y el solve Eikonal CPU en un worker, y
  `CLEAR PREVIEW` elimina sólo su overlay temporal. Cambiar `Preview Mode`
  reconstruye únicamente la textura debug. Sus estados son `IDLE`, `BAKING
  BATHYMETRY`, `SOLVING EIKONAL`, `BUILDING DEBUG`, `DONE` y `ERROR`; bloquea
  un segundo bake y espera el worker al salir del árbol.
  El overlay usa `BathymetryData.sea_level_y + preview_vertical_offset_m`.

`CoastalEikonalBaker` consume `CoastalPropagationBaker.bake_base_fields()`:
reutiliza una única implementación de dispersión/metrics, pero evita la fase
rectilínea y su ordenamiento completo. La visibilidad incidente y la distancia
ocludida se construyen con sweeps direccionales O(N), sin raymarch por celda ni
`sort_custom` del grid. La recuperación energética y el suavizado de dirección
son también O(N) por pasada, sin cambiar `travel_time`, `phase`, `reached` ni
`local_direction`. El preview imprime sus tiempos adicionales junto a
bathymetry, metrics, sweep Eikonal, fase, shadow, debug mesh y total.

Los parámetros de recuperación parten de `shadow_recovery_enabled = true`,
`shadow_diffraction_angle_deg = 12`, `shadow_recovery_strength = 1`. El campo
de presentación parte de tres pasadas, `direction_smoothing_strength = 0.35`
y `direction_smoothing_threshold_deg = 6`; son parámetros derivados del bake,
no de la identidad macroscópica de la ola.

Además de `eikonal_max_residual`, el bake registra
`eikonal_interior_residual_rad_m`: el máximo residual sólo en agua interior
reached con vecinos de agua reached, excluyendo el borde y las celdas de
transición junto a tierra. Sirve para distinguir la precisión del solve en el
interior de los gradientes necesariamente discretos de la frontera.

En modo normal LONG conserva el FFT y se desplaza/multiplica de forma
coherente. Las normales LONG se escalan con el desplazamiento de muestra; la
regla de cadena completa para un `phase_offset` espacialmente variable es una
aproximación explícita en 3B, no una normal costeña final.

## Validación y medidas

`tests/phase_3b_coastal_propagation_validation.gd` comprueba:

1. residual de dispersión y límites profundo/somero;
2. RAMP: lambda/c/Cg/phase y shoaling;
3. BANK: incremento de amplitud y memoria de fase tras recuperar profundidad;
4. dirección diagonal, mapping con origen negativo, bounds, payload GPU y
   compatibilidad de `shadow_scale` interpolado/legacy;
5. determinismo byte a byte de campos derivados.

`tests/phase_3b_1_eikonal_validation.gd` cubre agua plana (shadow neutro),
un obstáculo aislado, dos islas con canal, agua leeward alcanzada, giro de
dirección local, sombra suave, comparación con solve estricto y determinismo
del solve. También valida grids 512×512 y 1024×1024, recuperación de isla y
roca pequeña, continuidad de `render_direction`, residual interior y que el
debug conserve dos triángulos, no una malla por celda.

`tests/phase_3b_coastal_preview_validation.gd` cubre la máquina de estados,
worker, doble bake bloqueado, cierre durante solve, rebake, eliminación
selectiva del overlay y cambio de modo sin rebake.

`lab/benchmark/phase_3b_coastal_propagation_benchmark.gd` mide build, sample
CPU y submit de texturas. No crea dispatches extra ni readbacks: OFF y ON
tienen cero compute passes adicionales al FFT/clipmap; 3B añade dos fetches
RGBA32F a LONG y 32 B/nodo. 3B.1 conserva ese camino y suma una tercera
textura (48 B/nodo) exclusivamente para su diagnóstico mono eikonal; la
sombra blanda es CPU-only y no añade fetches. El
benchmark headless informa ese incremento de GPU estructural, no pretende ser
un tiempo de GPU de Steam Deck; ese frame time requiere ejecutar el mismo
perfil de clipmap en hardware objetivo.

En Windows Godot 4.7 headless, grid 65×65 (mediana de 3): build **43.844 ms**,
submit CPU de texturas **0.523 ms**, y sample CPU **2.500–2.781 µs/query**
para N=64–1024. El payload de ese caso es 135,200 B de VRAM.

## Deuda explícita para una fase posterior solicitada

1. sweep por buckets O(N) / tiled bake para grids grandes, si los perfiles lo
   justifican;
2. validación visual de `shadow_scale` sobre el render y posible integración
   explícita en un modelo futuro de amplitud, si se encarga;
3. propagación multibanda/espectral y conservation energética más completa;
4. breaking, foam, costa y normales con regla de cadena completa;
5. integrar el mismo modelo a cualquier query física sólo cuando se encargue
   explícitamente (3B no toca NATIVE OceanQuery).

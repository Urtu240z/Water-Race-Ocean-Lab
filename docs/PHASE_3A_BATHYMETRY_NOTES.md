# Ocean Lab — Fase 3A: Bathymetry Data / Bake Pipeline

## Alcance cerrado

3A responde únicamente a «qué profundidad y geometría costera hay aquí».
No modifica FFT/OceanQuery ni implementa shoaling, refracción, breaking,
óptica, propagación, estelas o física de costa. **Gate 3 no se declara.**

## Arquitectura

```text
Node3D BathymetrySource (artista / Blender; uno o varios MeshInstance3D)
        │  bake offline/dev-time
        ▼
BathymetryBaker
        ▼
BathymetryData .tres persistente (rejilla 2D world-space)
        ├─ depth / ∇depth / slope / land-water / shore distance / source mask
        ├─ BathymetryDebug (tooling visual)
        └─ sample_bathymetry(world_xz) (runtime, sólo arrays)
```

El seabed visual, collision seabed y BathymetryData son capas separadas.
El baker acepta preferentemente un `source_root: Node3D` y recorre todos sus
descendientes `MeshInstance3D`, incluyendo GLB con varias islas, rocas o
seabeds. `source: MeshInstance3D` se conserva como compatibilidad. Todas las
caras se transforman a world-space antes de rasterizar. En runtime no hay
raycasts, consultas de triángulos ni dependencia de cámara/clipmap/LOD/
orientación visual.

## Formato `BathymetryData`

- `world_origin_xz`: posición world del nodo `(0,0)`;
- `width`, `height`: número de nodos de muestra, bordes incluidos;
- `cell_size_m`: configurable; Lab usa 1.0 m;
- `sea_level_y`: explícito, default 0 m;
- por nodo: `depth_m`, `gradient_x`, `gradient_z`, `slope_magnitude` y
  `shore_signed_distance_m` (`PackedFloat32Array`), `land_water_mask`,
  `depth_source_mask` y `coast_metadata` (`PackedByteArray`).

La clasificación es global y por nodo: superficie sobre el nivel del mar es
LAND; superficie bajo el nivel del mar es WATER con profundidad medida; sin
superficie es WATER abierta. Para conservar la API existente, la tierra
mantiene profundidad firmada `sea_level_y - top_y`, aunque la máscara es la
autoridad para clasificarla. El agua abierta usa profundidad sintética basada
en la distancia firmada a la costa. `depth_source_mask` vale 1 sólo para agua
medida desde una superficie bajo el mar y 0 para agua sintética/tierra.
`coast_metadata` reserva el formato para tipos beach/rock/wall/reef sin
imponer un editor en esta fase.

### Mapping world-space

```text
grid = (world_xz - world_origin_xz) / cell_size_m
world_max = origin + (width-1, height-1) * cell_size_m
```

Los valores continuos usan bilinear sobre los cuatro nodos. La máscara usa el
nodo más cercano para no crear agua por interpolación sobre tierra. Fuera de
los límites se clampa al borde y `in_bounds=false` lo comunica al caller.
Esto está validado en X negativo, origen desplazado y bordes.

## Derivados

El baker proyecta verticalmente cada triángulo world-space sólo sobre los
nodos de su AABB XZ, manteniendo buffers temporales `top_surface_y` y
`has_surface`. Si varias caras cubren un nodo, conserva la Y más alta; es
deliberadamente offline y robusto para un fondo simplificado. Después calcula
diferencias finitas sobre `depth_m`: central en interior, one-sided en bordes.
El convenio es **`gradient = ∇depth`**, apunta hacia agua más profunda;
`slope_magnitude = length(gradient)`.

La distancia firmada se deriva de la transición global water/land mediante un
Euclidean Distance Transform 2D separable y determinista. Agua es positiva,
tierra negativa y las celdas de transición quedan en cero. Esto hace que el
canal entre islas use automáticamente la costa más cercana de cualquiera de
sus lados.

## Tooling y escenas

- `BathymetryBaker.bake_to_resource()` permite guardar un `.tres` desde un
  componente dev/editor;
- `BathymetryBaker` expone en el Inspector `BAKE PREVIEW`, `CLEAR PREVIEW` y
  `preview_mode`; el preview se crea en memoria como hijo interno temporal del
  root de la escena, con transform world-space identidad;
- `BathymetryDebug` dibuja un overlay con DEPTH, GRADIENT/SLOPE, LAND_WATER,
  SHORE_DISTANCE o DEPTH_SOURCE;
- `lab/bathymetry/bathymetry_cases.tscn` crea tres casos debug reales:
  RAMP BEACH, SUBMERGED BANK y SIMPLE ISLAND. Las geometrías son simples,
  pero pasan por el mismo MeshInstance→baker que un asset de Blender.

## Exactitud

`tests/phase_3a_bathymetry_validation.gd` PASS:

- ramp: depth interior 8.0 m y `∇depth.x = -0.34` con error `<1e-5`; también
  bilinear en world X negativo y bounds clamped explícito;
- bank: profundidad de cresta 4.0 m; exterior 8.8–9.1 m; gradiente central 0;
- island: centro con depth negativa/tierra, transición land→water entre los
  nodos 3 y 4 m desde centro, exterior profundo >7.9 m;
- determinismo de buffers, mapping, mask y memoria PASS.

`tests/phase_3a_bathymetry_coastal_validation.gd` PASS:

- isla única sin seabed: vacío como agua sintética;
- dos islas: recolección recursiva y canal con costa global;
- seabed real: profundidad medida conserva precedencia sobre synthetic.
- equivalencia del raster triangle-driven frente a referencia brute-force
  pequeña: PASS.

La precisión interior es mucho menor que la celda de 1 m porque las rampas y
las caras de prueba son lineales; shorelines discretas quedan naturalmente
cuantizadas a `cell_size_m`.

## Coste y memoria (Windows Godot 4.7 headless)

Bake offline de SUBMERGED BANK, rejilla 49×41, 3.840 triángulos: **2.850 s**.
Es O(celdas×triángulos) y no afecta runtime; una futura aceleración espacial
del baker sólo se justificará con assets de producción mayores.

Query `sample_bathymetry(world_xz, reusable_sample)`, mediana de 9:

| N | ms | µs/query |
|---:|---:|---:|
| 1 | 0.003 | 3.00 |
| 16 | 0.036 | 2.25 |
| 64 | 0.142 | 2.22 |
| 256 | 1.051 | 4.11 |
| 1024 | 2.258 | 2.21 |
| 10000 | 23.666 | 2.37 |

La consulta es una lectura/interpolación GDScript de arrays y no toca
geometría. El sample reutilizable evita allocs de resultados por query.

Memoria de payload, sin overhead de `Resource`/arrays: cinco float32 + tres
bytes por nodo = **23 B/nodo**.

| Grid | bytes | MiB |
|---|---:|---:|
| 256×256 | 1,179,648 | 1.13 |
| 512×512 | 4,718,592 | 4.50 |
| 1024×1024 | 18,874,368 | 18.00 |

## Deudas explícitas posteriores

1. aceleración espacial de bake para mallas grandes;
2. tiles/chunks/streaming, si el tamaño real de mundo lo exige;
3. edición/import de metadata de costa;
4. normal de costa, si una fase futura la necesita.

No son necesarios para consumir `depth` y `∇depth` en 3B.

## Recomendación exacta para 3B

Consumir **sólo** `BathymetryData.sample_bathymetry` como fuente de
profundidad y gradiente, manteniendo el FFT de mar abierto intacto. Empezar
con un caso RAMP/BANK, usar el convenio `∇depth → profundo`, y validar la
respuesta costera sin añadir aún tipos de costa, raycasts ni solver de aguas
someras.

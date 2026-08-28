# Ocean V3 — LOD geomorph

## Alcance

Ocean V3 mantiene los anillos cuadrados y el stitching 2:1 existentes. Este
cambio sólo suaviza la transición geométrica de cada nivel hacia la rejilla del
nivel siguiente; no modifica FFT, foam, SSPR/reflections ni los rangos de fade.

## Parámetros y coordenadas

`OceanClipmapSurface.lod_morph_ratio` es un parámetro exportado, con rango
`0.05..0.30` y valor inicial `0.12`. El valor se envía como uniform a ambos
materiales de superficie.

Cada `MeshInstance3D` recibe desde `OceanClipmapMeshBuilder`:

- `clipmap_spacing_m`: spacing del nivel actual.
- `clipmap_next_spacing_m`: spacing del nivel siguiente, exactamente el doble;
  vale `0` en el último nivel.
- `clipmap_outer_extent_m`: semiextensión exterior del anillo.
- `clipmap_inner_extent_m`: semiextensión interior; permite reconocer los
  vértices intermedios del borde de stitching.

El clipmap actual sigue exactamente la cámara y sus vértices son posiciones
locales múltiplos del spacing. Por eso la alineación no usa el origen mundial.
El shader obtiene el origen de `MODEL_MATRIX`, calcula la posición local y
cuantiza contra `clipmap_next_spacing_m`. Así el punto objetivo coincide con el
grid del siguiente anillo aun cuando la cámara se mueva continuamente.

## Fórmula

Para un vértice fino `fine_world_xz` y su posición local `local_xz`:

```glsl
float distance_metric = max(abs(local_xz.x), abs(local_xz.y));
float morph_start = outer_extent * (1.0 - lod_morph_ratio);
float lod_alpha = smoothstep(morph_start, outer_extent, distance_metric);

float coarse_spacing = max(next_spacing, spacing * 2.0);
vec2 coarse_local_xz = floor(local_xz / coarse_spacing + vec2(0.5)) * coarse_spacing;
vec2 sample_xz = mix(fine_world_xz, clipmap_origin_xz + coarse_local_xz, lod_alpha);
```

La cuantización es determinista porque se hace en el espacio local estable del
clipmap, con el mismo origen y spacing usados para generar los rings. No hay
redondeo respecto a `world_xz` ni estado temporal. La métrica Chebyshev es la
adecuada para la topología cuadrada actual.

## Orden de evaluación

`sample_xz` sustituye a la posición fina antes de los fetches de displacement,
normales, composición de bandas y datos geométricos asociados. El displacement
horizontal y vertical se aplica después, de modo que no se desplaza una ola ya
evaluada en otra fase. Las rutas posteriores de shoreline y breaker conservan
su orden actual.

En el borde exterior del nivel fino `lod_alpha` es `1`. El stitching del nivel
grueso conserva sus vértices intermedios y sus esquinas; esos vértices interiores
se colapsan al grid actual para coincidir con el borde fino después del morph.
Ambos lados evalúan la misma posición coarse, por lo que geomorph y stitching
son complementarios: geomorph elimina saltos y stitching evita cracks.

El último nivel no tiene siguiente grid y fuerza `lod_alpha = 0`.

## Debug y validación

`L` conserva el debug de colores por LOD. `Shift+L` activa el debug temporal de
geomorph: negro es `lod_alpha = 0` y blanco `lod_alpha = 1`.

La validación CPU `tests/phase_1c_validation.gd` mantiene las comprobaciones de
topología y stitching y verifica que el shader use el origen, spacing siguiente
y cuantización de clipmap-space. La validación runtime recomendada es congelar
la simulación, cruzar lentamente las fronteras hacia delante/atrás y
lateralmente, y revisar las cuatro esquinas con el debug activo.

## Coste y limitaciones

El coste adicional es sólo vertex shader: unas operaciones de `abs/max`,
`smoothstep`, `floor` y `mix`. No añade dispatches, texturas, readbacks,
asignaciones CPU por frame ni fetches FFT adicionales.

El morph no filtra frecuencias según spacing. Puede quedar shimmer especular o
variación de ondas pequeñas en LODs muy gruesos; eso pertenece al trabajo futuro
de frequency/band limiting por LOD y queda deliberadamente fuera de esta fase.

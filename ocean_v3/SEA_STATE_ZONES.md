# OceanSeaStateZone3D

This is the single current manual for local Sea State Zones. For the broader
system contract see [Current Ocean V3 architecture](../docs/OCEAN_V3_ARCHITECTURE.md).

`OceanSeaStateZone3D` es un campo local de estado del mar en coordenadas world-space. No es un `Area3D`, no tiene volumen de colisión y no usa `body_entered`/`body_exited`.

## Uso en una escena

1. En el editor: **Add Node → OceanSeaStateZone3D**.
2. Mantén `Node3D.scale` en `(1, 1, 1)`; el tamaño físico lo controla `Box Size`.
3. Mueve la zona con el gizmo normal y gírala en Y para orientar el rectángulo.
4. Usa los handles X/Z para cambiar `Box Size` y el handle exterior para cambiar `Feather Distance`.
5. Todos los cambios de handles tienen Undo/Redo y también pueden editarse desde el Inspector.

El rectángulo interior es el core. El feather se extiende fuera del core con el mismo perfil de distancia suave que usa el SDF runtime; el gizmo lo muestra como un contorno con esquinas redondeadas.

## Parámetros

- **LONG**: multiplicador de amplitud de la macroestructura LONG.
- **MID**: multiplicador de amplitud de la banda MID.
- **SHORT**: multiplicador de amplitud del detalle SHORT.
- **Choppiness**: multiplicador del desplazamiento horizontal/choppiness.
- **Foam Generation**: actividad local de nacimiento/presentación de foam.
- **Feather**: distancia exterior del blend suave desde el borde del core.
- **Strength**: peso global de la zona, de 0 a 1.
- **Priority**: orden de composición cuando hay zonas solapadas; las prioridades menores se aplican primero.

El valor 1 mantiene la banda sin modificar. Por ejemplo, un canal calmado puede usar:

```text
LONG 0.35   MID 0.10   SHORT 0.03
CHOP 0.45   FOAM 0.10  FEATHER 30 m
```

Hay un máximo de 8 zonas activas por `OceanV3`. Cuando se solapan, se componen secuencialmente por prioridad y, como desempate, por ruta del nodo. Los targets son valores absolutos respecto al estado global; no son productos acumulativos arbitrarios entre zonas.

## Relación con el océano global

El estado efectivo se entiende como:

```text
Global WavePreset × Coastal × OceanSeaStateZone3D
```

La zona modifica localmente la evaluación de la superficie y sus consumidores; no reconstruye H0 ni cambia la arquitectura de FFT, transiciones globales o Coastal. La implementación actual asume normalmente un `OceanV3` por nivel: la zona se registra en el primer OceanV3 del grupo `ocean_v3_root`.

Las zonas se aplican en render y en `OceanQueryReduced`. La presencia de una
zona activa hace que la selección de backend no use Native para esa consulta,
porque el Native actual no recibe descriptores espaciales de zona. La zona
tampoco es un detector de entrada: no necesita `Area3D`, `CollisionShape3D`,
`body_entered`, `body_exited` ni script de jugador.

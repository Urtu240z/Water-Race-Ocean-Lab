# Ocean Lab — Fase 0

## Alcance

Esta base no contiene malla, plano, shader, material, ruido, FFT, ondas, espuma, estelas ni ningún sustituto provisional de océano. `ocean_v3.tscn` es deliberadamente un nodo raíz vacío.

`ocean_v3` aloja sólo infraestructura reutilizable: reloj determinista, seed, perfiles y registro de módulos. `lab` contiene las cámaras, marcadores métricos, HUD y controles. No existe ninguna referencia de `ocean_v3` a `lab`.

## Ajustes comparados con Water Race

Se mantienen Godot 4.7, Forward+, D3D12 y Jolt. También se replica la interpolación física y la escala 3D de 0,7, porque afectan de manera sustancial a comportamiento y rendimiento medidos.

No se copian Input Map, autoloads de juego, importadores, iluminación global, lightmapping ni límite de hilos del editor: no forman parte de la base de Ocean Lab o introducirían dependencias de juego.

## Métricas

El HUD usa FPS, frame time aproximado, monitores de CPU de Godot, ticks físicos, resolución, draw calls, primitivas, memoria estática y estados propios. El frame time de GPU no se expone de forma fiable como métrica de runtime portable; se deja explícitamente para el profiler externo.

Una única ejecución sólo constituye un dato de baseline, nunca una conclusión de rendimiento.

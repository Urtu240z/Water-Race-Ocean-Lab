# Ocean V3 Foam Visual Lab

Laboratorio temporal de comparación A/B para `ocean_surface.gdshader`. Esta fase no optimiza Foam ni modifica las fórmulas de producción.

## Abrir

En Godot 4.7 abre y ejecuta `res://ocean_v3/tests/foam_visual_lab/foam_visual_lab.tscn`. La escena usa una instancia oculta de `OceanV3` como dueño de la simulación y dibuja cuatro candidatos en SubViewports independientes.

## Controles

- `F5`: alterna `PLAY` / `FROZEN` mediante el `SimulationClock` global de esta escena.
- `F`: fullscreen A/B.
- `SPACE`: alterna `BASELINE` y el candidato seleccionado en fullscreen.
- `1`, `2`, `3`: selecciona `OPTION A`, `OPTION B` u `OPTION C`.
- `P`: PERF MODE; muestra sólo un candidato y desactiva la actualización de los otros SubViewports.
- `0`: selecciona BASELINE en PERF MODE.
- `G`: vuelve a VISUAL GRID.

## Arquitectura

`OceanV3/OpenOceanFFT` se instancia una sola vez y permanece oculto. FFT, Crest Foam, Surface Foam, MID fold history, Coastal y sus `Texture2DRD` se calculan y publican una sola vez. Después de que la superficie está lista, el Lab duplica su `ShaderMaterial` cuatro veces y sustituye sólo el shader por:

- `shaders/ocean_surface_baseline.gdshader`
- `shaders/ocean_surface_option_a.gdshader`
- `shaders/ocean_surface_option_b.gdshader`
- `shaders/ocean_surface_option_c.gdshader`

Los cuatro SubViewports usan la misma geometría generada determinísticamente (16 m × 16 m, 128 celdas por lado), el mismo transform, la misma cámara virtual, resolución interna, Environment, luz y coordenadas world-space. El controlador sincroniza los uniforms dinámicos del material de producción, incluido `coastal_time_s`, `camera_world_xz` y el estado de breakers/reflexiones, para que las diferencias observadas pertenezcan al candidato.

En GRID, los cuatro candidatos permanecen en su `SubViewportContainer` original y renderizan continuamente. En FULLSCREEN A/B también siguen los cuatro en `UPDATE_ALWAYS`: el `TextureRect` de `FullscreenHost` muestra directamente el `ViewportTexture` ya existente del candidato elegido. Alternar `SPACE` o seleccionar `1`/`2`/`3` sólo cambia esa textura mostrada; no pausa ni reparenta ningún candidato.

PERF es deliberadamente distinto: únicamente el candidato seleccionado usa `UPDATE_ALWAYS` y los otros tres quedan en `UPDATE_DISABLED`. Al volver de PERF a GRID o FULLSCREEN A/B, el Lab reactiva los cuatro y muestra `A/B RESYNC` durante `VISUAL_RESYNC_FRAMES` (30) frames no bloqueantes. Sólo cuando el HUD muestra `A/B READY` debe hacerse una comparación temporal estricta: así se da tiempo a que los historiales de exposición y postprocesado de los viewports que estuvieron pausados vuelvan a avanzar.

La medición disponible en PERF es el tiempo de frame/FPS y los monitores CPU de Godot. No se inventa un GPU time: el proyecto marca explícitamente esa métrica como no disponible cuando el renderer no expone una lectura fiable.

## Autoridad de iluminación y exposición

La autoridad visual es la escena `foam_visual_lab.tscn`: `WorldEnvironment` aporta el `Environment` y los `CameraAttributes`, y `LabLight` aporta la `DirectionalLight3D`. Cada SubViewport crea su propio `World3D`, clona esos recursos y duplica esa luz con sus propiedades y transform, sin valores de iluminación codificados en el script. Así, los cuatro candidatos comparten exactamente la iluminación y la exposición definidas en la escena.

## Qué no usar para benchmarking

No medir rendimiento en VISUAL GRID: cuatro SubViewports renderizan simultáneamente y sirven para inspección visual. Usar exclusivamente `P`/PERF MODE, con un candidato activo cada vez, y registrar el renderer/dispositivo utilizado.

## Variantes futuras

Editar únicamente el shader de la opción que se quiera probar. Mantener BASELINE congelado como referencia y no cambiar la geometría, la cámara, la semilla, el preset, el Environment o los recursos de simulación al comparar. Cuando exista un ganador:

1. portar la solución al shader de producción;
2. validar la equivalencia y el rendimiento;
3. eliminar los shaders experimentales que no sirvan.

Los cuatro shaders actuales son temporales y comienzan byte-for-byte iguales al shader de producción. No se ha hecho ninguna refactorización de producción; cualquier impedimento arquitectónico restante debe resolverse de forma aislada en este Lab.

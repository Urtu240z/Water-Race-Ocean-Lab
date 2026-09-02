# Surface Foam FFT packing

Surface Foam conserva su espectro independiente de 512², dominio de 8 m y
actualización de 30 Hz. Este cambio no reutiliza datos del FFT principal.

El solver necesita tres campos espectrales complejos para reconstruir su
Jacobiano:

- `dhx_dx`;
- `dhz_dz`;
- `dhz_dx` (`dhx_dz` es el mismo término por irrotacionalidad).

Los tres son espectros hermitianos, por lo que sus IFFT espaciales son reales.
La ruta anterior ejecutaba tres transformadas complejas empaquetadas en dos
texturas RGBA32F ping-pong: dos campos en `DerivativeA` y uno en
`DerivativeB`.

La ruta actual empaqueta las diagonales como `H = dhx_dx + i * dhz_dz`:

```text
H.re = dhx_dx.re - dhz_dz.im
H.im = dhx_dx.im + dhz_dz.re
```

Por linealidad, `IFFT(H).re` reconstruye `dhx_dx` e `IFFT(H).im` reconstruye
`dhz_dz`. `dhz_dx` ocupa los dos canales restantes del mismo RGBA32F. Se pasan
de tres a dos transformadas complejas útiles sin cambiar la fórmula del
Jacobiano, el espectro, dominio, resolución, umbrales ni la persistencia.

Las 18 etapas Stockham permanecen: son nueve etapas por eje para una IFFT 2D
de 512², no 18 IFFT independientes. Cada etapa ahora procesa un RGBA32F
ping-pong en lugar de dos, reduciendo a la mitad los butterflies, lecturas y
escrituras de la parte FFT. La reconstrucción ocurre únicamente en el shader
de assemble antes de calcular el mismo Jacobiano.

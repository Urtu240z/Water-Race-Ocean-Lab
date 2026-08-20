# Water Race Ocean Lab

- Ocean V3 será el núcleo futuro de Water Race; no reutilices parches de Ocean V1/V2.
- `res://ocean_v3/` no puede depender de `res://lab/`; usa metros y segundos reales.
- Prioriza determinismo: tiempo, seed y parámetros deben ser reproducibles.
- Mide antes de optimizar. Steam Deck es un objetivo real.
- Todo sistema caro debe poder aislarse y medirse; evita readbacks GPU→CPU recurrentes sin benchmark.
- Los presets gráficos no cambian la identidad macroscópica de las olas.
- No implementes fases posteriores sin una petición expresa.
- Documenta los cambios arquitectónicos importantes.
- Water Race original es sólo referencia de lectura: nunca lo modifiques.

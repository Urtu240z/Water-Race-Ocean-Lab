# Fase 3B.3A — OceanQuery coastal exacto: optimización AVX2

La ruta native conserva el modelo coastal de 3B.3 y acelera exclusivamente
su evaluación CPU por lote. No cambia H0, emparejamiento canónico, pesos
angulares, presupuesto de modos, Newton ni la fórmula de corrección.

## Estructura

Al preparar un instante, LONG construye el componente exacto
`C = w(k) A + w(-k) B` y sus velocidades. También conserva una lista compacta
de pares cuyo peso no es exactamente cero; no hay umbrales espectrales.

En cada evaluación AVX2 coastal activa:

1. El sampler CPU obtiene `F(q)`, `J`, confianza y shoaling una vez por punto.
2. El pase LONG base fusiona `C(q)` usando el mismo `phi`, `sin` y `cos`.
3. Un pase AVX2 LONG compacto evalúa `C(F(q))` sólo para puntos coastal activos.
4. Se aplica sin cambios `S_eff * ((1-c)C(q) + c C(F(q))) - C(q)`, incluido
   el transporte `J^T` de gradiente y derivadas de desplazamiento.

Sin runtime coastal, sin pares coastal no nulos, o sin puntos con confianza
activa, el dispatch usa exactamente el kernel AVX2 abierto previo: no ejecuta
el sampler ni acumuladores suplementarios.

La ruta scalar 3B.3 de `accumulate_coastal_long_` permanece como referencia
de depuración y validación. El fallback establecido para subconjuntos activos
menores de cuatro puntos se conserva para AVX2, sin variar sus resultados.

## Diagnóstico

`tests/phase_3b_3_native_validation.gd -- --profile` informa:

- pares compactos nonzero/total;
- coste base abierto;
- incremento `Cq_fused` (pase base+fusión menos base abierto);
- sampler, `C(F(q))` AVX2 y combinación;
- equivalencia de la nueva ruta contra la referencia scalar en campos flat y
  bank, tiempos múltiples y lotes 1/16/64.

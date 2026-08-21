# Water Race — Ocean V3 — Especificación Maestra

> **Documento vivo y canónico del proyecto Ocean V3.**  
> Define objetivos, decisiones cerradas, límites de arquitectura, rendimiento y plan de validación.  
> Git debe conservar el historial: a partir de ahora se actualiza este mismo documento.  
> **Estado actual:** **Fase 1 completada. Gate 1 APROBADO. Fase 2A completada. Fase 2A.1 completada: Golden world-space reference disponible (inversión world_xz → q). Gate 2 todavía pendiente. Siguiente: Fase 2B — evaluador reduced/production de OceanQuery. Física del jetski NO iniciada.**

---


## Próxima acción aprobada

Crear **Water Race Ocean Lab** como proyecto Godot 4.7 independiente.

La primera implementación será exclusivamente:

**Fase 0 — laboratorio, métricas, tiempo determinista, seed, perfiles y cámaras.**

No implementar todavía:

- FFT/Tessendorf;
- geometría de agua;
- batimetría;
- rompientes;
- estelas;
- espuma;
- spray;
- óptica;
- reflejos;
- underwater;
- tsunami.

La Fase 1 empieza sólo después de validar el coste base del laboratorio.

---

## 1. Objetivo

El mar es el elemento central de **Water Race**.  
La prioridad es conseguir un océano que:

- se vea convincente a centímetros de la cámara;
- tenga comportamiento de ola reconocible y coherente;
- sea divertido y exigente de conducir;
- reaccione a costa, fondo, viento y obstáculos;
- pueda escalar desde Steam Deck hasta PC de gama alta;
- permita mejorar módulos visuales sin romper la física.

**Regla:** no añadir parches sobre Ocean V2. Ocean V3 se construirá limpio en un **Ocean Lab** independiente y se integrará cuando sea claramente superior.

---

## 2. Referencias principales

### Sea of Thieves
Referencia para:

- mar abierto;
- FFT/Tessendorf;
- masa y movimiento del océano;
- swell direccional;
- choppiness;
- crestas;
- whitecaps;
- foam persistente;
- coherencia física del agua.

### GTA V
Referencia para:

- transparencia;
- profundidad óptica;
- absorción/color;
- refracción;
- Fresnel;
- reflejos;
- caustics;
- microdetalle;
- escalabilidad gráfica.

### Water Race añade
Porque un juego de jetski lo necesita:

- breaking waves reales visualmente;
- geometría local capaz de volcar;
- whitewater persistente;
- interacción casco ↔ agua más precisa;
- coast/run-up más avanzado;
- submarino;
- tsunami;
- control del rider sobre el centro de masas.

---

## 3. Filosofía técnica

### 3.1 Ambición controlada
Se permiten sistemas más avanzados que los referentes si:

- aportan una mejora visible o jugable importante;
- tienen coste medible y acotado;
- degradan bien en hardware lento;
- poseen LOD, resolución, radio, frecuencia o densidad configurables.

Se descartan si:

- el coste crece sin control;
- son inestables;
- la mejora visual es marginal;
- no se pueden escalar correctamente.

### 3.2 Misma física, distinta calidad gráfica
Steam Deck y PC Ultra deben compartir:

- mismas olas principales;
- misma fase;
- misma altura;
- misma dirección;
- mismo breaking;
- misma interacción física.

Los presets cambian:

- resolución;
- partículas;
- buffers;
- reflejos;
- refracción;
- distancia;
- update rate;
- detalle geométrico.

### 3.3 Terminología de trabajo

Usar términos en español siempre que sea práctico. El término inglés puede aparecer entre paréntesis cuando ayude a buscar documentación o identificar código.

Ejemplos: estela (*wake*), agua blanca/aireada (*whitewater*), espuma (*foam*), rompiente (*breaker*), oleaje de viento (*wind sea*), espuma/spray arrastrados por viento (*spindrift*).

### 3.4 Determinismo
El océano debe ser reproducible mediante:

- seed;
- tiempo;
- espectro;
- viento;
- parámetros ambientales.

Beneficios:

- debugging;
- replays;
- ghost races;
- IA;
- futuro multijugador.

---

# 4. Escala física

Todo Ocean V3 trabaja en unidades reales:

- metros;
- segundos;
- m/s.

No usar escalas arbitrarias por nivel.

### Mar normal / Race Sea
Objetivo aproximado:

- Hs: **0,4–0,8 m**;
- crestas individuales ocasionales: **0,9–1,2 m**;
- swell principal: **0,45–0,70 m**, longitud **12–25 m**;
- wind sea: **0,10–0,30 m**, longitud **2–7 m**;
- microondas: visuales, sin importancia física.

No aumentar altura artificialmente para compensar cámara/FOV.

---

# 5. Generación del mar abierto

## Decisión
**FFT/Tessendorf espectral direccional.**

No usar hero waves diseñadas para ayudar al jugador.

Filosofía:

> El mar existe. El jugador se adapta a él.

Características:

- dirección dominante;
- swell;
- wind sea;
- secondary swell;
- cross sea;
- interferencias;
- irregularidad natural;
- crestas persistentes macroscópicamente.

### Persistencia
Una cresta relevante vista a distancia debe poder:

1. acercarse;
2. levantar al jetski;
3. continuar;
4. transformarse por la batimetría;
5. llegar a costa;
6. romper o disiparse.

No es necesario identificar cada micro-ripple como una entidad.

---

# 6. Forma de ola / afilado de cresta (choppiness)

El choppiness **no es fijo**.

Describe principalmente cuánto desplazamiento horizontal/compression tiene localmente la onda.

Debe evolucionar según:

- espectro;
- energía;
- viento;
- interferencias;
- profundidad;
- steepness.

Evolución deseada:

`redonda → asimétrica → afilada → whitecap → breaking`

No modelar cada ola como un objeto con un valor individual de choppiness.  
Derivar un **campo local y temporal** de steepness/choppiness.

---

# 7. Batimetría y fondo marino

## Decisión
El fondo marino participa realmente en el comportamiento de las olas.

El seabed podrá diseñarse en Blender, incluso low-poly.

Separar:

- **seabed visual**;
- **collision seabed**;
- **bathymetry field**.

La física del oleaje consulta la batimetría horneada, no el número de polígonos.

### Datos derivados
Automatizar al máximo:

- depth/bathymetry;
- depth gradient;
- shore distance;
- shore type;
- exposure;
- reflection factor;
- breaking bias;
- propagation fields.

Evitar pintar manualmente muchos mapas.

### Consecuencias
La batimetría modifica:

- velocidad;
- longitud de onda;
- dirección;
- shoaling;
- steepness;
- breaking.

---

# 8. Islas, canales y oleaje cruzado

Las olas **no buscan la costa**.

Llegan con una dirección inicial y el fondo modifica su propagación.

Alrededor de islas pueden aparecer:

- refracción;
- diffraction;
- wave shadow;
- cross sea;
- interferencias;
- reflexión.

Las zonas caóticas no deben depender principalmente de noise.

Regla:

> V2: noise crea las olas.  
> V3: las olas existen y el noise/vento las ensucia.

---

# 9. Olas rompiendo (breaking waves)

Ocean V3 debe permitir breaking por:

- poca profundidad;
- steepness excesiva;
- interferencia;
- viento;
- override artístico puntual.

## Límite del heightfield
Una superficie `Y = f(X,Z)` no puede representar una ola realmente overturning.

Por ello:

- FFT para océano principal;
- geometría local independiente para el breaker.

## Tipos principales

### Spilling
- rotura progresiva;
- foam cayendo por la cara frontal;
- más común en fondos suaves.

### Plunging
- labio proyectado hacia delante;
- overturning;
- impacto;
- spray fuerte;
- whitewater denso.

Debe ser menos frecuente y más espectacular.

### Surging / impacto duro
Útil como comportamiento secundario en costas muy inclinadas.

---

# 10. Agua blanca / agua aireada (whitewater)

Whitewater ≠ foam.

Whitewater representa agua muy aireada y turbulenta tras romper.

Debe tener:

- volumen aparente;
- persistencia;
- advección;
- turbulencia;
- burbujas;
- opacidad mayor;
- spray residual;
- pequeño desplazamiento local;
- influencia física moderada sobre el jetski.

No usar simulación volumétrica 3D completa.

### Arquitectura
`breaker geometry → impact → persistent whitewater field`

El campo alimenta:

- foam;
- turbulencia;
- bubbles;
- spray;
- spindrift;
- pequeñas perturbaciones físicas.

Puede acumularse entre varias olas.

---

# 11. Costa: 4 arquetipos iniciales

## 1. Playa suave
- shoaling;
- spilling/plunging;
- whitewater;
- swash;
- backwash;
- wetness/foam.

## 2. Roca / arrecife / banco
- steepening local;
- breaking parcial;
- whitewater irregular;
- spray caótico.

## 3. Muro / canal / escollera
- impacto;
- run-up vertical;
- spray;
- reflexión parcial;
- clapotis/interferencia.

## 4. Mar abierto
- whitecaps;
- breaking ocasional por viento/steepness;
- sin influencia costera inmediata.

No ampliar alcance antes de resolver bien estos cuatro.

---

# 12. Avance y retroceso en playa (swash / backwash)

En playas el agua debe avanzar y retroceder realmente.

Deseado:

`breaker → whitewater → run-up → pérdida de energía → backwash`

No limitarlo a una textura de foam.

### Criterio de ingeniería
No aprobar de entrada un solver costero enorme.

Primero intentar:

- batimetría;
- transformación de onda;
- breaker;
- whitewater;
- solución local de swash.

Añadir shallow-water solver sólo si es necesario.

### Rendimiento
La influencia batimétrica puede ser global y barata mediante datos horneados.

La simulación dinámica de alta calidad será:

- localizada;
- con LOD;
- centrada en zonas relevantes.

---

# 13. Estela y perturbaciones creadas por objetos

La estela no es un único efecto visual. Debe representar cómo el casco inyecta energía en el agua.

Separar:

1. **onda de desplazamiento del casco**;
2. **surco, turbulencia y aireación**;
3. **ondas de impacto por aterrizajes/golpes**;
4. **espuma persistente**;
5. **spray del casco**;
6. **chorro propulsor**, que pertenece al sistema del jetski/VFX y no debe confundirse con la estela hidrodinámica.

## 13.1 Desplazamiento y planeo

El casco desplaza agua lateralmente y hacia abajo. A velocidad alta entra además el **planeo**.

La forma de la estela depende de velocidad, volumen mojado, actitud de la moto, roll, estado del mar y régimen de planeo. No usar un ángulo de estela de Kelvin fijo como solución universal.

## 13.2 Salida del agua

Cuando el jetski despega desaparece rápidamente el apoyo hidrodinámico. Puede quedar agua arrastrada durante un instante y aparece spray. No inventar una gran fuerza de “succión” como mecanismo principal.

## 13.3 Entrada / golpe contra el agua

Un aterrizaje debe inyectar energía al océano y puede generar desplazamiento local, onda radiada, velocidad radial/lateral del agua, espuma, turbulencia y spray.

La respuesta depende de la entrada: plana, de proa, de popa o lateral.

## 13.4 Persistencia dependiente del estado del mar

No usar un tiempo de vida fijo.

**Agua calmada:** las ondas de desplazamiento e impacto permanecen reconocibles mucho más tiempo y pueden viajar lejos del jetski. La turbulencia y la espuma también dejan rastro prolongado.

**Mar movido:** la perturbación pierde identidad más rápido al mezclarse con oleaje, roturas, viento y agua aireada. La energía no desaparece instantáneamente; simplemente deja de ser distinguible antes.

Separar el decaimiento de onda coherente, turbulencia/aireación y espuma.

## 13.5 Múltiples jetskis: campo compartido

Las perturbaciones de todos los corredores deben escribirse en **un mismo campo dinámico** para que puedan cruzarse, interferir, sumarse y afectar físicamente a otros corredores.

Aplicar límites de energía, amortiguación y LOD para evitar acumulación artificial descontrolada.

## 13.6 Campo de perturbaciones

Mantener el océano FFT/Tessendorf separado:

`Océano base FFT + Campo de perturbaciones = Superficie final`

No modificar vértices concretos del océano. Los objetos escriben impulsos en coordenadas de mundo y la malla consulta/interpola el campo.

Datos candidatos: desplazamiento superficial con signo, velocidad horizontal X/Z o estado equivalente para propagación, y turbulencia/aireación.

La **espuma** debe usar un campo separado porque su transporte y persistencia no son los mismos que los de la onda.

## 13.7 Inyección inmediata y solver más lento

Separar frecuencia de física del jetski, inyección de impulsos, solver de perturbaciones y render.

Los eventos deben registrarse inmediatamente en el tick físico. El solver puede actualizarse a menor frecuencia y el renderer interpolar entre estados para mantener movimiento suave.

No fijar todavía 10/20/30/60 Hz. La frecuencia estable depende del tamaño de celda, velocidad de propagación, método numérico y condición CFL/estabilidad.

## 13.8 GPU, tiles activos y LOD

Candidato principal:

- solver 2D en GPU;
- doble buffer;
- tiles activos en coordenadas de mundo;
- dormir tiles cuando la energía residual sea irrelevante;
- LOD por distancia;
- no simular todo el mapa a alta resolución.

Parámetros escalables: resolución por tile, tamaño de tile, número máximo de tiles, frecuencia del solver y persistencia mínima.

## 13.9 Rendimiento y validación

Este sistema va más allá de los dos referentes principales y debe **ganarse el puesto mediante benchmark**.

Proceso obligatorio:

1. estimar memoria y ancho de banda;
2. crear prototipo mínimo;
3. medir coste aislado CPU/GPU;
4. probar múltiples jetskis;
5. variar resolución, tiles y frecuencia;
6. hacer stress test junto al resto del océano.

Probar 128² / 256² / 512² por tile, distintas precisiones, 4 / 8 / 16 tiles activos y 15 / 20 / 30 / 60 Hz.

Objetivo inicial orientativo: intentar que el sistema completo de perturbaciones quede claramente por debajo de ser un coste dominante del frame; **<1 ms en hardware objetivo medio sería un buen objetivo de prototipo, no una garantía**.

En Steam Deck se podrá reducir resolución, tiles activos, frecuencia y persistencia de perturbaciones pequeñas sin cambiar la física macroscópica del océano.


# 14. Spray, salpicaduras y agua expulsada

El spray no se trata como un único efecto blanco.

Separar por causa física:

1. **spray del casco**;
2. **agua expulsada por impacto/aterrizaje**;
3. **agua de rompientes**;
4. **espuma pulverizada por el viento**;
5. **chorro de propulsión del jetski**, fuera del núcleo Ocean V3.

## 14.1 Spray del casco

El casco en movimiento desplaza agua y genera spray lateral/proa.

Debe depender de:

- velocidad relativa casco-agua;
- área mojada;
- actitud/pitch;
- roll;
- pendiente local de la ola;
- régimen de planeo.

Puede existir incluso en agua muy calmada.

## 14.2 Impactos y aterrizajes

Un golpe contra el agua debe generar una respuesta coherente con:

- velocidad vertical;
- orientación del casco;
- zona de entrada;
- velocidad relativa del agua;
- energía del impacto.

El mismo evento debe poder alimentar:

- campo de perturbaciones;
- onda radiada;
- agua gruesa;
- spray fino;
- espuma;
- audio;
- cámara.

Evitar sistemas independientes que intenten detectar el mismo impacto por separado.

## 14.3 Dos escalas visuales

### Agua gruesa
Representa masas visibles de agua desplazada.

Usos:

- aterrizajes;
- rompientes;
- golpes contra muro;
- grandes desplazamientos laterales.

Candidato técnico:

- geometría temporal;
- ribbons;
- mallas procedurales simples.

Duración corta.

### Spray fino
Representa:

- gotas;
- mist;
- fragmentación secundaria;
- agua arrastrada por viento.

Candidato técnico:

- partículas GPU.

No usar RigidBody3D por gota.

## 14.4 Rompientes

El spray de una rompiente debe nacer del propio evento de breaking.

Puede incluir:

- masa gruesa;
- splash vertical;
- gotas;
- mist;
- whitewater;
- espuma arrastrada por viento.

No detectar de forma independiente dónde “parece” que debería haber spray.

## 14.5 Espuma pulverizada por el viento

Aparece cuando coinciden:

`viento fuerte + cresta/whitewater + steepness suficiente`

No generar spray blanco arbitrariamente sobre una superficie plana.

Es principalmente visual y muy escalable.

## 14.6 Chorro de propulsión

El chorro de la bomba del jetski pertenece al sistema de jetski/VFX.

Ocean V3 sólo recibe, si procede, la perturbación que ese chorro transmite a la superficie.

No confundirlo con la estela hidrodinámica del casco.

## 14.7 Filosofía visual aprobada

Usar una solución **realista de base, ligeramente amplificada para lectura y espectáculo**.

Regla:

> La física decide cuándo, dónde, en qué dirección y con qué energía sale el agua.  
> El renderer puede exagerar moderadamente cuánto se percibe.

El nivel de exageración debe ser configurable y revisable después de verlo en movimiento.

Evitar:

- “arcade blanco” permanente;
- spray sin causa física;
- exageraciones que oculten la lectura del mar.

## 14.8 Cámara

Un splash grande cercano puede producir:

- gotas de lente;
- distorsión/refracción temporal;
- audio;
- transición underwater si la cámara queda sumergida.

Debe poder reducirse o desactivarse mediante un ajuste de efectos de pantalla/accesibilidad.

## 14.9 Rendimiento y escalabilidad

Este subsistema debe escalar principalmente en lo visual.

Steam Deck / bajo:

- menos partículas;
- menor distancia;
- agua gruesa más simple;
- menos mist;
- menos secundarios.

High / Ultra:

- mayor densidad;
- mayor distancia;
- más fragmentación;
- mejor iluminación;
- más secundarios.

El evento físico base no cambia entre presets.


# 15. Reflexiones

Subsistema **desacoplado** de Ocean Core.

Debe consumir datos estables:

- surface position;
- normals;
- roughness;
- foam;
- whitewater;
- environment/camera.

No decide física.

### Prioridades
1. cielo / sol / luna;
2. iluminación urbana distante;
3. skyline / grandes masas;
4. estructuras y vehículos cercanos;
5. detalle lejano: prescindible.

### Estado del mar
Calmado:
- reflejo coherente/nítido.

Rough:
- reflejo roto;
- estirado;
- highlights fragmentados.

No reflejar detalle que la propia superficie destruirá visualmente.

### Escalabilidad
Control independiente de:

- resolución;
- distancia;
- update rate;
- capas visibles;
- técnica de reflection.

Debe ser reemplazable/mejorable sin tocar Ocean Core.

---

# 16. Refracción / óptica

Separar:

- **surface refraction**;
- **underwater renderer**.

Comparten una única definición óptica:

- absorption;
- scattering;
- clarity;
- turbidity.

### Desde fuera
Profundidad real controla:

- visibilidad del seabed;
- color;
- absorción;
- caustics;
- refraction clarity.

Evitar refracción exagerada tipo gelatina.

### Caustics
Aproximadas y escalables.

No simular óptica física completa si no aporta.

---

# 17. Vista bajo el agua (underwater)

No usar un simple filtro azul.

Debe respetar:

- absorción por distancia;
- scattering;
- pérdida de contraste;
- turbidez;
- whitewater;
- burbujas;
- superficie visible desde abajo.

La transición de cámara debe ser continua.

### Agua blanca vista desde debajo
Usar el mismo campo de whitewater para:

- scattering;
- opacity;
- bubble volume;
- perturbación visual.

---

# 18. Turbidez

Base por nivel + modificadores locales/dinámicos.

Causas:

- oleaje fuerte;
- corrientes;
- breaking sobre arena;
- runoff;
- tormenta;
- whitewater.

No asumir que la lluvia sola mueve el seabed.

Implementar principalmente como campo óptico barato.

Puede modificar:

- absorción;
- scattering;
- seabed visibility;
- caustics;
- refraction clarity.

---

# 19. Viento dinámico

El viento puede cambiar durante una carrera.

No cambiar el océano instantáneamente.

### Comportamiento
- las ondas pequeñas reaccionan rápido;
- wind sea evoluciona después;
- swell grande conserva memoria;
- cambios de dirección pueden producir cross sea;
- aumenta steepness;
- aumenta whitecaps;
- aumenta breaking;
- genera spindrift.

### Espuma y spray arrastrados por el viento (spindrift)
Debe depender de:

`wind + whitecap/whitewater + steepness`

No emitir spray arbitrario sobre agua plana.

### Rendimiento
El clima/espectro no necesita actualizarse a la frecuencia completa del renderer.

Partículas y spindrift son muy escalables.

---

# 20. Casco ↔ Agua

Objetivo:

**física creíble + asistencia configurable.**

No mantener física arcade y simulación separadas.

El océano debe poder consultar:

- height;
- normal;
- water velocity;
- whitewater;
- local flow.

### El casco debe sentir
- buoyancy;
- planing;
- hydrodynamic lift;
- drag;
- slam;
- pitch;
- roll;
- lateral wave impact;
- whitewater;
- current/flow.

No depender sólo de pocos puntos de flotación si la calidad final exige más.

### Slam
El aterrizaje debe producir fuerzas distintas según:

- plano;
- proa;
- popa;
- lateral.

El evento puede alimentar:

- cámara;
- audio;
- animación;
- spray;
- vibración.

---

# 21. Piloto / Asistencias

El rider debe modificar físicamente el centro de masas / momentos.

Ejemplos:

- peso delante → hundir proa;
- peso atrás → levantar proa;
- lateral → roll/carving.

## Dificultad
La dificultad modifica la asistencia, no la física base.

Asistencias posibles:

- roll stabilization;
- pitch damping;
- recovery help;
- landing stabilization;
- ejection threshold;
- lateral-wave correction.

Low assist expone más de la física real.

---

# 22. Maniobra submarino

Debe emerger de la misma física.

No usar animación/teleport/estado falso.

Condiciones:

- velocidad suficiente;
- rider hacia delante;
- actitud descendente;
- throttle apropiado.

Consecuencias:

- drag muy alto;
- fuerte desaceleración;
- buoyancy recuperadora;
- control reducido;
- tendencia natural a salir a superficie.

Debe durar lo que permita la física, no un temporizador artificial.

---

# 23. Caballitos y trucos físicos

Regla:

**primero intentar comportamiento emergente.**

Un caballito debería salir de:

- thrust;
- planing;
- center of mass;
- rider weight;
- hull forces.

Si físicamente funciona pero resulta difícil de controlar:

- añadir asistencia mínima;
- mantener causalidad física.

Evitar:

`if wheelie: set_rotation()`

---

# 24. Tsunamis

No son olas normales con amplitud multiplicada.

Características:

- longitud de onda enorme;
- poca pendiente en mar profundo;
- fuerte shoaling;
- desplazamiento masivo de agua;
- bore;
- run-up;
- inundación.

Debe reutilizar:

- bathymetry;
- nearshore;
- whitewater;
- turbidity;
- underwater;
- flow;
- run-up.

### Impacto sobre cámara/jugador
Esperado:

- visibilidad muy baja;
- sedimento;
- whitewater;
- bubbles;
- strong flow;
- spray;
- debris opcional.

No usar “pared azul transparente”.

---

# 25. Rendimiento / niveles de hardware

## 25.1 Presupuesto antes de implementar

Para cualquier sistema ambicioso: estimar coste teórico, memoria/ancho de banda, resolución/frecuencia/radio, crear prototipo mínimo, medir CPU/GPU en milisegundos, comprobar degradación en Steam Deck y hacer stress test combinado.

No rechazar una técnica sólo por ser ambiciosa ni aprobarla sólo porque parezca viable. Debe justificar los milisegundos que consume y degradar de forma controlada.

Cada sistema costoso debe exponer knobs claros.

Ejemplos:

- FFT resolution;
- FFT cascades;
- foam buffer resolution;
- whitewater resolution;
- reflection resolution;
- reflection update rate;
- refraction resolution;
- breaker mesh detail;
- simulation radius;
- nearshore active tiles;
- particle density;
- spindrift distance;
- caustics quality.

### Regla
Medir cada módulo aislado en Ocean Lab:

1. coste solo;
2. mejora visual;
3. coste combinado;
4. knob de degradación.

No asumir que una técnica es barata en Godot porque lo sea en GTA/Rare.

---

# 26. Arquitectura modular

Separación conceptual:

```text
Ocean Core
├─ Spectrum / FFT
├─ Bathymetry / Propagation
├─ Wave Query API
├─ Breaking Detection
├─ Breaker System
├─ Whitewater Field
├─ Shore / Swash
├─ Hull Interaction
└─ Weather / Wind

Ocean Renderer
├─ Surface
├─ Optics
├─ Reflection
├─ Refraction
├─ Foam
├─ Whitewater Rendering
├─ Caustics
├─ Spray / Spindrift
└─ Underwater
```

No implica obligatoriamente un shader/nodo por bloque.  
Sí implica responsabilidades y datos desacoplados.

---

# 27. Método de implementación

Antes de implementar **cada subsistema**, detenerse y revisar:

1. ¿Qué queremos visualmente?
2. ¿Qué queremos físicamente?
3. ¿Qué gameplay debe permitir?
4. ¿Qué otros sistemas toca?
5. ¿Qué comportamientos emergentes esperamos?
6. ¿Qué necesita asistencia?
7. ¿Qué consecuencias tiene en rider/cámara/VFX/audio?
8. ¿Qué coste tiene?
9. ¿Cómo escala?
10. ¿Qué pruebas demostrarán que funciona?

El plan conceptual no se implementa ciegamente.

---

# 28. Temas aún por cerrar antes del plan técnico

## Imprescindibles

### 1. Interacción con otros cuerpos
- barcos;
- objetos flotantes;
- cuerpos grandes;
- perturbaciones compartidas.

### 2. Reflexión física en costa dura
- energía reflejada;
- absorción;
- dispersión;
- clapotis;
- relevancia física para el jetski.

### 3. LOD espacial del océano
- cascadas FFT;
- clipmap;
- densidad geométrica;
- horizonte;
- radio de detalle;
- transición sin popping.

### 4. Sincronización Océano ↔ Física
- misma ola visual y física;
- evitar readback GPU→CPU caro;
- determinismo;
- frecuencia de consulta;
- coherencia con perturbaciones locales.

### 5. Ocean Lab / objetivos de validación
- mar calmado;
- mar normal de carrera;
- mar movido;
- playa;
- arrecife/banco;
- muro/canal;
- ciudad nocturna;
- vista bajo el agua;
- maniobra submarino;
- múltiples estelas;
- impactos;
- tsunami;
- rendimiento Steam Deck;
- rendimiento PC objetivo.

### 6. Presupuesto global del océano
- presupuesto CPU;
- presupuesto GPU;
- memoria;
- límites por preset;
- objetivo 60 FPS;
- degradación controlada por hardware.

## Fuera del alcance de Ocean V3: propulsión del jetski

Mantener un documento separado para una futura revisión de física/propulsión del jetski.

Temas ya identificados:

- bomba de chorro (*jet pump*);
- toma de agua y submersión;
- empuje;
- RPM/inercia si aporta;
- ventilación / entrada de aire;
- agua aireada;
- pérdida de empuje;
- cavitación simplificada;
- comportamiento durante la maniobra submarino.

Ocean V3 sólo debe exponer datos del agua suficientes para que ese sistema pueda resolverlos después.

## Secundarios, pueden cerrarse durante planificación

- lluvia sobre superficie;
- debris;
- sediment detail;
- foam streak aesthetics;
- audio hooks;
- accessibility;
- editor tooling;
- authoring UX.

---

# 29. Criterio para empezar a planificar

Empezar arquitectura/roadmap cuando estén cerrados los **6 temas imprescindibles** anteriores.

No es necesario resolver todos los detalles visuales antes de planificar.

Resultado esperado:

**Ocean V3 Design Spec v1.0**
→ arquitectura
→ módulos
→ interfaces
→ orden de implementación
→ benchmarks
→ Ocean Lab
→ integración futura en Water Race

---

## Estado actual

**Fase:** diseño conceptual.  
**Ocean V3:** todavía no implementar.  
**Próximo tema recomendado:** Interacción con otros cuerpos y perturbaciones externas.


## Campo disperso de perturbaciones: regiones activas

El campo de perturbaciones **no se actualizará completo** si la mayor parte está a cero.

### Principio
- Zona sin perturbación: estado implícito = 0.
- Un impacto, jetski, barco u objeto activa sólo la región necesaria.
- Regiones solapadas comparten el mismo campo.
- Si una onda alcanza el borde de una región activa, puede activar el tile vecino.
- Cuando la energía cae por debajo de un umbral, el tile se duerme o se libera.

### Implementación candidata
Preferir:
- tiles/rectángulos activos;
- pool/atlas reutilizable en GPU;
- dispatch coherente por bloques.

Evitar:
- miles de micro-cachés independientes por cada evento;
- actualizar un mapa global de alta resolución;
- mantener regiones activas sin energía visible.

### Rendimiento
El coste depende de:
- número de celdas activas;
- frecuencia del solver;
- número de buffers/pases;
- número de tiles despiertos.

No depende directamente del tamaño total del nivel.

En agua calmada:
- las perturbaciones pueden viajar más;
- se activan más tiles;
- duran más tiempo.

En mar movido:
- pierden identidad antes;
- los tiles se duermen más rápido.

Este sistema queda como **candidato principal** para las perturbaciones dinámicas y debe validarse en Ocean Lab.


## 13.10 Detalle secundario sin subir resolución del solver

Las perturbaciones pequeñas que no afecten de forma perceptible a la conducción no necesitan resolverse explícitamente en el campo físico.

Arquitectura por capas:

- **macro/meso físico:** deformaciones y ondas capaces de afectar al casco → campo de perturbaciones;
- **detalle secundario:** ripples/ondas pequeñas visibles pero irrelevantes para física → shader/VFX procedural;
- **microdetalle:** normales/rugosidad/spray.

El detalle secundario debe generarse a partir del mismo evento que originó la perturbación:

- posición;
- dirección;
- energía;
- edad;
- velocidad local;
- turbulencia.

No intentar “detectar” después una pequeña onda a partir de un mapa grueso si ya conocemos la causa.

Regla:
> Si puede cambiar de forma apreciable la trayectoria del jetski, debe existir en la representación física.  
> Si sólo aporta lectura visual a alta velocidad, puede ser procedural y no necesita aumentar la resolución del solver.


# LOD espacial, geometría y horizonte

## Decisión
Usar un sistema de **clipmap/anillos centrados en cámara** con una zona cercana de geometría densa y estable.

No usar de entrada teselación/adaptación dinámica por crestas.

### Principios
- La función/campo oceánico es el mismo en todos los LOD.
- Una cresta vista lejos debe ser la misma al acercarse.
- Sólo cambia la densidad con la que se muestrea/dibuja.
- La zona cercana mantiene alta densidad siempre para evitar popping y simplificar física/visual.
- Las olas que realmente vuelcan usan geometría local específica de rompiente.
- El horizonte debe ser continuo, sin cracks, cambios de frecuencia ni final visible de la malla.

### Escalabilidad
En hardware lento se reducen:
- densidad de anillos;
- distancia de detalle;
- resolución de efectos secundarios;
- frecuencia/calidad visual lejana.

No se cambia la identidad macroscópica de las olas.


# Sincronización Océano ↔ Física

## Decisión de diseño

Esta parte se considera una **decisión técnica de ingeniería**, no una decisión artística.

El objetivo observable es:

- la cresta que se ve debe ser la que siente el jetski;
- no debe haber flotación visualmente desfasada;
- no se aceptan readbacks GPU→CPU que provoquen stalls recurrentes;
- la solución debe escalar a Steam Deck y mantener determinismo.

## Candidato principal

- **GPU:** FFT/Tessendorf completo para render.
- **Física:** evaluador reducido del mismo espectro/seed/tiempo, usando sólo componentes capaces de afectar de forma apreciable al casco.
- **Perturbaciones locales:** elegir mediante benchmark entre CPU, GPU o solución híbrida.

El jetski no conocerá la implementación interna.

API conceptual:

`sample_water(position, time)`

Devuelve:

- altura;
- normal;
- velocidad local;
- turbulencia;
- whitewater/aireación relevante.

## Validación en Ocean Lab

Comparar en tiempo real:

- superficie visual;
- muestras físicas;
- error de altura/normal;
- coste CPU;
- coste GPU;
- estabilidad;
- escalabilidad.

No fijar todavía la implementación definitiva de perturbaciones hasta medir prototipos aislados.


# Reflexión e impacto contra costa dura

La respuesta no será un único patrón de “rebote + ondas circulares”.

Depende de la geometría y del tipo de borde.

## Pared lisa y vertical
- reflexión fuerte y coherente;
- dirección reflejada derivada de la normal local;
- posible clapotis/interferencia con las siguientes olas;
- impacto duro y spray;
- poca disipación comparada con una playa o escollera.

## Roca / obstáculo aislado
- scattering/difracción en varias direcciones;
- respuesta local aproximadamente radial en impactos puntuales;
- breaking parcial;
- turbulencia y spray.

## Escollera / borde rugoso o poroso
- mucha absorción/disipación;
- reflexión más débil y menos coherente;
- whitewater abundante;
- spray caótico;
- turbulencia local.

## Playa / pendiente suave
- shoaling;
- breaking;
- run-up;
- backwash;
- poca reflexión coherente.

## Arquitectura
Derivar u hornear campos costeros a partir de geometría/material:

- normal local;
- pendiente/verticalidad;
- roughness/porosidad;
- reflectividad;
- absorción;
- tendencia a breaking.

Evitar lógica cara triángulo por triángulo en runtime.

La energía reflejada/dispersada se inyecta en el mismo campo local de perturbaciones usado por estelas e impactos para permitir:

- interferencia;
- clapotis;
- ondas reflejadas físicamente perceptibles;
- mezcla con el oleaje base.

No generar automáticamente ondas circulares completas salvo impactos/obstáculos donde esa respuesta tenga sentido.



## Gestión del documento

Cuando se copie al repositorio, usar como nombre canónico:

`WATER_RACE_OCEAN_V3_DESIGN.md`

Actualizar siempre ese mismo archivo. No crear versiones numeradas; Git conserva el historial.


# Ocean Lab — Plan de validación e implementación

## Objetivo

Ocean Lab será un proyecto Godot limpio e independiente usado para construir y validar Ocean V3 antes de integrarlo en Water Race.

No arrastrar:

- Ocean V1/V2;
- shaders antiguos;
- deformaciones anteriores;
- sistemas de wake/estela existentes;
- lógica de niveles;
- riders;
- IA;
- menús.

Sí reutilizar cuando haga falta:

- escala real del jetski;
- un casco de prueba;
- materiales/sky de referencia;
- perfiles de hardware y resolución.

Regla de integración:

> Ocean V3 no sustituye al océano actual hasta que el conjunto pase las pruebas visuales, físicas y de rendimiento.

---

## Arquitectura objetivo

```text
OceanCore
├─ SpectrumFFT
├─ WaveState / Weather
├─ BathymetryData
├─ PropagationFields
├─ OceanQuery
├─ DisturbanceField
├─ BreakingDetector
├─ BreakerSystem
├─ WhitewaterField
└─ ShoreResponse

OceanRenderer
├─ ClipmapSurface
├─ SurfaceOptics
├─ Reflection
├─ Refraction
├─ Foam
├─ WhitewaterRenderer
├─ Caustics
├─ Spray
├─ Spindrift
└─ Underwater

External
├─ OceanInteractor
├─ TestHull
├─ CameraRig
└─ BenchmarkHUD
```

Los nombres son conceptuales y podrán cambiar.

---

# Riesgos técnicos identificados antes de programar

## 1. FFT + batimetría
No asumir que basta con “deformar” una FFT global según profundidad.

La refracción/shoaling costeros necesitan una capa específica de transformación espacial.

Plan:
- FFT produce el estado de mar abierto;
- batimetría y campos horneados modifican propagación/energía en zona costera;
- evitar resolver oceanografía completa por frame.

## 2. Breaking y geometría overturning
El breaker local debe reemplazar visualmente una sección del heightfield sin:
- doble superficie;
- costuras;
- popping;
- cambio brusco de normal.

Necesita transición explícita:
`pre-break → takeover → plunge → impact → whitewater → release`.

## 3. Sincronización visual ↔ física
No aprobar una solución con readback GPU→CPU recurrente que bloquee el frame.

Candidato:
- FFT visual en GPU;
- evaluación física reducida del mismo estado;
- perturbaciones locales decididas por benchmark CPU/GPU/híbrido.

## 4. Campo de perturbaciones
Usar representación dispersa por tiles/regiones activas.

No simular una textura global completa si está vacía.

El solver debe demostrar:
- propagación estable;
- interferencia entre fuentes;
- persistencia variable;
- transición entre tiles sin costuras;
- coste acotado.

## 5. Swash / run-up
No implementar de entrada un gran shallow-water solver.

Primero probar:
- transformación costera;
- breaker;
- whitewater;
- banda dinámica local de swash.

Sólo añadir solver de aguas someras si la solución anterior no consigue avance/retroceso convincente.

## 6. Tsunami
No derivarlo simplemente del FFT normal.

Será un evento de onda larga que reutiliza:
- batimetría;
- propagación;
- run-up;
- flujo;
- turbidez;
- whitewater;
- underwater.

---

# Orden de construcción

## Fase 0 — Laboratorio y métricas

Crear:
- proyecto Godot limpio;
- escena principal de test;
- cámara libre y cámara baja tipo carrera;
- cielo/sol;
- plano de referencia;
- BenchmarkHUD.

Medir siempre:
- FPS;
- frame time;
- CPU frame;
- GPU frame;
- memoria;
- coste individual de cada módulo;
- número de tiles/buffers/partículas activos.

Perfiles iniciales:
- Steam Deck target;
- PC medio;
- RTX 4070 Laptop / desarrollo.

### Gate 0
No avanzar sin poder activar/desactivar cada módulo y medirlo aisladamente.

---

## Fase 1 — Mar abierto

Implementar:
- FFT/Tessendorf direccional;
- seed determinista;
- swell;
- wind sea;
- secondary swell;
- cross sea;
- choppiness dinámico;
- clipmap/anillos;
- horizonte continuo.

No implementar todavía:
- costa;
- breaking;
- estelas;
- foam complejo.

### Escenas
1. Calm.
2. Race Sea.
3. Rough.

### Gate 1
Debe cumplir:
- crestas largas y legibles;
- irregularidad natural sin parecer noise;
- misma cresta persistente al acercarse;
- sin popping de LOD;
- mar normal dentro del rango físico acordado;
- rendimiento suficiente para dejar margen al resto de sistemas.

Si visualmente no produce “ahora sí”, no añadir capas para esconderlo: corregir el mar base.

---

## Fase 2 — Consulta física

Implementar API conceptual:

`sample_water(position, time)`

Debe devolver:
- altura;
- normal;
- velocidad local;
- estado de turbulencia relevante.

Crear probes visibles que comparen:
- superficie GPU;
- posición física calculada.

Añadir un casco pasivo de prueba antes del jetski completo.

### Gate 2
- error visual/físico no perceptible;
- sin stalls;
- determinismo;
- coste estable con múltiples consultas.

---

## Fase 3 — Batimetría y propagación costera

Crear pipeline de bake:

Entrada:
- seabed;
- shoreline;
- tipos de costa/material.

Salida:
- profundidad;
- gradiente;
- normal de costa;
- pendiente;
- exposición;
- reflectividad;
- absorción;
- campos de propagación necesarios.

Escenas:
1. Isla simple.
2. Dos islas con canal.
3. Banco de arena sumergido.
4. Playa.
5. Muro vertical.

Validar:
- shoaling;
- curvatura/refracción;
- sombra de oleaje;
- cross sea;
- cambios de steepness.

### Gate 3
Un banco submarino debe alterar visualmente la ola sin efectos pintados manualmente.

---

## Fase 4 — Breaking

Implementar:
- detección local de condición de rotura;
- spilling;
- plunging;
- geometría local overturning;
- transición con superficie FFT.

No implementar primero la espuma para “disimular”.

### Gate 4
Una ola debe poder:
1. venir de mar abierto;
2. empinarse;
3. cerrar la cresta;
4. volcar;
5. impactar;
6. dejar de ser breaker sin costuras.

Debe funcionar en:
- playa;
- banco;
- mar abierto por steepness/viento.

---

## Fase 5 — Whitewater

Implementar campo persistente compartido.

Debe conducir:
- espuma;
- aireación;
- turbulencia;
- opacidad;
- burbujas;
- spray residual;
- pequeño desplazamiento.

Validar acumulación de varias rompientes.

### Gate 5
Después de romper, la ola no puede volver instantáneamente a “agua limpia + textura blanca”.

---

## Fase 6 — Swash / backwash

Implementar la solución local mínima capaz de:
- avanzar agua sobre playa;
- variar alcance según energía;
- retroceder;
- acumularse con olas sucesivas;
- transportar espuma.

### Gate 6
Si no parece agua real avanzando/retrocediendo, evaluar shallow-water solver local.

No añadirlo por anticipado.

---

## Fase 7 — Perturbaciones dinámicas / estelas

Implementar:
- campo compartido;
- tiles activos;
- pool/atlas;
- stamps de eventos;
- interferencia;
- propagación;
- sleep/wake de tiles;
- persistencia según estado del mar.

Eventos iniciales:
- casco avanzando;
- giro;
- impacto plano;
- impacto de proa;
- objeto grande.

Detalle pequeño:
- procedural/shader;
- no aumentar solver sólo para microondas.

### Benchmark obligatorio
Probar:
- 128² / 256² / 512²;
- distintas dimensiones físicas por tile;
- distintas frecuencias;
- 1 / 4 / 8 / 16 fuentes;
- calm vs rough.

### Gate 7
Las perturbaciones deben:
- cruzarse;
- sumar/interferir;
- ser perceptibles físicamente;
- durar mucho más en calma;
- desaparecer antes en rough;
- no dominar el frame.

---

## Fase 8 — Spray y masas de agua

Implementar:
- agua gruesa temporal;
- partículas GPU;
- spray de casco;
- spray de impacto;
- spray de breaker;
- espuma pulverizada por viento.

Filosofía:
- causalidad física;
- presentación ligeramente amplificada;
- intensidad configurable.

### Gate 8
El impacto debe parecer desplazamiento de agua, no humo/partículas blancas.

---

## Fase 9 — Óptica estilo GTA V

Implementar por módulos:
- profundidad óptica;
- absorción;
- scattering;
- transparencia;
- refracción;
- Fresnel;
- caustics;
- turbidez.

### Gate 9
Tres pruebas visuales:
1. agua clara y calmada;
2. agua urbana/media;
3. agua turbia/tormenta.

La profundidad debe poder leerse visualmente.

---

## Fase 10 — Reflejos

Subsistema reemplazable.

Priorizar:
- cielo;
- sol/luna;
- skyline;
- luces urbanas;
- estructuras grandes;
- objetos cercanos.

Degradar:
- detalle lejano;
- geometría irrelevante;
- resolución;
- update rate.

### Gate 10
Gold City nocturno debe producir reflejos convincentes sin reflejar geometría inútil.

---

## Fase 11 — Underwater

Implementar:
- absorción;
- scattering;
- surface underside;
- inmersión parcial;
- whitewater desde abajo;
- turbidez;
- burbujas;
- transición continua.

### Gate 11
La cámara puede cruzar una ola sin cambio brusco de shader/estado.

---

## Fase 12 — Viento dinámico

Implementar evolución temporal:
- microondas primero;
- wind sea después;
- swell conserva memoria;
- cross sea;
- whitecaps;
- breaking;
- spindrift.

Mantener seed/determinismo.

### Gate 12
Una carrera puede evolucionar visual y físicamente de Calm/Race a Rough sin cambiar de “preset de océano”.

---

## Fase 13 — Tsunami

Sólo después de que:
- batimetría;
- run-up;
- whitewater;
- flow;
- underwater;
- turbidez

estén maduros.

Validar:
- onda larga;
- shoaling;
- bore;
- inundación;
- cámara engullida;
- agua turbia/aireada;
- retroceso.

### Gate 13
No aceptar una “ola normal gigante”.

---

# Matriz mínima de escenas de prueba

## Escena A — Mar abierto
- calm;
- race;
- rough;
- viento dinámico.

## Escena B — Playa
- fondo suave;
- banco de arena;
- spilling;
- plunging;
- swash/backwash.

## Escena C — Roca / arrecife
- breaking parcial;
- spray irregular;
- dispersión.

## Escena D — Muro / canal
- reflexión;
- clapotis;
- impacto;
- spray vertical.

## Escena E — Dos islas
- sombra;
- refracción;
- interferencia;
- cross sea.

## Escena F — Interacción
- múltiples jetskis falsos;
- estelas cruzadas;
- impactos;
- objeto grande.

## Escena G — Nocturna
- skyline;
- reflejos;
- emisivos;
- agua oscura.

## Escena H — Underwater
- agua clara;
- whitewater;
- inmersión parcial.

## Escena I — Tsunami
- aproximación;
- shoaling;
- bore;
- run-up;
- engulf.

---

# Criterios globales de aceptación

Ocean V3 sólo se considera listo para integración si cumple simultáneamente:

## Visual
- mar abierto convincente sin necesitar efectos para esconderlo;
- crestas con masa y dirección;
- breaking creíble;
- costa viva;
- foam/whitewater con persistencia;
- óptica y reflejos de nivel referente.

## Física
- ola visual = ola física;
- casco puede leer altura/normal/velocidad;
- perturbaciones relevantes son físicamente perceptibles;
- comportamiento estable y determinista.

## Rendimiento
- ningún módulo individual domina el frame sin justificación;
- todos los sistemas caros tienen knobs claros;
- Steam Deck mantiene el comportamiento macroscópico;
- PC potente escala principalmente calidad/densidad/distancia.

## Arquitectura
- renderer desacoplado de física;
- reflejos reemplazables;
- óptica modular;
- interactores genéricos;
- sin dependencias circulares entre subsistemas;
- cada módulo se puede desactivar para benchmark.

---

# Regla de trabajo durante implementación

Antes de cada fase:

1. revisar esta especificación;
2. revisar referencias técnicas relevantes;
3. preguntar qué comportamientos futuros puede bloquear;
4. revisar interacción con jetski/rider/cámara/VFX;
5. estimar coste;
6. definir benchmark;
7. implementar mínimo;
8. medir;
9. decidir si se mantiene, simplifica o descarta.

No convertir decisiones conceptuales antiguas en dogmas si los datos del prototipo muestran una solución mejor.

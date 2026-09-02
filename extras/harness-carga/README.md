# Medidor de carga + hook de contexto

Pone en el contexto de cada sesión de Claude Code cuánta cuota le queda a cada ejecutor
—Claude Code y Codex— y a qué ritmo la está gastando, para que la decisión "¿esto lo hago
aquí o lo delego?" se tome con un número en vez de por intuición.

## La métrica que decide: ritmo, no porcentaje

Todas las apps de cuota (incluida CuotaIA) muestran el porcentaje usado. Ese número no
alcanza para decidir, porque mezcla dos límites de naturaleza distinta:

- La **ventana corta** (5 h) se recupera sola. Un pico ahí no cuesta nada mañana.
- El **semanal** no se recupera hasta su reset. Es el único que puede dejarte sin
  ejecutor a mitad de semana.

Así que lo que importa es el ritmo: cuánto has gastado del semanal contra cuánto llevas
de la semana. El 2-sep-2026 los dos números decían cosas opuestas:

```
            ventana corta    semanal  sostenible   ritmo  queda/día
Claude        75% → 14:10      27.0%         16%    1.6x      12.5%
Codex          3% → 15:46      79.0%         36%    2.2x       4.7%
```

Codex tenía el **97 % de su ventana corta libre** y parecía el candidato obvio para
recibir carga. Pero su semanal iba a **2,2x del ritmo sostenible** y se agotaba al día
siguiente, con el reset cuatro días después. Mirar solo la ventana corta lleva a cargar
precisamente al ejecutor que se está muriendo.

## Instalación

```bash
./instalar.sh                 # instala los scripts y registra el hook SessionStart
./instalar.sh --solo-scripts  # instala sin tocar settings.json
```

Guarda un respaldo de `settings.json` con timestamp y es idempotente: correrlo dos veces
no duplica el hook.

## Uso

```bash
~/.claude/bin/carga-llm.sh          # tabla legible
~/.claude/bin/carga-llm.sh --json   # para otros scripts
```

## De dónde salen los datos

- **Claude Code**: `GET https://api.anthropic.com/api/oauth/usage` con el token OAuth del
  keychain (`Claude Code-credentials`), el mismo que usa CuotaIA. **Ese endpoint tiene
  rate limit propio** (HTTP 429 con ~11 llamadas en 15 min), así que el script cachea la
  respuesta 5 min y **nunca cachea un error**: guardar un 429 como si fuera una lectura
  buena es peor que no tener dato.
- **Codex**: el último bloque `rate_limits` que dejó en su rollout más reciente
  (`~/.codex/sessions/**/rollout-*.jsonl`). No se consulta ninguna API.

Si un proveedor no da datos, su fila dice `sin datos` y el hook no rompe la sesión.

## Qué inyecta el hook

La tabla, más la política de reparto: qué hace el hilo principal (decidir, verificar,
cerrar) y qué va a subagente con el modelo que le corresponde. Si existe
`~/.claude/carga-llm.local.md`, su contenido se anexa al final — ahí van las reglas propias
de cada instalación (qué ejecutor está autorizado en qué proyecto, casos concretos), que no
tienen por qué vivir en este repo. El fundamento es medido,
no opinado. Al medirlo sobre los transcripts de dos semanas de una instalación real, el
93 % del consumo se fue en el modelo más caro y cerca de dos tercios de los tokens salieron
del hilo principal, que arrastra todo el contexto acumulado y por eso paga cada tool call con
la ventana entera. Vale la pena medirlo en la propia instalación antes de decidir nada: el
log del guardián de modelo da ese número.

## El guardián de modelo (`require-agent-model.sh`)

Hook `PreToolUse` sobre las invocaciones de subagente. Impone dos cosas:

1. **Toda invocación declara `model`.** Omitirlo no es un default neutro: hereda el modelo
   de la sesión, que es el más caro, y gasta cuota sin que nadie lo haya decidido.
2. **Un modelo caro necesita una decisión previa por escrito.**

El punto 2 nació de un fracaso. La versión original bloqueaba el modelo caro solo si el
brief parecía recolección **y no** contenía ninguna palabra de juicio — una lista negra. Se
esquivaba escribiendo "evalúa" al pasar, sin ninguna intención de burlarla: así se redacta
normalmente. En la instalación donde se detectó, **una de cada tres invocaciones terminaba
en el modelo más caro y ninguna en el más barato**, con el guardián activo todo el tiempo.

Ahora la carga de la prueba está invertida. Un modelo caro pasa solo si:

- el `subagent_type` es un agente cuya **definición** (`~/.claude/agents/<nombre>.md`)
  declara ese modelo — eso ya es una decisión tomada, y volver a preguntarla en cada
  invocación es fricción sin información nueva; o
- el prompt trae `MODELO JUSTIFICADO: <razón>`, que deja el motivo por escrito.

Un agente genérico (`general-purpose`, `fork`, …) con modelo caro y sin justificación se
rechaza, con el mensaje que dice qué modelo corresponde. Pedir un modelo más caro que el
que declara la definición del agente también se rechaza; pedir uno más barato pasa.

Se registra cada invocación en `~/.claude/hooks/agent-model.log`, que es lo que permite
auditar después con qué modelo se hizo qué. Ese log fue el que reveló que las invocaciones
"sin model" eran intentos bloqueados y no ejecuciones: **el log se escribe antes de la
decisión**, y confundirlo habría llevado a arreglar un problema que no existía.

## El vigilante del hilo principal (`hilo-principal-delega.sh`)

El hilo principal de una sesión es el gasto más concentrado: corre en el modelo más caro y
arrastra todo el contexto acumulado, así que **cada tool call suya se paga con la ventana
entera**, mientras un subagente parte de cero y paga solo su brief. En la instalación donde
se midió, cerca de dos tercios de los tokens salían de ahí.

No se puede resolver con configuración, y vale la pena saber por qué:

- **No hay límite nativo de gasto para sesiones interactivas.** `--max-budget-usd` y
  `--max-turns` existen, pero solo en modo `-p`.
- **El payload de los hooks no trae telemetría de tokens ni de contexto.** Lo más cercano es
  `effort.level`, que es configuración, no consumo.
- Con `permissionDecision: "allow"`, el `permissionDecisionReason` **se le muestra al usuario
  pero no al modelo**. El único canal que llega al modelo es `additionalContext`.

Así que este hook cuenta y avisa. Lleva por sesión las tool calls del hilo principal y las
delegaciones, y cada 15 tool calls sin ninguna delegación le inyecta al modelo un aviso con
tres opciones explícitas: delegarlo, seguir porque es una decisión o una verificación corta,
o cerrar la faena y delegar el resto. Sobre el 85 % de la ventana de 5 h el aviso se endurece.

**No bloquea nada.** Interrumpir a media faena hace más daño que el gasto que evita.

Dos detalles de implementación que importan:

- Distingue el hilo principal de un subagente por la **ausencia** de `agent_id` en el
  payload: cuando el hook corre dentro de un subagente ese campo está presente, y ahí no hay
  nada que vigilar porque el subagente ya *es* la delegación.
- La cuota se lee **solo cuando toca avisar**, y a través del caché de `carga-llm.sh`, así que
  por muchas tool calls que haya no puede gatillar el rate limit del endpoint.

Overhead medido: **13 ms por tool call**. Requiere `jq`.

## Nota sobre husos horarios

Las horas de reset se muestran en la zona del sistema resolviendo su **nombre**
(`/etc/localtime`), no su offset. Usar el offset de hoy corre las fechas que cruzan un
cambio de horario de verano: con Chile pasando de −04 a −03, un reset del lunes 00:33
aparecía como domingo 23:33.

# Detección de consumo inusual

La app avisa cuando tu cuota se está gastando **más rápido de lo que acostumbras**. El caso que
busca cazar es concreto: lanzaste un comando, un agente o un bucle que se está comiendo la
semana sin que te dieras cuenta, y te enteras cuando ya no queda.

No es un umbral fijo. Un umbral fijo avisa cuando ya es tarde: "vas en 90%" no te dice si
llegaste ahí en cinco días de trabajo normal o en veinte minutos de un proceso desbocado.

## Qué se mide

La **ventana semanal**, no la de 5 horas.

La de 5 horas se resetea cuatro o cinco veces al día, y cada reset produce un salto negativo que
hay que descartar. Con muestras cada 60 segundos eso deja el historial lleno de huecos y de
tramos cortos. La semanal, en cambio, crece de forma monótona durante siete días: es una señal
mucho más limpia para estimar un ritmo.

## Cómo se muestrea

Cada 5 minutos se anexa una línea a `~/Library/Application Support/CuotaIA/history-<id>.jsonl`:

```json
{"t":1787977055,"s":34.0,"w":66.0}
```

`t` epoch en segundos, `s` la ventana corta, `w` la semanal. Se podan las muestras de más de
14 días al arrancar. El archivo es tuyo y no sale de tu Mac.

Cuando una consulta falla, la app aplica un backoff exponencial por proveedor (hasta 30 minutos,
respetando la cabecera `Retry-After`), así que el intervalo real entre muestras puede ser mayor
que 5 minutos. Por eso el descarte está en 25 y no en 15.

## Cómo se calcula el ritmo

Entre dos muestras consecutivas:

```
dt   = (t_i − t_i−1) / 60          minutos
dw   = w_i − w_i−1                 puntos porcentuales
rate = dw / dt                     pp/min
```

Se descarta la pareja si:

| Condición | Por qué |
|---|---|
| `dt < 0,5 min` | dos lecturas casi simultáneas: el cociente se dispara por ruido |
| `dt > 25 min` | el Mac durmió o la app estuvo cerrada; el consumo no ocurrió "en ese rato" |
| `dw < 0` | la ventana semanal se reseteó |

## Cuál es tu ritmo normal

La línea base se calcula sobre los últimos 7 días, usando **solo las tasas mayores que cero**.
Las horas en que no trabajaste no dicen nada sobre tu ritmo de trabajo; incluirlas empujaría la
base hacia cero y volvería la alerta histérica.

Se usa **mediana y MAD**, no media y desviación estándar:

```
m     = mediana(rates)
MAD   = mediana(|rate_i − m|)
sigma = 1,4826 × MAD
```

La media y la desviación estándar son justamente lo que una ráfaga contamina: el evento que
quieres detectar se mete en la estadística que debería servir para detectarlo. La mediana y el
MAD son robustos — hasta la mitad de las muestras pueden ser atípicas sin mover la referencia.
El `1,4826` es el factor que hace que `sigma` sea comparable a una desviación estándar cuando
los datos son normales.

## Cuándo dispara

```
piso   = 0,35 pp/min
umbral = max(m + 3·sigma, piso)
actual = media de las últimas 3 tasas válidas
dispara si actual > umbral
```

Tres decisiones que importan:

**El piso de 0,35 pp/min.** Sin él, alguien con una base cercana a cero recibiría una alerta la
primera vez que abre una sesión. 0,35 pp/min son 21 puntos por hora: a ese ritmo la semana
completa se consume en menos de cinco horas seguidas. Ese es exactamente el evento que vale la
pena interrumpirte.

**Tres muestras, no una.** Promediar tres lecturas evita que un solo tick raro —una lectura
retrasada, un salto por redondeo del servidor— genere un falso positivo. El precio es la latencia:
con muestreo cada 5 minutos, una ráfaga tarda unos 15 minutos en avisarte. El muestreo no puede
ser más rápido porque el endpoint de cuota de Anthropic corta a las pocas peticiones por minuto,
y una app que se autolimita deja de servir para lo que existe.

**Menos de 30 tasas positivas en el historial: no hay base.** Durante los primeros días la app
usa solo el piso. Prefiere no avisar a avisar mal: una alerta que se equivoca al principio es
una alerta que vas a silenciar para siempre.

## Qué dice la alerta

> **Claude va rápido** — 1,8%/min, 4× tu ritmo normal.
> A este ritmo la cuota semanal se acaba en 19 min.

Lo accionable es la proyección (`restante ÷ ritmo actual`), no el múltiplo. "4× lo normal" puede
ser inofensivo si venías de cero; "se acaba en 19 minutos" nunca lo es. El múltiplo se omite
mientras no haya línea base.

**Cooldown de 45 minutos** por proveedor, y no vuelve a disparar hasta que el ritmo baje del
umbral y suba de nuevo. Una ráfaga larga te avisa una vez, no cuarenta.

## Alertas de umbral

Aparte del detector, hay dos avisos simples al cruzar **80%** y **95%** de la cuota semanal, una
sola vez cada uno por ventana. Se rearman solos cuando cambia la fecha de reset.

## Probar el detector sin esperar una semana

```bash
./CuotaIA.app/Contents/MacOS/CuotaIA --simulate fixtures/rafaga.jsonl   # debe disparar
./CuotaIA.app/Contents/MacOS/CuotaIA --simulate fixtures/normal.jsonl   # no debe disparar
```

`--simulate` carga ese archivo como historial, corre el detector completo y dice si dispararía y
con qué texto. No toca la red ni tu historial real. Cualquier ajuste de los parámetros se valida
ahí antes de tocar el código.

## Ajustar los parámetros

Todos viven juntos al inicio de `Sources/UsageHistory.swift`. Si cambias uno, corre los dos
fixtures: están para que un ajuste no rompa en silencio el otro extremo del comportamiento.

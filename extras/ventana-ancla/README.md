# Anclar la ventana de 5 h

Fija el reset de la ventana rodante de Claude Code en una rejilla de horas propia
(por defecto **06 / 11 / 16 / 21**) en vez de dejarla donde caiga.

## El problema

La ventana de 5 h se ancla en el primer mensaje que mandas después de que expiró la
anterior, **al minuto exacto** — no redondea a la hora en punto (medido: ancla 09:09 →
reset 14:09). Como 24 no es múltiplo de 5, la hora del corte de la tarde depende por
completo de a qué hora arrancaste el día. Si tu franja de mayor consumo es la noche,
un arranque a las 10:45 hace que esa franja caiga siempre en una ventana ya avanzada.

Con la rejilla clavada eliges dónde caen los cortes. Ejemplo con 06/11/16/21: el tercer
corte deja una ventana fresca entrando a las 21:00.

## Por qué no basta un cron a las 6 AM

Es lo que hacen los scripts de *warmup* que circulan, y tiene un agujero: **el drift es
acumulativo**. Si a las 11:00 estás en pausa y vuelves 11:40, la ventana pasa a
11:40–16:40 y el corte de la noche se corre a 21:40 — justo lo que querías evitar.

Este script corre cada 10 minutos y reintenta dentro de una ventana de gracia de 90 min:
el primer chequeo que encuentre la ventana anterior ya expirada, ancla. La rejilla se
mantiene sola sin que tengas que estar al teclado.

## Instalación

```bash
./instalar.sh              # instala y carga el LaunchAgent
./instalar.sh --desinstalar
```

Para cambiar las horas, edita `TARGETS` en `~/.claude/bin/ventana-ancla.sh`.

## Qué hace en cada corrida

1. ¿La hora cae en la gracia de algún target? Si no, sale sin hacer nada.
2. ¿Ese target ya se ancló hoy? Sale.
3. ¿Ya sabe cuándo expira la ventana viva? Espera **sin consultar el endpoint**.
4. Si no lo sabe, consulta la cuota. Ventana viva → espera.
5. Ventana expirada → `claude -p "ok" --model haiku` y **verifica** que el reset
   resultante quedó donde debía, con el desvío en el log.

## Dos cosas que hay que saber

- **El endpoint de cuota tiene rate limit propio** (HTTP 429 con ~11 llamadas en 15 min).
  CuotaIA ya lo sondea cada 5 min, así que este script cachea el `resets_at` conocido en
  `~/.claude/state/ventana-ancla.reset` y consulta ~2 veces por target en vez de 9.
  Una respuesta sin la clave `five_hour` hace fallar la lectura a propósito: traducir un
  429 a "no hay ventana viva" dispararía un heartbeat a ciegas.
- **Esto reordena tu cuota, no la expande.** El límite semanal es independiente y sigue
  siendo el techo real. Si empiezas a chocar contra el semanal, más anclas no ayudan.

## Log

`~/.claude/logs/ventana-ancla.log` — una línea por decisión, con el porcentaje de uso y
el reset resultante. Es la serie de datos para evaluar si la rejilla te sirve.

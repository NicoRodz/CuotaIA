# CuotaIA

Cuánta cuota te queda en **Claude Code** y **Codex**, en la barra de menús de tu Mac.

```
 ✳ 39%   ⌘ 4%
```

Un icono por herramienta y la ventana de 5 horas. Cuando la cuota **semanal** de una de las dos
pasa de 75%, esa herramienta muestra las dos cifras (`✳ 39%·82%`) con la semanal coloreada: la
app se mantiene compacta mientras no hay nada que mirar, y se vuelve explícita cuando sí lo hay.

Un clic abre el panel con las barras de ambas ventanas, el plan de cada cuenta, el desglose
semanal por modelo y la hora a la que se reinicia cada una.

La app además **avisa cuando estás consumiendo cuota más rápido de lo habitual** — el caso de
haber lanzado algo que se está comiendo la semana sin que te enteres. Cómo se calcula eso está
en [`docs/DETECCION-ANOMALIAS.md`](docs/DETECCION-ANOMALIAS.md).

## Requisitos

- macOS 11 o superior
- Xcode Command Line Tools (`xcode-select --install`)
- Al menos una de las dos herramientas instalada y con sesión iniciada

**Si solo tienes una, la app muestra solo esa.** No hay que configurar nada: si `codex` no está
en el Mac, su sección no aparece.

## Instalación

```bash
git clone https://github.com/<tu-usuario>/CuotaIA.git
cd CuotaIA
./build.sh
open .
```

Arrastra `CuotaIA.app` a Aplicaciones y ábrela. Para que arranque sola, activa **Abrir al iniciar
sesión** en el panel de la app.

Compilar desde el código en tu propia máquina es a propósito: evita la advertencia de Gatekeeper
que sale con cualquier `.app` descargada sin firmar, y de paso puedes leer exactamente qué hace
antes de darle acceso a tus credenciales.

## De dónde salen los datos

| | Credencial | Consulta |
|---|---|---|
| **Claude Code** | Llavero de macOS, item `Claude Code-credentials` | `api.anthropic.com/api/oauth/usage` |
| **Codex** | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |

Son las mismas credenciales que ya usan las dos CLI en tu Mac, y los mismos servidores a los que
ya les hablan.

- **La app solo lee.** Nunca escribe ni renueva credenciales. Si el token de Claude vence, lo
  renueva la propia CLI la próxima vez que la uses; mientras tanto CuotaIA muestra el último
  valor conocido, atenuado.
- **No hay servidores de por medio.** Tu Mac le habla directo a Anthropic y a OpenAI. No hay
  telemetría, ni analítica, ni terceros.
- **El historial es local.** Vive en `~/Library/Application Support/CuotaIA/` y no sale de ahí.

> **Aviso.** Ninguno de los dos endpoints es una API pública documentada: son los que usan las
> propias herramientas. Pueden cambiar sin previo aviso y dejar la app muda hasta que se
> actualice. Nada aquí está afiliado a Anthropic ni a OpenAI.

## Uso desde la terminal

```bash
# Estado actual de todo, sin interfaz
./CuotaIA.app/Contents/MacOS/CuotaIA --once

# Probar el detector de anomalías con datos sintéticos (no toca la red)
./CuotaIA.app/Contents/MacOS/CuotaIA --simulate fixtures/rafaga.jsonl

# Dibujar el panel a PNG en tema claro y oscuro, sin abrir ventanas
./CuotaIA.app/Contents/MacOS/CuotaIA --render /tmp/panel.png

# Abrir el panel real en pantalla, sin clic, para revisar el vidrio
./CuotaIA.app/Contents/MacOS/CuotaIA --demo
```

`--once` sirve para meter la cuota en tu `statusline`, un script o un cron.

## Cómo está hecha

AppKit puro, sin dependencias, sin gestor de paquetes: `build.sh` invoca `swiftc` sobre
`Sources/` y arma el bundle. El panel es un `NSPanel` sin borde cuyo contenido va dentro de un
`NSGlassEffectView` — el vidrio del sistema de macOS 26, el mismo que usan Control Center y
Clima, que se adapta solo al fondo, al tema claro/oscuro y a "Reducir transparencia". En macOS
anteriores cae a un `NSVisualEffectView` de material `menu`. No es un `NSPopover` — ese pinta su
propio fondo opaco y no se cierra cuando abres otro ítem de la barra.

`build.sh` elige el `swiftc` más nuevo de los instalados en vez de confiar en `xcrun`: un Xcode
antiguo conviviendo con unos Command Line Tools recientes deja a `xcrun` apuntando al compilador
viejo, que no conoce las API de macOS 26.

```
Sources/
  Models.swift              contratos: QuotaProvider, Snapshot, Severity
  ClaudeProvider.swift      llavero + endpoint de Anthropic
  CodexProvider.swift       auth.json + endpoint de OpenAI
  UsageHistory.swift        muestreo, persistencia y detector
  Notifier.swift            notificaciones y cooldowns
  StatusBarController.swift el ícono, el texto y el timer
  ProviderIcon.swift        el símbolo de cada herramienta, compartido por barra y panel
  PanelUI.swift             el panel de vidrio
  LoginItem.swift           arranque automático vía LaunchAgent
  main.swift                arranque y modos de terminal
```

Los comentarios y la documentación están en español; los identificadores, en inglés.

## Licencia

MIT.

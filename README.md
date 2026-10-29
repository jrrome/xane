# XaneWM

Gestor de ventanas en mosaico para macOS, nativo en Swift, con la filosofía de un compositor
Wayland (sway, river, Hyprland). Toma como base el estudio de Shoji 1.2.3 (`../rea-shoji/pseudocodigo`)
e incorpora las propuestas de `MEJORAS.md`.

```
xanectl layout tile          xanectl "view 2; focus main"          xanectl query windows | jq
```

## Filosofía: un compositor Wayland sobre macOS

macOS no deja reemplazar el compositor, pero sí aplicar sus principios por encima de Accessibility:

| Principio Wayland | Cómo se aplica aquí |
|---|---|
| **El compositor manda.** Los clientes no deciden su geometría. | El estado del compositor es la verdad y la pantalla es su proyección. Si una app mueve o redimensiona sola una ventana en mosaico (`AXMoved`/`AXResized` sin arrastre del usuario), se vuelve a colocar. Si insiste, se le da tregua para evitar bucles. |
| **Estado con doble búfer y commit atómico** (`wl_surface.commit`). | Los comandos modifican `pending`. `commit()` calcula el layout completo, compara con la realidad y genera una `Transaction` con todos los cambios a la vez. `view 2; focus main` se aplica de una sola vez, sin estados intermedios. |
| **configure / ack con serial** (`xdg_surface`). | Cada petición de geometría lleva un serial. La app "confirma" con el marco que tomó realmente. Los acks antiguos se descartan. Si la ventana sale más grande de lo pedido, es su tamaño mínimo (`set_min_size`) y se aprende. |
| **Agarre interactivo** (move/resize grab). | Mientras el botón está pulsado no se mueve nada bajo el usuario. Al soltar se interpreta el gesto: redimensionar cambia los ratios del layout y soltar sobre otra ventana las intercambia o la manda a otra pantalla. |
| **Todo es un comando por IPC** (swaymsg, riverctl). | Un único lenguaje para la config, los atajos y `xanectl`, servido por un socket Unix (`/tmp/xanewm-<uid>.sock`). `xanectl subscribe` emite eventos JSON. |
| **Generadores de layout puros** (river-layout). | `XaneCore` no sabe nada de AppKit: de (área, nº de ventanas, mínimos, parámetros) a rectángulos. Se testea en cualquier plataforma. |
| **Tags en lugar de escritorios** (river, dwm). | Cada pantalla muestra una máscara de tags y cada ventana tiene las suyas. Puedes ver varios tags a la vez y poner una ventana en varios. |
| **Sin polling: todo va por eventos.** | `AXObserver` por app (creación, destrucción, movimiento, tamaño, foco, minimizar, ocultar), notificaciones de `NSWorkspace` y de pantallas. El permiso de Accesibilidad se espera con la notificación del sistema. |

## Arquitectura

```
 ┌──────────── XaneWM.app (proceso compositor, LSUIElement) ─────────────────────────────┐
 │                                                                                         │
 │  HotKeys (Carbon) ─┐    SocketServer (hilo IPC) ─┐    MouseMonitor (grab / FFM)          │
 │                    ▼                             ▼                                       │
 │            Server.run("cmd") ──► Compositor.execute ──► pending ──► commit() ──► Transaction
 │                    ▲               (XaneCore, puro)                     │   configures    │
 │                    │ eventos (main queue)                               ▼   por app       │
 │   ┌────────────────┴───────────┐   ┌────────────────────────────────────────────────┐    │
 │   │ AppWorker  pid 501 (hilo)  │   │ AppWorker  pid 733 (hilo) …  uno por app        │    │
 │   │ AXObserver + todas sus     │   │ en paralelo; si una app se cuelga solo se       │    │
 │   │ llamadas AX, en serie      │   │ bloquea su hilo                                 │    │
 │   └────────────────────────────┘   └────────────────────────────────────────────────┘    │
 │   WindowServer (CGWindowList: Space actual) · Displays · BorderOverlay · StatusBar      │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
          ▲ xanectl (CLI)
```

- **`Sources/XaneCore`** (puro, multiplataforma, con tests):
  - `Layout/`: árbol de cortes binarios con solver exacto de mínimos, generadores y "encajar el máximo de ventanas".
  - `Compositor/`: estado, commit, configure/ack, navegación, persistencia y aprendizaje de mínimos.
  - `Command/`: parser y config.
  - `IPC/`: protocolo y servidor de socket.
- **`Sources/XaneWM`** (macOS):
  - `Platform/AppWorker.swift`: un hilo con run loop por app.
  - `Platform/AX.swift`: utilidades AX.
  - `Platform/System.swift`: ventanas, pantallas, permisos y persistencia.
  - `Platform/Input.swift`: atajos, ratón y logs.
  - `Platform/Chrome.swift`: borde y barra de menús.
  - `Server.swift`: el orquestador.
- **`Sources/xanectl`**: cliente IPC.

### Motor de layout

Todo layout es un árbol de cortes binarios. Como los ejes se fijan antes de resolver, los mínimos de
cada subárbol se propagan de forma exacta y cada corte se resuelve en forma cerrada:

```
primero = clamp(ratio · disponible, mínimoPrimero, disponible − mínimoSegundo)
```

No hay bisección (Shoji hace 12 iteraciones por layout): cada intento es exacto. Si los mínimos no
caben, se prueba con una tesela menos y las ventanas sobrantes se apilan en la tesela con foco
(o flotan, con `set overflow float`). Cuesta microsegundos.

| Layout | Descripción |
|---|---|
| `dwindle` | BSP que corta siempre el lado más largo del área restante. Se adapta solo a monitores verticales, ultrapanorámicos e intermedios (MEJORAS §7). |
| `tile` | Principal + pila. Orientación `left/right/top/bottom` y `main-count` ajustables. |
| `columns` / `rows` | Reparto lineal exacto, con los huecos descontados. |
| `grid` | Cuadrícula adaptada a la proporción de la pantalla. |
| `monocle` | Todas ocupan el área completa. |

Redimensionar con el ratón o con `resize grow|shrink` mueve el corte que toca esa ventana. Los
ratios se guardan por **(pantalla, layout, nº de teselas)** (MEJORAS §8), así que redimensionar en
`tile` con 3 ventanas no deforma `grid` con 4.

## Qué se ha tomado de Shoji y qué cambia (MEJORAS.md)

| # | Propuesta | Estado |
|---|---|---|
| 1 | AX fuera del hilo principal y en paralelo por app | ✅ `AppWorker`: un hilo por app y peticiones fusionadas (solo se aplica la última por ventana) |
| 2 | `AXMoved`/`AXResized` e inventario incremental | ✅ eventos por ventana, inventario completo solo como respaldo (cambio de Space, al despertar) |
| 3 | Mínimos por tipo de ventana | ✅ clave `bundleID` + `AXIdentifier` (o subrol) |
| 4 | Escondite robusto para workspaces | ✅ esquina elegida por geometría (sin pantalla vecina), verificación y reintento |
| 5 | Logs privados | ✅ `os.Logger` con `privacy: .private` para nombres de apps; los títulos nunca se registran |
| 6 | Proporción en forma cerrada | ✅ solver exacto (ver arriba) |
| 7 | Grid consciente del aspecto | ✅ `dwindle` y `grid` |
| 8 | Ratios por (pantalla, layout, n) | ✅ |
| 9 | Permiso por notificación | ✅ `com.apple.accessibility.api`, con sondeo solo mientras falta el permiso |
| 10 | VoiceOver y `AXEnhancedUserInterface` | ✅ una vez por lote y app, y nunca con VoiceOver activo |
| 11 | Migrar mínimos en vez de borrarlos | ✅ pasan a "sospechosos" y se confirman al primer uso |
| 12 | Partir los objetos grandes | ✅ núcleo puro separado y comandos tipados en lugar de decenas de closures |
| 13 | Hueco exterior independiente | ✅ `gap-inner` / `gap-outer` |

También se conservan del original:

- el orden de pasos tamaño/posición, para que los bordes de pantalla no recorten la ventana;
- la verificación del marco tras mover;
- el doble chequeo antes de aprender un mínimo y los mínimos de casi toda la pantalla solo para la sesión;
- el área útil mínima de 400×300;
- la pausa durante el Stage Manager, el bloqueo de pantalla y el reposo;
- la cascada de 28 pt para lo que no cabe.

## Robustez

- **Nunca deja ventanas perdidas.** Al salir (menú, `xanectl quit`, `SIGTERM`) se devuelven a la vista las ventanas aparcadas. Tras un cuelgue, al arrancar, cualquier ventana fuera de pantalla se recupera, y los tags de cada ventana se restauran desde `~/Library/Application Support/xanewm/state.json`.
- **Apps colgadas.** Las llamadas AX tienen timeouts de 0,25 s por ventana y 0,5 s por app. Una app que no responde solo bloquea su hilo, y sus ventanas se conservan.
- **Peticiones perdidas.** Cada configure caduca a los 1,5 s. Si la realidad no coincide con lo pedido, el siguiente commit lo reenvía.
- **Apps que pelean.** Si una ventana se recoloca más de 4 veces en 3 s, se la deja en paz un rato.
- **Ventanas que se crean a medias.** Se vuelven a examinar a los 0,2 s y 0,8 s, y otra vez si cambian de tamaño.
- **Spaces nativos.** Solo se gestiona el Space actual. Las ventanas de otros Spaces conservan su sitio en el modelo y vuelven a colocarse al regresar. Las pestañas nativas funcionan solas: solo la pestaña visible ocupa tesela.
- **Instancia única** por socket. Con `make autostart`, launchd la reinicia si se cae (no si la cierras tú).

## Requisitos e instalación

macOS 13 o posterior, y Xcode 15+ (o la toolchain de Swift 5.9+).

```sh
cd xanewm
make test            # tests del núcleo (también corren en Linux)
make                 # compila y crea XaneWM.app (firma ad-hoc)
make install         # ~/Applications/XaneWM.app + ~/.local/bin/xanectl
open ~/Applications/XaneWM.app
make autostart       # opcional: arrancar al iniciar sesión y reiniciar si se cae
make logs            # log en vivo
```

La primera vez pedirá **Accesibilidad** (Ajustes del Sistema → Privacidad y seguridad →
Accesibilidad). macOS asocia el permiso a la firma. Con firma ad-hoc, cada recompilación parece
una app nueva y el permiso se pierde aunque el interruptor siga activado. Por eso `make` firma con el
primer certificado "Apple Development" del llavero si lo hay (o con `make SIGN_ID="…"`). Solo
recurre a la firma ad-hoc si no encuentra ninguno.

## Uso

La config está en `~/.config/xanewm/config` y se crea comentada la primera vez. Cada línea es un comando.

| Atajo (prefijo ⌃⌥) | Acción |
|---|---|
| `h j k l` | foco a izquierda / abajo / arriba / derecha (cruza pantallas) |
| `⇧ + h j k l` | intercambiar en esa dirección |
| `n` / `p` | ventana siguiente / anterior |
| `↩` | zoom: la ventana pasa a principal |
| `⇧ espacio` / `f` | flotar / pantalla completa del compositor |
| `d t c g m` | layout dwindle / tile / columns / grid / monocle |
| `\` | siguiente layout |
| `.` / `,` | agrandar / encoger |
| `=` / `-` | más / menos ventanas principales (`tile`) |
| `o` | rotar la orientación (`tile`) |
| `0` | restablecer proporciones |
| `1…9` | ver tag N (repetir vuelve al anterior) |
| `⇧ + 1…9` | mover la ventana al tag N |
| `tab` | tags anteriores |
| `[` / `]` | foco a la pantalla anterior / siguiente (con `⇧`: mover la ventana) |
| `r` / `⇧ r` | recolocar todo / recargar config |
| `⇧ p` | pausar / reanudar |
| `⇧ c` | cerrar ventana |

Con el ratón: arrastra una ventana sobre otra para intercambiarlas, o a otra pantalla para moverla
allí. Arrastra un borde para cambiar la proporción.

### Comandos

```
focus|swap  left|right|up|down|next|prev|main|recent      zoom
float|fullscreen [toggle|on|off]                           close
layout dwindle|tile|columns|rows|grid|monocle|next|prev
main-ratio 0.6|+0.05|-0.05      main-count 2|+1|-1      orientation left|right|top|bottom|next
resize grow|shrink [0.05] [horizontal|vertical]           reset-layout
view N|1,3|all|prev   view-toggle N   tag N|all   tag-toggle N
set-focused-tags MASK   set-view-tags MASK                 (compatibles con river)
focus-output next|prev|left|right|N     send-to-output next|prev|left|right|N
set <opción> <valor>    rule float|tile|ignore|tags N|output N  app-id X [title REGEX] [subrole S]
bind <teclas> <comando…>    unbind <teclas>|all    rule-clear
query windows|outputs|tree|state|bindings|rules|options    subscribe
exec <shell>    retile    reload    pause|resume|toggle-pause    quit
```

Opciones: `gap`, `gap-inner`, `gap-outer`, `default-layout`, `main-ratio`,
`attach top|bottom|after-focused`, `overflow stack|float`, `max-tiled`,
`new-window-output pointer|focused|app`, `focus-follows-mouse`, `focus-follows-mouse-delay`,
`mouse-follows-focus`, `view-back-and-forth`, `follow-activation`, `border`, `border-width`,
`border-color accent|#RRGGBB`, `border-radius`, `edges <arriba derecha abajo izquierda>`,
`enforce-layout`.

Teclas: `ctrl alt shift cmd` (o `hyper` / `meh`) + `a-z 0-9 return space tab escape left right up down
comma period slash semicolon quote leftbracket rightbracket backslash minus equal grave f1-f20`.

Ejemplos de scripting:

```sh
xanectl subscribe | while read -r ev; do echo "$ev"; done      # para una barra (SketchyBar…)
xanectl query outputs -p
xanectl rule tags 9 app-id com.spotify.client
```

## Límites conocidos

- **No mueve ventanas entre Spaces nativos.** Eso exige APIs privadas de SkyLight. Usa tags y un solo Space por pantalla.
- **Usa una única llamada privada:** `_AXUIElementGetWindow`, para dar a cada ventana una identidad estable compartida con `CGWindowList`. La usan yabai, AeroSpace, Amethyst y Rectangle, y lleva años estable. Todo lo demás es API pública y no necesita desactivar SIP.
- **Stage Manager:** se pausa mientras está activo, igual que Shoji.
- **Pantalla completa nativa:** la ventana se va a su propio Space y sale del mosaico. `fullscreen` (⌃⌥F) es la alternativa del compositor.
- **Hotkeys de Carbon:** no funcionan mientras otra app usa Secure Input (campos de contraseña). Es una restricción del sistema.

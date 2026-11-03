# vpn-forti

Herramienta independiente para comprobar y reconectar la VPN SSL de **FortiClient 7.0** (el túnel configurado en FortiClient; en PORTIC, «VPN Cerdanyola»).
Automatiza la consola de FortiClient (abrirla, rellenar el formulario, pulsar Conectar) y lee el **PIN del segundo factor** que llega por correo desde **Outlook web**, así que la reconexión es automática de principio a fin. Si el PIN no llega, avisa al usuario para que lo meta a mano.

La llaman otras apps (la primera, la skill `comparativa-migracion-web`) con la orden `asegurar`.

## Requisitos

- Windows 10/11 con PowerShell 5.1.
- **FortiClient 7.0** con el túnel SSL VPN de PORTIC ya creado en la consola.
- **Node 18** o posterior.
- **Microsoft Edge** (o Google Chrome).
- Una cuenta de PORTIC con correo en Outlook (el PIN del segundo factor llega allí).

`instalar.ps1` comprueba todo esto, pero **no instala programas**: si falta alguno lo dice y sale con el código 2.

## Instalación

### Desde el instalador de la comparativa

El instalador de la skill `comparativa-migracion-web` clona este repositorio y ejecuta:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File <carpeta>\instalar.ps1 -Silencioso -PedirCredencial
```

Solo hay que escribir usuario y contraseña de la VPN en el diálogo de Windows, si aún no estaban guardados.

### A mano, por clonado

```bat
git clone https://github.com/daniscsi/vpn-forti.git "%USERPROFILE%\Herramientas\vpn-forti"
cd /d "%USERPROFILE%\Herramientas\vpn-forti"
powershell -NoProfile -ExecutionPolicy Bypass -File instalar.ps1 -PedirCredencial
```

La carpeta puede ser cualquiera (mejor fuera de OneDrive, para que no sincronice `node_modules`).

### Qué hace `instalar.ps1`

Se puede ejecutar tantas veces como haga falta: sirve también para **reparar o actualizar** (después de un `git pull`).

1. Comprueba Node ≥ 18, Edge o Chrome y FortiClient.
2. `npm ci` (o `npm install` si no hay `package-lock.json`). Solo hay una dependencia, `playwright-core`, que usa el Edge o Chrome instalado.
3. Si no existe `config.json`, lo crea a partir de `config.ejemplo.json` con el **túnel detectado** en el registro de FortiClient (`HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels`). Si hay varios, usa el primero y lo avisa; si solo hay Chrome, pone `pin.canal = "chrome"`. Un `config.json` existente no se toca.
4. Fija la variable de entorno de usuario `VPN_FORTI` con la ruta de `vpn.ps1` (las apps la buscan ahí). Las consolas ya abiertas no la ven: el JSON la devuelve en `vpnForti`.
5. Si falta la tarea que arranca el servicio de FortiClient sin UAC (ver «Tarea del servicio de FortiClient»), lanza `vpn.ps1 instalar-tarea`: **un único UAC** que hay que aceptar. Con `-Silencioso` solo lo hace si se añade `-InstalarTarea`; si no, lo deja en `avisos`. Si no se instala, `tarea` es `false` y el código no cambia.
6. Comprueba la credencial y, con `-PedirCredencial`, abre el diálogo de `guardar-credencial` si aún no existe.

| Parámetro | Efecto |
|---|---|
| `-PedirCredencial` | Si no hay credencial genérica utilizable, abre el diálogo para guardarla. |
| `-InstalarTarea` | Con `-Silencioso`, instala también la tarea del servicio (un UAC). Sin `-Silencioso` ya se instala por defecto. |
| `-SinTarea` | No instala la tarea del servicio (queda en `avisos`). |
| `-Silencioso` | Sin mensajes ni ventanas (salvo el diálogo de la credencial y, con `-InstalarTarea`, el UAC); escribe en stdout una línea JSON con el resultado. El progreso va a stderr y a `%LOCALAPPDATA%\vpn-forti\instalar.log`. |
| `-Tunel "nombre"` | Túnel que se escribe en el `config.json` nuevo (si no, el detectado). |

Salida con `-Silencioso` (una línea):

```json
{"ok":true,"codigo":0,"version":"1.0.0","vpnForti":"C:\\...\\vpn-forti\\vpn.ps1","raiz":"C:\\...\\vpn-forti","node":{"ruta":"...","version":"v24.19.0"},"navegador":{"canal":"msedge","ruta":"..."},"fortiClient":"...","tunel":"VPN Cerdanyola","tuneles":["VPN Cerdanyola"],"config":{"ruta":"...","estado":"creado"},"dependencias":{"orden":"npm ci","playwrightCore":"1.64.1"},"credencial":true,"usuario":"...","faltan":[],"avisos":[],"mensaje":null}
```

| Código | Significado |
|---|---|
| 0 | Instalado (o ya lo estaba). `credencial` puede ser `false` si no se ha pedido: queda en `avisos`. |
| 1 | Error inesperado (`mensaje`). |
| 2 | Falta un requisito: `faltan` contiene `node`, `navegador` y/o `forticlient`. |
| 3 | Ha fallado npm (detalle en `%LOCALAPPDATA%\vpn-forti\instalar.log`). |
| 4 | Instalado, pero se ha pedido la credencial y se ha cancelado el diálogo. |

### Desinstalar

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File desinstalar.ps1 [-BorrarCredencial] [-Silencioso]
```

Quita la variable `VPN_FORTI` y la tarea `vpn-forti-servicio` (llama a `vpn.ps1 desinstalar-tarea`; si Windows no la deja borrar sin elevar, sale un UAC). Con `-BorrarCredencial` borra además las credenciales genéricas `vpn-forti:<túnel>` y el perfil de Outlook web (`%LOCALAPPDATA%\vpn-forti\perfil-outlook`). No borra la carpeta del código ni la credencial `FortiClient`. Códigos: 0 bien, 1 error (p. ej. el perfil está en uso porque Edge sigue abierto).

## Primera vez: tarea del servicio, credencial y sesión de Outlook

### Tarea del servicio de FortiClient (un único UAC)

```bat
vpn.cmd instalar-tarea
```

Sale **una vez** el Control de cuentas de usuario: acéptalo. Desde entonces la VPN se reconecta sin UAC.

**Por qué.** FortiClient VPN depende del servicio `FA_Scheduler` («FortiClient VPN Service Scheduler», `scheduler.exe`), que es de **inicio manual** y cuya ACL no deja arrancarlo a un usuario sin elevar. Tras reiniciar Windows el servicio está parado; al abrir `FortiClient.exe` en ese estado, FortiClient pide elevación para arrancarlo y sale el UAC. Una vez arrancado, el servicio sigue en marcha hasta el siguiente reinicio, así que el UAC solo salía **la primera conexión después de cada arranque** (comprobado el 31/10/2026: arranque 19:54:49, `vpn-forti` abre la consola a las 20:05:31 y `scheduler.exe` arranca a las 20:05:35). `FortiClient.exe` y `FortiTray.exe` son `asInvoker`; los que piden administrador son `scheduler.exe` y `FortiSSLVPNdaemon.exe`, que lanza el propio servicio.

**Qué registra.** La tarea programada `\vpn-forti-servicio`, con «ejecutar con los privilegios más altos», a nombre de tu usuario y solo con la sesión abierta. Su única acción es `<directorio del sistema>\sc.exe start FA_Scheduler` (ruta y argumentos fijos: no ejecuta ningún script de la carpeta del usuario). El servicio y el nombre de la tarea están **fijos en el código**: el proceso elevado no toma nada de `config.json` (si `config.json` trae `servicioForti` o `tareaServicio`, se ignoran con un aviso). Su seguridad es `O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGXSD;;;<tu SID>)`: propietario Administradores, control total para SYSTEM y Administradores, y para tu usuario solo leer, ejecutar y borrar. Así nada sin elevar puede cambiar la acción de una tarea que corre elevada. Al instalar se borra la tarea anterior si existe, se crea de nuevo y se comprueba: si la acción no es exactamente esa, si no tiene privilegios más altos, si el propietario no es Administradores o si alguien que no sea SYSTEM o Administradores tiene escritura, `WD` o `WO`, se borra y sale con 1. No se toca el UAC, ni las políticas, ni la configuración del servicio.

**Cómo se usa.** Antes de abrir la consola, `conectar`, `asegurar` y `volcar` miran el servicio. Si está parado y la tarea existe, la lanzan (equivale a `schtasks /run /tn vpn-forti-servicio`, sin UAC) y esperan a que el servicio esté en marcha (`esperaServicioSeg`, 30 s; si no, código 7). Si está parado y **no** hay tarea:

- llamada desde una app (salida redirigida): notificación «falta la tarea de vpn-forti» y **código 7**, sin abrir FortiClient, en lugar de quedarse esperando a un UAC que nadie acepta;
- desde una consola visible (doble clic en `vpn.cmd`): como antes, abre FortiClient y **sale el UAC**, que aceptas a mano. Además, notificación y aviso en `avisos` para que instales la tarea.

`estado` dice si el servicio está en marcha y si la tarea está instalada (`servicioForti`, `tareaServicio`, con `seguridad` y `problemas`).

Quitarla: `vpn.cmd desinstalar-tarea` (sin UAC; si Windows no la deja borrar, pide uno). `desinstalar.ps1` también la quita.

#### Comprobación manual después de instalarla

Desde una consola **sin elevar** (`cmd` normal):

```bat
schtasks /run /tn vpn-forti-servicio
:: debe decir CORRECTO: se lanza sin UAC (si el servicio ya estaba en marcha, sc.exe acaba con 1056, y es normal)
schtasks /change /tn vpn-forti-servicio /tr calc.exe
:: debe dar «Acceso denegado»: el usuario no puede cambiar la acción
vpn.cmd estado
:: tareaServicio.seguridad empieza por O:BA y problemas está vacío
schtasks /delete /tn vpn-forti-servicio /f
:: se borra sin elevar (permiso SD)
schtasks /create /tn vpn-forti-servicio /tr calc.exe /sc once /st 23:59 /rl highest
:: debe dar «Acceso denegado»: sin elevar no se puede crear una tarea con privilegios más altos
vpn.cmd instalar-tarea
:: la deja otra vez instalada (un UAC)
```

Si `schtasks /run` diera «Acceso denegado» con `GRGX`, hay que cambiar en `Registrar-Tarea` (`vpn.ps1`) el permiso del usuario de `GRGXSD` a `FRFXSD` y volver a instalarla.

> Solo sirve si tu usuario es administrador local (con UAC). Un usuario estándar no puede registrar una tarea con privilegios más altos ni arrancar el servicio; ahí el servicio tendría que dejarlo arrancado un administrador.

### Credencial de la VPN

La contraseña se guarda en el **Administrador de credenciales de Windows** como credencial **genérica** (la API CredRead por P/Invoke, sin ficheros ni módulos de terceros). Por defecto se busca, por este orden:

1. la credencial genérica `FortiClient`;
2. la credencial genérica `vpn-forti:<túnel>` (p. ej. `vpn-forti:VPN Cerdanyola`).

El **usuario** también sale de la credencial: no se configura en ningún otro sitio.

Para crearla:

```bat
vpn.cmd guardar-credencial
```

Abre el diálogo de Windows, pide usuario y contraseña y los guarda en `vpn-forti:<túnel>` (otro target: `-Target`). `instalar.ps1 -PedirCredencial` hace lo mismo si aún no existe.
También puedes crearla a mano en Panel de control > Administrador de credenciales > **Credenciales genéricas** > Agregar, con la dirección `FortiClient`.

> Una credencial guardada como **credencial de Windows** (tipo «Contraseña de dominio», `Domain:target=FortiClient` en `cmdkey /list`) **no vale**: Windows no deja leer su contraseña desde un proceso de usuario. Si solo existe esa, la herramienta sale con el código 3 y lo dice.

Borrarla: `vpn.cmd borrar-credencial` (o `-Target ...`).

### Sesión de Outlook web

El PIN se lee de https://outlook.office.com/mail/?realm=portic.net con **Microsoft Edge visible** (Playwright, `channel: 'msedge'`) y un perfil propio de la herramienta: `%LOCALAPPDATA%\vpn-forti\perfil-outlook`. No se toca el perfil real de Edge ni el de Chrome.

La primera vez, ejecuta `vpn.cmd probar-bandeja` para abrir Edge con ese perfil y comprobar que entra. Comprobado el 30/10/2026 con la VPN desconectada: con `?realm=portic.net`, Edge **entra directo a la bandeja por el SSO de la empresa**, sin pedir credenciales (la primera de las tres opciones previstas). Chrome (`"canal": "chrome"` en `config.json`) queda como alternativa, sin probar.
Si algún día pide inicio de sesión, la ventana se queda abierta con una franja roja «inicia sesión en Outlook»: inicia sesión una vez y el perfil lo recuerda.

```bat
vpn.cmd probar-bandeja   :: solo comprueba que llega a la bandeja, sin abrir ningún correo
vpn.cmd probar-pin       :: valida el filtro y la regex con los correos del PIN
```

`probar-pin` sirve además para validar el filtro y la regex: lista remitente, asunto y hora de los correos que pasan el filtro **con los dígitos enmascarados**, abre solo el más reciente y dice si la regex encuentra el PIN y cuántos dígitos tiene, sin mostrarlo.

Outlook web se alcanza sin VPN (comprobado con la VPN desconectada), así que el PIN se puede leer mientras la VPN está caída.

## Órdenes

```
powershell -NoProfile -ExecutionPolicy Bypass -File vpn.ps1 <orden> [opciones]
vpn.cmd <orden> [opciones]          (sin argumentos, con doble clic: asegurar)
```

| Orden | Qué hace |
|---|---|
| `estado` | Devuelve `{conectada, adaptador, dns, tunel, servicioForti, tareaServicio}`. Conectada = adaptador «Fortinet SSL VPN Virtual Ethernet Adapter» `Up` **y** `transportistas-desa.portic.net` resuelve (sin VPN da NXDOMAIN). |
| `conectar [-Tunel "nombre"] [-EsperaSeg 180]` | Reconecta (ver «Cómo conecta»). |
| `asegurar [mismas opciones]` | Si ya está conectada sale 0 al instante; si no, hace `conectar`. **Es la que deben llamar las apps.** |
| `guardar-credencial [-Target t] [-Usuario u]` | Pide usuario y contraseña y los guarda como credencial genérica. |
| `borrar-credencial [-Target t]` | Borra la credencial genérica. |
| `aceptar-certificado` | Lee el certificado del servidor del túnel, muestra sujeto, emisor, huella y caducidad, y si lo confirmas añade la huella a `config.json`. |
| `volcar` | Diagnóstico: árbol de accesibilidad de la consola (roles, nombres, estados; nunca valores de campos). Si tiene que abrir la consola, arranca antes el servicio como `conectar` (puede salir con 7). |
| `probar-bandeja` | Comprueba que Outlook web llega a la bandeja, sin abrir correos. |
| `probar-pin` | Diagnóstico de Outlook web (ver arriba). |
| `aviso [-Mensaje "..."]` | Prueba el aviso visible: notificación de Windows y ventanita en primer plano con pitido. |
| `credencial` | Comprueba si hay credencial genérica utilizable: 0 sí (con `target` y `usuario`), 3 no. |
| `version` | Muestra la versión (fichero `VERSION`), la ruta, el túnel en uso y los túneles del registro. |
| `instalar-tarea` | Una sola vez (un UAC): registra la tarea `vpn-forti-servicio` que arranca el servicio de FortiClient sin UAC (ver «Tarea del servicio»). |
| `desinstalar-tarea` | Borra esa tarea. |
| `bandeja [-SinConectar]` | Se queda en el área de notificación (ver «Bandeja»). Es lo que abre el acceso directo «Reconectar VPN». |

Opciones de `conectar`/`asegurar`:

- `-SinPinCorreo`: modo semiautomático; no abre Outlook y avisa al usuario para que meta el código.
- `-NoPulsar`: para pruebas. Prepara el formulario (túnel, usuario, contraseña), comprueba que la contraseña ha quedado entera, **la vuelve a borrar** y sale sin pulsar Conectar.

### Salida y códigos

Siempre una única línea JSON en **stdout**, por ejemplo:

```json
{"orden":"estado","codigo":0,"conectada":true,"adaptador":{"nombre":"Ethernet 4","estado":"Up"},"dns":{"host":"transportistas-desa.portic.net","ip":"100.64.100.21"},"tunel":"VPN Cerdanyola"}
```

Si hay algo que avisar (p. ej. varios túneles en FortiClient), la línea lleva además `avisos`. El progreso va a **stderr** y al log `%LOCALAPPDATA%\vpn-forti\vpn.log`. La contraseña y el PIN no se escriben nunca (como mucho, «PIN recibido»).

| Código | Significado |
|---|---|
| 0 | Conectada (o la orden ha ido bien) |
| 1 | No conectada (`estado`) o error genérico / cancelado |
| 2 | Tiempo agotado: no se ha conectado en `EsperaSeg` |
| 3 | No hay credencial utilizable (no existe, o solo existe como credencial de Windows) |
| 4 | No se encuentra la interfaz de FortiClient o no se puede manejar |
| 5 | FortiClient muestra un error al conectar (p. ej. credenciales incorrectas); van en `errores` |
| 6 | Certificado del servidor inesperado: se ha pulsado «No» en la alerta de seguridad |
| 7 | (`conectar`, `asegurar`, `volcar`; no desde una consola visible) El servicio de FortiClient está parado y no hay tarea para arrancarlo sin UAC (`tareaInstalada: false`: ejecuta una vez `vpn.cmd instalar-tarea`), o la tarea no lo ha arrancado a tiempo (`ultimoResultado`) |

## Cómo conecta

1. Si ya hay VPN, termina. Un mutex evita que dos apps reconecten a la vez: la segunda espera a la primera.
2. Comprueba la credencial (código 3 si no sirve).
3. Notificación «Reconectando VPN…». Arranca `pin-outlook.mjs` (Edge visible), espera a tener la bandeja cargada y toma una **línea base** con los correos que ya hay (en Prioritarios y Otros).
4. Abre o trae al frente la consola de FortiClient. Antes de abrirla, si el servicio `FA_Scheduler` está parado, lo arranca con la tarea `vpn-forti-servicio`. Si no hay tarea, sale con el código 7, o, desde una consola visible, abre FortiClient y sale el UAC como antes. FortiClient.exe lanzado directamente desde otro proceso sale sin abrir ventana; se lanza a través del Explorador, como un doble clic.
5. Activa la accesibilidad de Chromium (FortiClient es Electron) pidiendo el objeto MSAA de la ventana; sin eso UIA solo ve 3 nodos.
6. Comprueba el desplegable «Nombre de VPN» y, si hace falta, elige el túnel tecleando su nombre.
7. Rellena «Nombre de Usuario» solo si está vacío.
8. Enfoca «Contraseña» y teclea la contraseña con `SendInput` Unicode **directamente desde el blob nativo** del Administrador de credenciales: no pasa por ningún string de PowerShell, ni por el portapapeles. Antes de cada carácter comprueba que FortiClient sigue en primer plano; si no, para (código 4). Después comprueba que el campo tiene tantos caracteres como la contraseña guardada.
9. Pulsa «Conectar» (acción por defecto MSAA, sin clics por coordenadas).
   - FortiTray abre entonces un diálogo Win32 «Alerta de seguridad» («El certificado que está viendo no coincide con el nombre del sitio…»), porque el túnel se conecta por IP (213.229.151.254:11443) y el certificado es `*.portic.net`.
   - Antes de contestar, la herramienta lee el certificado del servidor del túnel (`Server` en el registro) con `SslStream`. Pulsa «Sí» solo si la huella SHA1 está en `certificado.huellas`. Si no, pulsa «No» y sale con el código 6 y un aviso visible.
   - Si la huella es nueva pero el sujeto es `CN=*.portic.net` y la cadena valida, lo avisa como «certificado renovado», pero tampoco lo acepta solo: revísalo con `vpn.cmd aceptar-certificado`.
   - Los botones del diálogo son de dibujo propio: UIA los ve como `Pane` sin patrón Invoke. Se pulsan con `WM_COMMAND` por su id de control (1 = «Sí», 2 = «No»).
   - Certificado actual: `CN=*.portic.net, O=Portic Barcelona SA`, emisor GeoTrust TLS RSA CA G1 (DigiCert), SHA1 `5E6F397764845E5EB3D2AB88A471A9E50F41F659`, caduca el 23/03/2027.
10. `pin-outlook.mjs` busca el primer correo **nuevo** (que no estaba en la línea base) que pase el filtro, abre solo ese, extrae el PIN con la regex, lo pasa a `vpn.ps1` por la tubería y cierra el navegador.
11. `vpn.ps1` espera a que aparezca el campo del token, teclea el PIN y pulsa OK/Aceptar/Continuar (o Intro).
12. Espera a que `estado` dé conectada y muestra la notificación «VPN conectada».

Si el correo no llega a tiempo (o falla Node, Playwright u Outlook), pasa al **aviso manual**: notificación, ventanita en primer plano «VPN: introduce el código del segundo factor en FortiClient» y pitido, y sigue esperando hasta `EsperaSeg`.

### Privacidad del correo

- Solo se abre el correo del PIN. Para localizarlo se compara en memoria el texto de las filas de la bandeja con el filtro; no se guarda ni se escribe nada de ellas.
- `pin.accion` (desactivado por defecto, `ninguna`): `leido` lo marca como leído. `eliminar` ya no borra (se ignora con un aviso): el borrado solo lo gobierna «Borrar los correos leídos» (abajo), para que la casilla de la bandeja diga siempre lo que pasa. Ojo: según tu configuración de Outlook web, abrir el correo ya puede marcarlo como leído.
- **Borrar los correos leídos** (`pin.borrarLeidos`, por defecto `false`; también la casilla del menú de la bandeja): tras leer el PIN, manda **solo ese correo** a Elementos eliminados (Supr, nunca Mayús+Supr: se puede recuperar). Solo borra si el PIN ha salido del cuerpo del correo abierto con la regex principal (`pin.regexPin`, no con la alternativa), si hay exactamente una fila seleccionada y si esa fila es la del PIN (pasa el filtro, no lleva en el asunto un PIN distinto y es la misma fila o lleva el mismo PIN), y comprueba después que la fila ha desaparecido. Ante cualquier duda no borra nada: lo apunta en el log y en `avisos`, y la conexión sigue. El borrado se hace antes de pasar el PIN a `vpn.ps1` y como mucho retrasa el PIN 6 s. Si Outlook web agrupa por conversación, se borra la conversación de esa fila (los correos «AuthCode» suelen llegar sueltos). Según el ajuste de Outlook web «Después de mover o eliminar un elemento», puede abrirse el correo siguiente (y quedar como leído): conviene elegir «Volver a la carpeta actual». `vpn.cmd probar-pin` dice, sin borrar nada, si borraría el correo del PIN más reciente.

## Configuración (`config.json`)

Lo crea `instalar.ps1` a partir de `config.ejemplo.json` (no se sube a git). Se puede usar otro fichero con la variable `VPN_FORTI_CONFIG`. Claves principales:

| Clave | Por defecto |
|---|---|
| `tunel` | vacío: el túnel del registro de FortiClient (el primero si hay varios, con aviso). `-Tunel` manda sobre todo. |
| `fortiClientExe` | vacío: `%ProgramFiles%\Fortinet\FortiClient\FortiClient.exe` |
| `esperaSeg` | `180` |
| `esperaServicioSeg` | `30`: lo que espera a que el servicio arranque tras lanzar la tarea |
| `hostDns` | `transportistas-desa.portic.net` |
| `credenciales` | `["FortiClient", "vpn-forti:{tunel}"]` |
| `pin.activado` | `true` |
| `pin.url` | `https://outlook.office.com/mail/?realm=portic.net` |
| `pin.canal` | `msedge` (o `chrome`) |
| `pin.filtro` | `notification\.fortinet\.net\|AuthCode`: regex (sin distinguir mayúsculas) sobre remitente, asunto y vista previa de la fila |
| `pin.regexPin` | `(?:AuthCode:\|token code is)\s*(\d{4,10})`: el PIN va en el grupo 1 |
| `certificado.huellas` | `["5E6F397764845E5EB3D2AB88A471A9E50F41F659"]` |
| `pin.regexPinAlternativa` | `\b(\d{6})\b`, si la primera no encuentra nada |
| `pin.loginTimeoutSeg` | `600`: lo que espera a que inicies sesión en Outlook |
| `pin.accion` | `ninguna` / `leido` (`eliminar` se ignora: usa `pin.borrarLeidos`) |
| `pin.borrarLeidos` | `false`: «Borrar los correos leídos» (ver «Privacidad del correo»). La bandeja la cambia desde su menú. |
| `intervaloBandejaSeg` | `15`: cada cuánto mira la bandeja si hay VPN |

## Uso desde otras apps

### Node

```js
const { spawnSync } = require('node:child_process');
const ruta = process.env.VPN_FORTI;   // la fija instalar.ps1
const r = spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ruta, 'asegurar'],
  { encoding: 'utf8', timeout: 15 * 60 * 1000 });
const res = JSON.parse((r.stdout || '').trim().split(/\r?\n/).pop() || '{}');
if (r.status !== 0) throw new Error(`VPN no disponible (código ${r.status}): ${res.mensaje || ''}`);
```

### Python

```python
import json, os, subprocess
ruta = os.environ["VPN_FORTI"]   # la fija instalar.ps1
r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ruta, "asegurar"],
                   capture_output=True, text=True, encoding="utf-8", timeout=15 * 60)
res = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
if r.returncode != 0:
    raise RuntimeError(f"VPN no disponible (código {r.returncode}): {res.get('mensaje', '')}")
```

`asegurar` puede tardar: la espera de inicio de sesión en Outlook (hasta `pin.loginTimeoutSeg`) más la conexión (`EsperaSeg`). Pon un timeout generoso en quien la llama.

## Prueba real (30/10/2026)

- 08:18, primer intento: código 2. Faltaba gestionar la «Alerta de seguridad» del certificado.
- 08:24, segundo intento: `conectar -EsperaSeg 240`, código 0 en **30 s**. Cronología:
  - +3 s: bandeja de Outlook lista;
  - +7 s: contraseña escrita y Conectar pulsado;
  - +8 s: alerta de seguridad, certificado conocido, «Sí»;
  - +22 s: PIN recibido y escrito;
  - +30 s: `estado` conectada.
- `asegurar` con la VPN ya conectada: código 0 en 1,5 s.

## Detalles técnicos y límites

- La consola de FortiClient 7.0 es una app **Electron** (`resources\app.asar`) que bloquea `--remote-debugging-port`, así que no hay CDP. El árbol UIA solo tiene la ventana, «Chrome Legacy Window» e «Intermediate D3D Window». En cambio, al pedir el objeto MSAA (`AccessibleObjectFromWindow`, `OBJID_CLIENT`) Chromium activa su accesibilidad y el árbol MSAA es completo: combo «Nombre de VPN» (rol 46), campos «Nombre de Usuario» y «Contraseña» (rol 42, este con estado *protegido*), casillas y botón «Conectar»/«Desconectar» (rol 43). Por eso se usa MSAA y no UIA.
- `put_accValue` cambia lo que se ve en el campo, pero el formulario no se entera bien (al teclear después, el valor quedó corrupto). Por eso todo se escribe con teclado (`SendInput` Unicode).
- Pantalla del token (vista en la prueba real): el texto «Un mensaje de email que contiene un Token Code será enviado a …», un campo «Token» (rol 42, protegido y enfocado) y los botones «Aceptar» y «Cancelar». Se localiza con `regexCampoToken` y `regexBotonToken`; si FortiClient cambia, ejecuta `vpn.cmd volcar` en esa pantalla y ajusta esas regex en `config.json`.
- Correo del PIN (formato real): remitente `DoNotReply@notification.fortinet.net`, asunto `AuthCode: NNNNNN` y cuerpo «Your authentication token code is NNNNNN.». Llega unos 14 s después de pulsar Conectar.
- El menú del icono de la bandeja (FortiTray) no se usa: es un menú Win32 que habría que abrir con clic derecho en el área de notificación (a menudo en el desbordamiento), y además solo lanza la conexión: usuario, contraseña y token siguen pidiéndose en la consola.

## Bandeja (área de notificación)

`vpn.ps1 bandeja` deja un icono en el área de notificación con el estado de la VPN, que mira cada `intervaloBandejaSeg` segundos:

- punto **verde**: conectada;
- punto **ámbar**: reconectando (la propia bandeja u otra app está haciendo `conectar`/`asegurar`);
- punto **rojo**: sin VPN.

Al abrirse, si no hay VPN, reconecta (salvo con `-SinConectar`). Si ya hay una bandeja abierta, la segunda le pide que reconecte y sale. Al abrirse comprueba también si hay actualizaciones (`actualizar.ps1`), como `vpn.cmd`; si se ha actualizado, se relanza sola con la versión nueva. Una bandeja que ya lleva tiempo abierta sigue con la versión con la que arrancó hasta que se cierra.

Menú del botón derecho:

| Opción | Qué hace |
|---|---|
| (estado) | Conectada / Reconectando / Sin VPN. |
| Reconectar | Lanza `vpn.ps1 asegurar` en otro proceso (si ya hay VPN no hace nada). Si falla, avisa con un globo. |
| Borrar los correos leídos | Casilla enlazada a `pin.borrarLeidos` de `config.json` (o el de `VPN_FORTI_CONFIG`): se guarda al marcarla y se relee al abrir el menú. Vale para la siguiente conexión. |
| Abrir el registro | `vpn.log` en el Bloc de notas. |
| Salir | Quita el icono y cierra la bandeja. |

No reconecta sola cuando se cae la VPN: solo con «Reconectar», con el acceso directo o con las apps.

## Icono y acceso directo

`vpn.cmd` no puede llevar icono. `crear-acceso.ps1` crea el acceso directo **«Reconectar VPN»** (con `vpn.ico`) en el Escritorio y en la carpeta, y borra el antiguo «VPN FortiClient» si apuntaba a `vpn.cmd`. `instalar.ps1` lo ejecuta (salvo con `-Silencioso`). Abre `vpn.ps1 bandeja` sin ventana: reconecta si hace falta y se queda en el área de notificación.

Para cambiar el icono:

- **Acceso directo:** `crear-acceso.ps1 -Icono <ruta.ico>`, o sustituir `vpn.ico` y volver a ejecutarlo. También admite `-Nombre` (otro nombre) y `-Destinos` (otras carpetas).
- **Bandeja:** si junto a `vpn.ico` hay `vpn_conectada.ico`, `vpn_reconectando.ico` y `vpn_sinvpn.ico`, los usa tal cual. Si no, los genera a partir de `vpn.ico` con el punto de color.
- **Propuestas:** los iconos `vpn_A_*.ico`, `vpn_B_*.ico` y `vpn_C_*.ico` se copian quitando la letra.

## Actualización automática

`vpn.cmd` ejecuta lo primero `actualizar.ps1` (también lo hace la bandeja al abrirse): **comprueba siempre** si hay versión nueva en `origin` (`git fetch`, con corte a los 15 s sin red) y la descarga con `git pull --ff-only`. No imprime nada (la salida de `vpn.cmd` es el JSON de `vpn.ps1`): solo deja rastro en `actualizar.log` («ACTUALIZADO a la versión X», o por qué no se actualiza). No hay servidor que reiniciar.

- Se salta con `ACTUALIZAR_SIN=1`; `ACTUALIZAR_CADA_MIN=N` (opcional, 0 por defecto) limita la comprobación a una cada N minutos.
- Tras un pull correcto escribe `.actualizado` (versión, commits y hora; `vpn.cmd` lo borra) y, si cambia `package.json`/`package-lock.json`, hace `npm ci`.
- Con cambios locales en ficheros versionados y commits nuevos no actualiza y deja `.actualizacion-pendiente` con el motivo (no se muestra en consola).
- Los tests del script están en `visor-pruebas	ests	est_actualizar.py` (también prueban esta copia, idéntica).

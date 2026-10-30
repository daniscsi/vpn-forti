# vpn-forti

Herramienta independiente para comprobar y reconectar la VPN SSL de **FortiClient 7.0** (túnel «VPN Cerdanyola»).
Automatiza la consola de FortiClient (abrirla, rellenar el formulario, pulsar Conectar) y lee el **PIN del segundo factor** que llega por correo desde **Outlook web**, así que la reconexión es automática de principio a fin. Si el PIN no llega, avisa al usuario para que lo meta a mano.

La llaman otras apps (la primera, la skill `comparativa-migracion-web`) con la orden `asegurar`.

## Instalación

1. Requisitos: Windows 10/11, PowerShell 5.1, FortiClient 7.0 con el túnel ya configurado, Node 18 o posterior y Microsoft Edge (o Chrome).
2. Dependencias de Node (solo `playwright-core`, que usa el Edge o Chrome instalado):

   ```bat
   cd C:\Users\Scsi\Herramientas\vpn-forti
   npm install
   ```

3. Variable de entorno para que las apps encuentren la herramienta:

   ```bat
   setx VPN_FORTI "C:\Users\Scsi\Herramientas\vpn-forti\vpn.ps1"
   ```

4. (Opcional) Copia `config.ejemplo.json` a `config.json` y ajústalo. También se puede indicar otro fichero con la variable `VPN_FORTI_CONFIG`.

## Una sola vez: credencial y sesión de Outlook

### Credencial de la VPN

La contraseña se guarda en el **Administrador de credenciales de Windows** como credencial **genérica** (la API CredRead por P/Invoke, sin ficheros ni módulos de terceros). Por defecto se busca, por este orden:

1. la credencial genérica `FortiClient`;
2. la credencial genérica `vpn-forti:VPN Cerdanyola`.

Para crearla:

```bat
vpn.cmd guardar-credencial
```

Abre el diálogo de Windows, pide usuario y contraseña y los guarda en `vpn-forti:VPN Cerdanyola` (otro target: `-Target`).
También puedes crearla a mano en Panel de control > Administrador de credenciales > **Credenciales genéricas** > Agregar, con la dirección `FortiClient`.

> Una credencial guardada como **credencial de Windows** (tipo «Contraseña de dominio», `Domain:target=FortiClient` en `cmdkey /list`) **no vale**: Windows no deja leer su contraseña desde un proceso de usuario. Si solo existe esa, la herramienta sale con el código 3 y lo dice.

Borrarla: `vpn.cmd borrar-credencial` (o `-Target ...`).

### Sesión de Outlook web

El PIN se lee de https://outlook.office.com/mail/?realm=portic.net con **Microsoft Edge visible** (Playwright, `channel: 'msedge'`) y un perfil propio de la herramienta: `%LOCALAPPDATA%\vpn-forti\perfil-outlook`. No se toca el perfil real de Edge ni el de Chrome.

Comprobado el 30/10/2026 con la VPN desconectada: con `?realm=portic.net`, Edge **entra directo a la bandeja por el SSO de la empresa**, sin pedir credenciales (la primera de las tres opciones previstas). Chrome (`"canal": "chrome"` en `config.json`) queda como alternativa, sin probar.
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
| `estado` | Devuelve `{conectada, adaptador, dns, tunel}`. Conectada = adaptador «Fortinet SSL VPN Virtual Ethernet Adapter» `Up` **y** `transportistas-desa.portic.net` resuelve (sin VPN da NXDOMAIN). |
| `conectar [-Tunel "VPN Cerdanyola"] [-EsperaSeg 180]` | Reconecta (ver «Cómo conecta»). |
| `asegurar [mismas opciones]` | Si ya está conectada sale 0 al instante; si no, hace `conectar`. **Es la que deben llamar las apps.** |
| `guardar-credencial [-Target t] [-Usuario u]` | Pide usuario y contraseña y los guarda como credencial genérica. |
| `borrar-credencial [-Target t]` | Borra la credencial genérica. |
| `volcar` | Diagnóstico: árbol de accesibilidad de la consola (roles, nombres, estados; nunca valores de campos). |
| `probar-bandeja` | Comprueba que Outlook web llega a la bandeja, sin abrir correos. |
| `probar-pin` | Diagnóstico de Outlook web (ver arriba). |
| `aviso [-Mensaje "..."]` | Prueba el aviso visible: notificación de Windows y ventanita en primer plano con pitido. |

Opciones de `conectar`/`asegurar`:

- `-SinPinCorreo`: modo semiautomático; no abre Outlook y avisa al usuario para que meta el código.
- `-NoPulsar`: para pruebas. Prepara el formulario (túnel, usuario, contraseña), comprueba que la contraseña ha quedado entera, **la vuelve a borrar** y sale sin pulsar Conectar.

### Salida y códigos

Siempre una única línea JSON en **stdout**, por ejemplo:

```json
{"orden":"estado","codigo":0,"conectada":true,"adaptador":{"nombre":"Ethernet 4","estado":"Up"},"dns":{"host":"transportistas-desa.portic.net","ip":"100.64.100.21"},"tunel":"VPN Cerdanyola"}
```

El progreso va a **stderr** y al log `%LOCALAPPDATA%\vpn-forti\vpn.log`. La contraseña y el PIN no se escriben nunca (como mucho, «PIN recibido»).

| Código | Significado |
|---|---|
| 0 | Conectada (o la orden ha ido bien) |
| 1 | No conectada (`estado`) o error genérico / cancelado |
| 2 | Tiempo agotado: no se ha conectado en `EsperaSeg` |
| 3 | No hay credencial utilizable (no existe, o solo existe como credencial de Windows) |
| 4 | No se encuentra la interfaz de FortiClient o no se puede manejar |
| 5 | FortiClient muestra un error al conectar (p. ej. credenciales incorrectas); van en `errores` |

## Cómo conecta

1. Si ya hay VPN, termina. Un mutex evita que dos apps reconecten a la vez: la segunda espera a la primera.
2. Comprueba la credencial (código 3 si no sirve).
3. Notificación «Reconectando VPN…». Arranca `pin-outlook.mjs` (Edge visible), espera a tener la bandeja cargada y toma una **línea base** con los correos que ya hay (en Prioritarios y Otros).
4. Abre o trae al frente la consola de FortiClient. FortiClient.exe lanzado directamente desde otro proceso sale sin abrir ventana; se lanza a través del Explorador, como un doble clic.
5. Activa la accesibilidad de Chromium (FortiClient es Electron) pidiendo el objeto MSAA de la ventana; sin eso UIA solo ve 3 nodos.
6. Comprueba el desplegable «Nombre de VPN» y, si hace falta, elige el túnel tecleando su nombre.
7. Rellena «Nombre de Usuario» solo si está vacío.
8. Enfoca «Contraseña» y teclea la contraseña con `SendInput` Unicode **directamente desde el blob nativo** del Administrador de credenciales: no pasa por ningún string de PowerShell, ni por el portapapeles. Antes de cada carácter comprueba que FortiClient sigue en primer plano; si no, para (código 4). Después comprueba que el campo tiene tantos caracteres como la contraseña guardada.
9. Pulsa «Conectar» (acción por defecto MSAA, sin clics por coordenadas).
10. `pin-outlook.mjs` busca el primer correo **nuevo** (que no estaba en la línea base) que pase el filtro, abre solo ese, extrae el PIN con la regex, lo pasa a `vpn.ps1` por la tubería y cierra el navegador.
11. `vpn.ps1` espera a que aparezca el campo del token, teclea el PIN y pulsa OK/Aceptar/Continuar (o Intro).
12. Espera a que `estado` dé conectada y muestra la notificación «VPN conectada».

Si el correo no llega a tiempo (o falla Node, Playwright u Outlook), pasa al **aviso manual**: notificación, ventanita en primer plano «VPN: introduce el código del segundo factor en FortiClient» y pitido, y sigue esperando hasta `EsperaSeg`.

### Privacidad del correo

- Solo se abre el correo del PIN. Para localizarlo se compara en memoria el texto de las filas de la bandeja con el filtro; no se guarda ni se escribe nada de ellas.
- `pin.accion` (desactivado por defecto, `ninguna`): `leido` lo marca como leído y `eliminar` lo manda a Elementos eliminados. Ojo: según tu configuración de Outlook web, abrir el correo ya puede marcarlo como leído.

## Configuración (`config.json`)

Ver `config.ejemplo.json`. Claves principales:

| Clave | Por defecto |
|---|---|
| `tunel` | `VPN Cerdanyola` |
| `esperaSeg` | `180` |
| `hostDns` | `transportistas-desa.portic.net` |
| `credenciales` | `["FortiClient", "vpn-forti:{tunel}"]` |
| `pin.activado` | `true` |
| `pin.url` | `https://outlook.office.com/mail/?realm=portic.net` |
| `pin.canal` | `msedge` (o `chrome`) |
| `pin.filtro` | regex (sin distinguir mayúsculas) sobre remitente/asunto/vista previa de la fila |
| `pin.regexPin` | regex con el PIN en el grupo 1, anclada a «token / código / code / PIN» |
| `pin.regexPinAlternativa` | `\b(\d{6})\b`, si la primera no encuentra nada |
| `pin.loginTimeoutSeg` | `600`: lo que espera a que inicies sesión en Outlook |
| `pin.accion` | `ninguna` / `leido` / `eliminar` |

## Uso desde otras apps

### Node

```js
const { spawnSync } = require('node:child_process');
const ruta = process.env.VPN_FORTI || 'C:\\Users\\Scsi\\Herramientas\\vpn-forti\\vpn.ps1';
const r = spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ruta, 'asegurar'],
  { encoding: 'utf8', timeout: 15 * 60 * 1000 });
const res = JSON.parse((r.stdout || '').trim().split(/\r?\n/).pop() || '{}');
if (r.status !== 0) throw new Error(`VPN no disponible (código ${r.status}): ${res.mensaje || ''}`);
```

### Python

```python
import json, os, subprocess
ruta = os.environ.get("VPN_FORTI", r"C:\Users\Scsi\Herramientas\vpn-forti\vpn.ps1")
r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ruta, "asegurar"],
                   capture_output=True, text=True, encoding="utf-8", timeout=15 * 60)
res = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
if r.returncode != 0:
    raise RuntimeError(f"VPN no disponible (código {r.returncode}): {res.get('mensaje', '')}")
```

`asegurar` puede tardar: la espera de inicio de sesión en Outlook (hasta `pin.loginTimeoutSeg`) más la conexión (`EsperaSeg`). Pon un timeout generoso en quien la llama.

## Detalles técnicos y límites

- La consola de FortiClient 7.0 es una app **Electron** (`resources\app.asar`) que bloquea `--remote-debugging-port`, así que no hay CDP. El árbol UIA solo tiene la ventana, «Chrome Legacy Window» e «Intermediate D3D Window». En cambio, al pedir el objeto MSAA (`AccessibleObjectFromWindow`, `OBJID_CLIENT`) Chromium activa su accesibilidad y el árbol MSAA es completo: combo «Nombre de VPN» (rol 46), campos «Nombre de Usuario» y «Contraseña» (rol 42, este con estado *protegido*), casillas y botón «Conectar»/«Desconectar» (rol 43). Por eso se usa MSAA y no UIA.
- `put_accValue` cambia lo que se ve en el campo, pero el formulario no se entera bien (al teclear después, el valor quedó corrupto). Por eso todo se escribe con teclado (`SendInput` Unicode).
- Lo único sin probar con FortiClient de verdad es la pantalla del token tras Conectar: se busca un campo editable cuyo nombre case con `regexCampoToken` (o sin nombre) y un botón que case con `regexBotonToken`. Si no lo encuentra, ejecuta `vpn.cmd volcar` durante esa pantalla y ajusta esas regex en `config.json`.
- El menú del icono de la bandeja (FortiTray) no se usa: es un menú Win32 que habría que abrir con clic derecho en el área de notificación (a menudo en el desbordamiento), y además solo lanza la conexión: usuario, contraseña y token siguen pidiéndose en la consola.

// pin-outlook.mjs: lee el PIN del segundo factor de FortiClient desde Outlook web.
//
// Lo lanza vpn.ps1 (no hace falta llamarlo a mano) y se comunica por stdout con
// una línea JSON por evento:
//   {"evento":"login_necesario"}  la sesión de Outlook ha caducado; la ventana queda abierta
//   {"evento":"listo"}            bandeja cargada y línea base tomada: ya se puede pulsar Conectar
//   {"evento":"borrado","ok":true|false,"motivo":"..."}  con --borrar-leido, resultado de borrar el
//                                 correo del PIN (llega justo antes de "pin"; si falla, la conexión sigue)
//   {"evento":"pin","pin":"..."}  PIN encontrado (solo viaja por la tubería, nunca a un log)
//   {"evento":"sin_pin"}          no ha llegado el correo en el plazo
//   {"evento":"error","mensaje":"..."}
// Si recibe la línea "fin" por stdin, cierra el navegador y sale.
//
// Modo diagnóstico (a mano):  node pin-outlook.mjs --explorar
//   Lista remitente, asunto (con los dígitos enmascarados) y hora de los correos que
//   pasan el filtro, y dice si la regex del PIN encuentra algo, sin mostrar el PIN.
//
// Privacidad: solo se abre el correo nuevo que pasa el filtro. Para localizarlo se
// compara el texto de la lista de la bandeja en memoria; nada de eso se escribe.

import { chromium } from 'playwright-core';
import { createInterface } from 'node:readline';
import os from 'node:os';
import path from 'node:path';

function opciones(argv) {
  const o = {
    url: 'https://outlook.office.com/mail/?realm=portic.net',
    canal: 'msedge', // msedge | chrome
    perfil: path.join(process.env.LOCALAPPDATA || os.homedir(), 'vpn-forti', 'perfil-outlook'),
    // Formato real (30/10/2026): de DoNotReply@notification.fortinet.net, asunto «AuthCode: NNNNNN»,
    // cuerpo «Your authentication token code is NNNNNN.»
    filtro: 'notification\\.fortinet\\.net|AuthCode',
    regexPin: '(?:AuthCode:|token code is)\\s*(\\d{4,10})\\b',
    regexPinAlternativa: '\\b(\\d{6})\\b',
    timeoutSeg: 120,
    loginTimeoutSeg: 600,
    sondeoSeg: 3,
    accion: 'ninguna', // ninguna | leido (el borrado solo lo gobierna --borrar-leido)
    borrarLeido: false, // borra solo el correo del PIN recién leído (a Elementos eliminados)
    explorar: false,
    soloBandeja: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const v = () => argv[++i];
    switch (a) {
      case '--url': o.url = v(); break;
      case '--perfil': o.perfil = v(); break;
      case '--filtro': o.filtro = v(); break;
      case '--regex-pin': o.regexPin = v(); break;
      case '--regex-pin-alternativa': o.regexPinAlternativa = v(); break;
      case '--timeout-seg': o.timeoutSeg = Number(v()); break;
      case '--login-timeout-seg': o.loginTimeoutSeg = Number(v()); break;
      case '--sondeo-seg': o.sondeoSeg = Number(v()); break;
      case '--accion': o.accion = v(); break;
      case '--borrar-leido': o.borrarLeido = true; break;
      case '--explorar': o.explorar = true; break;
      case '--segundo-plano': o.segundoPlano = true; break;
      case '--solo-bandeja': o.soloBandeja = true; break;
      case '--canal': o.canal = v(); break;
      default: break;
    }
  }
  return o;
}

const O = opciones(process.argv);
const emitir = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
const diag = (m) => process.stderr.write(`[pin-outlook] ${m}\n`);
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
const reFiltro = new RegExp(O.filtro, 'i');

function extraerPin(texto) {
  if (!texto) return null;
  for (const fuente of [O.regexPin, O.regexPinAlternativa]) {
    if (!fuente) continue;
    const m = new RegExp(fuente, 'i').exec(texto);
    if (m) return m[1] || m[0];
  }
  return null;
}

// Solo con la regex principal (AuthCode/token code): la alternativa (6 dígitos sueltos) no basta para borrar.
export function extraerPinPrincipal(texto) {
  if (!texto || !O.regexPin) return null;
  const m = new RegExp(O.regexPin, 'i').exec(texto);
  return m ? (m[1] || m[0]) : null;
}

// Aviso dentro de la propia página cuando no estamos en Outlook (inicio de sesión).
const AVISO_LOGIN = () => {
  const poner = () => {
    if (location.hostname.startsWith('outlook.')) return;
    if (document.getElementById('vpn-forti-aviso')) return;
    const d = document.createElement('div');
    d.id = 'vpn-forti-aviso';
    d.textContent = 'vpn-forti: inicia sesión en Outlook. La herramienta espera y seguirá sola.';
    d.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#c50f1f;color:#fff;font:bold 18px Segoe UI,sans-serif;padding:12px;text-align:center';
    (document.body || document.documentElement).appendChild(d);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', poner); else poner();
  setInterval(poner, 2000);
};

// Lee las filas de la bandeja (pestaña visible) en la página y devuelve id + texto.
async function filas(page) {
  return page.evaluate(() => {
    const out = [];
    document.querySelectorAll('[role="listbox"] [role="option"]').forEach((el, i) => {
      const id = el.getAttribute('data-convid') || el.getAttribute('data-item-id') || el.id || ('idx' + i + ':' + (el.getAttribute('aria-label') || '').slice(0, 80));
      el.setAttribute('data-vpnforti', String(i));
      out.push({ id, marca: String(i), sel: el.getAttribute('aria-selected') === 'true', texto:(el.getAttribute('aria-label') || '') + '\n' + (el.innerText || '') });
    });
    return out;
  });
}

async function pestanas(page) {
  // Bandeja Prioritarios / Otros: hay que mirar las dos.
  const tabs = page.locator('[role="tab"]').filter({ hasText: /^(Prioritarios|Otros|Focused|Other)$/ });
  const n = await tabs.count().catch(() => 0);
  const r = [];
  for (let i = 0; i < n; i++) r.push(tabs.nth(i));
  return r;
}

async function enBandeja(page) {
  if (!new URL(page.url()).hostname.startsWith('outlook.')) return false;
  return page.locator('[role="listbox"] [role="option"]').first().isVisible().catch(() => false);
}

// Devuelve a la pantalla la ventana lanzada fuera de ella (hace falta para iniciar sesión).
async function traerAPantalla(page) {
  if (!O.segundoPlano || O.explorar) return;
  try {
    const cdp = await page.context().newCDPSession(page);
    const { windowId } = await cdp.send('Browser.getWindowForTarget');
    await cdp.send('Browser.setWindowBounds', { windowId, bounds: { left: 80, top: 60, width: 1100, height: 800, windowState: 'normal' } });
  } catch (e) { diag('no se ha podido traer la ventana: ' + e.message); }
}

async function esperarBandeja(page) {
  const limite = Date.now() + O.loginTimeoutSeg * 1000;
  let avisado = false;
  const inicio = Date.now();
  while (Date.now() < limite) {
    if (await enBandeja(page)) return true;
    const host = (() => { try { return new URL(page.url()).hostname; } catch { return ''; } })();
    if (!avisado && (!host.startsWith('outlook.') || Date.now() - inicio > 20000)) {
      avisado = true;
      emitir({ evento: 'login_necesario' });
      await traerAPantalla(page);
      await page.bringToFront().catch(() => {});
      diag('Sesión de Outlook no iniciada: esperando a que el usuario inicie sesión.');
    }
    await dormir(1500);
  }
  return false;
}

async function recorrerPestanas(page, fn) {
  const tabs = await pestanas(page);
  if (tabs.length === 0) { await fn(); return; }
  for (const t of tabs) {
    await t.click().catch(() => {});
    await dormir(800);
    await fn();
  }
}

async function cuerpoAbierto(page) {
  const sel = ['[aria-label="Cuerpo del mensaje"]', '[aria-label="Message body"]', '[role="main"] [role="document"]', '#ReadingPaneContainerId'];
  for (const s of sel) {
    const l = page.locator(s).first();
    if (await l.isVisible().catch(() => false)) return (await l.innerText().catch(() => '')) || '';
  }
  return '';
}

// ¿Es esta fila el correo del PIN que se acaba de leer? Tiene que pasar el filtro, no llevar en el
// asunto/vista previa un PIN distinto y ser la misma fila (mismo id) o llevar el mismo PIN.
export function esFilaDelPin(fila, idOriginal, pin) {
  if (!fila || !pin || !reFiltro.test(fila.texto)) return false;
  const pinFila = extraerPin(fila.texto);
  if (pinFila && pinFila !== pin) return false;
  return fila.id === idOriginal || pinFila === pin;
}

// Decide si se puede borrar: exactamente una fila seleccionada y que sea la del PIN.
export function filaABorrar(lista, idOriginal, pin) {
  const sel = lista.filter((x) => x.sel);
  if (sel.length !== 1) return { fila: null, motivo: `hay ${sel.length} filas seleccionadas (se esperaba 1)` };
  if (!esFilaDelPin(sel[0], idOriginal, pin)) return { fila: null, motivo: 'la fila seleccionada no es la del PIN' };
  return { fila: sel[0], motivo: null };
}

// Borra (Supr: a Elementos eliminados, nunca Mayús+Supr) solo el correo del PIN recién leído.
// No reintenta con nada más amplio: ante cualquier duda, no borra y devuelve el motivo.
async function borrarCorreoDelPin(page, idOriginal, pin, plazo) {
  const { fila, motivo } = filaABorrar(await filas(page), idOriginal, pin);
  if (!fila) return { ok: false, motivo };
  const sel = `[role="listbox"] [role="option"][data-vpnforti="${fila.marca}"]`;
  const estaEnfocada = () => page.evaluate((s) => { const r = document.querySelector(s); return !!r && r.contains(document.activeElement); }, sel).catch(() => false);
  await page.locator(sel).first().focus().catch(() => {});
  let enfocada = await estaEnfocada();
  if (!enfocada) {
    // Outlook web deja el foco en el panel de lectura tras abrir el correo: un clic en la fila (ya seleccionada) lo devuelve a la lista.
    await page.locator(sel).first().click({ timeout: 1500 }).catch(() => {});
    await dormir(300);
    enfocada = await estaEnfocada();
  }
  if (Date.now() > plazo) return { ok: false, motivo: 'tiempo agotado antes de borrar' };
  if (enfocada) {
    await page.keyboard.press('Delete');
  } else {
    // Sin foco en la fila: botón «Eliminar» de la barra de comandos, que actúa sobre el único correo seleccionado (va a Elementos eliminados).
    const boton = page.locator('button[aria-label="Eliminar"], button[aria-label="Delete"], [role="menuitem"][aria-label="Eliminar"], [role="menuitem"][aria-label="Delete"]').first();
    if (!(await boton.isVisible().catch(() => false))) {
      const ae = await page.evaluate(() => { const e = document.activeElement; return e ? `${e.tagName}[${(e.getAttribute('role') || '')}|${(e.getAttribute('aria-label') || '').slice(0, 40)}]` : 'ninguno'; }).catch(() => '?');
      return { ok: false, motivo: `no se ha podido enfocar la fila del PIN ni hay botón Eliminar (foco en ${ae})` };
    }
    await boton.click({ timeout: 1500 }).catch(() => {});
  }
  const limite = Date.now() + 4000;
  while (Date.now() < limite) {
    await dormir(500);
    if (!(await filas(page)).some((x) => esFilaDelPin(x, idOriginal, pin))) {
      await dormir(1500);   // que Outlook web termine de mover el correo antes de cerrar el navegador
      return { ok: true, motivo: null };
    }
  }
  return { ok: false, motivo: 'la fila sigue en la bandeja tras pulsar Supr' };
}

async function principal() {
  const ctx = await chromium.launchPersistentContext(O.perfil, {
    channel: O.canal,
    headless: false,
    viewport: null,
    args: ['--window-size=1100,800', '--disable-features=Translate,TranslateUI',
      // Segundo plano: ventana fuera de la pantalla; si Outlook pide login, se trae delante (traerAPantalla).
      ...(O.segundoPlano && !O.explorar ? ['--window-position=-32000,-32000'] : [])],
    // Sin la barra «Un software de prueba automatizado está controlando…».
    ignoreDefaultArgs: ['--enable-automation'],
  });
  let cerrado = false;
  const cerrar = async () => { if (cerrado) return; cerrado = true; await ctx.close().catch(() => {}); };
  createInterface({ input: process.stdin }).on('line', async (l) => { if (l.trim() === 'fin') { await cerrar(); process.exit(0); } });

  try {
    await ctx.addInitScript(AVISO_LOGIN);
    const page = ctx.pages()[0] || (await ctx.newPage());
    await page.goto(O.url, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch((e) => diag('goto: ' + e.message));

    if (!(await esperarBandeja(page))) { emitir({ evento: 'error', mensaje: 'No se ha iniciado sesión en Outlook en el plazo' }); await cerrar(); process.exit(3); }

    if (O.soloBandeja) {
      // Solo comprueba que llega a la bandeja: no abre ningún correo.
      let n = 0;
      await recorrerPestanas(page, async () => { n += (await filas(page)).filter((f) => reFiltro.test(f.texto)).length; });
      console.log(JSON.stringify({ bandeja: true, canal: O.canal, host: new URL(page.url()).hostname, filasQuePasanElFiltro: n }));
      await cerrar();
      return;
    }

    if (O.explorar) {
      const vistos = new Set();
      await recorrerPestanas(page, async () => {
        for (const f of await filas(page)) {
          if (vistos.has(f.id) || !reFiltro.test(f.texto)) continue;
          vistos.add(f.id);
          const lineas = f.texto.split('\n').map((s) => s.trim()).filter(Boolean);
          console.log('---');
          console.log('resumen : ' + lineas.slice(0, 4).join(' | ').replace(/\d/g, '#').slice(0, 300));
          console.log('regex en la lista: ' + (extraerPin(f.texto) ? `sí (${extraerPin(f.texto).length} dígitos)` : 'no'));
          if (vistos.size === 1) {
            // Solo el más reciente que pasa el filtro: se abre para probar la regex sobre el cuerpo.
            await page.locator(`[role="listbox"] [role="option"][data-vpnforti="${f.marca}"]`).first().click().catch(() => {});
            await dormir(1500);
            const cuerpo = await cuerpoAbierto(page);
            const p = extraerPin(cuerpo);
            console.log('cuerpo (dígitos enmascarados): ' + cuerpo.replace(/\d/g, '#').replace(/\s+/g, ' ').slice(0, 400));
            console.log('regex en el cuerpo: ' + (p ? `sí (${p.length} dígitos)` : 'no'));
            // Simulación de «Borrar los correos leídos», sin pulsar nada: ¿se borraría esta fila?
            const pp = extraerPinPrincipal(cuerpo);
            const { fila, motivo } = filaABorrar(await filas(page), f.id, pp);
            let foco = false;
            if (fila) {
              const s = `[role="listbox"] [role="option"][data-vpnforti="${fila.marca}"]`;
              await page.locator(s).first().focus().catch(() => {});
              foco = await page.evaluate((x) => { const r = document.querySelector(x); return !!r && r.contains(document.activeElement); }, s).catch(() => false);
            }
            console.log('borrar los correos leídos (simulado, no se borra): ' + (!pp ? 'no (sin PIN de la regex principal en el cuerpo)' : fila ? (foco ? 'se borraría esta fila' : 'no (no se puede enfocar la fila)') : `no (${motivo})`));
          }
        }
      });
      console.log(`coincidencias: ${vistos.size}`);
      await cerrar();
      return;
    }

    // Línea base: todo lo que ya está en la bandeja no cuenta.
    const base = new Set();
    await recorrerPestanas(page, async () => { for (const f of await filas(page)) base.add(f.id); });
    emitir({ evento: 'listo' });
    diag(`Línea base: ${base.size} correos ya presentes; esperando el del PIN.`);

    const limite = Date.now() + O.timeoutSeg * 1000;
    let ultimaRecarga = Date.now();
    while (Date.now() < limite) {
      let pin = null;
      await recorrerPestanas(page, async () => {
        if (pin) return;
        for (const f of await filas(page)) {
          if (base.has(f.id)) continue;
          if (!reFiltro.test(f.texto)) { base.add(f.id); continue; }
          base.add(f.id);
          diag('Correo del PIN localizado; abriéndolo.');
          await page.locator(`[role="listbox"] [role="option"][data-vpnforti="${f.marca}"]`).first().click().catch(() => {});
          await dormir(1500);
          const cuerpo = await cuerpoAbierto(page);
          const pinCuerpo = extraerPin(cuerpo);
          pin = pinCuerpo || extraerPin(f.texto);
          if (pin) {
            if (O.accion === 'leido') await page.keyboard.press('q').catch(() => {});
            if (O.borrarLeido) {
              // Solo si el PIN sale del cuerpo con la regex principal (el correo está abierto y
              // seleccionado; la alternativa podría venir de otro correo aún en el panel); máximo 6 s.
              const r = !pinCuerpo || extraerPinPrincipal(cuerpo) !== pin
                ? { ok: false, motivo: 'el PIN no se ha leído del cuerpo del correo abierto con la regex principal' }
                : await Promise.race([
                  borrarCorreoDelPin(page, f.id, pin, Date.now() + 5000).catch((e) => ({ ok: false, motivo: String(e && e.message || e).slice(0, 200) })),
                  dormir(6000).then(() => ({ ok: false, motivo: 'tiempo agotado al borrar' })),
                ]);
              emitir({ evento: 'borrado', ok: r.ok, motivo: r.motivo });
              diag(r.ok ? 'Correo del PIN borrado (Elementos eliminados).' : `No se ha borrado el correo del PIN: ${r.motivo}`);
            }
            emitir({ evento: 'pin', pin });
            return;
          }
        }
      });
      if (pin) { diag('PIN recibido.'); await cerrar(); process.exit(0); }
      if (Date.now() - ultimaRecarga > 30000) { ultimaRecarga = Date.now(); await page.reload({ waitUntil: 'domcontentloaded' }).catch(() => {}); await esperarBandeja(page); }
      await dormir(O.sondeoSeg * 1000);
    }
    emitir({ evento: 'sin_pin' });
    await cerrar();
    process.exit(2);
  } catch (e) {
    emitir({ evento: 'error', mensaje: String(e && e.message || e).slice(0, 300) });
    await cerrar();
    process.exit(1);
  }
}

// PIN_OUTLOOK_SIN_ARRANQUE=1 permite importar el módulo (pruebas) sin abrir el navegador.
if (!process.env.PIN_OUTLOOK_SIN_ARRANQUE) principal();

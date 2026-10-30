// Pruebas de la interfaz web (HU19 / DEV008): cargan los módulos REALES de api/static/js en un DOM
// simulado (jsdom) y los ejecutan contra la API real. No usan navegador.
//
// Variables de entorno:
//   API_URL   API real SIN autenticación (obligatoria), p. ej. http://127.0.0.1:5101
//   AUTH_URL  API con el simulador de la HU18 y --pruebas (opcional), p. ej. http://127.0.0.1:5102
//   STATIC_DIR  carpeta con la interfaz (por defecto ../api/static)
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { JSDOM } from "jsdom";

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const STATIC = process.env.STATIC_DIR || path.resolve(AQUI, "../api/static");
const API_URL = process.env.API_URL;
const AUTH_URL = process.env.AUTH_URL;
const fetchReal = globalThis.fetch;

// ---------------------------------------------------------------- utilidades
async function esperar(cond, ms = 5000, paso = 15) {
  const t0 = Date.now();
  for (;;) {
    const r = cond();
    if (r) return r;
    if (Date.now() - t0 > ms) throw new Error(`Tiempo agotado esperando: ${cond.toString().slice(0, 120)}`);
    await new Promise((res) => setTimeout(res, paso));
  }
}

async function montar(baseUrl) {
  const html = fs.readFileSync(path.join(STATIC, "index.html"), "utf8");
  const dom = new JSDOM(html, { url: `${baseUrl}/ui/`, pretendToBeVisual: true });
  const w = dom.window;
  Object.assign(globalThis, {
    window: w, document: w.document, Node: w.Node, location: w.location,
    sessionStorage: w.sessionStorage, confirm: () => true, __UI_PRUEBAS__: true,
  });
  globalThis.fetch = (u, o) => fetchReal(new URL(u, baseUrl).href, o);
  w.__xss = undefined;

  // Copia aislada de los módulos: cada escenario tiene su propio estado (token, sesión...)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ui-"));
  fs.cpSync(path.join(STATIC, "js"), path.join(dir, "js"), { recursive: true });
  fs.writeFileSync(path.join(dir, "package.json"), '{"type":"module"}');
  const cargar = (f) => import(pathToFileURL(path.join(dir, "js", f)).href);
  const [main, api, auth] = [await cargar("main.js"), await cargar("api.js"), await cargar("auth.js")];
  return {
    w, main, api, auth, baseUrl,
    limpiar() { main.detener(); fs.rmSync(dir, { recursive: true, force: true }); },
  };
}

const q = (sel) => document.querySelector(sel);
const qa = (sel) => Array.from(document.querySelectorAll(sel));
const texto = (sel) => (q(sel)?.textContent ?? "");
const filaCon = (t) => qa("tbody tr").find((tr) => tr.textContent.includes(t));

function llenar(form, valores) {
  for (const [nombre, valor] of Object.entries(valores)) {
    const el = form.querySelector(`[name="${nombre}"]`);
    assert.ok(el, `no existe el campo ${nombre}`);
    el.value = valor;
  }
}
function enviar(form) {
  form.dispatchEvent(new window.Event("submit", { cancelable: true, bubbles: true }));
}
const irA = (ui, vista) => { q(`#menu button[data-vista="${vista}"]`).click(); };

// ---------------------------------------------------------------- 1. API sin autenticación (estado actual)
describe("Interfaz contra la API sin autenticación", { skip: !API_URL }, () => {
  let ui;
  before(async () => { ui = await montar(API_URL); await ui.main.arrancar(); });
  after(() => ui?.limpiar());

  test("detecta que no hay autenticación y muestra los tickets", async () => {
    assert.equal(ui.auth.sesion.modo, "none");
    await esperar(() => q("table.tabla-tickets"));
    assert.equal(q("#menu").hidden, false);
    assert.equal(q("#btn-salir").hidden, true, "sin login no debe haber botón Salir");
    assert.match(texto("#estado-conexion"), /Conectado/);
  });

  test("crea un usuario desde el formulario", async () => {
    irA(ui, "usuarios");
    await esperar(() => q("table.tabla-usuarios"));
    q("#btn-nuevo-usuario").click();
    const form = await esperar(() => q("#panel-usuario form"));
    llenar(form, { nombre: "Ana Pérez", email: "ana@example.com", rol: "tecnico" });
    enviar(form);
    await esperar(() => filaCon("ana@example.com"));
    assert.ok(filaCon("Técnico"), "debe mostrarse el rol");
  });

  test("muestra los errores de validación junto a cada campo", async () => {
    q("#btn-nuevo-usuario").click();
    const form = await esperar(() => q("#panel-usuario form"));
    llenar(form, { nombre: "A", email: "x", rol: "cliente" });
    enviar(form);
    await esperar(() => form.querySelector('[data-campo="nombre"] .error').textContent !== "");
    assert.match(form.querySelector('[data-campo="nombre"] .error').textContent, /entre 2 y 100/);
    assert.match(form.querySelector('[data-campo="email"] .error').textContent, /email/i);
    assert.match(form.querySelector(".error-general").textContent, /Revise los campos/);
  });

  test("rechaza un email duplicado con un mensaje claro", async () => {
    const form = q("#panel-usuario form");
    llenar(form, { nombre: "Otra Ana", email: "ANA@example.com", rol: "cliente" });
    enviar(form);
    await esperar(() => /Ya existe un usuario/.test(form.querySelector(".error-general").textContent));
  });

  test("crea un ticket, lo lista y cuenta el resumen", async () => {
    irA(ui, "tickets");
    await esperar(() => q("table.tabla-tickets"));
    q("#btn-nuevo-ticket").click();
    const form = await esperar(() => q("#panel-ticket form"));
    const opcion = Array.from(form.querySelectorAll("#f-usuario_id option")).find((o) => o.textContent.includes("ana@example.com"));
    assert.ok(opcion, "el selector de usuario debe listar a Ana");
    llenar(form, { titulo: "VPN no conecta", descripcion: "Sin handshake", prioridad: "alta", usuario_id: opcion.value });
    enviar(form);
    await esperar(() => filaCon("VPN no conecta"));
    assert.match(texto(".resumen"), /Total: 1/);
    assert.ok(filaCon("VPN no conecta").textContent.includes("Alta"));
  });

  test("valida un título demasiado corto", async () => {
    q("#btn-nuevo-ticket").click();
    const form = await esperar(() => q("#panel-ticket form"));
    const opcion = Array.from(form.querySelectorAll("#f-usuario_id option"))[1];
    llenar(form, { titulo: "ab", prioridad: "media", usuario_id: opcion.value });
    enviar(form);
    await esperar(() => form.querySelector('[data-campo="titulo"] .error').textContent !== "");
    assert.match(form.querySelector('[data-campo="titulo"] .error').textContent, /entre 3 y 120/);
    form.querySelector("button.sec").click();   // Cancelar
  });

  test("el contenido malicioso se muestra como texto y no se ejecuta", async () => {
    const malo = '<img src=x onerror="window.__xss=1">';
    q("#btn-nuevo-ticket").click();
    const form = await esperar(() => q("#panel-ticket form"));
    const opcion = Array.from(form.querySelectorAll("#f-usuario_id option"))[1];
    llenar(form, { titulo: malo, descripcion: "<script>window.__xss=2</script>", prioridad: "baja", usuario_id: opcion.value });
    enviar(form);
    const fila = await esperar(() => filaCon("onerror"));
    assert.ok(fila.textContent.includes("<img src=x"), "el texto debe verse literal");
    assert.equal(qa("img").length, 0, "no debe haberse creado ningún <img>");
    assert.equal(qa("script[src]").length, 1, "solo el script de la propia interfaz");
    assert.equal(window.__xss, undefined, "no debe haberse ejecutado código");
  });

  test("cerrar un ticket lo deja cerrado y no editable", async () => {
    const fila = filaCon("VPN no conecta");
    fila.querySelector('[data-accion="cerrar"]').click();
    await esperar(() => /Cerrado/.test(filaCon("VPN no conecta").textContent));
    const f2 = filaCon("VPN no conecta");
    assert.equal(f2.querySelector('[data-accion="editar"]').disabled, true);
    assert.equal(f2.querySelector('[data-accion="cerrar"]'), null);
  });

  test("editar un ticket envía solo los campos cambiados", async () => {
    const fila = filaCon("onerror");
    fila.querySelector('[data-accion="editar"]').click();
    const form = await esperar(() => q("#panel-ticket form"));
    llenar(form, { prioridad: "alta", estado: "en_progreso" });
    enviar(form);
    await esperar(() => /En progreso/.test(filaCon("onerror").textContent));
    assert.ok(filaCon("onerror").textContent.includes("Alta"));
  });

  test("los filtros reducen la lista", async () => {
    const sel = q("#filtro-estado");
    sel.value = "cerrado";
    sel.dispatchEvent(new window.Event("change", { bubbles: true }));
    await esperar(() => qa("tbody tr").length === 1);
    assert.ok(filaCon("VPN no conecta"));
    sel.value = "";
    sel.dispatchEvent(new window.Event("change", { bubbles: true }));
    await esperar(() => qa("tbody tr").length === 2);
  });

  test("no deja eliminar un usuario con tickets sin cerrar", async () => {
    irA(ui, "usuarios");
    await esperar(() => q("table.tabla-usuarios") && filaCon("ana@example.com"));
    filaCon("ana@example.com").querySelector('[data-accion="eliminar"]').click();
    await esperar(() => /sin cerrar/.test(texto("#aviso")));
    assert.ok(q("#aviso").classList.contains("error"));
    assert.ok(filaCon("ana@example.com"), "el usuario debe seguir en la lista");
  });

  test("detecta la caída de la conexión y su recuperación", async () => {
    const buena = globalThis.fetch;
    globalThis.fetch = () => Promise.reject(new Error("red caída"));
    for (let i = 0; i < 3; i++) await ui.main.tick();
    assert.match(texto("#estado-conexion"), /Sin conexión/);
    assert.ok(q("#estado-conexion").classList.contains("mal"));
    globalThis.fetch = buena;
    await ui.main.tick();
    assert.match(texto("#estado-conexion"), /Conectado/);
    assert.match(texto("#aviso"), /Conexión recuperada/);
  });

  test("avisa cuando responde otro servidor (failover)", async () => {
    const buena = globalThis.fetch;
    globalThis.fetch = async (u, o) => {
      const r = await buena(u, o);
      if (String(u).includes("/api/status")) {
        const datos = await r.json();
        datos.hostname = "otro-servidor-xyz";
        return new Response(JSON.stringify(datos), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      return r;
    };
    await ui.main.tick();
    globalThis.fetch = buena;
    assert.match(texto("#aviso"), /otro servidor/);
  });

  test("normalizarError entiende las dos formas de error de la API", () => {
    const a = ui.api.normalizarError(409, { error: { codigo: "email_duplicado", mensaje: "Ya existe", detalles: { email: "x" } } });
    assert.deepEqual([a.status, a.codigo, a.message, a.detalles], [409, "email_duplicado", "Ya existe", { email: "x" }]);
    const b = ui.api.normalizarError(409, { error: "email_duplicado", mensaje: "Ya existe un usuario con ese email" });
    assert.deepEqual([b.codigo, b.message], ["email_duplicado", "Ya existe un usuario con ese email"]);
    const c = ui.api.normalizarError(502, null);
    assert.deepEqual([c.codigo, c.message], ["error", "Error 502"]);
  });
});

// ---------------------------------------------------------------- 2. Con el simulador de la HU18 (login y roles)
describe("Interfaz con autenticación (simulador de la HU18)", { skip: !AUTH_URL }, () => {
  let ui;
  before(async () => { ui = await montar(AUTH_URL); await ui.main.arrancar(); });
  after(() => ui?.limpiar());

  async function iniciarSesion(correo, clave) {
    const form = await esperar(() => q("form.login"));
    q("#login-usuario").value = correo;
    q("#login-clave").value = clave;
    enviar(form);
  }

  test("detecta que se exige autenticación y muestra el login", async () => {
    assert.equal(ui.auth.sesion.modo, "token");
    await esperar(() => q("form.login"));
    assert.equal(q("#menu").hidden, true, "sin sesión no debe verse el menú");
  });

  test("rechaza credenciales inválidas", async () => {
    await iniciarSesion("tecnico@example.com", "incorrecta");
    await esperar(() => /Credenciales inválidas/.test(texto("form.login .error-general")));
    assert.equal(window.sessionStorage.length, 0, "no debe guardarse ningún token");
  });

  test("el técnico inicia sesión, ve Usuarios y puede operar", async () => {
    await iniciarSesion("tecnico@example.com", "Tecnico123!");
    await esperar(() => q("table.tabla-tickets"));
    assert.equal(q("#menu-usuarios").hidden, false);
    assert.equal(q("#btn-salir").hidden, false);
    assert.match(texto("#sesion"), /tecnico/);
    assert.ok(window.sessionStorage.length === 1, "el token queda en sessionStorage");
    // Crear un ticket demuestra que el token viaja en la cabecera (el simulador exige autenticación en todo /api/*)
    q("#btn-nuevo-ticket").click();
    const form = await esperar(() => q("#panel-ticket form"));
    const opcion = Array.from(form.querySelectorAll("#f-usuario_id option"))[1];
    llenar(form, { titulo: "Ticket del técnico", prioridad: "media", usuario_id: opcion.value });
    enviar(form);
    await esperar(() => filaCon("Ticket del técnico"));
    irA(ui, "usuarios");
    await esperar(() => q("table.tabla-usuarios") && filaCon("cliente@example.com"));
    q("#btn-nuevo-usuario").click();
    const f = await esperar(() => q("#panel-usuario form"));
    assert.ok(f.querySelector('[name="clave"]'), "con login, el formulario de usuario pide contraseña");
  });

  test("si el token deja de valer, vuelve al login con un aviso", async () => {
    irA(ui, "tickets");
    await esperar(() => q("table.tabla-tickets"));
    await fetchReal(`${AUTH_URL}/__test/revocar`, { method: "POST" });   // el servidor olvida todos los tokens
    const sel = q("#filtro-estado");
    sel.value = "abierto";
    sel.dispatchEvent(new window.Event("change", { bubbles: true }));
    await esperar(() => q("form.login"));
    assert.match(texto("#aviso"), /sesión expiró/);
    assert.equal(q("#menu").hidden, true);
    assert.equal(window.sessionStorage.length, 0);
  });

  test("el cliente no ve Usuarios, crea tickets a su nombre y no puede eliminar", async () => {
    await iniciarSesion("cliente@example.com", "Cliente123!");
    await esperar(() => q("table.tabla-tickets"));
    assert.equal(q("#menu-usuarios").hidden, true);
    assert.equal(qa('[data-accion="eliminar"]').length, 0, "el cliente no ve el botón Eliminar");
    q("#btn-nuevo-ticket").click();
    const form = await esperar(() => q("#panel-ticket form"));
    assert.equal(form.querySelector("#f-usuario_id"), null, "el cliente no elige usuario");
    llenar(form, { titulo: "Ticket del cliente", prioridad: "baja" });
    enviar(form);
    await esperar(() => filaCon("Ticket del cliente"));
  });

  test("el cliente es redirigido si intenta abrir Usuarios", async () => {
    window.location.hash = "#/usuarios";
    await esperar(() => /no permite gestionar usuarios/.test(texto("#aviso")));
    assert.ok(q("table.tabla-tickets"));
  });

  test("Salir cierra la sesión", async () => {
    q("#btn-salir").click();
    await esperar(() => q("form.login"));
    assert.equal(window.sessionStorage.length, 0);
    assert.equal(q("#menu").hidden, true);
  });
});

// Arranque de la interfaz: detecta el modo de autenticación, enruta las vistas y vigila la conexión.
import { CONFIG } from "./config.js";
import * as api from "./api.js";
import * as auth from "./auth.js";
import { vistaTickets, vistaUsuarios, vistaLogin } from "./vistas.js";

const $ = (id) => document.getElementById(id);
let temporizadorAviso = null;
let temporizadorMonitor = null;
let detenido = false;

export function avisar(tipo, texto) {
  const a = $("aviso");
  a.className = `aviso ${tipo}`;
  a.textContent = texto;
  a.hidden = false;
  clearTimeout(temporizadorAviso);
  if (tipo !== "error") temporizadorAviso = setTimeout(() => { a.hidden = true; }, 6000);
}

// ------------------------------------------------------------ menú y sesión
export function pintarMenu() {
  const conAcceso = auth.hayAcceso();
  $("menu").hidden = !conAcceso;
  $("menu-usuarios").hidden = !auth.esTecnico();
  const hayLogin = auth.sesion.modo === "token" && auth.sesion.usuario;
  $("btn-salir").hidden = !hayLogin;
  const s = $("sesion");
  s.hidden = !hayLogin;
  s.textContent = hayLogin ? `${auth.sesion.usuario.nombre || auth.sesion.usuario.email} · ${auth.sesion.usuario.rol}` : "";
}

export async function enrutar() {
  const raiz = $("contenido");
  if (!auth.hayAcceso()) {
    pintarMenu();
    vistaLogin(raiz, () => { avisar("ok", "Sesión iniciada."); pintarMenu(); enrutar(); });
    return;
  }
  pintarMenu();
  let ruta = (location.hash || "").replace(/^#\/?/, "") || "tickets";
  if (ruta === "usuarios" && !auth.esTecnico()) {
    avisar("warn", "Su rol no permite gestionar usuarios.");
    ruta = "tickets";
    location.hash = "#/tickets";
  }
  document.querySelectorAll("#menu button").forEach((b) => b.classList.toggle("activo", b.dataset.vista === ruta));
  raiz.replaceChildren();
  if (ruta === "usuarios") await vistaUsuarios(raiz, avisar);
  else await vistaTickets(raiz, avisar);
}

function cerrarSesion(mensaje) {
  auth.salir();
  if (mensaje) avisar("warn", mensaje);
  pintarMenu();
  enrutar();
}

// ------------------------------------------------------------ supervisión de la conexión
const monitor = { fallos: 0, caido: false, ultimoHost: null };

export async function tick() {
  const caja = $("estado-conexion");
  try {
    const { datos, ms } = await api.estado();
    const host = datos && datos.hostname ? String(datos.hostname).slice(0, 12) : "";
    monitor.fallos = 0;
    caja.className = "estado ok";
    caja.textContent = `● Conectado${host ? ` · servidor ${host}` : ""} · ${ms} ms`;
    caja.title = datos && datos.client_ip ? `Origen visto por la API: ${datos.client_ip}` : "";
    if (monitor.caido) { avisar("ok", "Conexión recuperada."); monitor.caido = false; }
    if (monitor.ultimoHost && host && host !== monitor.ultimoHost) {
      avisar("info", `Ahora responde otro servidor (${host}). Los datos pueden diferir del servidor anterior.`);
    }
    if (host) monitor.ultimoHost = host;
  } catch (_e) {
    monitor.fallos += 1;
    if (monitor.fallos >= CONFIG.FALLOS_PARA_ALERTA) {
      monitor.caido = true;
      caja.className = "estado mal";
      caja.textContent = "● Sin conexión con el servicio (¿VPN o servidor caído?)";
    }
  }
}

function programarMonitor() {
  if (detenido) return;
  temporizadorMonitor = setTimeout(async () => { await tick(); programarMonitor(); }, CONFIG.POLL_MS);
}

export function detener() {
  detenido = true;
  clearTimeout(temporizadorMonitor);
  clearTimeout(temporizadorAviso);
}

// ------------------------------------------------------------ arranque
async function iniciarSesion() {
  for (;;) {
    try { await auth.iniciar(); return; }
    catch (e) {
      if (detenido) return;
      avisar("error", `${e.message} Reintentando…`);
      await new Promise((r) => setTimeout(r, CONFIG.POLL_MS));
    }
  }
}

export async function arrancar() {
  detenido = false;
  api.alPerderSesion(() => cerrarSesion("La sesión expiró o fue cerrada. Inicie sesión de nuevo."));
  document.querySelectorAll("#menu button").forEach((b) => b.addEventListener("click", () => { location.hash = `#/${b.dataset.vista}`; }));
  $("btn-salir").addEventListener("click", () => cerrarSesion("Sesión cerrada."));
  window.addEventListener("hashchange", enrutar);
  await tick();
  programarMonitor();
  await iniciarSesion();
  await enrutar();
}

if (!globalThis.__UI_PRUEBAS__) arrancar();

// Cliente de la API REST. Toda la comunicación con el servicio pasa por aquí.
import { CONFIG } from "./config.js";

let token = null;
let alPerderSesionFn = null;

export class ApiError extends Error {
  constructor(status, codigo, mensaje, detalles = null) {
    super(mensaje);
    this.name = "ApiError";
    this.status = status;       // 0 = sin conexión
    this.codigo = codigo;
    this.detalles = detalles;   // {campo: mensaje} en errores 422
  }
}

export function setToken(t) { token = t || null; }
export function getToken() { return token; }
export function alPerderSesion(fn) { alPerderSesionFn = fn; }

// La API devuelve dos formas de error: {"error": {"codigo", "mensaje", "detalles"}} (la normal)
// y {"error": "<codigo>", "mensaje": "..."} (los manejadores de PostgreSQL de app.py).
export function normalizarError(status, datos) {
  let codigo = "error";
  let mensaje = `Error ${status}`;
  let detalles = null;
  const e = datos && datos.error;
  if (e && typeof e === "object") {
    codigo = e.codigo || codigo;
    mensaje = e.mensaje || mensaje;
    detalles = e.detalles || null;
  } else if (typeof e === "string") {
    codigo = e;
    mensaje = (datos && datos.mensaje) || mensaje;
  } else if (datos && datos.mensaje) {
    mensaje = datos.mensaje;
  }
  return new ApiError(status, codigo, mensaje, detalles);
}

async function pedir(metodo, ruta, cuerpo, { conToken = true, notificar = true } = {}) {
  const cabeceras = { Accept: "application/json" };
  if (cuerpo !== undefined) cabeceras["Content-Type"] = "application/json";
  if (conToken && token) cabeceras[CONFIG.AUTH_HEADER] = `${CONFIG.AUTH_ESQUEMA} ${token}`;

  const t0 = performance.now();
  let resp;
  try {
    resp = await fetch(ruta, {
      method: metodo,
      headers: cabeceras,
      body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
      signal: AbortSignal.timeout(CONFIG.TIMEOUT_MS),
    });
  } catch (_e) {
    throw new ApiError(0, "sin_conexion", "No se pudo contactar con el servicio. ¿Está activa la VPN?");
  }
  const ms = Math.round(performance.now() - t0);

  let datos = null;
  if (resp.status !== 204) {
    try { datos = await resp.json(); } catch (_e) { datos = null; }
  }
  if (!resp.ok) {
    const err = normalizarError(resp.status, datos);
    if (resp.status === 401 && conToken && token && notificar && alPerderSesionFn) alPerderSesionFn();
    throw err;
  }
  return { datos, ms };
}

export const pedirSinToken = (metodo, ruta, cuerpo) => pedir(metodo, ruta, cuerpo, { conToken: false });
export const pedirConToken = (metodo, ruta, cuerpo, opciones) => pedir(metodo, ruta, cuerpo, { conToken: true, ...opciones });

const consulta = (obj) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(obj || {})) if (v !== "" && v !== null && v !== undefined) p.set(k, v);
  const s = p.toString();
  return s ? `?${s}` : "";
};

// --- Estado del servicio (público)
export const estado = () => pedir("GET", "/api/status", undefined, { conToken: false });

// --- Usuarios
export const listarUsuarios = async () => (await pedir("GET", "/api/usuarios")).datos.data;
export const crearUsuario = async (d) => (await pedir("POST", "/api/usuarios", d)).datos;
export const actualizarUsuario = async (id, d) => (await pedir("PATCH", `/api/usuarios/${id}`, d)).datos;
export const eliminarUsuario = async (id) => { await pedir("DELETE", `/api/usuarios/${id}`); };

// --- Tickets
export const listarTickets = async (filtros) => (await pedir("GET", `/api/tickets${consulta(filtros)}`)).datos.data;
export const crearTicket = async (d) => (await pedir("POST", "/api/tickets", d)).datos;
export const actualizarTicket = async (id, d) => (await pedir("PATCH", `/api/tickets/${id}`, d)).datos;
export const eliminarTicket = async (id) => { await pedir("DELETE", `/api/tickets/${id}`); };

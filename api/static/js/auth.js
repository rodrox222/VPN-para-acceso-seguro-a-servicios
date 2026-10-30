// Sesión. Funciona hoy sin autenticación (modo "none") y con la HU18 (modo "token").
import { CONFIG } from "./config.js";
import * as api from "./api.js";

const CLAVE_SESION = "vpn_api_sesion";

export const sesion = { modo: "none", usuario: null };

// El token vive en sessionStorage: se borra al cerrar la pestaña. La política CSP del servicio
// y el uso de textContent (nunca innerHTML) reducen el riesgo de que un script lo lea.
function guardar(token) { try { sessionStorage.setItem(CLAVE_SESION, token); } catch (_e) { /* sin almacenamiento */ } }
function leer() { try { return sessionStorage.getItem(CLAVE_SESION); } catch (_e) { return null; } }
function borrar() { try { sessionStorage.removeItem(CLAVE_SESION); } catch (_e) { /* nada */ } }

// La ruta "me" puede devolver el usuario directamente o dentro de {usuario: {...}}
const extraerUsuario = (datos) => (datos && typeof datos.usuario === "object" ? datos.usuario : datos);

async function obtenerYo(opciones) {
  const { datos } = await api.pedirConToken("GET", CONFIG.ENDPOINTS.me, undefined, opciones);
  return extraerUsuario(datos);
}

async function detectarModo() {
  try {
    await api.pedirSinToken("GET", CONFIG.ENDPOINTS.me);
    return "token";                                            // la ruta existe y respondió
  } catch (e) {
    if (e.status === 401 || e.status === 403) return "token";  // existe y exige credenciales
    if (e.status === 0) throw e;                               // sin conexión: el llamador reintenta
    return "none";                                             // 404: la API aún no tiene autenticación
  }
}

export async function iniciar() {
  const modo = CONFIG.AUTH_MODE === "auto" ? await detectarModo() : CONFIG.AUTH_MODE;
  sesion.modo = modo;
  sesion.usuario = null;
  if (modo === "token") {
    const guardado = leer();
    if (guardado) {
      api.setToken(guardado);
      try {
        sesion.usuario = await obtenerYo({ notificar: false });   // valida el token guardado
      } catch (e) {
        if (e.status === 0) throw e;
        salir();                                                  // token vencido o inválido
      }
    }
  }
  return sesion;
}

export async function login(usuario, clave) {
  const cuerpo = { [CONFIG.LOGIN_CAMPOS.usuario]: usuario, [CONFIG.LOGIN_CAMPOS.clave]: clave };
  const { datos } = await api.pedirSinToken("POST", CONFIG.ENDPOINTS.login, cuerpo);
  const token = datos && datos[CONFIG.RESPUESTA_LOGIN.token];
  if (!token) throw new api.ApiError(500, "respuesta_login", "El servicio no devolvió un token de sesión.");
  api.setToken(token);
  guardar(token);
  sesion.usuario = (datos && datos[CONFIG.RESPUESTA_LOGIN.usuario]) || (await obtenerYo());
  return sesion.usuario;
}

export function salir() {
  api.setToken(null);
  borrar();
  sesion.usuario = null;
}

export const esTecnico = () => sesion.modo === "none" || sesion.usuario?.rol === CONFIG.ROLES.tecnico;
export const esCliente = () => sesion.modo === "token" && sesion.usuario?.rol === CONFIG.ROLES.cliente;
export const hayAcceso = () => sesion.modo === "none" || sesion.usuario !== null;

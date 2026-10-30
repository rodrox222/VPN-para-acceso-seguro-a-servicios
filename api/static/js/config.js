// Configuración de la interfaz.
// Si la HU18 usa nombres distintos para el login, el token o los roles, se ajusta SOLO este archivo.
export const CONFIG = {
  // "auto": detecta si la API exige autenticación | "none": sin login | "token": con login
  AUTH_MODE: "auto",

  // Rutas de autenticación esperadas (contrato propuesto para la HU18; ver docs/DEV008)
  ENDPOINTS: { login: "/api/auth/login", me: "/api/auth/me" },

  // Nombres de los campos del cuerpo del login
  LOGIN_CAMPOS: { usuario: "email", clave: "password" },

  // Dónde vienen el token y el usuario en la respuesta del login
  RESPUESTA_LOGIN: { token: "token", usuario: "usuario" },

  // Cabecera en la que se envía el token
  AUTH_HEADER: "Authorization",
  AUTH_ESQUEMA: "Bearer",

  // Valores del campo "rol" del usuario
  ROLES: { tecnico: "tecnico", cliente: "cliente" },

  // Campo para fijar la contraseña al crear usuarios (solo con login). null = no mostrar
  CAMPO_CLAVE_USUARIO: "password",

  // Supervisión de la conexión
  POLL_MS: 5000,
  FALLOS_PARA_ALERTA: 3,
  TIMEOUT_MS: 5000,
};

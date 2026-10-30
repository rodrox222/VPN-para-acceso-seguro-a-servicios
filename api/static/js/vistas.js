// Vistas de la interfaz. Todo el texto que viene de la API se inserta con textContent
// (nunca con innerHTML) para que un título o nombre malicioso no pueda ejecutar código.
import * as api from "./api.js";
import * as auth from "./auth.js";
import { CONFIG } from "./config.js";

const PRIORIDADES = ["baja", "media", "alta"];
const ESTADOS = ["abierto", "en_progreso", "cerrado"];
const ROLES = ["cliente", "tecnico"];
const ETQ_ESTADO = { abierto: "Abierto", en_progreso: "En progreso", cerrado: "Cerrado" };
const ETQ_PRIO = { baja: "Baja", media: "Media", alta: "Alta" };
const ETQ_ROL = { cliente: "Cliente", tecnico: "Técnico" };

// ---------------------------------------------------------------- utilidades de DOM
export function h(tag, props = null, ...hijos) {
  const el = document.createElement(tag);
  let valor;
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k === "value") valor = v;
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, String(v));
  }
  agregar(el, hijos);
  if (valor !== undefined) el.value = valor;   // después de crear las <option>
  return el;
}

function agregar(el, hijos) {
  for (const hijo of hijos) {
    if (hijo === null || hijo === undefined || hijo === false) continue;
    if (Array.isArray(hijo)) agregar(el, hijo);
    else if (hijo instanceof Node) el.appendChild(hijo);
    else el.appendChild(document.createTextNode(String(hijo)));
  }
}

const fecha = (iso) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : d.toLocaleString("es");
};

function campo(nombre, etiqueta, control, ayuda) {
  return h("div", { class: "campo", "data-campo": nombre },
    h("label", { for: `f-${nombre}`, text: etiqueta }),
    control,
    ayuda ? h("small", { class: "ayuda", text: ayuda }) : null,
    h("div", { class: "error", role: "alert" }));
}

function selectSimple(id, valores, etiquetas, actual) {
  return h("select", { id, name: id.replace(/^f-/, ""), value: actual },
    valores.map((v) => h("option", { value: v, text: etiquetas[v] || v })));
}

function limpiarErrores(form) {
  form.querySelectorAll(".error").forEach((e) => { e.textContent = ""; });
  const g = form.querySelector(".error-general");
  if (g) g.textContent = "";
}

// Muestra los errores 422 junto a cada campo y el resto en un mensaje general
function mostrarErrores(form, err) {
  limpiarErrores(form);
  const general = form.querySelector(".error-general");
  let enCampos = 0;
  const sueltos = [];
  if (err.detalles && typeof err.detalles === "object") {
    const contenedores = Array.from(form.querySelectorAll("[data-campo]"));
    for (const [k, msg] of Object.entries(err.detalles)) {
      const cont = contenedores.find((c) => c.dataset.campo === k);
      if (cont) { cont.querySelector(".error").textContent = msg; enCampos += 1; }
      else sueltos.push(`${k}: ${msg}`);
    }
  }
  if (sueltos.length) general.textContent = sueltos.join(" · ");
  else if (enCampos) general.textContent = "Revise los campos marcados.";
  else general.textContent = mensajeDe(err);
}

export function mensajeDe(err) {
  if (err && err.status === 403) return "No tiene permiso para realizar esta acción.";
  return (err && err.message) || "Error inesperado.";
}

const badge = (clase, texto) => h("span", { class: `badge ${clase}`, text: texto });

// ---------------------------------------------------------------- login
export function vistaLogin(raiz, alIngresar) {
  const esCorreo = CONFIG.LOGIN_CAMPOS.usuario === "email";
  const iUsuario = h("input", { id: "login-usuario", name: "usuario", type: esCorreo ? "email" : "text", autocomplete: "username" });
  const iClave = h("input", { id: "login-clave", name: "clave", type: "password", autocomplete: "current-password" });
  const error = h("div", { class: "error-general", role: "alert" });
  const boton = h("button", { type: "submit", text: "Ingresar" });
  const form = h("form", { class: "panel login", novalidate: true, "aria-label": "Iniciar sesión" },
    h("h2", { text: "Iniciar sesión" }),
    h("div", { class: "campo" }, h("label", { for: "login-usuario", text: esCorreo ? "Correo electrónico" : "Usuario" }), iUsuario),
    h("div", { class: "campo" }, h("label", { for: "login-clave", text: "Contraseña" }), iClave),
    error, boton);
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    error.textContent = "";
    boton.disabled = true;
    try {
      await auth.login(iUsuario.value.trim(), iClave.value);
      alIngresar();
    } catch (e) {
      error.textContent = e.status === 401 ? "Credenciales inválidas." : mensajeDe(e);
    } finally {
      boton.disabled = false;
    }
  });
  raiz.replaceChildren(form);
  iUsuario.focus();
}

// ---------------------------------------------------------------- tickets
export async function vistaTickets(raiz, avisar) {
  const st = { usuarios: [], tickets: [], filtros: { estado: "", prioridad: "", usuario_id: "" } };
  const veUsuarios = auth.esTecnico();
  const puedeEliminar = auth.esTecnico();
  const yo = auth.sesion.usuario;

  const nombreDe = (id) => {
    const u = st.usuarios.find((x) => x.id === id);
    if (u) return u.nombre;
    if (yo && yo.id === id) return yo.nombre;
    return `#${id}`;
  };

  const resumen = h("div", { class: "resumen", "aria-label": "Resumen de tickets" });
  const cuerpo = h("tbody");
  const vacio = h("p", { class: "vacio", hidden: true, text: "No hay tickets que coincidan con los filtros." });
  const panel = h("section", { class: "panel", id: "panel-ticket", hidden: true });

  const selEstado = h("select", { id: "filtro-estado", "aria-label": "Filtrar por estado", onchange: (e) => { st.filtros.estado = e.target.value; recargar(); } },
    h("option", { value: "", text: "Todos los estados" }),
    ESTADOS.map((v) => h("option", { value: v, text: ETQ_ESTADO[v] })));
  const selPrio = h("select", { id: "filtro-prioridad", "aria-label": "Filtrar por prioridad", onchange: (e) => { st.filtros.prioridad = e.target.value; recargar(); } },
    h("option", { value: "", text: "Todas las prioridades" }),
    PRIORIDADES.map((v) => h("option", { value: v, text: ETQ_PRIO[v] })));
  const selUsr = veUsuarios
    ? h("select", { id: "filtro-usuario", "aria-label": "Filtrar por usuario", onchange: (e) => { st.filtros.usuario_id = e.target.value; recargar(); } },
        h("option", { value: "", text: "Todos los usuarios" }))
    : null;

  const btnNuevo = h("button", { type: "button", id: "btn-nuevo-ticket", text: "Nuevo ticket", onclick: () => abrirFormulario(null) });

  const tabla = h("table", { class: "tabla tabla-tickets" },
    h("thead", {}, h("tr", {}, ["ID", "Ticket", "Prioridad", "Estado", "Usuario", "Actualizado", "Acciones"].map((t) => h("th", { scope: "col", text: t })))),
    cuerpo);

  raiz.replaceChildren(
    h("div", { class: "cabecera-vista" }, h("h2", { text: "Tickets" }), btnNuevo),
    panel,
    h("div", { class: "filtros" }, selEstado, selPrio, selUsr),
    resumen,
    h("div", { class: "contenedor-tabla" }, tabla),
    vacio);

  function pintarFiltroUsuarios() {
    if (!selUsr) return;
    const actual = st.filtros.usuario_id;
    selUsr.replaceChildren(
      h("option", { value: "", text: "Todos los usuarios" }),
      st.usuarios.map((u) => h("option", { value: String(u.id), text: u.nombre })));
    selUsr.value = actual;
  }

  function pintar() {
    const cuenta = (e) => st.tickets.filter((t) => t.estado === e).length;
    resumen.replaceChildren(
      h("span", { class: "dato", text: `Total: ${st.tickets.length}` }),
      h("span", { class: "dato", text: `Abiertos: ${cuenta("abierto")}` }),
      h("span", { class: "dato", text: `En progreso: ${cuenta("en_progreso")}` }),
      h("span", { class: "dato", text: `Cerrados: ${cuenta("cerrado")}` }));
    cuerpo.replaceChildren(st.tickets.map(fila));
    vacio.hidden = st.tickets.length > 0;
  }

  function fila(t) {
    const cerrado = t.estado === "cerrado";
    return h("tr", { "data-id": t.id },
      h("td", { text: t.id }),
      h("td", { class: "titulo" },
        h("strong", { text: t.titulo }),
        t.descripcion ? h("div", { class: "desc", text: t.descripcion }) : null),
      h("td", {}, badge(`prio-${t.prioridad}`, ETQ_PRIO[t.prioridad] || t.prioridad)),
      h("td", {}, badge(`est-${t.estado}`, ETQ_ESTADO[t.estado] || t.estado)),
      h("td", { text: nombreDe(t.usuario_id) }),
      h("td", { text: fecha(t.actualizado_en) }),
      h("td", { class: "acciones" },
        h("button", { type: "button", class: "sec", "data-accion": "editar", disabled: cerrado,
          title: cerrado ? "Un ticket cerrado no se puede modificar" : null, text: "Editar", onclick: () => abrirFormulario(t) }),
        cerrado ? null : h("button", { type: "button", class: "sec", "data-accion": "cerrar", text: "Cerrar", onclick: () => cerrarTicket(t) }),
        puedeEliminar ? h("button", { type: "button", class: "peligro", "data-accion": "eliminar", text: "Eliminar", onclick: () => eliminarTicket(t) }) : null));
  }

  async function recargar() {
    try {
      if (veUsuarios && st.usuarios.length === 0) {
        try { st.usuarios = await api.listarUsuarios(); } catch (e) { if (e.status !== 403) throw e; }
        pintarFiltroUsuarios();
      }
      st.tickets = await api.listarTickets(st.filtros);
      pintar();
    } catch (e) {
      avisar("error", mensajeDe(e));
    }
  }

  async function cerrarTicket(t) {
    try {
      await api.actualizarTicket(t.id, { estado: "cerrado" });
      avisar("ok", `Ticket #${t.id} cerrado.`);
      await recargar();
    } catch (e) { avisar("error", mensajeDe(e)); }
  }

  async function eliminarTicket(t) {
    if (!confirm(`¿Eliminar el ticket #${t.id}? Esta acción no se puede deshacer.`)) return;
    try {
      await api.eliminarTicket(t.id);
      avisar("ok", `Ticket #${t.id} eliminado.`);
      await recargar();
    } catch (e) { avisar("error", mensajeDe(e)); }
  }

  function cerrarFormulario() { panel.replaceChildren(); panel.hidden = true; }

  function abrirFormulario(ticket) {
    const editando = Boolean(ticket);
    const iTitulo = h("input", { id: "f-titulo", name: "titulo", type: "text", maxlength: "120", autocomplete: "off", value: ticket ? ticket.titulo : "" });
    const iDesc = h("textarea", { id: "f-descripcion", name: "descripcion", rows: "4", maxlength: "1000", value: ticket ? ticket.descripcion : "" });
    const iPrio = selectSimple("f-prioridad", PRIORIDADES, ETQ_PRIO, ticket ? ticket.prioridad : "media");
    const iEstado = editando ? selectSimple("f-estado", ESTADOS, ETQ_ESTADO, ticket.estado) : null;
    const iUsuario = veUsuarios
      ? h("select", { id: "f-usuario_id", name: "usuario_id" },
          h("option", { value: "", text: "Seleccione un usuario" }),
          st.usuarios.map((u) => h("option", { value: String(u.id), text: `${u.nombre} (${u.email})` })))
      : null;
    if (iUsuario && ticket) iUsuario.value = String(ticket.usuario_id);

    const errorGeneral = h("div", { class: "error-general", role: "alert" });
    const guardar = h("button", { type: "submit", text: "Guardar" });
    const form = h("form", { novalidate: true, "aria-label": editando ? "Editar ticket" : "Nuevo ticket" },
      h("h3", { text: editando ? `Editar ticket #${ticket.id}` : "Nuevo ticket" }),
      campo("titulo", "Título", iTitulo),
      campo("descripcion", "Descripción", iDesc, "Opcional, hasta 1000 caracteres."),
      campo("prioridad", "Prioridad", iPrio),
      iUsuario ? campo("usuario_id", "Usuario", iUsuario) : null,
      iEstado ? campo("estado", "Estado", iEstado) : null,
      errorGeneral,
      h("div", { class: "botones" }, guardar,
        h("button", { type: "button", class: "sec", text: "Cancelar", onclick: cerrarFormulario })));

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      limpiarErrores(form);
      const nuevos = { titulo: iTitulo.value.trim(), descripcion: iDesc.value, prioridad: iPrio.value };
      if (iEstado) nuevos.estado = iEstado.value;
      if (iUsuario) { if (iUsuario.value !== "") nuevos.usuario_id = Number(iUsuario.value); }
      else if (!editando && yo && yo.id !== undefined) nuevos.usuario_id = yo.id;   // cliente: siempre a su nombre
      guardar.disabled = true;
      try {
        if (editando) {
          const cambios = {};
          for (const [k, v] of Object.entries(nuevos)) if (v !== ticket[k]) cambios[k] = v;
          if (Object.keys(cambios).length === 0) { avisar("info", "No hay cambios que guardar."); cerrarFormulario(); return; }
          await api.actualizarTicket(ticket.id, cambios);
          avisar("ok", `Ticket #${ticket.id} actualizado.`);
        } else {
          const creado = await api.crearTicket(nuevos);
          avisar("ok", `Ticket #${creado.id} creado.`);
        }
        cerrarFormulario();
        await recargar();
      } catch (e) {
        mostrarErrores(form, e);
      } finally {
        guardar.disabled = false;
      }
    });

    panel.replaceChildren(form);
    panel.hidden = false;
    iTitulo.focus();
  }

  await recargar();
}

// ---------------------------------------------------------------- usuarios
export async function vistaUsuarios(raiz, avisar) {
  const st = { usuarios: [] };
  const conClave = auth.sesion.modo === "token" && CONFIG.CAMPO_CLAVE_USUARIO;
  const cuerpo = h("tbody");
  const vacio = h("p", { class: "vacio", hidden: true, text: "Todavía no hay usuarios." });
  const panel = h("section", { class: "panel", id: "panel-usuario", hidden: true });

  const tabla = h("table", { class: "tabla tabla-usuarios" },
    h("thead", {}, h("tr", {}, ["ID", "Nombre", "Email", "Rol", "Creado", "Acciones"].map((t) => h("th", { scope: "col", text: t })))),
    cuerpo);

  raiz.replaceChildren(
    h("div", { class: "cabecera-vista" }, h("h2", { text: "Usuarios" }),
      h("button", { type: "button", id: "btn-nuevo-usuario", text: "Nuevo usuario", onclick: () => abrirFormulario(null) })),
    panel,
    h("div", { class: "contenedor-tabla" }, tabla),
    vacio);

  function pintar() {
    cuerpo.replaceChildren(st.usuarios.map((u) => h("tr", { "data-id": u.id },
      h("td", { text: u.id }),
      h("td", { text: u.nombre }),
      h("td", { text: u.email }),
      h("td", {}, badge(`rol-${u.rol}`, ETQ_ROL[u.rol] || u.rol)),
      h("td", { text: fecha(u.creado_en) }),
      h("td", { class: "acciones" },
        h("button", { type: "button", class: "sec", "data-accion": "editar", text: "Editar", onclick: () => abrirFormulario(u) }),
        h("button", { type: "button", class: "peligro", "data-accion": "eliminar", text: "Eliminar", onclick: () => eliminar(u) })))));
    vacio.hidden = st.usuarios.length > 0;
  }

  async function recargar() {
    try {
      st.usuarios = await api.listarUsuarios();
      pintar();
    } catch (e) { avisar("error", mensajeDe(e)); }
  }

  async function eliminar(u) {
    if (!confirm(`¿Eliminar al usuario ${u.nombre}? Se eliminarán también sus tickets cerrados.`)) return;
    try {
      await api.eliminarUsuario(u.id);
      avisar("ok", `Usuario ${u.nombre} eliminado.`);
      await recargar();
    } catch (e) { avisar("error", mensajeDe(e)); }   // p. ej. 409: tiene tickets sin cerrar
  }

  function cerrarFormulario() { panel.replaceChildren(); panel.hidden = true; }

  function abrirFormulario(usuario) {
    const editando = Boolean(usuario);
    const iNombre = h("input", { id: "f-nombre", name: "nombre", type: "text", maxlength: "100", autocomplete: "off", value: usuario ? usuario.nombre : "" });
    const iEmail = h("input", { id: "f-email", name: "email", type: "email", maxlength: "120", autocomplete: "off", value: usuario ? usuario.email : "" });
    const iRol = selectSimple("f-rol", ROLES, ETQ_ROL, usuario ? usuario.rol : "cliente");
    const iClave = conClave ? h("input", { id: "f-clave", name: "clave", type: "password", autocomplete: "new-password" }) : null;
    const errorGeneral = h("div", { class: "error-general", role: "alert" });
    const guardar = h("button", { type: "submit", text: "Guardar" });
    const form = h("form", { novalidate: true, "aria-label": editando ? "Editar usuario" : "Nuevo usuario" },
      h("h3", { text: editando ? `Editar usuario #${usuario.id}` : "Nuevo usuario" }),
      campo("nombre", "Nombre", iNombre),
      campo("email", "Correo electrónico", iEmail),
      campo("rol", "Rol", iRol),
      iClave ? campo(CONFIG.CAMPO_CLAVE_USUARIO, "Contraseña", iClave, editando ? "Déjela vacía para no cambiarla." : null) : null,
      errorGeneral,
      h("div", { class: "botones" }, guardar,
        h("button", { type: "button", class: "sec", text: "Cancelar", onclick: cerrarFormulario })));

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      limpiarErrores(form);
      const nuevos = { nombre: iNombre.value.trim(), email: iEmail.value.trim(), rol: iRol.value };
      if (iClave && iClave.value) nuevos[CONFIG.CAMPO_CLAVE_USUARIO] = iClave.value;
      guardar.disabled = true;
      try {
        if (editando) {
          const cambios = {};
          for (const [k, v] of Object.entries(nuevos)) if (v !== usuario[k]) cambios[k] = v;
          if (Object.keys(cambios).length === 0) { avisar("info", "No hay cambios que guardar."); cerrarFormulario(); return; }
          await api.actualizarUsuario(usuario.id, cambios);
          avisar("ok", `Usuario ${nuevos.nombre} actualizado.`);
        } else {
          await api.crearUsuario(nuevos);
          avisar("ok", `Usuario ${nuevos.nombre} creado.`);
        }
        cerrarFormulario();
        await recargar();
      } catch (e) {
        mostrarErrores(form, e);
      } finally {
        guardar.disabled = false;
      }
    });

    panel.replaceChildren(form);
    panel.hidden = false;
    iNombre.focus();
  }

  await recargar();
}

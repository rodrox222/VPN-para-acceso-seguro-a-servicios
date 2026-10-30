from flask import Flask, jsonify, request, g
from werkzeug.exceptions import HTTPException
from werkzeug.security import generate_password_hash, check_password_hash
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from datetime import datetime, timezone
from threading import RLock
import re
import socket
import os
import psycopg

if os.environ.get("DATABASE_URL"):
    from repository_pg import PostgresRepository
    repo = PostgresRepository(os.environ["DATABASE_URL"])
else:
    from repository import InMemoryRepository
    repo = InMemoryRepository()

app = Flask(__name__)
from ui import ui_bp          # HU19: interfaz web en /ui/
app.register_blueprint(ui_bp)

app.json.ensure_ascii = False   # tildes legibles en las respuestas
app.json.sort_keys = False      # conservar el orden de los campos

LOCK = RLock()  # verificar + escribir debe ser atómico entre hilos de Gunicorn

PRIORIDADES = ("baja", "media", "alta")
ESTADOS = ("abierto", "en_progreso", "cerrado")
ROLES = ("cliente", "tecnico")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# =====================================================================
# HU-18: Configuración de Autenticación y Tokens
# =====================================================================
AUTH_SECRET = os.environ.get("AUTH_SECRET", "vpn-telematica-g35-secreto-compartido-2026")
AUTH_REQUIRED = os.environ.get("AUTH_REQUIRED", "true").lower() in ("true", "1")
_token_serializer = URLSafeTimedSerializer(AUTH_SECRET, salt="vpn-auth-token")


def generar_token(usuario_id):
    """Genera un token firmado criptográficamente válido por 24 horas."""
    return _token_serializer.dumps({"uid": usuario_id})


def verificar_token(token):
    """Valida la firma y vigencia del token con el secreto compartido."""
    try:
        datos = _token_serializer.loads(token, max_age=86400)
        return datos.get("uid")
    except (BadSignature, SignatureExpired, Exception):
        return None


def _sanear_usuario(usuario):
    """Elimina el password_hash antes de retornar el usuario al exterior."""
    if not usuario:
        return None
    d = dict(usuario)
    d.pop("password_hash", None)
    return d


def _sembrar_usuarios_demo():
    """Siembra los usuarios iniciales para pruebas y entorno de desarrollo."""
    semillas = [
        {"nombre": "Técnico Demo", "email": "tecnico@example.com", "rol": "tecnico", "clave": "Tecnico123!"},
        {"nombre": "Cliente Demo", "email": "cliente@example.com", "rol": "cliente", "clave": "Cliente123!"},
    ]
    for s in semillas:
        try:
            existente = repo.buscar_usuario_por_email(s["email"])
            if not existente:
                repo.crear_usuario({
                    "nombre": s["nombre"],
                    "email": s["email"],
                    "rol": s["rol"],
                    "password_hash": generate_password_hash(s["clave"]),
                })
        except Exception:
            pass


_sembrar_usuarios_demo()


# =====================================================================
# Endpoints existentes (HU-05 / HU-07): no modificar
# =====================================================================
@app.route('/', methods=['GET'])
def index():
    return jsonify({
        "service": "API REST Telematica - Grupo 35",
        "status": "online",
        "vpn_interface": "wg0 (10.0.0.1:5000)",
        "client_ip": request.remote_addr,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200


@app.route('/api/status', methods=['GET'])
def status():
    return jsonify({
        "status": "ok",
        "message": "Acceso seguro verificado a traves del tunel WireGuard",
        "hostname": socket.gethostname(),
        "server_ip": "10.0.0.1",
        "client_ip": request.remote_addr,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200


@app.route('/api/echo', methods=['GET', 'POST'])
def echo():
    payload = request.get_json(silent=True) or request.args.to_dict() or {}
    return jsonify({
        "method": request.method,
        "client_ip": request.remote_addr,
        "received_data": payload,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200


# =====================================================================
# HU-08 (DEV003): errores y validación comunes
# =====================================================================
class ApiError(Exception):
    def __init__(self, status, codigo, mensaje, detalles=None):
        super().__init__(mensaje)
        self.status = status
        self.codigo = codigo
        self.mensaje = mensaje
        self.detalles = detalles


def _error_json(status, codigo, mensaje, detalles=None):
    cuerpo = {"error": {"codigo": codigo, "mensaje": mensaje}}
    if detalles:
        cuerpo["error"]["detalles"] = detalles
    return jsonify(cuerpo), status


@app.errorhandler(ApiError)
def _manejar_api_error(e):
    return _error_json(e.status, e.codigo, e.mensaje, e.detalles)


@app.errorhandler(HTTPException)
def _manejar_http(e):
    return _error_json(e.code, e.name.lower().replace(" ", "_"), e.description)


@app.errorhandler(Exception)
def _manejar_inesperado(e):
    app.logger.exception("Error no controlado")
    return _error_json(500, "error_interno", "Error interno del servidor")


def _cuerpo_json():
    datos = request.get_json(force=True, silent=True)
    if not isinstance(datos, dict):
        raise ApiError(400, "json_invalido", "El cuerpo debe ser un objeto JSON válido")
    return datos


def _texto(minimo, maximo):
    def validar(valor):
        if not isinstance(valor, str):
            raise ValueError("debe ser texto")
        valor = valor.strip()
        if not minimo <= len(valor) <= maximo:
            raise ValueError(f"debe tener entre {minimo} y {maximo} caracteres")
        return valor
    return validar


def _email(valor):
    valor = _texto(5, 120)(valor).lower()
    if not EMAIL_RE.match(valor):
        raise ValueError("formato de email inválido")
    return valor


def _opcion(opciones):
    def validar(valor):
        if not isinstance(valor, str) or valor not in opciones:
            raise ValueError("debe ser uno de: " + ", ".join(opciones))
        return valor
    return validar


def _entero_positivo(valor):
    if isinstance(valor, bool) or not isinstance(valor, int) or valor < 1:
        raise ValueError("debe ser un entero positivo")
    return valor


def _entero_query(valor):
    try:
        numero = int(valor)
    except ValueError:
        raise ValueError("debe ser un entero positivo")
    return _entero_positivo(numero)


def _validar(datos, esquema, parcial):
    """esquema = {campo: (validador, requerido)}. Rechaza campos desconocidos."""
    errores, limpio = {}, {}
    for campo in datos:
        if campo not in esquema:
            errores[campo] = "campo no permitido"
    for campo, (validador, requerido) in esquema.items():
        if campo not in datos:
            if requerido and not parcial:
                errores[campo] = "campo obligatorio"
            continue
        try:
            limpio[campo] = validador(datos[campo])
        except ValueError as exc:
            errores[campo] = str(exc)
    if errores:
        raise ApiError(422, "validacion", "Datos inválidos", errores)
    return limpio


ESQUEMA_USUARIO = {
    "nombre": (_texto(2, 100), True),
    "email": (_email, True),
    "rol": (_opcion(ROLES), False),
    "password": (_texto(6, 128), False),
}
DEFECTO_USUARIO = {"rol": "cliente"}

ESQUEMA_TICKET = {
    "titulo": (_texto(3, 120), True),
    "descripcion": (_texto(0, 1000), False),
    "prioridad": (_opcion(PRIORIDADES), False),
    "estado": (_opcion(ESTADOS), False),
    "usuario_id": (_entero_positivo, True),
}
DEFECTO_TICKET = {"descripcion": "", "prioridad": "media", "estado": "abierto"}


def _creado(recurso, ruta):
    resp = jsonify(recurso)
    resp.status_code = 201
    resp.headers["Location"] = f"{ruta}/{recurso['id']}"
    return resp


# =====================================================================
# HU-18: Middleware de autenticación y control de roles
# =====================================================================
@app.before_request
def verificar_autenticacion():
    ruta = request.path
    # Rutas públicas
    if (
        ruta in ("/", "/api/status", "/api/auth/login")
        or ruta.startswith("/ui")
        or ruta.startswith("/__test")
        or request.method == "OPTIONS"
    ):
        return None

    if not ruta.startswith("/api/"):
        return None

    cab = request.headers.get("Authorization", "")
    token = cab[7:].strip() if cab.startswith("Bearer ") else ""
    uid = verificar_token(token) if token else None
    usuario = repo.obtener_usuario(uid) if uid else None

    if not usuario:
        # Permitir bypass solo si explícitamente se configuró AUTH_REQUIRED=false y no se envió token
        if not AUTH_REQUIRED and not cab:
            return None
        raise ApiError(401, "no_autenticado", "Debe iniciar sesión para usar este recurso.")

    g.usuario = usuario
    g.yo = usuario

    # Control de roles (RBAC) para clientes
    if usuario.get("rol") == "cliente":
        if ruta.startswith("/api/usuarios"):
            raise ApiError(403, "sin_permiso", "Su rol no permite gestionar usuarios.")
        if ruta.startswith("/api/tickets") and request.method == "DELETE":
            raise ApiError(403, "sin_permiso", "Su rol no permite eliminar tickets.")
        if ruta == "/api/tickets" and request.method == "POST":
            cuerpo = request.get_json(silent=True) or {}
            if "usuario_id" in cuerpo and cuerpo["usuario_id"] != usuario["id"]:
                raise ApiError(403, "sin_permiso", "Solo puede crear tickets a su nombre.")


# =====================================================================
# HU-18: Endpoints de Autenticación
# =====================================================================
@app.route('/api/auth/login', methods=['POST'])
def auth_login():
    d = request.get_json(silent=True) or {}
    email = str(d.get("email", "")).strip().lower()
    clave = str(d.get("password", ""))

    usuario = repo.buscar_usuario_por_email(email)
    if not usuario or not usuario.get("password_hash") or not check_password_hash(usuario["password_hash"], clave):
        raise ApiError(401, "credenciales_invalidas", "Correo o contraseña incorrectos.")

    token = generar_token(usuario["id"])
    return jsonify({
        "token": token,
        "usuario": _sanear_usuario(usuario)
    }), 200


@app.route('/api/auth/me', methods=['GET'])
def auth_me():
    usuario = getattr(g, "usuario", None)
    if not usuario:
        raise ApiError(401, "no_autenticado", "Debe iniciar sesión para usar este recurso.")
    return jsonify(_sanear_usuario(usuario)), 200


# =====================================================================
# HU-08 (DEV003): recurso USUARIOS
# =====================================================================
def _usuario_o_404(uid):
    usuario = repo.obtener_usuario(uid)
    if usuario is None:
        raise ApiError(404, "no_encontrado", f"No existe el usuario con id {uid}")
    return usuario


def _exigir_email_libre(email, excepto_id=None):
    existente = repo.buscar_usuario_por_email(email)
    if existente and existente["id"] != excepto_id:
        raise ApiError(409, "email_duplicado", "Ya existe un usuario con ese email")


@app.route('/api/usuarios', methods=['GET'])
def listar_usuarios():
    items = [_sanear_usuario(u) for u in repo.listar_usuarios()]
    return jsonify({"total": len(items), "data": items}), 200


@app.route('/api/usuarios', methods=['POST'])
def crear_usuario():
    datos = _validar(_cuerpo_json(), ESQUEMA_USUARIO, parcial=False)
    with LOCK:
        _exigir_email_libre(datos["email"])
        clave = datos.pop("password", "Usuario123!")
        datos["password_hash"] = generate_password_hash(clave)
        usuario = repo.crear_usuario({**DEFECTO_USUARIO, **datos})
    return _creado(_sanear_usuario(usuario), "/api/usuarios")


@app.route('/api/usuarios/<int:uid>', methods=['GET'])
def obtener_usuario(uid):
    return jsonify(_sanear_usuario(_usuario_o_404(uid))), 200


@app.route('/api/usuarios/<int:uid>', methods=['PUT', 'PATCH'])
def actualizar_usuario(uid):
    """PUT = reemplazo completo; PATCH = modificación parcial."""
    parcial = request.method == 'PATCH'
    with LOCK:
        _usuario_o_404(uid)
        datos = _validar(_cuerpo_json(), ESQUEMA_USUARIO, parcial)
        cambios = datos if parcial else {**DEFECTO_USUARIO, **datos}
        if "password" in cambios:
            pwd = cambios.pop("password")
            cambios["password_hash"] = generate_password_hash(pwd)
        if "email" in cambios:
            _exigir_email_libre(cambios["email"], excepto_id=uid)
        return jsonify(_sanear_usuario(repo.actualizar_usuario(uid, cambios))), 200


@app.route('/api/usuarios/<int:uid>', methods=['DELETE'])
def eliminar_usuario(uid):
    with LOCK:
        _usuario_o_404(uid)
        activos = repo.contar_tickets_activos(uid)
        if activos:
            raise ApiError(
                409, "usuario_con_tickets_activos",
                f"El usuario tiene {activos} ticket(s) sin cerrar; ciérrelos antes de eliminarlo")
        repo.eliminar_tickets_de_usuario(uid)   # solo quedan tickets cerrados (historial)
        repo.eliminar_usuario(uid)
    return "", 204


# =====================================================================
# HU-08 (DEV003): recurso TICKETS
# =====================================================================
def _ticket_o_404(tid):
    ticket = repo.obtener_ticket(tid)
    if ticket is None:
        raise ApiError(404, "no_encontrado", f"No existe el ticket con id {tid}")
    return ticket


def _exigir_usuario(uid):
    if repo.obtener_usuario(uid) is None:
        raise ApiError(422, "validacion", "Datos inválidos", {"usuario_id": "el usuario no existe"})


def _filtros_tickets(args):
    filtros, errores = {}, {}
    for campo, validador in (("estado", _opcion(ESTADOS)),
                             ("prioridad", _opcion(PRIORIDADES)),
                             ("usuario_id", _entero_query)):
        if campo in args:
            try:
                filtros[campo] = validador(args[campo])
            except ValueError as exc:
                errores[campo] = str(exc)
    if errores:
        raise ApiError(422, "validacion", "Filtros inválidos", errores)
    return filtros


@app.route('/api/tickets', methods=['GET'])
def listar_tickets():
    filtros = _filtros_tickets(request.args)
    if getattr(g, "usuario", None) and g.usuario.get("rol") == "cliente":
        # El cliente SOLO ve sus propios tickets
        filtros["usuario_id"] = g.usuario["id"]
    items = repo.listar_tickets(**filtros)
    return jsonify({"total": len(items), "data": items}), 200


@app.route('/api/tickets', methods=['POST'])
def crear_ticket():
    datos = _validar(_cuerpo_json(), ESQUEMA_TICKET, parcial=False)
    if getattr(g, "usuario", None) and g.usuario.get("rol") == "cliente":
        # Se asegura que quede asignado al cliente autenticado
        datos["usuario_id"] = g.usuario["id"]
    with LOCK:
        _exigir_usuario(datos["usuario_id"])
        ticket = repo.crear_ticket({**DEFECTO_TICKET, **datos})
    return _creado(ticket, "/api/tickets")


@app.route('/api/tickets/<int:tid>', methods=['GET'])
def obtener_ticket(tid):
    ticket = _ticket_o_404(tid)
    if getattr(g, "usuario", None) and g.usuario.get("rol") == "cliente":
        if ticket["usuario_id"] != g.usuario["id"]:
            raise ApiError(404, "no_encontrado", f"No existe el ticket con id {tid}")
    return jsonify(ticket), 200


@app.route('/api/tickets/<int:tid>', methods=['PUT', 'PATCH'])
def actualizar_ticket(tid):
    """PUT = reemplazo completo; PATCH = modificación parcial."""
    parcial = request.method == 'PATCH'
    with LOCK:
        actual = _ticket_o_404(tid)
        if getattr(g, "usuario", None) and g.usuario.get("rol") == "cliente":
            if actual["usuario_id"] != g.usuario["id"]:
                raise ApiError(404, "no_encontrado", f"No existe el ticket con id {tid}")
        if actual["estado"] == "cerrado":
            raise ApiError(409, "ticket_cerrado", "Un ticket cerrado no se puede modificar")
        datos = _validar(_cuerpo_json(), ESQUEMA_TICKET, parcial)
        cambios = datos if parcial else {**DEFECTO_TICKET, **datos}
        if getattr(g, "usuario", None) and g.usuario.get("rol") == "cliente":
            if "usuario_id" in cambios and cambios["usuario_id"] != g.usuario["id"]:
                raise ApiError(403, "sin_permiso", "No puede reasignar el ticket a otro usuario")
        elif "usuario_id" in cambios:
            _exigir_usuario(cambios["usuario_id"])
        return jsonify(repo.actualizar_ticket(tid, cambios)), 200


@app.route('/api/tickets/<int:tid>', methods=['DELETE'])
def eliminar_ticket(tid):
    with LOCK:
        _ticket_o_404(tid)
        repo.eliminar_ticket(tid)
    return "", 204


# --- Errores de Base de Datos PostgreSQL
@app.errorhandler(psycopg.errors.UniqueViolation)
def _unico(e):
    return jsonify({"error": "email_duplicado", "mensaje": "Ya existe un usuario con ese email"}), 409


@app.errorhandler(psycopg.errors.ForeignKeyViolation)
def _fk_violation(e):
    from flask import request
    if request.method == 'DELETE':
        return jsonify({"error": "conflicto", "mensaje": "El usuario tiene tickets asociados"}), 409
    return jsonify({"error": "validacion", "mensaje": "El usuario_id no existe"}), 422


if __name__ == '__main__':
    app.run(host='10.0.0.1', port=5000)

#!/usr/bin/env python3
"""SIMULADOR DE LA HU18 — SOLO PARA DESARROLLO Y PRUEBAS DE LA INTERFAZ (HU19).

NO es seguridad real: contraseñas en claro y tokens en memoria, sin expiración ni cifrado.
Nunca se despliega ni se sube a un servidor. Sirve para probar la interfaz con login y roles
mientras la HU18 se termina, siguiendo el contrato PROPUESTO (docs/DEV008, sección 3):

  POST /api/auth/login   {"email", "password"}  ->  200 {"token", "usuario": {id, nombre, email, rol}}
                                                    401 {"error": {"codigo": "credenciales_invalidas", ...}}
  GET  /api/auth/me      (con token)            ->  200 {id, nombre, email, rol}
  Cabecera:  Authorization: Bearer <token>   en todas las rutas /api/* excepto /api/status y el login
  Sin token o token inválido -> 401 "no_autenticado";  rol sin permiso -> 403 "sin_permiso"

Reglas simuladas:
  tecnico  -> todo
  cliente  -> no puede usar /api/usuarios*, no puede borrar tickets y solo crea tickets a su nombre
              (el listado de tickets NO se filtra en el simulador; la HU18 real debería hacerlo)

Uso:  python tools/mock_hu18.py [--puerto 5000] [--host 127.0.0.1] [--pruebas]
Cuentas:  tecnico@example.com / Tecnico123!     cliente@example.com / Cliente123!
"""
import argparse
import os
import secrets
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "api")))

import app as app_module  # noqa: E402  (la API real, con su repositorio en memoria)
from flask import g, jsonify, request  # noqa: E402

app = app_module.app
repo = app_module.repo

CUENTAS = {
    "tecnico@example.com": {"clave": "Tecnico123!", "nombre": "Técnico Demo", "rol": "tecnico"},
    "cliente@example.com": {"clave": "Cliente123!", "nombre": "Cliente Demo", "rol": "cliente"},
}
TOKENS = {}   # token -> id de usuario
HABILITAR_PRUEBAS = False


def _publico(u):
    return {"id": u["id"], "nombre": u["nombre"], "email": u["email"], "rol": u["rol"]}


def _sembrar():
    for email, c in CUENTAS.items():
        u = repo.buscar_usuario_por_email(email) or repo.crear_usuario({"nombre": c["nombre"], "email": email, "rol": c["rol"]})
        c["id"] = u["id"]


def _error(status, codigo, mensaje):
    return jsonify({"error": {"codigo": codigo, "mensaje": mensaje}}), status


@app.before_request
def exigir_autenticacion():
    ruta = request.path
    if ruta in ("/", "/api/status", "/api/auth/login") or ruta.startswith("/ui") or ruta.startswith("/__test"):
        return None
    if not ruta.startswith("/api/"):
        return None
    cab = request.headers.get("Authorization", "")
    token = cab[7:] if cab.startswith("Bearer ") else ""
    uid = TOKENS.get(token)
    yo = repo.obtener_usuario(uid) if uid else None
    if not yo:
        return _error(401, "no_autenticado", "Debe iniciar sesión para usar este recurso.")
    g.yo = yo
    if yo["rol"] == "cliente":
        if ruta.startswith("/api/usuarios"):
            return _error(403, "sin_permiso", "Su rol no permite gestionar usuarios.")
        if ruta.startswith("/api/tickets") and request.method == "DELETE":
            return _error(403, "sin_permiso", "Su rol no permite eliminar tickets.")
        if ruta == "/api/tickets" and request.method == "POST":
            cuerpo = request.get_json(silent=True) or {}
            if cuerpo.get("usuario_id") != yo["id"]:
                return _error(403, "sin_permiso", "Solo puede crear tickets a su nombre.")
    return None


@app.post("/api/auth/login")
def login():
    d = request.get_json(silent=True) or {}
    c = CUENTAS.get(str(d.get("email", "")).strip().lower())
    if not c or c["clave"] != d.get("password"):
        return _error(401, "credenciales_invalidas", "Correo o contraseña incorrectos.")
    token = secrets.token_urlsafe(24)
    TOKENS[token] = c["id"]
    return jsonify({"token": token, "usuario": _publico(repo.obtener_usuario(c["id"]))})


@app.get("/api/auth/me")
def me():
    return jsonify(_publico(g.yo))


@app.post("/__test/revocar")
def revocar_tokens():
    if not HABILITAR_PRUEBAS:
        return _error(404, "no_encontrado", "No existe.")
    TOKENS.clear()
    return jsonify({"revocados": True})


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--puerto", type=int, default=5000)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--pruebas", action="store_true", help="habilita /__test/revocar (solo para las pruebas automáticas)")
    a = ap.parse_args()
    HABILITAR_PRUEBAS = a.pruebas
    _sembrar()
    print(f"[SIMULADOR HU18] http://{a.host}:{a.puerto}/ui/   (solo desarrollo)")
    for email, c in CUENTAS.items():
        print(f"   {c['rol']:8s} {email} / {c['clave']}")
    app.run(host=a.host, port=a.puerto, threaded=True)

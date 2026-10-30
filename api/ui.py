"""Interfaz web (HU19 / DEV008): sirve los archivos de api/static/ bajo /ui/.

Se mantiene en un módulo aparte para no tocar app.py más que con dos líneas
(import y register_blueprint) y evitar conflictos con la HU18 (autenticación).
Las cabeceras de seguridad hacen que el navegador solo ejecute código del propio
servicio: no se carga nada de Internet ni se admite JavaScript en línea.
"""
import os

from flask import Blueprint, send_from_directory

_STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

ui_bp = Blueprint("ui", __name__, url_prefix="/ui")

CSP = (
    "default-src 'none'; "
    "script-src 'self'; "
    "style-src 'self'; "
    "img-src 'self' data:; "
    "connect-src 'self'; "
    "base-uri 'none'; "
    "form-action 'self'; "
    "frame-ancestors 'none'"
)


@ui_bp.get("/")
def index():
    return send_from_directory(_STATIC, "index.html")


@ui_bp.get("/<path:ruta>")
def archivo(ruta):
    # send_from_directory rechaza rutas que salgan de la carpeta (404)
    return send_from_directory(_STATIC, ruta)


@ui_bp.after_request
def cabeceras_de_seguridad(resp):
    resp.headers["Content-Security-Policy"] = CSP
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Cache-Control"] = "no-cache"
    return resp

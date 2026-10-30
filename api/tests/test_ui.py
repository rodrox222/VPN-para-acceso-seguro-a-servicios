"""Pruebas de la interfaz web (HU19 / DEV008): servidor de archivos y cabeceras de seguridad."""
import pathlib
import re

import pytest

import app as app_module

STATIC = pathlib.Path(app_module.__file__).parent / "static"


@pytest.fixture()
def client():
    app_module.app.config["TESTING"] = False
    app_module.repo.reset()
    return app_module.app.test_client()


def test_interfaz_se_sirve_en_ui(client):
    r = client.get("/ui/")
    assert r.status_code == 200 and "text/html" in r.content_type
    assert b"<title>" in r.data


def test_cabeceras_de_seguridad(client):
    r = client.get("/ui/")
    csp = r.headers["Content-Security-Policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'self'" in csp
    assert "frame-ancestors 'none'" in csp
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Referrer-Policy"] == "no-referrer"


def test_todos_los_recursos_enlazados_existen(client):
    html = client.get("/ui/").get_data(as_text=True)
    rutas = re.findall(r'(?:src|href)="(/ui/[^"]+)"', html)
    assert rutas, "index.html debería enlazar CSS y JS"
    for ruta in rutas:
        assert client.get(ruta).status_code == 200, ruta


def test_importaciones_entre_modulos_js_existen():
    for js in (STATIC / "js").glob("*.js"):
        for rel in re.findall(r'from\s+"\./([^"]+)"', js.read_text(encoding="utf-8")):
            assert (STATIC / "js" / rel).exists(), f"{js.name} importa {rel}, que no existe"


def test_html_compatible_con_csp_sin_codigo_en_linea():
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert not re.search(r"<script(?![^>]*\bsrc=)[^>]*>", html), "script en línea"
    assert not re.search(r"\son\w+\s*=", html), "manejador de evento en línea"
    assert 'style="' not in html, "estilo en línea"
    assert "http://" not in html and "https://" not in html, "recurso externo"


def _sin_comentarios(codigo):
    codigo = re.sub(r"/\*.*?\*/", "", codigo, flags=re.S)
    return re.sub(r"//[^\n]*", "", codigo)


def test_js_no_usa_innerhtml_ni_eval():
    for js in (STATIC / "js").glob("*.js"):
        codigo = _sin_comentarios(js.read_text(encoding="utf-8"))   # los comentarios pueden mencionarlo
        assert "innerHTML" not in codigo, f"{js.name} usa innerHTML"
        assert "outerHTML" not in codigo and "insertAdjacentHTML" not in codigo and "document.write" not in codigo
        assert not re.search(r"\beval\s*\(|new Function\s*\(", codigo), f"{js.name} evalúa código"


@pytest.mark.parametrize("ruta", ["/ui/../app.py", "/ui/%2e%2e/app.py", "/ui/..%2fapp.py", "/ui/js/../../app.py"])
def test_no_se_sale_de_la_carpeta_static(client, ruta):
    r = client.get(ruta)
    assert b"from flask" not in r.data and b"register_blueprint" not in r.data


def test_archivo_inexistente_devuelve_json_404(client):
    r = client.get("/ui/js/nada.js")
    assert r.status_code == 404 and "error" in r.get_json()


def test_solo_get_en_la_interfaz(client):
    assert client.post("/ui/").status_code == 405
    assert client.delete("/ui/js/main.js").status_code == 405


def test_la_api_existente_no_cambia(client):
    r = client.get("/")
    assert r.status_code == 200 and r.get_json()["status"] == "online"
    assert client.get("/api/status").get_json()["status"] == "ok"
    assert client.get("/api/usuarios").get_json()["total"] == 0

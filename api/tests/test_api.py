import pytest

import app as app_module


@pytest.fixture()
def client():
    app_module.app.config["TESTING"] = False  # probar el manejo real de errores
    app_module.repo.reset()
    return app_module.app.test_client()


def nuevo_usuario(client, nombre="Ana Pérez", email="ana@example.com", **extra):
    return client.post("/api/usuarios", json={"nombre": nombre, "email": email, **extra})


def nuevo_ticket(client, usuario_id, titulo="VPN no conecta", **extra):
    return client.post("/api/tickets", json={"titulo": titulo, "usuario_id": usuario_id, **extra})


# ------------------------------------------------- endpoints existentes
def test_endpoints_existentes_siguen_funcionando(client):
    assert client.get("/").status_code == 200
    assert client.get("/api/status").get_json()["status"] == "ok"
    assert client.post("/api/echo", json={"a": 1}).get_json()["received_data"] == {"a": 1}


# ---------------------------------------------------------- usuarios CRUD
def test_usuarios_crud_completo(client):
    r = nuevo_usuario(client)
    assert r.status_code == 201
    assert r.headers["Location"] == "/api/usuarios/1"
    u = r.get_json()
    assert u["rol"] == "cliente" and u["id"] == 1

    assert client.get("/api/usuarios").get_json()["total"] == 1
    assert client.get("/api/usuarios/1").status_code == 200

    r = client.put("/api/usuarios/1", json={"nombre": "Ana Gómez", "email": "ana@example.com", "rol": "tecnico"})
    assert r.status_code == 200 and r.get_json()["rol"] == "tecnico"

    r = client.patch("/api/usuarios/1", json={"nombre": "Ana G."})
    assert r.get_json()["nombre"] == "Ana G." and r.get_json()["rol"] == "tecnico"

    assert client.delete("/api/usuarios/1").status_code == 204
    assert client.get("/api/usuarios/1").status_code == 404


def test_put_resetea_campos_opcionales_y_exige_obligatorios(client):
    nuevo_usuario(client, rol="tecnico")
    r = client.put("/api/usuarios/1", json={"nombre": "Ana Pérez", "email": "ana@example.com"})
    assert r.get_json()["rol"] == "cliente"
    r = client.put("/api/usuarios/1", json={"nombre": "Ana Pérez"})
    assert r.status_code == 422 and "email" in r.get_json()["error"]["detalles"]


def test_email_duplicado_409_insensible_a_mayusculas(client):
    nuevo_usuario(client)
    r = nuevo_usuario(client, nombre="Otra Ana", email="ANA@Example.com")
    assert r.status_code == 409
    assert r.get_json()["error"]["codigo"] == "email_duplicado"


def test_email_propio_no_cuenta_como_duplicado_al_actualizar(client):
    nuevo_usuario(client)
    r = client.put("/api/usuarios/1", json={"nombre": "Ana P.", "email": "ana@example.com"})
    assert r.status_code == 200


def test_usuario_validaciones_422(client):
    r = client.post("/api/usuarios", json={"nombre": "A", "email": "no-es-email", "rol": "jefe", "x": 1})
    assert r.status_code == 422
    detalles = r.get_json()["error"]["detalles"]
    assert set(detalles) == {"nombre", "email", "rol", "x"}


def test_json_invalido_400(client):
    r = client.post("/api/usuarios", data="esto no es json", content_type="application/json")
    assert r.status_code == 400
    assert r.get_json()["error"]["codigo"] == "json_invalido"
    r = client.post("/api/usuarios", json=[1, 2, 3])
    assert r.status_code == 400


def test_404_y_405_en_json(client):
    r = client.get("/api/no-existe")
    assert r.status_code == 404 and "error" in r.get_json()
    r = client.delete("/api/usuarios")
    assert r.status_code == 405 and "error" in r.get_json()
    assert client.get("/api/usuarios/999").status_code == 404
    assert client.get("/api/usuarios/abc").status_code == 404


# ----------------------------------------------------------- tickets CRUD
def test_tickets_crud_completo(client):
    nuevo_usuario(client)
    r = nuevo_ticket(client, 1, descripcion="Sin handshake")
    assert r.status_code == 201
    t = r.get_json()
    assert t["estado"] == "abierto" and t["prioridad"] == "media" and t["usuario_id"] == 1

    assert client.get("/api/tickets/1").status_code == 200
    r = client.put("/api/tickets/1", json={"titulo": "VPN sin handshake", "usuario_id": 1, "prioridad": "alta"})
    assert r.get_json()["prioridad"] == "alta"
    r = client.patch("/api/tickets/1", json={"estado": "en_progreso"})
    assert r.get_json()["estado"] == "en_progreso"

    assert client.delete("/api/tickets/1").status_code == 204
    assert client.get("/api/tickets/1").status_code == 404


def test_ticket_con_usuario_inexistente_422(client):
    r = nuevo_ticket(client, 99)
    assert r.status_code == 422
    assert "usuario_id" in r.get_json()["error"]["detalles"]


def test_ticket_validaciones_422(client):
    nuevo_usuario(client)
    r = client.post("/api/tickets", json={"titulo": "ab", "usuario_id": "1", "estado": "x", "prioridad": "ya"})
    assert r.status_code == 422
    assert set(r.get_json()["error"]["detalles"]) == {"titulo", "usuario_id", "estado", "prioridad"}
    assert client.post("/api/tickets", json={"titulo": "Válido", "usuario_id": True}).status_code == 422


def test_ticket_cerrado_no_se_modifica(client):
    nuevo_usuario(client)
    nuevo_ticket(client, 1)
    client.patch("/api/tickets/1", json={"estado": "cerrado"})
    r = client.patch("/api/tickets/1", json={"titulo": "Nuevo título"})
    assert r.status_code == 409
    assert r.get_json()["error"]["codigo"] == "ticket_cerrado"
    assert client.put("/api/tickets/1", json={"titulo": "Otro", "usuario_id": 1}).status_code == 409


def test_cambiar_ticket_a_usuario_inexistente_422(client):
    nuevo_usuario(client)
    nuevo_ticket(client, 1)
    assert client.patch("/api/tickets/1", json={"usuario_id": 50}).status_code == 422


def test_filtros_de_tickets(client):
    nuevo_usuario(client)
    nuevo_usuario(client, nombre="Beto Ruiz", email="beto@example.com")
    nuevo_ticket(client, 1, prioridad="alta")
    nuevo_ticket(client, 1, titulo="Lento", prioridad="baja")
    nuevo_ticket(client, 2, titulo="Sin acceso", prioridad="alta")
    client.patch("/api/tickets/3", json={"estado": "en_progreso"})

    assert client.get("/api/tickets").get_json()["total"] == 3
    assert client.get("/api/tickets?prioridad=alta").get_json()["total"] == 2
    assert client.get("/api/tickets?usuario_id=1").get_json()["total"] == 2
    assert client.get("/api/tickets?estado=en_progreso&prioridad=alta").get_json()["total"] == 1
    assert client.get("/api/tickets?estado=raro").status_code == 422
    assert client.get("/api/tickets?usuario_id=abc").status_code == 422


# ------------------------------------------------------- reglas cruzadas
def test_no_se_elimina_usuario_con_tickets_activos(client):
    nuevo_usuario(client)
    nuevo_ticket(client, 1)
    r = client.delete("/api/usuarios/1")
    assert r.status_code == 409
    assert r.get_json()["error"]["codigo"] == "usuario_con_tickets_activos"

    client.patch("/api/tickets/1", json={"estado": "en_progreso"})
    assert client.delete("/api/usuarios/1").status_code == 409

    client.patch("/api/tickets/1", json={"estado": "cerrado"})
    assert client.delete("/api/usuarios/1").status_code == 204
    assert client.get("/api/tickets").get_json()["total"] == 0  # historial eliminado en cascada

def test_persistencia_postresql():
    """Prueba requerida en HU09: El dato sobrevive a la destrucción del repositorio"""
    import os
    if not os.environ.get("DATABASE_URL"):
        import pytest
        pytest.skip("Se requiere DATABASE_URL para probar persistencia real")
    
    from repository_pg import PostgresRepository
    
    repo1 = PostgresRepository(os.environ["DATABASE_URL"])
    repo1.reset()
    creado = repo1.crear_usuario({"nombre": "Prueba", "email": "test@db.com", "rol": "cliente"})
    
    repo2 = PostgresRepository(os.environ["DATABASE_URL"])
    recuperado = repo2.buscar_usuario_por_email("test@db.com")
    
    assert recuperado is not None
    assert recuperado["id"] == creado["id"]

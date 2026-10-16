# DEV004 (HU09) — Guía de implementación: base de datos PostgreSQL

**Para:** quien implemente la HU09.
**Requerimiento (backlog):** integrar una base de datos persistente (PostgreSQL) para soportar las operaciones de negocio de la API.
**Sprint:** 2 · **Prioridad:** 9 · **Esfuerzo estimado:** 7
**Antes de empezar:** tener HU08 (DEV003) fusionada en `main`. Esta HU **no cambia los endpoints**: solo cambia de dónde salen los datos.

## 1. Punto de partida

La API (carpeta `api/`) ya expone el CRUD de **usuarios** y **tickets**, pero guarda todo en memoria: al reiniciar el contenedor se pierde.

```
api/
├── app.py            # endpoints, validaciones y reglas de negocio
├── repository.py     # InMemoryRepository  ← lo que hay que reemplazar por PostgreSQL
├── Dockerfile        # gunicorn -w 1 --threads 4
├── requirements.txt  # Flask, gunicorn
└── tests/test_api.py # 15 pruebas
docker-compose.yml    # solo servicio api-rest (puerto 10.0.0.1:5000, red br-vpnapi)
.env.example
```

**Idea central:** `app.py` nunca toca datos directamente; solo llama a métodos de un objeto `repo`. Se crea `repository_pg.py` con **los mismos métodos** y `app.py` elige cuál usar según una variable de entorno. La versión en memoria se conserva para que `pytest` siga funcionando sin base de datos.

## 2. Arquitectura objetivo

```
Peer VPN ──► 10.0.0.1:5000 ──► [api-rest] ──► [db: PostgreSQL]
                                                  └── volumen pgdata (persistente)
```

- La base de datos **no publica ningún puerto** (sin `ports:`): solo la API la alcanza, por la red interna `br-vpnapi`, usando el nombre de servicio `db`.
- Los datos viven en un **volumen nombrado** (`pgdata`), no dentro del contenedor.

## 3. Tablas a crear

Crear `db/init.sql` (PostgreSQL lo ejecuta solo la **primera vez**, cuando el volumen está vacío). Refleja exactamente el modelo y las validaciones que ya aplica la API.

```sql
-- db/init.sql
CREATE TABLE usuarios (
    id             SERIAL PRIMARY KEY,
    nombre         VARCHAR(100) NOT NULL CHECK (char_length(nombre) BETWEEN 2 AND 100),
    email          VARCHAR(120) NOT NULL,
    rol            TEXT NOT NULL DEFAULT 'cliente' CHECK (rol IN ('cliente', 'tecnico')),
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Email único sin distinguir mayúsculas (la API ya lo guarda en minúsculas)
CREATE UNIQUE INDEX usuarios_email_unico ON usuarios (lower(email));

CREATE TABLE tickets (
    id             SERIAL PRIMARY KEY,
    titulo         VARCHAR(120) NOT NULL CHECK (char_length(titulo) BETWEEN 3 AND 120),
    descripcion    VARCHAR(1000) NOT NULL DEFAULT '',
    prioridad      TEXT NOT NULL DEFAULT 'media'  CHECK (prioridad IN ('baja', 'media', 'alta')),
    estado         TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto', 'en_progreso', 'cerrado')),
    usuario_id     INTEGER NOT NULL REFERENCES usuarios (id) ON DELETE RESTRICT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX tickets_usuario_idx ON tickets (usuario_id);
CREATE INDEX tickets_estado_idx  ON tickets (estado);
```

### Relación entre tablas

```
usuarios (1) ────────< (N) tickets
   id  ◄────────────────  usuario_id   (FK, ON DELETE RESTRICT)
```

### Equivalencia con las reglas de negocio de HU08

| Regla de la API | Respaldo en la base de datos |
|---|---|
| Email único (409 `email_duplicado`) | Índice único `usuarios_email_unico` |
| Ticket debe tener usuario existente (422) | Clave foránea `usuario_id` |
| `rol`, `prioridad`, `estado` solo valores definidos | Restricciones `CHECK` |
| Longitudes de nombre, título y descripción | `CHECK` / `VARCHAR` |
| No borrar usuario con tickets activos (409) | Lógica de la API (consulta + borrado en transacción) |
| Ticket cerrado no se modifica (409) | Lógica de la API |

> La API **sigue validando** antes de escribir (da mejores mensajes de error). La base de datos es la red de seguridad si algo se salta esas comprobaciones.

## 4. Contrato que debe cumplir `repository_pg.py`

La clase `PostgresRepository` debe tener **exactamente estos métodos**, con estos retornos (son los que `app.py` usa hoy):

| Método | Devuelve |
|---|---|
| `listar_usuarios()` | lista de dicts |
| `obtener_usuario(uid)` | dict o `None` |
| `buscar_usuario_por_email(email)` | dict o `None` |
| `crear_usuario(datos)` | dict del usuario creado |
| `actualizar_usuario(uid, cambios)` | dict actualizado |
| `eliminar_usuario(uid)` | `True` si existía |
| `listar_tickets(estado=None, prioridad=None, usuario_id=None)` | lista de dicts (filtros opcionales y combinables) |
| `obtener_ticket(tid)` | dict o `None` |
| `crear_ticket(datos)` | dict del ticket creado |
| `actualizar_ticket(tid, cambios)` | dict actualizado |
| `eliminar_ticket(tid)` | `True` si existía |
| `contar_tickets_activos(usuario_id)` | entero (tickets `abierto` o `en_progreso`) |
| `eliminar_tickets_de_usuario(usuario_id)` | entero (cuántos borró) |
| `reset()` | vacía las tablas (solo para pruebas) |

**Formato de los dicts** (idéntico al actual, para no romper nada):

- usuario: `id, nombre, email, rol, creado_en, actualizado_en`
- ticket: `id, titulo, descripcion, prioridad, estado, usuario_id, creado_en, actualizado_en`
- `creado_en` y `actualizado_en` deben salir como **texto ISO 8601 en UTC** (ej. `2026-10-15T22:17:18.478079+00:00`). El driver devuelve objetos `datetime`; hay que convertirlos con `.isoformat()`, o `jsonify` los serializará con otro formato.
- `actualizar_*` debe actualizar también `actualizado_en = now()`.

## 5. Pasos

### 5.1 Dependencias

`api/requirements.txt`: agregar el driver y el pool de conexiones.

```
Flask==3.0.3
gunicorn==22.0.0
psycopg[binary]==3.2.3
psycopg-pool==3.2.3
```

### 5.2 `api/repository_pg.py` (esqueleto de referencia)

Patrón a seguir; completar los métodos restantes de la tabla de la sección 4.

```python
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

COLS_USUARIO = ("nombre", "email", "rol")
COLS_TICKET = ("titulo", "descripcion", "prioridad", "estado", "usuario_id")


def _fila(row):
    """Convierte las fechas a ISO 8601, como hace el repositorio en memoria."""
    if row is None:
        return None
    for campo in ("creado_en", "actualizado_en"):
        row[campo] = row[campo].isoformat()
    return row


def _set(cambios, permitidas):
    # Solo columnas de la lista blanca: nunca construir SQL con texto del cliente.
    cols = [c for c in cambios if c in permitidas]
    return ", ".join(f"{c} = %({c})s" for c in cols)


class PostgresRepository:
    def __init__(self, dsn):
        self._pool = ConnectionPool(
            dsn, min_size=1, max_size=5, open=True,
            kwargs={"row_factory": dict_row},
        )

    def crear_usuario(self, datos):
        with self._pool.connection() as conn:   # commit automático al salir
            row = conn.execute(
                "INSERT INTO usuarios (nombre, email, rol) "
                "VALUES (%(nombre)s, %(email)s, %(rol)s) RETURNING *",
                datos,
            ).fetchone()
        return _fila(row)

    def obtener_usuario(self, uid):
        with self._pool.connection() as conn:
            row = conn.execute("SELECT * FROM usuarios WHERE id = %s", (uid,)).fetchone()
        return _fila(row)

    def actualizar_usuario(self, uid, cambios):
        sets = _set(cambios, COLS_USUARIO)
        with self._pool.connection() as conn:
            row = conn.execute(
                f"UPDATE usuarios SET {sets}, actualizado_en = now() "
                "WHERE id = %(id)s RETURNING *",
                {**cambios, "id": uid},
            ).fetchone()
        return _fila(row)

    def eliminar_usuario(self, uid):
        with self._pool.connection() as conn:
            return conn.execute("DELETE FROM usuarios WHERE id = %s", (uid,)).rowcount > 0

    def listar_tickets(self, estado=None, prioridad=None, usuario_id=None):
        condiciones, params = [], {}
        for campo, valor in (("estado", estado), ("prioridad", prioridad), ("usuario_id", usuario_id)):
            if valor is not None:
                condiciones.append(f"{campo} = %({campo})s")
                params[campo] = valor
        where = ("WHERE " + " AND ".join(condiciones)) if condiciones else ""
        with self._pool.connection() as conn:
            rows = conn.execute(f"SELECT * FROM tickets {where} ORDER BY id", params).fetchall()
        return [_fila(r) for r in rows]

    def contar_tickets_activos(self, usuario_id):
        with self._pool.connection() as conn:
            return conn.execute(
                "SELECT count(*) AS n FROM tickets "
                "WHERE usuario_id = %s AND estado IN ('abierto', 'en_progreso')",
                (usuario_id,),
            ).fetchone()["n"]

    def reset(self):
        with self._pool.connection() as conn:
            conn.execute("TRUNCATE tickets, usuarios RESTART IDENTITY")

    # ... completar: listar_usuarios, buscar_usuario_por_email, crear_ticket,
    #     obtener_ticket, actualizar_ticket, eliminar_ticket, eliminar_tickets_de_usuario
```

Notas:

- `listar_*` debe ordenar por `id` para que las respuestas sean estables.
- `buscar_usuario_por_email`: comparar con `lower(email) = lower(%s)`.
- Si una consulta `UPDATE ... RETURNING` no devuelve fila, el recurso no existe: `app.py` ya comprueba la existencia antes de llamar, así que no debería ocurrir.

### 5.3 Elegir el repositorio en `api/app.py`

Reemplazar estas dos líneas:

```python
from repository import InMemoryRepository
...
repo = InMemoryRepository()
```

por:

```python
import os

if os.environ.get("DATABASE_URL"):
    from repository_pg import PostgresRepository
    repo = PostgresRepository(os.environ["DATABASE_URL"])
else:
    from repository import InMemoryRepository   # pruebas locales sin base de datos
    repo = InMemoryRepository()
```

Con esto no se toca ningún endpoint.

### 5.4 `api/Dockerfile`

Copiar el nuevo archivo:

```dockerfile
COPY app.py repository.py repository_pg.py ./
```

Mantener `gunicorn -w 1 --threads 4` (ver sección 8).

### 5.5 `docker-compose.yml`

Agregar el servicio `db`, el volumen, y hacer que la API espere a que la base esté sana:

```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: api-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-helpdesk}
      POSTGRES_USER: ${POSTGRES_USER:-helpdesk}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Defina POSTGRES_PASSWORD en el archivo .env}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    networks:
      - vpn_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    # SIN "ports:": la base de datos no se publica en ningún host ni interfaz.

  api-rest:
    # ... (lo que ya existe) ...
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER:-helpdesk}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB:-helpdesk}

volumes:
  pgdata:
```

> **No copiar el endurecimiento de la API al servicio `db`** (`read_only`, `cap_drop: ALL`): PostgreSQL necesita escribir y cambiar permisos en su carpeta de datos y no arrancaría. Si quieren endurecerlo, probarlo aparte.

### 5.6 Credenciales (importante)

- **`.env.example`** (se sube a Git): agregar solo **valores de ejemplo**.
  ```
  POSTGRES_DB=helpdesk
  POSTGRES_USER=helpdesk
  POSTGRES_PASSWORD=cambiar-esta-clave
  ```
- **`.env`** (real, **no se sube**): cada integrante lo crea con `cp .env.example .env` y pone su propia contraseña. El `.gitignore` del repo ya bloquea `.env`; comprobarlo con `git status` antes del commit.
- Si una contraseña real llega a Git por error, **cambiarla**: borrarla del último commit no basta, queda en el historial.

### 5.7 Traducir errores de la base de datos

La API valida antes de escribir, pero si dos peticiones coinciden en el tiempo, la base de datos es la última barrera. Capturar en `app.py` (o convertir dentro del repositorio):

| Error de psycopg | Respuesta HTTP |
|---|---|
| `psycopg.errors.UniqueViolation` | 409 `email_duplicado` |
| `psycopg.errors.ForeignKeyViolation` | 422 `validacion` (`usuario_id`), o 409 si ocurre al borrar un usuario |

Ejemplo de manejador en `app.py`:

```python
import psycopg

@app.errorhandler(psycopg.errors.UniqueViolation)
def _unico(e):
    return _error_json(409, "email_duplicado", "Ya existe un usuario con ese email")
```

### 5.8 Borrado de usuario en una transacción

El borrado actual hace dos pasos (borrar tickets cerrados, borrar usuario). Con base de datos conviene que sea **atómico**: o se hace todo o nada. Para evitar que entre un ticket nuevo mientras se borra, bloquear la fila del usuario al inicio de la transacción:

```sql
SELECT id FROM usuarios WHERE id = %s FOR UPDATE;
```

La creación de un ticket nuevo para ese usuario esperará a que termine el borrado, y la clave foránea impedirá dejar tickets huérfanos.

## 6. Pruebas

1. **Sin base de datos** (no definir `DATABASE_URL`): `pytest` debe seguir dando `15 passed`.
2. **Contra PostgreSQL:** las mismas 15 pruebas deben pasar usando la base real. Como el fixture hace `repo.reset()` (vacía las tablas), **nunca apuntarlas a la base de datos de trabajo**. Usar una base desechable:

   ```bash
   docker run -d --name pg-test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test \
     -p 127.0.0.1:55432:5432 \
     -v "$PWD/db/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro" \
     postgres:16-alpine

   cd api
   source .venv/bin/activate
   pip install -r requirements-dev.txt
   DATABASE_URL=postgresql://postgres:test@127.0.0.1:55432/test pytest

   docker rm -f pg-test
   ```

3. Agregar al menos una prueba de **persistencia**: crear un usuario con un repositorio, crear una instancia nueva de `PostgresRepository` y comprobar que el dato sigue ahí.

## 7. Validación en el entorno real

Desde la raíz del repositorio:

```bash
cp .env.example .env        # editar y poner una contraseña propia
docker compose up -d --build
docker compose ps           # db y api-rest deben aparecer como "healthy"
```

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | `docker compose ps` | `db` y `api-rest` healthy |
| 2 | CRUD completo desde un peer por la VPN (mismos comandos de DEV003) | Mismo comportamiento que antes |
| 3 | Crear datos y `docker compose restart api-rest` | Los datos siguen ahí |
| 4 | `docker compose down` y luego `docker compose up -d` (**sin** `-v`) | Los datos siguen ahí |
| 5 | `docker compose down -v` y levantar de nuevo | Datos vacíos (el volumen se borró) |
| 6 | Reglas 409 y 422 de DEV003 | Siguen funcionando |
| 7 | `nc -zv 10.0.0.1 5432` desde un peer, y `ss -tlnp \| grep 5432` en el host | Puerto cerrado: la base de datos no es accesible desde fuera |
| 8 | `docker compose exec db psql -U helpdesk -d helpdesk -c "\dt"` | Aparecen `usuarios` y `tickets` |

## 8. Cosas a tener en cuenta

1. **`docker compose restart` ya no vacía los datos.** Para empezar de cero ahora se usa `docker compose down -v`.
2. **`init.sql` solo corre con el volumen vacío.** Si cambia el esquema, hay que borrar el volumen (`down -v`) o escribir una migración.
3. **Mantener `gunicorn -w 1`.** El candado `LOCK` de `app.py` solo protege dentro de un proceso. Subir los workers exige apoyarse solo en transacciones y restricciones de la base de datos, y repetir las pruebas.
4. **La base de datos no se publica.** Para inspeccionarla usar `docker compose exec db psql ...`, no abrir el puerto 5432.
5. **Zona horaria:** las fechas se guardan en `TIMESTAMPTZ` y se devuelven en UTC.
6. **Contraseña:** nunca en el código, en el `docker-compose.yml` ni en capturas de pantalla.

## 9. Tareas (Taiga)

| # | Tarea |
|---|---|
| 1 | Diseñar el esquema y escribir `db/init.sql` |
| 2 | Agregar el servicio `db` al compose (volumen, healthcheck, sin puertos) |
| 3 | Gestionar credenciales con `.env` y `.env.example` |
| 4 | Implementar `repository_pg.py` con el contrato de la sección 4 |
| 5 | Traducir errores de la base de datos a 409/422 y borrado en transacción |
| 6 | Seleccionar el repositorio por `DATABASE_URL` en `app.py` |
| 7 | Actualizar `requirements.txt` y `Dockerfile` |
| 8 | Pruebas: 15 sin base de datos, 15 contra PostgreSQL y una de persistencia |
| 9 | Validar persistencia (restart, down/up) y aislamiento del puerto 5432 |
| 10 | Evidencias, `docs/DEV004-postgresql.md` y README |
| 11 | Rama, commit, push y Pull Request |

## 10. Evidencias para `evidencias/DEV004/`

| Archivo | Contenido |
|---|---|
| `01-pytest-memoria.png` | `pytest` sin base de datos (15 passed) |
| `02-pytest-postgres.png` | `pytest` con `DATABASE_URL` (15 passed) |
| `03-compose-healthy.png` | `docker compose ps` con `db` y `api-rest` healthy |
| `04-tablas.png` | `\dt` y `\d tickets` en psql (muestra la FK y los CHECK) |
| `05-crud-vpn.png` | CRUD desde un peer por la VPN |
| `06-persistencia.png` | Datos antes y después de `restart` y de `down`/`up` |
| `07-down-v.png` | Datos vacíos tras `down -v` |
| `08-puerto-5432.png` | Puerto 5432 no accesible desde fuera |

> ⚠ En las capturas no debe verse la contraseña (cuidado con `.env` y con `docker compose config`, que la imprime).

## 11. Criterio de aceptación (HU09)

- [ ] Tablas `usuarios` y `tickets` creadas con claves, índices y restricciones.
- [ ] La API usa PostgreSQL sin cambios en los endpoints.
- [ ] Los datos persisten tras reiniciar el contenedor y tras `down`/`up`.
- [ ] La base de datos no es accesible desde fuera (sin puertos publicados).
- [ ] Las 15 pruebas pasan con y sin base de datos.
- [ ] Credenciales fuera del repositorio (`.env` ignorado, `.env.example` con placeholders).
- [ ] Evidencias en `evidencias/DEV004/` y documento `docs/DEV004-postgresql.md`.
- [ ] Pull Request revisado por otro integrante.

## 12. Cierre en Git

```bash
git checkout main && git pull
git checkout -b feature/DEV004-postgresql
git status        # sin .env, .venv, __pycache__ ni contraseñas
git add .
git commit -m "feat(DEV004): persistencia con PostgreSQL para usuarios y tickets"
git push -u origin feature/DEV004-postgresql
```

Abrir un Pull Request hacia `main` y pedir revisión a otro integrante.

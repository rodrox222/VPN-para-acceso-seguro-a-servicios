# DEV003 — Endpoints con lógica de negocio real: CRUD de usuarios y tickets (HU08)

**Requerimiento:** ampliar la API REST implementando al menos dos recursos con operaciones CRUD completas que representen un caso de uso de producción real.
**Sprint:** 2 · **Prioridad:** 8 · **Esfuerzo estimado:** 9
**Depende de:** HU05 (API base) y HU07 (API en Docker accesible solo por la VPN)

## 1. Caso de uso

Sistema de **soporte técnico remoto** (helpdesk): los usuarios de la red VPN registran incidencias (tickets) sobre el servicio. Se implementan dos recursos relacionados:

- **usuarios**: quienes reportan o atienden incidencias.
- **tickets**: incidencias, cada una asociada a un usuario.

La relación ticket → usuario será una clave foránea cuando se incorpore PostgreSQL (HU09).

## 2. Modelo de datos

**usuario**

| Campo | Tipo | Regla |
|---|---|---|
| `id` | entero | Asignado por el servidor; no se reutiliza |
| `nombre` | texto | Obligatorio, 2–100 caracteres |
| `email` | texto | Obligatorio, formato válido, único (sin distinguir mayúsculas), se guarda en minúsculas |
| `rol` | texto | `cliente` (por defecto) o `tecnico` |
| `creado_en`, `actualizado_en` | fecha UTC | Asignados por el servidor |

**ticket**

| Campo | Tipo | Regla |
|---|---|---|
| `id` | entero | Asignado por el servidor |
| `titulo` | texto | Obligatorio, 3–120 caracteres |
| `descripcion` | texto | Opcional, hasta 1000 caracteres (por defecto vacío) |
| `prioridad` | texto | `baja`, `media` (por defecto) o `alta` |
| `estado` | texto | `abierto` (por defecto), `en_progreso` o `cerrado` |
| `usuario_id` | entero | Obligatorio; debe existir el usuario |
| `creado_en`, `actualizado_en` | fecha UTC | Asignados por el servidor |

Los campos no definidos (incluidos `id` y las fechas) se rechazan con 422.

## 3. Endpoints

Se mantienen los existentes (`/`, `/api/status`, `/api/echo`) sin cambios. Nuevos:

| Recurso | Método | Ruta | Éxito | Errores |
|---|---|---|---|---|
| usuarios | GET | `/api/usuarios` | 200 `{total, data}` | |
| | POST | `/api/usuarios` | 201 + `Location` | 400, 409, 422 |
| | GET | `/api/usuarios/<id>` | 200 | 404 |
| | PUT | `/api/usuarios/<id>` | 200 | 404, 409, 422 |
| | PATCH | `/api/usuarios/<id>` | 200 | 404, 409, 422 |
| | DELETE | `/api/usuarios/<id>` | 204 | 404, 409 |
| tickets | GET | `/api/tickets` | 200 `{total, data}` | 422 (filtros) |
| | POST | `/api/tickets` | 201 + `Location` | 400, 422 |
| | GET | `/api/tickets/<id>` | 200 | 404 |
| | PUT | `/api/tickets/<id>` | 200 | 404, 409, 422 |
| | PATCH | `/api/tickets/<id>` | 200 | 404, 409, 422 |
| | DELETE | `/api/tickets/<id>` | 204 | 404 |

- **PUT** reemplaza el recurso completo: exige los campos obligatorios y los opcionales omitidos vuelven a su valor por defecto. **PATCH** modifica solo los campos enviados.
- `GET /api/tickets` acepta filtros combinables: `?estado=`, `?prioridad=`, `?usuario_id=`.

## 4. Reglas de negocio

| Regla | Respuesta |
|---|---|
| El email de un usuario es único | 409 `email_duplicado` |
| Un ticket debe pertenecer a un usuario existente (al crear o al reasignar) | 422 `validacion` (`usuario_id`) |
| `estado`, `prioridad` y `rol` solo admiten los valores definidos | 422 `validacion` |
| No se elimina un usuario con tickets `abierto` o `en_progreso` | 409 `usuario_con_tickets_activos` |
| Al eliminar un usuario sin tickets activos, se eliminan también sus tickets cerrados (historial) | 204 |
| Un ticket cerrado no se puede modificar (PUT ni PATCH) | 409 `ticket_cerrado` |
| Cuerpo ausente o que no es un objeto JSON | 400 `json_invalido` |

**Formato de error** (siempre JSON):
```json
{"error": {"codigo": "validacion", "mensaje": "Datos inválidos", "detalles": {"titulo": "debe tener entre 3 y 120 caracteres"}}}
```

## 5. Diseño y cambios en el repositorio

```
api/
├── app.py               # endpoints, validaciones y reglas de negocio
├── repository.py        # capa de datos en memoria (nuevo)
├── Dockerfile           # modificado
├── requirements.txt
├── requirements-dev.txt # pytest (solo desarrollo) (nuevo)
├── pytest.ini           # (nuevo)
└── tests/test_api.py    # 15 pruebas automáticas (nuevo)
```

- **Capa de repositorio:** `app.py` no accede a los datos directamente; usa `InMemoryRepository`. En HU09 se sustituye por una implementación sobre PostgreSQL con los mismos métodos, sin reescribir los endpoints.
- **Concurrencia:** las operaciones que verifican y luego escriben (email único, usuario existente, borrado con tickets) se ejecutan bajo un candado, porque Gunicorn atiende con varios hilos.
- **Persistencia:** los datos viven en memoria y **se pierden al reiniciar el contenedor**. Es una limitación esperada hasta HU09.

### Cambios en el `Dockerfile`

1. `COPY app.py repository.py ./`: sin `repository.py` el contenedor no arranca.
2. `gunicorn -w 1 --threads 4`: con datos en memoria hace falta **un solo worker**; con varios, cada uno tendría datos distintos. En HU09 se podrá aumentar.

El `HEALTHCHECK` (`/api/status`) y `docker-compose.yml` no cambian; el contenedor sigue siendo `read_only`.

## 6. Pruebas automáticas

Desde `api/`, con un entorno virtual:

```bash
sudo apt install -y python3-venv python3-pip
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

Resultado esperado: `15 passed`. Cubren: endpoints existentes, CRUD completo de ambos recursos, PUT vs PATCH, email duplicado, validaciones, JSON inválido, 404/405 en JSON, filtros, usuario inexistente, ticket cerrado y borrado de usuario con tickets activos.

## 7. Despliegue

Desde la raíz del repositorio:

```bash
docker compose up -d --build
docker compose ps          # api-rest debe aparecer como "healthy"
```

Para reiniciar los datos entre pruebas: `docker compose restart api-rest`.

## 8. Validación por la VPN

Con el túnel activo en un peer (el servidor escucha solo en `10.0.0.1:5000`):

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | POST `/api/usuarios` | 201 + `Location: /api/usuarios/1` |
| 2 | GET, PUT y PATCH de usuarios | 200 con datos actualizados |
| 3 | POST y listado de tickets, con `?prioridad=alta` | 201 / 200 filtrado |
| 4 | PUT y PATCH de tickets | 200 |
| 5 | POST de usuario con email repetido | 409 `email_duplicado` |
| 6 | POST con datos inválidos | 422 con `detalles` |
| 7 | POST de ticket con `usuario_id` inexistente | 422 |
| 8 | DELETE de usuario con ticket abierto | 409 `usuario_con_tickets_activos` |
| 9 | PATCH de un ticket cerrado | 409 `ticket_cerrado` |
| 10 | DELETE de ticket y de usuario, luego GET | 204, 204, 404 |
| 11 | **Sin VPN:** `curl --max-time 5 http://10.0.0.1:5000/api/usuarios` | Sin respuesta (tiempo agotado) |

### Ejemplos de comandos

**Linux / macOS / peer Linux:**
```bash
curl -i -X POST http://10.0.0.1:5000/api/usuarios \
  -H 'Content-Type: application/json' \
  -d '{"nombre":"Ana Perez","email":"ana@example.com"}'
curl -X POST http://10.0.0.1:5000/api/tickets \
  -H 'Content-Type: application/json' \
  -d '{"titulo":"VPN no conecta","usuario_id":1,"prioridad":"alta"}'
curl "http://10.0.0.1:5000/api/tickets?prioridad=alta"
curl -i -X DELETE http://10.0.0.1:5000/api/usuarios/1
```

**Windows (CMD):** las comillas simples no funcionan; usar comillas dobles escapadas:
```
curl -i -X POST http://10.0.0.1:5000/api/usuarios -H "Content-Type: application/json" -d "{\"nombre\":\"Ana Perez\",\"email\":\"ana@example.com\"}"
```
En PowerShell `curl` es un alias de `Invoke-WebRequest`; usar `curl.exe` o `Invoke-RestMethod`.

## 9. Solución de problemas

| Síntoma | Causa probable |
|---|---|
| `json_invalido` desde Windows | Comillas mal escapadas en CMD/PowerShell (ver sección 8) |
| El contenedor no arranca (`ModuleNotFoundError: repository`) | El `Dockerfile` no copia `repository.py` |
| Datos que aparecen y desaparecen entre llamadas | Gunicorn con más de un worker |
| `pytest: command not found` | Falta activar el entorno virtual o instalar `requirements-dev.txt` |
| `pytest` no encuentra pruebas | `test_api.py` debe estar en `api/tests/` |
| Sin respuesta desde el peer | Túnel inactivo o contenedor no `healthy` (`docker compose logs api-rest`) |
| Los datos desaparecieron tras reiniciar | Esperado: almacenamiento en memoria hasta HU09 |

## 10. Criterio de aceptación (HU08)

- [ ] Al menos dos recursos (usuarios y tickets) con CRUD completo.
- [ ] Validaciones y reglas de negocio con códigos HTTP correctos.
- [ ] Errores devueltos siempre en JSON.
- [ ] 15 pruebas automáticas aprobadas.
- [ ] API desplegada en Docker (`healthy`) y accesible desde un peer por la VPN.
- [ ] Sin VPN, la API no responde.
- [ ] Evidencias subidas a `evidencias/DEV003/`; sin claves ni `.conf` reales.
- [ ] Revisado por **otro integrante** mediante Pull Request.

## 11. Cierre de la HU en Git

```bash
git checkout -b feature/DEV003-api-crud
git status        # verificar: sin .venv, __pycache__, .pytest_cache ni claves
git add .
git commit -m "feat(DEV003): CRUD de usuarios y tickets con reglas de negocio"
git push -u origin feature/DEV003-api-crud
```
Abrir un Pull Request hacia `main` y pedir revisión a otro integrante.

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

COLS_USUARIO = ("nombre", "email", "rol")
COLS_TICKET = ("titulo", "descripcion", "prioridad", "estado", "usuario_id")

def _fila(row):
    if row is None:
        return None
    for campo in ("creado_en", "actualizado_en"):
        if campo in row and row[campo]:
            row[campo] = row[campo].isoformat()
    return row

def _set(cambios, permitidas):
    cols = [c for c in cambios if c in permitidas]
    return ", ".join(f"{c} = %({c})s" for c in cols)

class PostgresRepository:
    def __init__(self, dsn):
        self._pool = ConnectionPool(
            dsn, min_size=1, max_size=5, open=True,
            kwargs={"row_factory": dict_row},
        )

    def listar_usuarios(self):
        with self._pool.connection() as conn:
            rows = conn.execute("SELECT * FROM usuarios ORDER BY id").fetchall()
        return [_fila(r) for r in rows]

    def obtener_usuario(self, uid):
        with self._pool.connection() as conn:
            row = conn.execute("SELECT * FROM usuarios WHERE id = %s", (uid,)).fetchone()
        return _fila(row)

    def buscar_usuario_por_email(self, email):
        with self._pool.connection() as conn:
            row = conn.execute("SELECT * FROM usuarios WHERE lower(email) = lower(%s)", (email,)).fetchone()
        return _fila(row)

    def crear_usuario(self, datos):
        with self._pool.connection() as conn:
            row = conn.execute(
                "INSERT INTO usuarios (nombre, email, rol) "
                "VALUES (%(nombre)s, %(email)s, %(rol)s) RETURNING *",
                datos,
            ).fetchone()
        return _fila(row)

    def actualizar_usuario(self, uid, cambios):
        sets = _set(cambios, COLS_USUARIO)
        if not sets:
            return self.obtener_usuario(uid)
        with self._pool.connection() as conn:
            row = conn.execute(
                f"UPDATE usuarios SET {sets}, actualizado_en = now() "
                "WHERE id = %(id)s RETURNING *",
                {**cambios, "id": uid},
            ).fetchone()
        return _fila(row)

    def eliminar_usuario(self, uid):
        with self._pool.connection() as conn:
            with conn.transaction():
                conn.execute("SELECT id FROM usuarios WHERE id = %s FOR UPDATE", (uid,))
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

    def obtener_ticket(self, tid):
        with self._pool.connection() as conn:
            row = conn.execute("SELECT * FROM tickets WHERE id = %s", (tid,)).fetchone()
        return _fila(row)

    def crear_ticket(self, datos):
        with self._pool.connection() as conn:
            row = conn.execute(
                "INSERT INTO tickets (titulo, descripcion, prioridad, estado, usuario_id) "
                "VALUES (%(titulo)s, %(descripcion)s, %(prioridad)s, %(estado)s, %(usuario_id)s) RETURNING *",
                datos,
            ).fetchone()
        return _fila(row)

    def actualizar_ticket(self, tid, cambios):
        sets = _set(cambios, COLS_TICKET)
        if not sets:
            return self.obtener_ticket(tid)
        with self._pool.connection() as conn:
            row = conn.execute(
                f"UPDATE tickets SET {sets}, actualizado_en = now() "
                "WHERE id = %(id)s RETURNING *",
                {**cambios, "id": tid},
            ).fetchone()
        return _fila(row)

    def eliminar_ticket(self, tid):
        with self._pool.connection() as conn:
            return conn.execute("DELETE FROM tickets WHERE id = %s", (tid,)).rowcount > 0

    def contar_tickets_activos(self, usuario_id):
        with self._pool.connection() as conn:
            return conn.execute(
                "SELECT count(*) AS n FROM tickets "
                "WHERE usuario_id = %s AND estado IN ('abierto', 'en_progreso')",
                (usuario_id,),
            ).fetchone()["n"]

    def eliminar_tickets_de_usuario(self, usuario_id):
        with self._pool.connection() as conn:
            return conn.execute("DELETE FROM tickets WHERE usuario_id = %s", (usuario_id,)).rowcount

    def reset(self):
        with self._pool.connection() as conn:
            conn.execute("TRUNCATE tickets, usuarios RESTART IDENTITY CASCADE")

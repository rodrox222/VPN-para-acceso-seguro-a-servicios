"""Capa de datos en memoria (HU-08 / DEV003).

Solo guarda y consulta datos; las reglas de negocio viven en app.py.
En HU-09 esta clase se reemplaza por una implementación sobre PostgreSQL
que exponga los mismos métodos, sin tocar los endpoints.
"""
from datetime import datetime, timezone
from threading import RLock

ESTADOS_ACTIVOS = ("abierto", "en_progreso")


def _ahora():
    return datetime.now(timezone.utc).isoformat()


class InMemoryRepository:
    def __init__(self):
        self._lock = RLock()
        self.reset()

    def reset(self):
        with self._lock:
            self._usuarios = {}
            self._tickets = {}
            self._seq = {"usuario": 0, "ticket": 0}

    # ------------------------------------------------------------ usuarios
    def listar_usuarios(self):
        with self._lock:
            return [dict(u) for u in self._usuarios.values()]

    def obtener_usuario(self, uid):
        with self._lock:
            u = self._usuarios.get(uid)
            return dict(u) if u else None

    def buscar_usuario_por_email(self, email):
        with self._lock:
            for u in self._usuarios.values():
                if u["email"] == email:
                    return dict(u)
            return None

    def crear_usuario(self, datos):
        with self._lock:
            self._seq["usuario"] += 1
            uid = self._seq["usuario"]
            ahora = _ahora()
            usuario = {"id": uid, **datos, "creado_en": ahora, "actualizado_en": ahora}
            self._usuarios[uid] = usuario
            return dict(usuario)

    def actualizar_usuario(self, uid, cambios):
        with self._lock:
            usuario = self._usuarios[uid]
            usuario.update(cambios)
            usuario["actualizado_en"] = _ahora()
            return dict(usuario)

    def eliminar_usuario(self, uid):
        with self._lock:
            return self._usuarios.pop(uid, None) is not None

    # ------------------------------------------------------------- tickets
    def listar_tickets(self, estado=None, prioridad=None, usuario_id=None):
        with self._lock:
            resultado = []
            for t in self._tickets.values():
                if estado is not None and t["estado"] != estado:
                    continue
                if prioridad is not None and t["prioridad"] != prioridad:
                    continue
                if usuario_id is not None and t["usuario_id"] != usuario_id:
                    continue
                resultado.append(dict(t))
            return resultado

    def obtener_ticket(self, tid):
        with self._lock:
            t = self._tickets.get(tid)
            return dict(t) if t else None

    def crear_ticket(self, datos):
        with self._lock:
            self._seq["ticket"] += 1
            tid = self._seq["ticket"]
            ahora = _ahora()
            ticket = {"id": tid, **datos, "creado_en": ahora, "actualizado_en": ahora}
            self._tickets[tid] = ticket
            return dict(ticket)

    def actualizar_ticket(self, tid, cambios):
        with self._lock:
            ticket = self._tickets[tid]
            ticket.update(cambios)
            ticket["actualizado_en"] = _ahora()
            return dict(ticket)

    def eliminar_ticket(self, tid):
        with self._lock:
            return self._tickets.pop(tid, None) is not None

    def contar_tickets_activos(self, usuario_id):
        with self._lock:
            return sum(
                1
                for t in self._tickets.values()
                if t["usuario_id"] == usuario_id and t["estado"] in ESTADOS_ACTIVOS
            )

    def eliminar_tickets_de_usuario(self, usuario_id):
        with self._lock:
            ids = [i for i, t in self._tickets.items() if t["usuario_id"] == usuario_id]
            for i in ids:
                del self._tickets[i]
            return len(ids)

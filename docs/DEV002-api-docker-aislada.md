# DEV002 — Despliegue de la API REST en contenedor Docker aislado (HU07)

**Requerimiento:** contenerizar la API REST con Docker, mapeando el puerto del servicio **únicamente a la interfaz VPN del servidor** (`10.0.0.1`) para reforzar el aislamiento a nivel de infraestructura.
**Sprint:** 2 · **Depende de:** HU01 (`wg0` activa en `10.0.0.1/24`). Para las pruebas desde cliente: HU02/HU03 (peers registrados). **Se acopla con:** HU05 (apagado de servicio local) y HU06 (firewall), ver secciones 4 y 7.

---

## 1. Prerrequisitos

- `vpn-servidor` con `wg0` activa: `sudo ./scripts/99-verificar-servidor.sh` debe dar "todo correcto" (HU01).
- Al menos un cliente que llegue a `10.0.0.1` (por ejemplo `wgtest`).
- La VM tiene Internet por el adaptador NAT (se descargan Docker y la imagen `python:3.10-slim`).
- **Snapshot previo** (`vm-pre-docker`): instalar Docker modifica reglas de red del servidor; conviene poder volver atrás.

## 2. Parámetros del diseño

| Parámetro | Valor | Dónde se define |
|---|---|---|
| IP de publicación (solo VPN) | `10.0.0.1` | `.env` → `VPN_BIND_IP` |
| Puerto de la API | `5000` | `.env` → `API_PORT` |
| Mapeo de puertos | `"10.0.0.1:5000:5000"` | `docker-compose.yml` |
| Red interna de Docker | `172.18.0.0/24`, puente `br-vpnapi` | `.env` → `API_SUBNET` |
| IP interna del contenedor | `172.18.0.10` | `.env` → `API_IP` |
| Imagen base / servidor | `python:3.10-slim` + Gunicorn | `api/Dockerfile` (coherente con HU05) |
| Usuario en el contenedor | `appuser` (uid 10001), sin root | `api/Dockerfile` |

**Idea central:** el aislamiento lo da el **mapeo de puertos con IP explícita**. Si se escribiera `"5000:5000"`, Docker publicaría el puerto en *todas* las interfaces. Dentro del contenedor la app escucha en `0.0.0.0:5000`; eso no la expone porque el puerto del host solo existe en `10.0.0.1`.

## 3. Qué cambia al instalar Docker (leer antes de empezar)

Docker requiere el reenvío de paquetes (IP forwarding) y gestiona reglas propias de `iptables`. Consecuencias para lo ya documentado:

1. Las notas de **ADM001 (sección 3)** y **CLI001 (sección 8)** afirman que el reenvío está desactivado por diseño. Tras instalar Docker, `net.ipv4.ip_forward` pasa a ser `1`. 
2. Que los clientes **sigan sin alcanzarse entre sí** ya no lo garantiza "reenvío apagado", sino la política de la cadena `FORWARD` y las reglas de la HU06.

Comprobación antes y después de instalar:
```bash
sysctl net.ipv4.ip_forward
sudo iptables -S FORWARD | head -3
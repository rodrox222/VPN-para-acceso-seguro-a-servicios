# Historia de Usuario 05 (DEV001): Despliegue del prototipo en entorno de pruebas local

## 1. Descripción
Despliegue integral del prototipo (Servidor VPN WireGuard + Servicio Telemático API REST en Flask con Gunicorn) en un entorno local aislado, validando la conectividad de extremo a extremo antes de migrar a un entorno cloud con costos asociados.

## 2. Parámetros de Despliegue
- **Servidor VPN:** Interfaz `wg0` (`10.0.0.1/24`), puerto UDP `51820`.
- **Servicio API REST:** Python 3.10 con Flask y Gunicorn.
- **Enlace y Aislamiento:** El servicio escucha exclusivamente en `10.0.0.1:5000`, evitando la exposición directa en las interfaces de red física o pública.
- **Gestión de Servicios:** Automatizado mediante `systemd` (`telematica-api.service`).

## 3. Evidencias de Validación
- Verificación del socket de Gunicorn en escucha en `10.0.0.1:5000`.
- Pruebas funcionales exitosas (`GET /`, `GET /api/status`, `POST /api/echo`) desde el túnel VPN con respuesta `HTTP 200 OK`.
- Verificación de aislamiento de red (rechazo de conexiones directas en la interfaz física de la máquina virtual).

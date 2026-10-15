# Historia de Usuario 06 (ADM004): Reglas de firewall para bloquear el acceso directo a la API

## 1. Descripción
Configuración de `iptables` para que la API REST (TCP 5000) sea accesible únicamente desde la interfaz de WireGuard (`wg0`), descartando (`DROP`) cualquier intento de conexión desde la interfaz física.

## 2. Diseño de Seguridad
Implementa aislamiento en capa de red (Netfilter) y descarte silencioso (`DROP`). Además, se habilitó IP forwarding (`net.ipv4.ip_forward=1`) en preparación para la integración con contenedores Docker (HU-07).

## 3. Pruebas de Seguridad Realizadas
El acceso por `wg0` retorna `HTTP 200 OK`. El acceso por la interfaz física `192.168.1.18` resulta en `Connection timed out`.

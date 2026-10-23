# ADM005 (HU-14): Despliegue de Servidor WireGuard Secundario (Redundancia)

## Objetivo
Desplegar un servidor WireGuard secundario, redundante e independiente en una máquina virtual local (simulando una segunda instancia en la nube). Este servidor cuenta con sus propias claves criptográficas, pero mantiene la misma estructura de direccionamiento interno y servicios (API REST) que el servidor principal, sentando las bases para el balanceo de carga (HU-15) y failover (HU-16).

## Especificaciones Técnicas
* **Sistema Operativo:** Ubuntu 22.04 LTS (VM local en modo Bridged).
* **Direccionamiento VPN (`wg0`):** `10.0.0.1/24` (Misma IP que el primario para failover transparente).
* **Puerto de Escucha:** UDP `51820`.
* **Servicios Alojados:** Docker (API REST en el puerto `5000` y Base de Datos aislada).

## Seguridad y Firewall
Se implementó un esquema de seguridad estricto para aislar los contenedores:
* **Cadena `DOCKER-USER`:** Configurada mediante `iptables` con una política por defecto `FORWARD = DROP`.
* **Aislamiento de la API:** La API REST solo responde a peticiones provenientes de la interfaz `wg0` (`10.0.0.1`). Cualquier intento de acceso desde el exterior (ej. IP de la red local `192.168.1.9` o internet) es bloqueado inmediatamente (Timeout).
* **Orden de Arranque:** El servicio de Docker está configurado para arrancar obligatoriamente **después** de `wg-quick@wg0`, evitando conflictos de enrutamiento al reiniciar el servidor.

## Archivos Entregables
* `config/wg0-secundario-plantilla.conf`: Plantilla base de configuración del túnel para el servidor secundario. **Nota:** Las claves privadas han sido omitidas de este archivo por seguridad. Los bloques de los clientes (Peers) se encuentran comentados a la espera de la sincronización automatizada (HU-17).

## Pasos de Despliegue (Resumen)
Si se necesita recrear este servidor desde cero, los pasos ejecutados fueron:

1. **Preparación del Entorno:**
```bash
sudo apt update
sudo apt install docker.io docker-compose wireguard -y
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
```

2. **Generación de Claves (Independientes del servidor principal):**
```bash
cd /etc/wireguard
sudo sh -c 'umask 077; wg genkey | tee server_private.key | wg pubkey > server_public.key'
```

3. **Configuración de Servicios:**
* Se adaptó la configuración del firewall (`09-reglas-docker-user.sh`).
* Se desplegó la API usando `docker-compose up -d`.
* Se habilitó el túnel en el arranque: `sudo systemctl enable --now wg-quick@wg0`.

## Verificación y Pruebas

Para comprobar el correcto funcionamiento y aislamiento del servidor, ejecutar:

* **Comprobación del servicio VPN:**
```bash
sudo wg show
ip a show wg0
```

* **Prueba de acceso válido (Estando conectado a la VPN):**
```bash
curl -s http://10.0.0.1:5000/api/status
```
*(Debe retornar JSON con status: "ok")*

* **Prueba de bloqueo del firewall (Desde fuera de la VPN):**
```bash
curl -m 5 http://<IP_PUBLICA_O_LOCAL>:5000
```
*(Debe fallar por Timeout confirmando el aislamiento)*

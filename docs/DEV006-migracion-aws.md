# DEV006 — Migración del prototipo a una instancia AWS EC2 (HU13)

**Requerimiento:** migrar el prototipo ya validado (VPN WireGuard + API REST + PostgreSQL en Docker) a una instancia real en AWS EC2, replicando la configuración del entorno de pruebas, para la demostración final y para que el equipo trabaje sobre un servidor común sin intercambiar la `.ova`.
**Sprint:** 3 · **Depende de:** HU01–HU10 (servidor WireGuard, clientes, revocación, firewall, Docker, CRUD, PostgreSQL, OpenAPI).

---

## 0. Resumen del orden de trabajo

| Fase | Dónde | Qué se hace |
|---|---|---|
| A | Consola AWS | Cuenta, región, par de claves, grupo de seguridad, instancia, Elastic IP |
| B | Servidor (SSH) | Clonar el repo, preparar el sistema, WireGuard, Docker, `.env`, despliegue, firewall, verificación |
| C | Servidor + clientes | Parche del endpoint, crear peers, entregar configuraciones, conectar y probar |
| D | Servidor | Reinicio y persistencia |
| E | Equipo | Acceso SSH de los integrantes, flujo de trabajo, respaldo (AMI) |
| F | Opcional | Cerrar el SSH público y administrar por la VPN |

## 1. Qué se migra y cómo

| Componente | Cómo llega al servidor AWS | Script / acción |
|---|---|---|
| Sistema base y herramientas | Se instala desde cero | `10-aws-preparar-servidor.sh` (**nuevo**) |
| WireGuard (`wg0`) | **Claves nuevas** generadas en el servidor | `01-instalar-wireguard.sh`, `02-configurar-servidor.sh`, `99-verificar-servidor.sh` |
| Docker y orden de arranque | Se instala desde cero | `06-instalar-docker.sh`, `07-orden-arranque-docker-wg.sh` |
| API + PostgreSQL | `docker compose` con `.env` propio | `08-desplegar-api.sh` |
| Firewall | Reglas compatibles con Docker | `09-reglas-docker-user.sh` (**nuevo**, sustituye a `05` en AWS) |
| Clientes (peers) | Se crean de nuevo | `agregar-cliente.sh` (con un parche, §2.3) |
| Verificación y evidencia | — | `11-verificar-despliegue-aws.sh` (**nuevo**), `98-probar-aislamiento-api.sh` |

**No se ejecutan en AWS:** `04-desplegar-api-local.sh` (la API de la HU05 como servicio del host; ahora es un contenedor) ni `05-configurar-firewall-api.sh` (ver §2.2).

## 2. Hallazgos que condicionan la migración

Salen de leer el repositorio actual. Si alguno no se corresponde con lo que ustedes tienen en la `.ova`, avisen.

### 2.1 La capa gratuita de AWS cambió
- Cuentas creadas **antes del 15/07/2025**: 12 meses con instancias t2.micro o t3.micro.
- Cuentas creadas **a partir de esa fecha**: plan gratuito basado en créditos (USD 100 al registrarse y hasta USD 100 más por tareas de iniciación). Dura **6 meses o hasta agotar los créditos**, y la cuenta se cierra si no se pasa a un plan de pago. Tipos de instancia elegibles: t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large y m7i-flex.large.
- AWS cobra por cada dirección IPv4 pública, también la de una instancia en ejecución. Confirmen el costo en la calculadora de precios y en *Billing* antes de dejar la instancia encendida.
- **Consecuencia para el informe:** la fila "Proveedor cloud" de la sección 9 dice "capa gratuita de 12 meses". Eso solo es cierto para cuentas antiguas. Texto sugerido: *"La capa gratuita de AWS para cuentas nuevas es un plan basado en créditos (hasta USD 200, con vigencia máxima de 6 meses); las cuentas anteriores al 15/07/2025 conservan 12 meses de t2/t3.micro. El costo del proyecto se mantiene en cero durante el semestre."*
- Verifiquen la etiqueta **"Free tier eligible"** del tipo de instancia en la región que elijan antes de lanzarla.

### 2.2 La persistencia del firewall de la HU06 no es compatible con Docker
`05-configurar-firewall-api.sh` guarda **todas** las reglas con `iptables-save` y crea `telematica-firewall.service`, que en cada arranque ejecuta `iptables-restore` sin `--noflush`. Eso reemplaza tablas completas. Con Docker en marcha puede borrar sus cadenas y reglas NAT, y el puerto publicado deja de funcionar. Además:
- Ese servicio y Docker arrancan los dos "después de `wg0`", sin orden entre sí.
- La HU06 activó `ip_forward` de forma persistente (`/etc/sysctl.d/99-wireguard-forwarding.conf`). Docker solo pone la política `FORWARD` en `DROP` cuando es **él** quien activa el reenvío, así que aquí quedaría en `ACCEPT`.
- Las reglas de `INPUT` no ven el tráfico hacia un puerto publicado de un contenedor: ese tráfico va por `FORWARD`.

Por eso en AWS se usa `09-reglas-docker-user.sh`: reglas en la cadena `DOCKER-USER` (R1: solo `wg0` llega a la API; R2: los clientes no se alcanzan entre sí; política `FORWARD` en `DROP`), reaplicadas por `docker-user-rules.service` **después** de que Docker arranca. Es una lectura del script y de la documentación de Docker, no una prueba en su `.ova`: pueden comprobarlo allí tras un reinicio con `sudo iptables -t nat -S DOCKER | grep 5000` y `systemctl status telematica-firewall.service`.

### 2.3 `agregar-cliente.sh` tiene el endpoint escrito fijo
Usa `192.168.23.137:51820`. En AWS debe ser la Elastic IP. Parche (probado sobre las líneas del script): exige la variable `WG_ENDPOINT` **al inicio**, antes de consumir una IP del DHCP.
```bash
sed -i '/^CLIENT_NAME=\$1/a : "${WG_ENDPOINT:?Define WG_ENDPOINT=IP_PUBLICA:51820 (ver docs/DEV006)}"' scripts/agregar-cliente.sh
sed -i 's|^SERVER_ENDPOINT=.*|SERVER_ENDPOINT="${WG_ENDPOINT}"|' scripts/agregar-cliente.sh
```
Súbanlo al repositorio. Actualicen también el parámetro "Endpoint del servidor" de `docs/ADM002`.

### 2.4 Las claves cambian: ninguna configuración de cliente de la `.ova` sirve
El servidor AWS genera sus propias claves. Cada integrante necesita una configuración nueva (con la clave pública y el endpoint nuevos). Además, la `.ova` circuló con la misma clave privada de servidor para todos: **no la copien a AWS**.

### 2.5 Nombres de interfaz
En AWS la interfaz pública suele ser `ens5`, no `enp0s8`. Las guías con `tcpdump -i enp0s8` o `rp_filter` sobre `enp0s8` deben usar `-i any` o `ens5` (confírmenlo con `ip -br link`). Los ajustes de rendimiento de VirtualBox (checksum, `rp_filter`) **no** se aplican en AWS.

### 2.6 Otros ajustes menores
- `*.pem` no está en el `.gitignore` (los pares de claves de AWS se descargan como `.pem`).
- Mensajes cruzados: `06` apunta a `05-orden-arranque...` (es `07`), `07` a `06-desplegar...` (es `08`) y `08` a `04-instalar-docker.sh` (es `06`):
```bash
sed -i 's|scripts/05-orden-arranque-docker-wg.sh|scripts/07-orden-arranque-docker-wg.sh|' scripts/06-instalar-docker.sh
sed -i 's|\./scripts/06-desplegar-api.sh|./scripts/08-desplegar-api.sh|' scripts/07-orden-arranque-docker-wg.sh
sed -i 's|scripts/04-instalar-docker.sh|scripts/06-instalar-docker.sh|' scripts/08-desplegar-api.sh
echo "*.pem" >> .gitignore
```
- El informe (secciones 6, 8.2.3 y 9) dice Python 3.11, pero `api/Dockerfile` usa `python:3.10-slim` (igual que la HU05). Alineen uno de los dos.
- `agregar-cliente.sh` necesita `dhclient` y `dnsmasq`: los instala `10-aws-preparar-servidor.sh`.

### 2.7 Contraseña de la base de datos
`08-desplegar-api.sh` copia `.env.example` si no existe `.env`, y deja la contraseña de ejemplo. Creen el `.env` **antes**. Usen una contraseña hexadecimal: `docker-compose.yml` la inserta en una URL (`DATABASE_URL`) y caracteres como `/`, `+`, `@` o `=` la rompen.

### 2.8 Si el servidor AWS usa Ubuntu 24.04 en lugar de 22.04
Docker soporta oficialmente 22.04, 24.04 y 26.04, y WireGuard está en el kernel de las tres, así que la pila funciona igual. Lo que cambia:
- **`dhclient`:** `agregar-cliente.sh` lo usa para el DHCP proxy. En 24.04 el paquete `isc-dhcp-client` pasó a `universe` y está en desuso (ISC dejó de mantener el cliente; el cliente por defecto es `dhcpcd`). Sigue instalable, y `10-aws-preparar-servidor.sh` habilita `universe` si hace falta. **No lo he probado con `agregar-cliente.sh`**: creen el primer peer cuanto antes (Fase C1). Si fallara, la versión anterior del script con IP automática por lectura de `wg0.conf` está en `docs/ADM002-scripts-cliente.md` y no necesita `dhclient`.
- **Informe:** el entorno local sigue siendo 22.04; el servidor real sería 24.04. Lo más honesto es decirlo así en la sección 9 (sistema operativo) y en la 8.5 (despliegue), justificándolo: soporte más largo y es la imagen elegible de la capa gratuita.
- Los scripts `10` y `11` avisan cuando el sistema no es 22.04, pero no fallan por eso.
- No usen 26.04: es una versión muy reciente, el proyecto no se ha probado en ella y no he podido comprobar la disponibilidad de `dhclient` allí.

## 3. Parámetros del despliegue en AWS

| Parámetro | Valor |
|---|---|
| Región | Una sola para todo (grupo de seguridad, par de claves y Elastic IP son regionales). Sugerencia: São Paulo (`sa-east-1`) por cercanía; compruébenlo con `ping` y con la etiqueta *Free tier eligible* |
| AMI | Ubuntu Server 22.04 LTS (HVM), SSD, x86_64; si no está disponible con la etiqueta *Free tier eligible*, Ubuntu Server 24.04 LTS (ver §2.8) |
| Tipo de instancia | `t3.small` (2 GB) si es elegible en su cuenta; si no, `t3.micro` (1 GB, el script crea swap). Es una estimación mía que 1 GB alcanza para Docker + PostgreSQL + API; `t3.small` da margen para builds y pruebas |
| Disco | 20 GiB gp3 |
| Grupo de seguridad | **Entrada:** UDP 51820 desde `0.0.0.0/0`; TCP 22 solo desde las IP de los integrantes. **No** abrir 5000 ni 5432 |
| IP pública | Elastic IP asociada (para que el `Endpoint` no cambie al detener/iniciar) |
| Usuario SSH | `ubuntu` |
| Red VPN | `wg0` = `10.0.0.1/24`, UDP 51820 (contrato del proyecto) |

## 4. Procedimiento paso a paso

### Fase A — Consola de AWS

**A1. Cuenta.** Un integrante crea la cuenta (puede pedir una tarjeta para verificarla). Eligan el plan y anoten la fecha de creación: define el vencimiento. Conviene crear una alerta de presupuesto (*Billing → Budgets*). No compartan las credenciales raíz: si otros necesitan consola, usen usuarios IAM.

**A2. Región.** Seleccionen la región arriba a la derecha y no la cambien.

**A3. Par de claves.** *EC2 → Network & Security → Key Pairs → Create key pair*: nombre `vpn-aws`, formato `.pem`. Se descarga una sola vez.
```bash
mkdir -p ~/.ssh && mv ~/Descargas/vpn-aws.pem ~/.ssh/ && chmod 400 ~/.ssh/vpn-aws.pem
```
Nunca se sube a GitHub ni se comparte por chat.

**A4. Lanzar la instancia.** *EC2 → Launch instance*:
1. Nombre: `vpn-servidor-aws`.
2. Imagen: *Ubuntu Server 22.04 LTS (HVM), SSD Volume Type* **solo si** aparece con la etiqueta *Free tier eligible* y publicada por Canonical. Si no aparece así (la consola actual ofrece 24.04 y 26.04), usen **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type** y lean §2.8. **No** usen: 26.04, las variantes *Ubuntu Pro*, *with SQL Server* ni *Deep Learning*.
3. Tipo: `t3.small` o `t3.micro` (con la etiqueta *Free tier eligible*).
4. Par de claves: `vpn-aws`.
5. *Network settings → Edit*: grupo nuevo `sg-vpn-servidor`.
   - Regla 1: SSH, TCP 22, origen *My IP*.
   - Regla 2 (*Add security group rule*): *Custom UDP*, puerto **51820**, origen *Anywhere-IPv4* (`0.0.0.0/0`).
   - Dejen desmarcadas las casillas de HTTP/HTTPS.
6. Almacenamiento: 20 GiB, gp3.
7. *Launch instance*.

**A5. Elastic IP.** *EC2 → Elastic IPs → Allocate Elastic IP address → Allocate*; luego *Actions → Associate Elastic IP address* y elijan la instancia. Anoten la IP: de aquí en adelante es `<EIP>`.

**A6. Comprobar el acceso.**
```bash
ssh -i ~/.ssh/vpn-aws.pem ubuntu@<EIP>
```

### Fase B — Servidor

**B1. Traer el repositorio.** Si es público: `git clone https://github.com/<usuario>/<repositorio>.git`. Si es privado, usen una *deploy key* de solo lectura:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy -N ""
cat ~/.ssh/github_deploy.pub                     # copiarla en GitHub: Settings → Deploy keys → Add (solo lectura)
printf 'Host github.com\n  IdentityFile ~/.ssh/github_deploy\n' >> ~/.ssh/config
git clone git@github.com:<usuario>/<repositorio>.git && cd <repositorio>
```
Incorporen en el repo los parches de §2.3 y §2.6 y los scripts nuevos de este paquete (`09`, `10`, `11`) antes de seguir.

**B2. Preparar el sistema.**
```bash
sudo ./scripts/10-aws-preparar-servidor.sh
```

**B3. WireGuard (con claves nuevas).**
```bash
sudo ./scripts/01-instalar-wireguard.sh
sudo ./scripts/02-configurar-servidor.sh
sudo ./scripts/99-verificar-servidor.sh        # debe terminar en "todo correcto"
sudo cat /etc/wireguard/server_public.key     # la necesitarán los clientes (no es secreta)
```

**B4. Docker.**
```bash
sudo ./scripts/06-instalar-docker.sh
exit                                          # cerrar sesión y volver a entrar por SSH (grupo docker)
cd <repositorio>
sudo ./scripts/07-orden-arranque-docker-wg.sh
```

**B5. Configuración (`.env`) con contraseña propia.**
```bash
printf 'POSTGRES_DB=helpdesk\nPOSTGRES_USER=helpdesk\nPOSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)" > .env
chmod 600 .env
git status                                    # no debe aparecer .env
```

**B6. Desplegar.**
```bash
./scripts/08-desplegar-api.sh
```
Debe terminar con `api-rest` *healthy* y `docker port` mostrando `10.0.0.1:5000`.

**B7. Firewall compatible con Docker.**
```bash
sudo ./scripts/09-reglas-docker-user.sh aplicar
sudo ./scripts/09-reglas-docker-user.sh instalar-servicio
```
No ejecuten `05-configurar-firewall-api.sh` en este servidor.

**B8. Verificación integral.**
```bash
sudo ./scripts/11-verificar-despliegue-aws.sh | tee evidencias/DEV006/verificacion.txt
sudo ./scripts/98-probar-aislamiento-api.sh servidor
sudo ./scripts/98-probar-aislamiento-api.sh hu06
```
La salida indica qué falta. Hasta que haya peers, el aviso "no hay peers registrados" es normal.

### Fase C — Clientes

**C1. Crear un peer por integrante** (los archivos se generan en el directorio actual, fuera del repositorio):
```bash
mkdir -p ~/clientes && cd ~/clientes
sudo env WG_ENDPOINT="<EIP>:51820" ~/<repositorio>/scripts/agregar-cliente.sh Rodrigo
sudo env WG_ENDPOINT="<EIP>:51820" ~/<repositorio>/scripts/agregar-cliente.sh Harol
# ... uno por integrante
sudo chown -R "$USER:$USER" ~/clientes
sudo wg show
```

**C2. Entregar cada configuración** (contiene la clave privada del cliente) y borrarla del servidor cuando el integrante confirme que conecta:
```bash
# en el equipo del integrante
scp -i ~/.ssh/vpn-aws.pem ubuntu@<EIP>:~/clientes/Harol.conf .
# en el servidor, ya confirmado
rm ~/clientes/Harol.conf ~/clientes/Harol_private.key
```

**C3. Conectar.**
- Linux: `sudo install -m 600 Harol.conf /etc/wireguard/wgaws.conf && sudo wg-quick up wgaws`
- Windows/macOS: app WireGuard → *Importar túnel(es) desde archivo*.

**C4. Probar desde cada cliente.**
```bash
ping -c 4 10.0.0.1
curl -s http://10.0.0.1:5000/api/status
curl -s http://10.0.0.1:5000/api/usuarios
curl -i -X POST http://10.0.0.1:5000/api/usuarios -H 'Content-Type: application/json' \
     -d '{"nombre":"Ana Perez","email":"ana@example.com"}'
```
Prueben desde **redes distintas** (casa, datos móviles): es la diferencia real frente a la VM.

### Fase D — Reinicio y persistencia
```bash
# datos de PostgreSQL: sobreviven a reiniciar el contenedor y a bajar/subir (sin -v)
docker compose restart api-rest
docker compose down && docker compose up -d       # nunca "down -v": borra la base de datos
# reinicio completo de la instancia
sudo reboot
# al volver (≈1 min), por SSH:
sudo ./scripts/11-verificar-despliegue-aws.sh
```
La API puede registrar errores de conexión unos segundos tras el arranque hasta que PostgreSQL esté listo. Los clientes reconectan solos gracias a `PersistentKeepalive`.

### Fase E — El equipo trabajando sobre el servidor

**E1. Acceso SSH de cada integrante.** Cada uno genera su clave (`ssh-keygen -t ed25519`) y pasa **solo la pública**; el administrador la añade:
```bash
echo "ssh-ed25519 AAAA... integrante" >> ~/.ssh/authorized_keys
```
Y en AWS, agrega la IP del integrante como regla SSH del grupo de seguridad. Si su IP cambia seguido, ver Fase F.

**E2. Actualizar el servidor con cambios nuevos.**
```bash
cd ~/<repositorio> && git pull
./scripts/08-desplegar-api.sh
```
`db/init.sql` solo se ejecuta con el volumen vacío: un cambio de esquema exige una migración o `docker compose down -v` (borra los datos).

**E3. Herramientas para las pruebas reales.** `iperf3` y `tcpdump` ya quedan instalados. Para medir el efecto de la VPN, el grupo de seguridad bloquea ICMP por defecto: si lo necesitan como línea base, habiliten ICMP temporalmente solo para sus IP.

**E4. Respaldo equivalente a la `.ova`.** *EC2 → Instances → Actions → Image and templates → Create image* genera una AMI. Contiene las claves privadas del servidor: no se comparte ni se hace pública. Genera costo de almacenamiento.

### Fase F — Opcional: cerrar el SSH público
Cuando todos tengan su peer funcionando, pueden administrar el servidor **por la VPN** (`ssh -i vpn-aws.pem ubuntu@10.0.0.1`) y quitar la regla TCP 22 del grupo de seguridad. Antes de hacerlo, asegúrense de que alguien con acceso a la consola pueda volver a abrirla si `wg0` falla.

## 5. Pruebas de validación

| # | Prueba | Cómo | Resultado esperado |
|---|---|---|---|
| 1 | Verificación integral | `11-verificar-despliegue-aws.sh` | Sin fallos |
| 2 | Aislamiento en el servidor | `98-probar-aislamiento-api.sh servidor` | Todas las verificaciones pasan |
| 3 | Capa de firewall | `98-probar-aislamiento-api.sh hu06` | R1 presente |
| 4 | Túnel real desde Internet | `ping -c 4 10.0.0.1` desde ≥3 clientes en redes distintas | 0 % de pérdida y handshake en `wg show` |
| 5 | API por la VPN | `curl` a `/api/status`, `/api/usuarios` y un POST | 200 / 201 |
| 6 | La API no es pública | desde un equipo **sin** VPN: `nc -vz -w 4 <EIP> 5000` y `nc -vz -w 4 <EIP> 5432` | Tiempo agotado en ambos (el grupo de seguridad los bloquea) |
| 7 | Sin túnel no hay acceso | `sudo wg-quick down wgaws` y `curl --max-time 5 http://10.0.0.1:5000/api/status` | Falla |
| 8 | Cliente no registrado | clave privada al azar, como en CLI001 (8.1) | Sin handshake |
| 9 | Revocación | revocar un peer (ADM003) y probar desde él | 100 % de pérdida; el resto sigue |
| 10 | Aislamiento entre clientes | desde un peer, `ping` a la IP de otro peer | 100 % de pérdida |
| 11 | Persistencia de datos | crear un usuario, `down`/`up` sin `-v` | El dato sigue |
| 12 | Reinicio de la instancia | `sudo reboot` y repetir la prueba 1 | `wg0`, contenedores y reglas vuelven solos |

La prueba 6 no puede hacerse desde dentro de la instancia: tiene que ser desde Internet.

## 6. Evidencias para `evidencias/DEV006/`
- Capturas de la consola: instancia, grupo de seguridad (solo UDP 51820 y SSH restringido) y Elastic IP. **Sin** claves ni credenciales.
- Salida de `11-verificar-despliegue-aws.sh` antes y después del reinicio.
- Salidas de `98-probar-aislamiento-api.sh`.
- `wg show` con los handshakes (sin `wg showconf`).
- Resultados de las pruebas 4 a 11 desde clientes reales.

## 7. Solución de problemas

| Síntoma | Causa probable |
|---|---|
| No hay `latest handshake` | Regla del grupo de seguridad con TCP en vez de **UDP**, o puerto distinto de 51820; `Endpoint` con la IP equivocada; clave pública del servidor antigua (de la `.ova`) |
| Handshake pero no hay ping | `AllowedIPs` distinto a la IP asignada; el peer no quedó en `wg0.conf` |
| `08-desplegar-api.sh`: `no está asignada a ninguna interfaz` | `wg0` caída: `sudo systemctl status wg-quick@wg0` |
| La API falla tras reiniciar | Algo borró las reglas NAT de Docker (p. ej. `telematica-firewall.service`): `sudo iptables -t nat -S DOCKER`; deshabilitarlo y usar `09` |
| `docker: permission denied` | Cerrar sesión y volver a entrar (grupo `docker`) |
| `agregar-cliente.sh`: `WG_ENDPOINT` | Falta pasar la variable (§2.3) |
| `agregar-cliente.sh`: el DHCP no responde | `dnsmasq`/`dhclient` ausentes (rehacer `10-...`) o `br-wg-dhcp` sin crear; revisar `systemctl status dnsmasq` |
| El script del servidor no ve la IP pública | Falta la Elastic IP, o la instancia se detuvo/inició y cambió de IP |
| Paquetes grandes fallan, los pequeños no | Problema de MTU del túnel: probar con `MTU = 1280` en la configuración del cliente |
| No hay RAM al construir la imagen | Instancia de 1 GB sin swap: ejecutar `10-...` o usar `t3.small` |

## 8. Costos y ciclo de vida
- Detener la instancia no elimina el costo de la IPv4 pública ni del disco; terminarla sí elimina la instancia pero **no libera** la Elastic IP: hay que liberarla.
- En el plan gratuito de cuentas nuevas, la cuenta se cierra a los 6 meses o al agotar créditos. Antes de la defensa final comprueben cuántos créditos quedan.
- Antes de que venza la cuenta, exporten lo necesario (evidencias, AMI si se requiere) a otro lugar.

## 9. Documentos e informe a actualizar
1. **README:** quitar la distribución por `.ova`, añadir DEV006 y los scripts `09`–`11`.
2. **ADM004 (HU06):** aclarar que con Docker las reglas efectivas están en `DOCKER-USER` y que en AWS se usa `09`.
3. **ADM002:** endpoint parametrizado con `WG_ENDPOINT`.
4. **ADM001 / ENTORNO-VM:** indicar que la `.ova` es solo para el entorno local y que el servidor real está en AWS.
5. **Informe, sección 9:** corregir la fila del proveedor cloud (§2.1), la versión de Python (§2.6) y, si el servidor AWS usa 24.04, la fila del sistema operativo (§2.8). **Sección 8.5:** la interfaz pública en AWS es `ens5`, no `eth0`.

## 10. Criterio de aceptación (HU13)
- [ ] Instancia Ubuntu 22.04 en AWS con Elastic IP; grupo de seguridad solo con UDP 51820 y SSH restringido.
- [ ] `wg0` activa con claves propias del servidor AWS (no las de la `.ova`).
- [ ] API y PostgreSQL en contenedores `healthy`; `docker port api-rest` = `10.0.0.1:5000`; PostgreSQL sin puertos publicados.
- [ ] Al menos 3 clientes conectados desde redes distintas y probando la API por la VPN.
- [ ] Sin VPN no hay acceso a la API desde Internet (prueba 6).
- [ ] Reglas R1/R2 persistentes; `telematica-firewall.service` no interfiere.
- [ ] Sobrevive a un reinicio (prueba 12).
- [ ] Evidencias en `evidencias/DEV006/`; sin `.pem`, `.env` ni claves en Git.
- [ ] Revisado por **otro integrante** mediante Pull Request.

## 11. Cierre en Git
```bash
git checkout -b feature/DEV006-migracion-aws
git add scripts/09-reglas-docker-user.sh scripts/10-aws-preparar-servidor.sh scripts/11-verificar-despliegue-aws.sh \
        scripts/agregar-cliente.sh scripts/06-instalar-docker.sh scripts/07-orden-arranque-docker-wg.sh \
        scripts/08-desplegar-api.sh docs/DEV006-migracion-aws.md evidencias/DEV006/ .gitignore
git status        # verificar: no aparece .env, .pem ni .key
git commit -m "feat(DEV006): migración a AWS EC2 con firewall compatible con Docker"
git push -u origin feature/DEV006-migracion-aws
```
Abrir un Pull Request hacia `main` y pedir revisión a otro integrante.

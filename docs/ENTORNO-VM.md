# Entorno de máquinas virtuales (VirtualBox y VMware)

Cada integrante usa **su propia VM**. Las VM **no se comparten** entre integrantes (VirtualBox y VMware usan formatos y redes virtuales distintos): lo que se comparte es el **repositorio**. Cualquiera reconstruye el mismo estado ejecutando los scripts.

## 1. Especificación común de la VM servidor (valores sugeridos)

| Parámetro | Valor |
|---|---|
| Sistema operativo | Ubuntu 22.04 LTS (Server recomendado por ser más liviano; Desktop también sirve) |
| Recursos | 2 vCPU, 2 GB RAM, 20 GB de disco (WireGuard consume muy poco; más adelante se sumarán Docker y la base de datos) |
| Nombre de la VM | `vpn-servidor` |
| Adaptador de red 1 | **NAT** (da Internet para `apt`) |
| Adaptador de red 2 | **Solo-anfitrión / Host-only** (permite que tu equipo se conecte a la VM) |
| Extra recomendado | Instalar *OpenSSH server* durante la instalación (para entrar por `ssh` desde el anfitrión) |

## 2. Modos de red: cuál usar

| Modo | Qué permite | Uso en el proyecto |
|---|---|---|
| NAT | La VM sale a Internet; nadie entra a ella | Instalar paquetes |
| Host-only / Solo-anfitrión | Comunicación **solo** entre la VM y su propio anfitrión | **Trabajo individual**: el anfitrión actúa como cliente VPN |
| Bridged / Puente | La VM obtiene IP de tu red local real | Solo si varios integrantes están **en la misma red local** y quieren probar contra un mismo servidor |

> Una VM en tu laptop **no es alcanzable** por compañeros en otra red. Para pruebas conjuntas a distancia hará falta un servidor con IP pública (el VPS de AWS planificado en DEV006).

## 3. VirtualBox sobre CachyOS (anfitrión Arch-based)

### 3.1 Instalación en el anfitrión
CachyOS usa su propio kernel, por lo que VirtualBox necesita los módulos compilados para ese kernel (DKMS) y sus cabeceras:

```bash
uname -r                                   # identifica tu kernel
sudo pacman -S virtualbox virtualbox-host-dkms linux-cachyos-headers
sudo usermod -aG vboxusers $USER
sudo reboot
```
- Reemplaza `linux-cachyos-headers` por las cabeceras que correspondan a tu kernel si no usas el kernel por defecto de CachyOS.
- Tras reiniciar, verifica con `lsmod | grep vboxdrv`. Si no aparece, revisa la compilación DKMS con `dkms status`.
- El *Extension Pack* **no** es necesario para este proyecto.

### 3.2 Red solo-anfitrión
En VirtualBox: *Herramientas → Red (Network Manager) → Redes solo-anfitrión → Crear*. Deja el **servidor DHCP habilitado**. El rango por defecto (`192.168.56.0/24`) funciona sin configuración adicional.

### 3.3 Crear la VM
1. *Nueva* → nombre `vpn-servidor`, tipo Linux / Ubuntu (64-bit), ISO de Ubuntu 22.04.
2. Recursos según la tabla de la sección 1.
3. *Configuración → Red*: Adaptador 1 = **NAT**; Adaptador 2 = **Adaptador solo-anfitrión** (la red creada arriba).
4. Instalar Ubuntu (marcar *OpenSSH server* si es Server).

### 3.4 Obtener la IP de la VM
Dentro de la VM:
```bash
ip -br -4 addr
```
Busca la interfaz con IP `192.168.56.x`: **esa es la IP del servidor** para la configuración del cliente. Si la interfaz solo-anfitrión no tiene IP, es que no recibió DHCP; revisa que el servidor DHCP de la red solo-anfitrión esté habilitado.

### 3.5 Tu anfitrión como cliente VPN de prueba
En CachyOS:
```bash
sudo pacman -S wireguard-tools
sudo ./scripts/03-cliente-prueba.sh <CLAVE_PUBLICA_SERVIDOR> 192.168.56.x
```
El script usa la interfaz `wgtest` (no `wg0`) para no chocar con otras VPN que ya tengas en tu equipo. Solo enruta `10.0.0.0/24` por el túnel; el resto de tu tráfico no cambia.

## 4. VMware (compañeros)

- Sirve VMware Workstation o Player. Crear la VM igual que en 3.3 con las mismas especificaciones.
- Adaptador 1 = **NAT**; añadir un segundo adaptador = **Host-only**. VMware crea por defecto sus redes virtuales para esos modos; el rango de IP **depende de cada instalación**, así que cada uno debe leer la IP real de su VM con `ip -br -4 addr` (no copiar la de otro compañero).
- Cliente de prueba:
  - **Anfitrión Windows/macOS:** instalar la app oficial *WireGuard* e importar un túnel vacío; copiar el contenido de configuración que genera el procedimiento manual de `docs/ADM001-servidor-wireguard.md` (sección 4.2).
  - **Anfitrión Linux:** igual que 3.5.

## 5. Snapshot (punto de restauración)

Con la VM terminada y verificada, tomar un snapshot para poder volver sin reinstalar:
- VirtualBox: *Máquina → Tomar instantánea*, o `VBoxManage snapshot "vpn-servidor" take base-ADM001`.
- VMware: *VM → Snapshot → Take Snapshot*.

Nombre sugerido: `base-ADM001`.

## 6. Checklist: entorno listo
- [ ] La VM arranca y tiene Internet (`ping -c 2 archive.ubuntu.com`).
- [ ] `ip -br -4 addr` muestra una IP en la red solo-anfitrión.
- [ ] El anfitrión hace `ping` a esa IP.
- [ ] `git clone` del repositorio funciona dentro de la VM (o el repo se copió con `scp`).

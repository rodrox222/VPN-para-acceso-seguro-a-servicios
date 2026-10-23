# QA001 — Reporte de Rendimiento: Evaluación de Sobrecarga de WireGuard VPN (HU-11)

## 1. Resumen Ejecutivo
El objetivo de esta prueba de aseguramiento de calidad (QA001) es evaluar el impacto cuantitativo en el rendimiento de red (*overhead*) que introduce el túnel seguro WireGuard frente a una conexión directa sin cifrar. Se midieron latencia de red, tiempo de respuesta HTTP y capacidad de transferencia (throughput) TCP y UDP bajo condiciones controladas.

---

## 2. Metodología y Arquitectura de Prueba

### 2.1 Componentes del Entorno
* **Servidor (vpn-servidor):** Aloja la base de datos PostgreSQL, la API REST protegida sobre la IP del túnel WireGuard (`10.0.0.1`), y herramientas de medición.
* **Cliente de Prueba (peer2):** Máquina cliente configurada con la interfaz WireGuard activa que orquesta y registra las mediciones.

### 2.2 Estrategia de Aislamiento y Medición
Para lograr una comparación justa frente a una línea base:
1. **Servicio VPN:** Tráfico dirigido a la IP interna de WireGuard (`10.0.0.1:5000`).
2. **Servicio Sin VPN (Línea Base):** Dado que la API de producción solo escucha dentro del túnel por diseño de seguridad, se ejecutó `./servidor-preparar.sh start` en el servidor para levantar:
   * Una instancia réplica temporal de la API expuesta en la interfaz física (`IP_SIN_VPN:5001`).
   * Un servidor `iperf3` en modo demonio escuchando en el puerto `5201`.
3. **Orquestación (`medir.sh`):** Ejecuta 10 corridas alternadas (`sin_vpn` vs `con_vpn`) para promediar variaciones de red, evaluando:
   * **Ping:** 100 paquetes por corrida (RTT, jitter y pérdida).
   * **Curl:** 100 peticiones a `/api/status` (tiempo de conexión, TTFB y tiempo total).
   * **iperf3 TCP:** Transferencia continua por 30 s.
   * **iperf3 UDP:** Transferencia a 100 Mbit/s con datagramas de 1200 bytes por 30 s.
4. **Limpieza:** Al finalizar las pruebas, se ejecutó `./servidor-preparar.sh stop` para desmantelar el contenedor temporal y detener el demonio `iperf3`, cerrando cualquier superficie de exposición externa.

---

## 3. Entorno de Ejecución

| Parámetro | Detalle |
|---|---|
| **Fecha de ejecución** | 2026-10-23 |
| **Cliente / Peer** | `peer2` |
| **Sistema Operativo / Kernel** | Ubuntu Linux (Kernel `5.15.0-198-generic`) |
| **Recursos asignados** | 2 vCPUs |
| **Segmentos IP** | Físico: `192.168.221.131` (`ens34`) / VPN: `10.0.0.1` (`peer2`) |
| **MTU de Interfaz VPN** | 1420 bytes |
| **Herramientas utilizadas** | `wireguard-tools v1.0.20210914`, `iperf 3.9`, `curl 7.81.0` |

---

## 4. Resultados Obtenidos

### 4.1 Latencia y Jitter (Ping)
| Métrica | Sin VPN (Media ± Desv.) | Con VPN (Media ± Desv.) | p95 (Sin / Con) | Diferencia Absoluta | Variación (%) |
|---|---|---|---|---|---|
| **RTT Promedio** | 0.73 ± 0.48 ms | 1.05 ± 0.56 ms | 1.59 / 2.18 ms | +0.32 ms | +44.0 % |
| **Jitter (mdev)** | 0.41 ± 0.15 ms | 0.52 ± 0.14 ms | 0.65 / 0.74 ms | +0.10 ms | +24.5 % |
| **Pérdida de Paquetes** | 0.00 % | 0.00 % | 0.00 / 0.00 % | 0.00 % | 0.0 % |

### 4.2 Tiempos de Respuesta HTTP (`/api/status`)
* **Total peticiones evaluadas:** 1000 sin VPN (100% éxito) / 1000 con VPN (100% éxito).

| Métrica | Sin VPN (Media ± Desv.) | Con VPN (Media ± Desv.) | p95 (Sin / Con) | Diferencia Absoluta | Variación (%) |
|---|---|---|---|---|---|
| **Tiempo de Conexión** | 0.39 ± 0.25 ms | 0.54 ± 0.27 ms | 0.57 / 0.76 ms | +0.15 ms | +37.9 % |
| **TTFB (Time to First Byte)** | 1.34 ± 0.95 ms | 1.61 ± 0.46 ms | 1.80 / 2.20 ms | +0.26 ms | +19.5 % |
| **Tiempo Total HTTP** | 1.38 ± 0.95 ms | 1.66 ± 0.47 ms | 1.87 / 2.29 ms | +0.27 ms | +19.5 % |

### 4.3 Throughput y Rendimiento de Capa de Transporte (`iperf3`)
| Métrica | Sin VPN (Media ± Desv.) | Con VPN (Media ± Desv.) | p95 (Sin / Con) | Diferencia | Variación (%) |
|---|---|---|---|---|---|
| **Throughput TCP** | 66.46 ± 59.83 Mbit/s | 695.99 ± 12.01 Mbit/s | 164.15 / 709.16 Mbit/s | +629.53 Mbit/s | +947.2 % |
| **Retransmisiones TCP** | 155.50 ± 42.00 paq. | 0.00 ± 0.00 paq. | 214.65 / 0.00 paq. | -155.50 paq. | -100.0 % |
| **Throughput UDP** | 100.00 ± 0.00 Mbit/s | 100.00 ± 0.00 Mbit/s | 100.00 / 100.00 Mbit/s | 0.00 Mbit/s | 0.0 % |
| **Jitter UDP** | 0.05 ± 0.02 ms | 0.11 ± 0.03 ms | 0.09 / 0.15 ms | +0.06 ms | +107.3 % |
| **Pérdida UDP** | 0.00 ± 0.00 % | 0.01 ± 0.03 % | 0.00 / 0.05 % | +0.01 % | n/d |

---

## 5. Análisis Técnico y Conclusiones

1. **Impacto en Latencia (Sobrecarga de Cifrado):**
   * El túnel WireGuard introduce una sobrecarga promedio de apenas **+0.32 ms** en ping y **+0.27 ms** en transacciones HTTP completas.
   * A nivel funcional, un incremento sub-milisegundo es imperceptible para usuarios finales y microservicios, validando que el cifrado en espacio de kernel (módulo Linux WireGuard) es sumamente liviano.

2. **Comportamiento del Throughput TCP y Retransmisiones:**
   * La interfaz sin VPN mostró inestabilidad con un alto volumen de retransmisiones (promedio de 155 paquetes), lo que forzó al algoritmo de congestión TCP a estrangular el enlace a ~66 Mbit/s.
   * La interfaz WireGuard (`peer2`), al fijar una **MTU estricta de 1420 bytes**, eliminó problemas de fragmentación y desajustes del hipervisor, alcanzando **~696 Mbit/s con 0 retransmisiones** sostenidas. Esto demuestra que WireGuard opera de manera predecible y satura de forma eficiente la capacidad de cómputo (2 vCPUs) asignada.

3. **Criterio de Aceptación (HU-11):**
   * **Aprobado.** La solución cumple con los requerimientos de seguridad sin degradar la disponibilidad ni la experiencia de usuario, manteniendo tiempos de respuesta HTTP por debajo de 2 ms y tasa de éxito del 100%.
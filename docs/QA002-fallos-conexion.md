# Historia de Usuario 12 (QA002): Pruebas de Comportamiento ante Fallos de Conexión

## 1. Descripción
Evaluación experimental de la resiliencia y estabilidad del túnel WireGuard bajo condiciones de degradación de red física (pérdida progresiva de paquetes mediante `tc netem`) e interrupción abrupta de la interfaz virtual (`wg0`), analizando el impacto sobre el transporte ICMP y la disponibilidad del servicio telemático API REST.

---

## 2. Metodología de Pruebas
1. **Prueba A (Pérdida Progresiva de Paquetes):** Se manipuló la cola de salida de la interfaz física del servidor (`ens34`) mediante la herramienta de control de tráfico del kernel de Linux (`tc qdisc add dev ens34 root netem loss X%`), evaluando niveles de 5%, 10%, 30% y 50%.
2. **Prueba B (Caída Abrupta y Reconexión):** Se forzó la desconexión total de la interfaz VPN del servidor (`sudo ip link set wg0 down`) durante un flujo continuo de tráfico ICMP desde el cliente Windows, reactivándola posteriormente (`sudo ip link set wg0 up`) para medir la latencia de recuperación.

---

## 3. Matriz de Resultados Experimentales

| Escenario / Nivel | Pérdida Inducida | Pérdida Observada (ICMP) | Latencia Media (RTT) | Estado API REST (`/api/status`) | Comportamiento del Túnel WireGuard |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Línea Base** | 0% | 0% (0/20) | 1 ms | `HTTP 200 OK` | Operación óptima y fluida. |
| **Degradación Leve** | 5% | 0% (0/20) | <1 ms | `HTTP 200 OK` | Sin impacto perceptible en ráfagas cortas. |
| **Degradación Moderada** | 10% | 5% (1/20) | <1 ms | `HTTP 200 OK` | Retransmisión TCP transparente. |
| **Degradación Severa** | 30% | 35% (7/20) | <1 ms | `HTTP 200 OK` | Pérdidas ICMP visibles; la API se mantiene accesible. |
| **Degradación Crítica** | 50% | 55% (11/20) | <1 ms | `HTTP 200 OK` | Conexión inestable pero funcional vía retransmisiones. |
| **Caída Abrupta** | 100% | 17% (en ráfaga continua) | Inmediata | Timeout transitorio | **Recuperación inmediata (<1s).** Arquitectura *stateless* sin renegociación manual. |

---

## 4. Conclusiones Técnicas
- **Resiliencia sobre UDP:** Al operar encapsulado en datagramas UDP (puerto 51820), WireGuard no arrastra la sobrecarga de control de flujo en la capa de túnel, delegando la recuperación de paquetes perdidos a la capa de transporte interna (TCP de la API REST).
- **Roaming y Reconexión Stateless:** La recuperación ante caídas es automática e inmediata. A diferencia de soluciones basadas en sesiones tradicionales (OpenVPN/IPsec), WireGuard reanuda el cifrado y enrutamiento en cuanto el socket vuelve a estar disponible sin necesidad de renegociar claves criptográficas.

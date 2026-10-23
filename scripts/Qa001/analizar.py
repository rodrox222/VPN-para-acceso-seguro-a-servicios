#!/usr/bin/env python3
"""QA001 / HU-11 — Procesa los datos crudos de medir.sh.

Uso:  python3 analizar.py <carpeta_de_resultados>

Lee <carpeta>/raw/{sin_vpn,con_vpn}/ y genera en <carpeta>:
  resumen.csv   tabla comparativa (media, desviación, p95, diferencia con VPN)
  resumen.md    la misma tabla en Markdown + lectura rápida + referencias del estado del arte
  grafico_*.png gráficos (solo si matplotlib está instalado: pip install matplotlib)

Solo usa la biblioteca estándar de Python (matplotlib es opcional).
"""
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

ESCENARIOS = ("sin_vpn", "con_vpn")
NAN = float("nan")

RE_TIME = re.compile(r"time=([\d.]+) ms")
RE_LOSS = re.compile(r"([\d.]+)% packet loss")
RE_RTT = re.compile(r"= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms")


# ----------------------------------------------------------------- estadísticas
def media(v):
    return statistics.fmean(v) if v else NAN


def desv(v):
    return statistics.stdev(v) if len(v) > 1 else (0.0 if v else NAN)


def percentil(v, p):
    if not v:
        return NAN
    s = sorted(v)
    k = (len(s) - 1) * p / 100
    f, c = math.floor(k), math.ceil(k)
    return s[int(k)] if f == c else s[f] + (s[c] - s[f]) * (k - f)


def stats(v):
    return {
        "n": len(v), "media": media(v), "desv": desv(v), "p95": percentil(v, 95),
        "min": min(v) if v else NAN, "max": max(v) if v else NAN,
    }


# ------------------------------------------------------------------- lectura
def vacio():
    return {k: [] for k in (
        "ping_rtt", "ping_jitter", "ping_loss",
        "curl_connect", "curl_ttfb", "curl_total",
        "tcp_mbps", "tcp_retr", "udp_mbps", "udp_jitter", "udp_loss")} | {"curl_ok": 0, "curl_n": 0, "corridas": 0}


def leer_ping(path, d):
    txt = path.read_text(errors="replace")
    d["ping_rtt"] += [float(x) for x in RE_TIME.findall(txt)]
    m = RE_LOSS.search(txt)
    if m:
        d["ping_loss"].append(float(m.group(1)))
    m = RE_RTT.search(txt)
    if m:
        d["ping_jitter"].append(float(m.group(4)))  # mdev


def leer_curl(path, d):
    with path.open() as fh:
        for fila in csv.DictReader(fh):
            d["curl_n"] += 1
            if fila["http_code"] == "200":
                d["curl_ok"] += 1
                d["curl_connect"].append(float(fila["connect_s"]) * 1000)
                d["curl_ttfb"].append(float(fila["ttfb_s"]) * 1000)
                d["curl_total"].append(float(fila["total_s"]) * 1000)


def leer_json(path):
    try:
        j = json.loads(path.read_text())
    except (ValueError, OSError):
        return None
    return None if "error" in j or "end" not in j else j["end"]


def leer_tcp(path, d):
    end = leer_json(path)
    if end:
        d["tcp_mbps"].append(end["sum_received"]["bits_per_second"] / 1e6)
        retr = end.get("sum_sent", {}).get("retransmits")
        if retr is not None:
            d["tcp_retr"].append(float(retr))


def leer_udp(path, d):
    end = leer_json(path)
    if end:
        s = end["sum"]
        d["udp_mbps"].append(s["bits_per_second"] / 1e6)
        d["udp_jitter"].append(s.get("jitter_ms", NAN))
        d["udp_loss"].append(s.get("lost_percent", NAN))


def cargar(carpeta):
    datos = {}
    for esc in ESCENARIOS:
        d = vacio()
        raw = carpeta / "raw" / esc
        if not raw.is_dir():
            sys.exit(f"ERROR: no existe {raw}")
        d["corridas"] = len(list(raw.glob("run*_ping.txt")))
        for p in sorted(raw.glob("run*_ping.txt")):
            leer_ping(p, d)
        for p in sorted(raw.glob("run*_curl.csv")):
            leer_curl(p, d)
        for p in sorted(raw.glob("run*_tcp.json")):
            leer_tcp(p, d)
        for p in sorted(raw.glob("run*_udp.json")):
            leer_udp(p, d)
        datos[esc] = d
    return datos


# ------------------------------------------------------------------ resumen
# (clave, nombre, unidad, "menor"|"mayor" = qué valor es mejor)
METRICAS = [
    ("ping_rtt", "Ping: RTT", "ms", "menor"),
    ("ping_jitter", "Ping: jitter (mdev por corrida)", "ms", "menor"),
    ("ping_loss", "Ping: pérdida de paquetes", "%", "menor"),
    ("curl_connect", "HTTP: tiempo de conexión", "ms", "menor"),
    ("curl_ttfb", "HTTP: tiempo al primer byte", "ms", "menor"),
    ("curl_total", "HTTP: tiempo total", "ms", "menor"),
    ("tcp_mbps", "iperf3 TCP: throughput", "Mbit/s", "mayor"),
    ("tcp_retr", "iperf3 TCP: retransmisiones", "paquetes", "menor"),
    ("udp_mbps", "iperf3 UDP: throughput", "Mbit/s", "mayor"),
    ("udp_jitter", "iperf3 UDP: jitter", "ms", "menor"),
    ("udp_loss", "iperf3 UDP: pérdida", "%", "menor"),
]


def limpiar(v):
    return [x for x in v if not math.isnan(x)]


def comparar(datos):
    filas = []
    for clave, nombre, unidad, mejor in METRICAS:
        s = stats(limpiar(datos["sin_vpn"][clave]))
        c = stats(limpiar(datos["con_vpn"][clave]))
        hay = bool(s["n"] and c["n"])
        delta = c["media"] - s["media"] if hay else NAN
        pct = delta / s["media"] * 100 if hay and s["media"] != 0 else NAN
        filas.append({"clave": clave, "nombre": nombre, "unidad": unidad, "mejor": mejor,
                      "sin": s, "con": c, "delta": delta, "pct": pct})
    return filas


def fmt(x, dec=2):
    return "n/d" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{dec}f}"


def fmt_pct(x):
    return "n/d" if math.isnan(x) else f"{x:+.1f} %"


def escribir_csv(filas, destino):
    with destino.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["metrica", "unidad", "n_sin", "media_sin", "desv_sin", "p95_sin",
                    "n_con", "media_con", "desv_con", "p95_con", "diferencia_abs", "diferencia_pct"])
        for f in filas:
            w.writerow([f["nombre"], f["unidad"],
                        f["sin"]["n"], fmt(f["sin"]["media"], 4), fmt(f["sin"]["desv"], 4), fmt(f["sin"]["p95"], 4),
                        f["con"]["n"], fmt(f["con"]["media"], 4), fmt(f["con"]["desv"], 4), fmt(f["con"]["p95"], 4),
                        fmt(f["delta"], 4), fmt(f["pct"], 2)])


def tabla_md(filas, claves):
    sel = [f for f in filas if f["clave"] in claves]
    out = ["| Métrica | Unidad | Sin VPN (media ± desv.) | Con VPN (media ± desv.) | p95 sin / con | Diferencia | Variación |",
           "|---|---|---|---|---|---|---|"]
    for f in sel:
        s, c = f["sin"], f["con"]
        out.append(f"| {f['nombre']} | {f['unidad']} | {fmt(s['media'])} ± {fmt(s['desv'])} | "
                   f"{fmt(c['media'])} ± {fmt(c['desv'])} | {fmt(s['p95'])} / {fmt(c['p95'])} | "
                   f"{fmt(f['delta'])} | {fmt_pct(f['pct'])} |")
    return "\n".join(out)


def lectura_rapida(filas, datos):
    por = {f["clave"]: f for f in filas}
    out = []
    for clave, etiqueta in (("tcp_mbps", "TCP"), ("udp_mbps", "UDP")):
        a, b = len(datos["sin_vpn"][clave]), len(datos["con_vpn"][clave])
        esperadas = max(datos["sin_vpn"]["corridas"], datos["con_vpn"]["corridas"])
        if a < esperadas or b < esperadas:
            out.append(f"- ⚠ **iperf3 {etiqueta}:** solo {a} corridas válidas sin VPN y {b} con VPN de {esperadas}. "
                       f"Revise los archivos `run*_{etiqueta.lower()}.err/.json` en `raw/`: las corridas fallidas se descartan.")
    r = por["ping_rtt"]
    if r["sin"]["n"] and r["con"]["n"]:
        out.append(f"- **Latencia (ping):** el RTT medio pasó de {fmt(r['sin']['media'])} ms a {fmt(r['con']['media'])} ms "
                   f"({fmt(r['delta'])} ms, {fmt_pct(r['pct'])}).")
    t = por["curl_total"]
    if t["sin"]["n"] and t["con"]["n"]:
        out.append(f"- **Tiempo de respuesta HTTP total:** de {fmt(t['sin']['media'])} ms a {fmt(t['con']['media'])} ms "
                   f"({fmt_pct(t['pct'])}).")
    tc = por["tcp_mbps"]
    if tc["sin"]["n"] and tc["con"]["n"]:
        out.append(f"- **Throughput TCP:** de {fmt(tc['sin']['media'], 1)} Mbit/s a {fmt(tc['con']['media'], 1)} Mbit/s "
                   f"({fmt_pct(tc['pct'])}).")
    for esc, etiqueta in (("sin_vpn", "sin VPN"), ("con_vpn", "con VPN")):
        d = datos[esc]
        if d["curl_n"] and d["curl_ok"] < d["curl_n"]:
            out.append(f"- Peticiones HTTP fallidas {etiqueta}: {d['curl_n'] - d['curl_ok']} de {d['curl_n']}.")
    return "\n".join(out) if out else "- (sin datos suficientes)"


REFERENCIAS = """| Estudio | Qué comparó | Resultado reportado |
|---|---|---|
| Donenfeld (2017) | WireGuard vs OpenVPN e IPsec | ~1 Gbit/s, menor latencia y menor uso de CPU |
| Osswald et al. (2021) | WireGuard vs DTLS y QUIC | Menor sobrecarga de protocolo y mejor throughput |
| Papadogiannakis et al. (2020) | WireGuard vs OpenVPN en AWS EC2 t2.micro | ~3x de throughput y ~50 % menos latencia que OpenVPN |

> **Cómo leer la comparación:** esos estudios comparan WireGuard contra *otras VPN*; esta medición lo compara
> contra *no usar VPN*. No son la misma pregunta: aquí se mide el **costo** de WireGuard sobre la línea base.
> Lo comparable con la literatura es el orden de magnitud (¿el throughput se acerca a la capacidad del enlace?
> ¿el sobrecosto de latencia es pequeño?), no el factor 3x ni el 50 %. Además, un entorno local (VM sobre red
> virtual) no es comparable con EC2 por Internet: ver *Limitaciones* en la documentación."""


def escribir_md(carpeta, filas, datos):
    entorno = (carpeta / "entorno.txt")
    entorno_txt = entorno.read_text() if entorno.exists() else "(sin entorno.txt)"
    md = f"""# QA001 — Resultados de rendimiento con y sin VPN

Carpeta de datos: `{carpeta.name}` · corridas: {datos['sin_vpn']['corridas']} (sin VPN) / {datos['con_vpn']['corridas']} (con VPN)

## Lectura rápida

{lectura_rapida(filas, datos)}

## Latencia

{tabla_md(filas, ("ping_rtt", "ping_jitter", "ping_loss"))}

## Tiempos de respuesta HTTP (`/api/status`)

{tabla_md(filas, ("curl_connect", "curl_ttfb", "curl_total"))}

Peticiones correctas: sin VPN {datos['sin_vpn']['curl_ok']}/{datos['sin_vpn']['curl_n']} ·
con VPN {datos['con_vpn']['curl_ok']}/{datos['con_vpn']['curl_n']}

## Throughput (iperf3)

{tabla_md(filas, ("tcp_mbps", "tcp_retr", "udp_mbps", "udp_jitter", "udp_loss"))}

*Variación = (con VPN − sin VPN) / sin VPN. En latencia, un valor positivo es peor; en throughput, un valor negativo es peor.
`n/d` aparece cuando la línea base es 0 (por ejemplo, 0 % de pérdida) o no hay datos.*

## Contraste con el estado del arte

{REFERENCIAS}

## Entorno de la medición

```
{entorno_txt.strip()}
```
"""
    (carpeta / "resumen.md").write_text(md)


def graficos(carpeta, filas):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("Aviso: matplotlib no está instalado; se omiten los gráficos (pip install matplotlib).")
        return

    def barras(claves, titulo, ylabel, archivo):
        sel = [f for f in filas if f["clave"] in claves and f["sin"]["n"] and f["con"]["n"]]
        if not sel:
            return
        fig, ax = plt.subplots(figsize=(7, 4))
        ancho = 0.35
        xs = range(len(sel))
        ax.bar([x - ancho / 2 for x in xs], [f["sin"]["media"] for f in sel], ancho,
               yerr=[f["sin"]["desv"] for f in sel], capsize=3, label="Sin VPN")
        ax.bar([x + ancho / 2 for x in xs], [f["con"]["media"] for f in sel], ancho,
               yerr=[f["con"]["desv"] for f in sel], capsize=3, label="Con VPN (WireGuard)")
        ax.set_xticks(list(xs))
        ax.set_xticklabels([f["nombre"].split(": ")[-1] for f in sel])
        ax.set_ylabel(ylabel)
        ax.set_title(titulo)
        ax.legend()
        fig.tight_layout()
        fig.savefig(carpeta / archivo, dpi=150)
        plt.close(fig)

    barras(("ping_rtt", "curl_connect", "curl_ttfb", "curl_total"), "Latencia (media ± desv.)", "ms", "grafico_latencia.png")
    barras(("tcp_mbps", "udp_mbps"), "Throughput (media ± desv.)", "Mbit/s", "grafico_throughput.png")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    carpeta = Path(sys.argv[1]).resolve()
    if not (carpeta / "raw").is_dir():
        sys.exit(f"ERROR: {carpeta} no contiene la carpeta raw/")
    datos = cargar(carpeta)
    filas = comparar(datos)
    escribir_csv(filas, carpeta / "resumen.csv")
    escribir_md(carpeta, filas, datos)
    graficos(carpeta, filas)
    print(f"Generado: {carpeta / 'resumen.md'}")
    print(f"Generado: {carpeta / 'resumen.csv'}")


if __name__ == "__main__":
    main()

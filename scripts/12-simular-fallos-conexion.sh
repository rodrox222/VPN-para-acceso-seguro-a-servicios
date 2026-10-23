#!/usr/bin/env bash
set -euo pipefail

INTERFACE="ens34"
LOG_DIR="evidencias/QA002"
mkdir -p "$LOG_DIR"

echo "=== INICIANDO SIMULACIÓN COMPLETA DE PÉRDIDA DE PAQUETES (HU-12) ==="

# Limpiar cualquier regla previa
sudo tc qdisc del dev "$INTERFACE" root 2>/dev/null || true

niveles=(5 10 30 50 70 90)

for loss in "${niveles[@]}"; do
    echo -e "\n[!] Aplicando pérdida de paquetes: $loss% en la interfaz $INTERFACE"
    sudo tc qdisc add dev "$INTERFACE" root netem loss $loss%
    
    echo ">> El servidor está simulando $loss% de pérdida física."
    echo ">> VE A POWERSHELL EN WINDOWS Y EJECUTA:"
    echo ">> 1. ping -n 20 10.0.0.1"
    echo ">> 2. curl.exe -i --connect-timeout 3 http://10.0.0.1:5000/api/status"
    echo ">> Al terminar en Windows, presiona ENTER aquí para avanzar al siguiente nivel..."
    read
    
    # Limpiamos la regla para el siguiente ciclo
    sudo tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
done

echo -e "\n=== SIMULACIÓN COMPLETADA. Red restaurada a la normalidad. ==="

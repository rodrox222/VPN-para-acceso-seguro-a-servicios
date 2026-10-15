from flask import Flask, jsonify, request
from datetime import datetime, timezone
import socket

app = Flask(__name__)

@app.route('/', methods=['GET'])
def index():
    return jsonify({
        "service": "API REST Telematica - Grupo 35",
        "status": "online",
        "vpn_interface": "wg0 (10.0.0.1:5000)",
        "client_ip": request.remote_addr,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200

@app.route('/api/status', methods=['GET'])
def status():
    return jsonify({
        "status": "OK",
        "message": "Acceso seguro verificado a traves del tunel WireGuard",
        "hostname": socket.gethostname(),
        "server_ip": "10.0.0.1",
        "client_ip": request.remote_addr,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200

@app.route('/api/echo', methods=['GET', 'POST'])
def echo():
    payload = request.get_json(silent=True) or request.args.to_dict() or {}
    return jsonify({
        "method": request.method,
        "client_ip": request.remote_addr,
        "received_data": payload,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }), 200

if __name__ == '__main__':
    app.run(host='10.0.0.1', port=5000)

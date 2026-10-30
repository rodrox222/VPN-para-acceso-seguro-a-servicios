#!/usr/bin/env bash
# DEV008 / HU19 - Integra la interfaz web en el repositorio con los mínimos cambios:
#   - api/app.py:     registra el blueprint de la interfaz (2 líneas)
#   - api/Dockerfile: copia ui.py y la carpeta static/ a la imagen (2 líneas)
# Es idempotente: se puede ejecutar varias veces. Ejecutar desde la raíz del repositorio.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="api/app.py"
DOCKERFILE="api/Dockerfile"

for f in "$APP" "$DOCKERFILE" api/ui.py api/static/index.html; do
  [[ -f "$f" ]] || { echo "[ERROR] Falta $f. ¿Copiaste el paquete en la raíz del repositorio?" >&2; exit 1; }
done

# ---- app.py
if grep -q 'register_blueprint(ui_bp)' "$APP"; then
  echo "[INFO] $APP ya registra la interfaz."
else
  grep -q '^app = Flask(__name__)' "$APP" || { echo "[ERROR] No encuentro 'app = Flask(__name__)' en $APP; añade a mano:  from ui import ui_bp  /  app.register_blueprint(ui_bp)" >&2; exit 1; }
  sed -i '/^app = Flask(__name__)/a from ui import ui_bp          # HU19: interfaz web en /ui/\napp.register_blueprint(ui_bp)' "$APP"
  echo "[OK] $APP: interfaz registrada."
fi

# ---- Dockerfile
if grep -q 'ui\.py' "$DOCKERFILE"; then
  echo "[INFO] $DOCKERFILE ya copia la interfaz."
elif grep -q '^COPY app.py repository.py repository_pg.py \./' "$DOCKERFILE"; then
  sed -i 's|^COPY app.py repository.py repository_pg.py \./|COPY app.py repository.py repository_pg.py ui.py ./\nCOPY static ./static|' "$DOCKERFILE"
  echo "[OK] $DOCKERFILE: se copian ui.py y static/."
else
  echo "[AVISO] No reconozco la línea COPY de $DOCKERFILE. Añade a mano:" >&2
  echo "          COPY ui.py ./" >&2
  echo "          COPY static ./static" >&2
fi

echo
echo "------ Cambios ------"
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  git --no-pager diff -- "$APP" "$DOCKERFILE" || true
else
  grep -n 'ui_bp' "$APP" || true
  grep -n 'ui.py\|static' "$DOCKERFILE" || true
fi
echo "---------------------"
echo "[SIGUIENTE] cd api && pytest   y luego   ./scripts/08-desplegar-api.sh"

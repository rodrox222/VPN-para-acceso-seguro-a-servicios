FROM python:3.10-slim

# Instalar curl para el HEALTHCHECK
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Crear usuario sin privilegios (uid 10001) según los parámetros de diseño
RUN useradd -u 10001 -m appuser

WORKDIR /app

# Instalar dependencias
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar código de la app (HU-08: ahora incluye la capa de datos)
COPY app.py repository.py ./

# Cambiar propietario y usar el usuario sin privilegios
RUN chown -R appuser:appuser /app
USER 10001

# Definir Healthcheck
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://127.0.0.1:5000/api/status || exit 1

# Iniciar Gunicorn.
# IMPORTANTE (HU-08): 1 solo worker porque los datos viven en memoria; con varios
# workers cada uno tendría sus propios datos. En HU-09 (PostgreSQL) se puede subir.
CMD ["gunicorn", "-w", "1", "--threads", "4", "-b", "0.0.0.0:5000", "app:app"]

CREATE TABLE usuarios (
    id             SERIAL PRIMARY KEY,
    nombre         VARCHAR(100) NOT NULL CHECK (char_length(nombre) BETWEEN 2 AND 100),
    email          VARCHAR(120) NOT NULL,
    rol            TEXT NOT NULL DEFAULT 'cliente' CHECK (rol IN ('cliente', 'tecnico')),
    password_hash  VARCHAR(255) NOT NULL DEFAULT '',
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS usuarios_email_unico ON usuarios (lower(email));
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255) NOT NULL DEFAULT '';

CREATE TABLE tickets (
    id             SERIAL PRIMARY KEY,
    titulo         VARCHAR(120) NOT NULL CHECK (char_length(titulo) BETWEEN 3 AND 120),
    descripcion    VARCHAR(1000) NOT NULL DEFAULT '',
    prioridad      TEXT NOT NULL DEFAULT 'media'  CHECK (prioridad IN ('baja', 'media', 'alta')),
    estado         TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto', 'en_progreso', 'cerrado')),
    usuario_id     INTEGER NOT NULL REFERENCES usuarios (id) ON DELETE RESTRICT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX tickets_usuario_idx ON tickets (usuario_id);
CREATE INDEX tickets_estado_idx  ON tickets (estado);

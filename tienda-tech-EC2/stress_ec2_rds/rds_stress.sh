#!/usr/bin/env bash
set -euo pipefail

#############################################
# RDS MySQL Stress v4.1 (60s total) + Reco
# Fix: timeout + MYSQL_PWD usando bash -c
#############################################

# ===== Configuración (edita aquí) =====
HOST="database-2.cb2qows604dx.us-east-1.rds.amazonaws.com"
PORT=3306
USER="admin"                   # Cambiar por tu usuario
PASS="tiendatech1234"          # cambiar por tu password
DBNAME="tienda_tecnologica"   # base de datos creada en RDS para la app

CURRENT_CLASS="db.t4g.micro"
TARGET_CLASS="db.t4g.small"

# ===== Duración total (segundos) =====
TOTAL_SECONDS=70

# ===== Carga / parámetros =====
BASE_CONC=5
BASE_QUERIES=50

# Opción A: HOG bajo para dejar aire (max_connections=60 -> 55-58)
HOG_CONN=55

# STORM
STORM_CONC="80,120,160"
STORM_QUERIES=80000

CONNECT_TIMEOUT=5

#############################################
# Helpers
#############################################
TS="$(date +%Y%m%d_%H%M%S)"
SAFE_HOST="${HOST//./_}"
LOG="mysqlstress_${SAFE_HOST}_${TS}.log"
REPORT="recomendacion_mysqlstress_${SAFE_HOST}_${TS}.md"

MYSQL_BASE=(mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER" "-D$DBNAME" --connect-timeout="$CONNECT_TIMEOUT" -N -s)

HOG_PIDS=()
cleanup() {
  if ((${#HOG_PIDS[@]} > 0)); then
    kill "${HOG_PIDS[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log() { echo -e "$*" | tee -a "$LOG"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Falta comando requerido: $1"; exit 1; }; }

#############################################
# Pre-check
#############################################
require_cmd mysql
require_cmd mysqlslap
require_cmd awk
require_cmd grep
require_cmd timeout
require_cmd bash

START_EPOCH="$(date +%s)"
END_EPOCH=$((START_EPOCH + TOTAL_SECONDS))

log "============================================================"
log "RDS MySQL Stress v4.1 (60s total) + Recomendación"
log "Fecha: $TS"
log "Endpoint: $HOST:$PORT | DB: $DBNAME"
log "Instancia actual: $CURRENT_CLASS | Propuesta: $TARGET_CLASS"
log "TOTAL_SECONDS=$TOTAL_SECONDS"
log "HOG: conexiones=$HOG_CONN (deja aire)"
log "STORM: conc=$STORM_CONC | queries=$STORM_QUERIES (por el tiempo restante)"
log "Log: $LOG"
log "============================================================"
log ""

# Leer max_connections
set +e
MAX_CONN=$(MYSQL_PWD="$PASS" "${MYSQL_BASE[@]}" -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2}' | head -n1)
set -e
if [[ -n "${MAX_CONN:-}" ]]; then
  log "max_connections (RDS): $MAX_CONN"
else
  log "max_connections: (no se pudo leer; seguimos igual)"
fi
log ""

#############################################
# [0] Baseline corto
#############################################
log "[0/3] Baseline (rápido)"
MYSQL_PWD="$PASS" mysqlslap \
  --host="$HOST" --port="$PORT" \
  --user="$USER" --password="$PASS" \
  --concurrency="$BASE_CONC" \
  --iterations=1 \
  --number-of-queries="$BASE_QUERIES" \
  --auto-generate-sql \
  | tee -a "$LOG" || true
log ""

#############################################
# [1] HOG hasta el final
#############################################
HOG_SLEEP_SEC=$((END_EPOCH - $(date +%s)))
if (( HOG_SLEEP_SEC < 15 )); then HOG_SLEEP_SEC=15; fi

log "[1/3] HOG: abriendo $HOG_CONN conexiones sostenidas por ~${HOG_SLEEP_SEC}s"
log "TIP: refresca tu app web: deberías ver lentitud/errores intermitentes o que a ratos NO cargan datos."
log ""

set +e
for i in $(seq 1 "$HOG_CONN"); do
  (
    MYSQL_PWD="$PASS" "${MYSQL_BASE[@]}" -e "SELECT SLEEP(${HOG_SLEEP_SEC});" >/dev/null 2>&1
  ) &
  HOG_PIDS+=("$!")
  if (( i % 25 == 0 )); then sleep 0.2; fi
done
set -e

sleep 2
set +e
HOG_CHECK_OUT="$(MYSQL_PWD="$PASS" "${MYSQL_BASE[@]}" -e "SELECT 1;" 2>&1)"
HOG_CHECK_RC=$?
set -e

if echo "$HOG_CHECK_OUT" | grep -qi "too many connections"; then
  log "⚠️ HOG: se observa saturación (Too many connections)."
elif (( HOG_CHECK_RC != 0 )); then
  log "⚠️ HOG: error de conexión (rc=$HOG_CHECK_RC): $HOG_CHECK_OUT"
else
  log "✅ HOG activo (hay aire; aún permite algunas conexiones)."
fi
log ""

#############################################
# [2] STORM por el tiempo restante
#############################################
NOW_EPOCH="$(date +%s)"
STORM_WINDOW=$((END_EPOCH - NOW_EPOCH - 3))
if (( STORM_WINDOW < 10 )); then STORM_WINDOW=10; fi

log "[2/3] STORM: ejecutando mysqlslap por ~${STORM_WINDOW}s (con HOG activo)"
log "Si mysqlslap falla por conexiones, también cuenta como evidencia."
log ""

set +e
STORM_OUT="$(timeout "${STORM_WINDOW}s" bash -c "
  export MYSQL_PWD='$PASS';
  mysqlslap \
    --host='$HOST' --port='$PORT' \
    --user='$USER' --password='$PASS' \
    --concurrency='$STORM_CONC' \
    --number-of-queries='$STORM_QUERIES' \
    --auto-generate-sql \
    --engine=InnoDB
" 2>&1)"
STORM_RC=$?
set -e

echo "$STORM_OUT" | tee -a "$LOG"
log ""

#############################################
# [3] Esperar hasta 60s y soltar HOG
#############################################
NOW_EPOCH="$(date +%s)"
if (( NOW_EPOCH < END_EPOCH )); then
  sleep $((END_EPOCH - NOW_EPOCH))
fi

cleanup

#############################################
# Análisis y Recomendación (robusta)
#############################################
TOO_MANY_CONN="no"
if echo "${HOG_CHECK_OUT:-}" | grep -qi "too many connections"; then TOO_MANY_CONN="yes"; fi
if echo "${STORM_OUT:-}" | grep -qi "too many connections"; then TOO_MANY_CONN="yes"; fi
if (( STORM_RC != 0 )) && echo "${STORM_OUT:-}" | grep -qi "Error when connecting to server"; then TOO_MANY_CONN="yes"; fi

AVG_SEC=$(echo "$STORM_OUT" | awk -F': ' '/Average number of seconds to run all queries/{print $2}' | head -n1 | awk '{print $1}')
MIN_SEC=$(echo "$STORM_OUT" | awk -F': ' '/Minimum number of seconds to run all queries/{print $2}' | head -n1 | awk '{print $1}')
MAX_SEC=$(echo "$STORM_OUT" | awk -F': ' '/Maximum number of seconds to run all queries/{print $2}' | head -n1 | awk '{print $1}')

RECO_TITLE=""
RECO_BODY=""

if [[ "$TOO_MANY_CONN" == "yes" ]]; then
  RECO_TITLE="❌ HALLAZGO: Saturación de conexiones (Too many connections)"
  RECO_BODY=$(
    cat <<EOF
Durante ~${TOTAL_SECONDS}s se evidenció saturación/rechazo de conexiones a MySQL.
Esto puede provocar que la aplicación web quede “arriba” pero SIN cargar datos (el backend no logra abrir/obtener conexiones).

RECOMENDACIÓN PRINCIPAL:
✅ Escalar verticalmente RDS de $CURRENT_CLASS a $TARGET_CLASS.

ACCIONES COMPLEMENTARIAS:
1) Revisar/ajustar pool de conexiones del backend (Node): límites, timeouts, reintentos y liberación correcta.
2) Optimizar queries (índices, evitar N+1, reducir tiempos de transacción).
3) Revisar en CloudWatch: DatabaseConnections, CPUUtilization, FreeableMemory, Read/WriteLatency.
EOF
  )
else
  RECO_TITLE="⚠️ HALLAZGO: No se detectó saturación explícita de conexiones"
  RECO_BODY=$(
    cat <<EOF
No se detectó “Too many connections” en esta corrida (~${TOTAL_SECONDS}s).

Para hacerlo más visible en la web (max_connections=${MAX_CONN:-N/A}):
- Sube HOG_CONN a 56-58 (dejando 2-4 conexiones libres)
- Aumenta STORM_CONC (ej: "120,160,200") o STORM_QUERIES
EOF
  )
fi

#############################################
# Reporte MD
#############################################
cat > "$REPORT" <<EOF
# Informe de Stress RDS MySQL (v4.1) y Recomendación

**Fecha:** $TS  
**Duración total:** ~${TOTAL_SECONDS}s  
**Endpoint:** $HOST:$PORT  
**DB:** $DBNAME  
**Instancia actual:** $CURRENT_CLASS  
**Instancia propuesta:** $TARGET_CLASS  
**max_connections:** ${MAX_CONN:-N/A}

## Parámetros
- HOG: conexiones=$HOG_CONN | duración aprox=${HOG_SLEEP_SEC}s
- STORM: concurrency=$STORM_CONC | queries=$STORM_QUERIES | ventana aprox=${STORM_WINDOW}s

## Resultados STORM
- RC: $STORM_RC
- Average seconds: ${AVG_SEC:-N/A}s
- Min seconds: ${MIN_SEC:-N/A}s
- Max seconds: ${MAX_SEC:-N/A}s
- Detectó Too many connections: $TOO_MANY_CONN

## $RECO_TITLE
$RECO_BODY

## Archivos
- Log: \`$LOG\`
- Reporte: \`$REPORT\`
EOF

#############################################
# Mostrar recomendación al final
#############################################
log "================ RECOMENDACIÓN FINAL ================"
log "$RECO_TITLE"
log "$RECO_BODY"
log "====================================================="
log ""
log "✅ Listo. Revisa:"
log " - $LOG"
log " - $REPORT"
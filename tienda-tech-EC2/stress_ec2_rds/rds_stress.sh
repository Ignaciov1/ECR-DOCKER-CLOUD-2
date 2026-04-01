#!/usr/bin/env bash
set -euo pipefail

#############################################
# RDS MySQL Stress v4.1 (60s total) + Reco
# Fix: Host y Password actualizados para Ignacio
#############################################

# ===== Configuración (DATOS ACTUALIZADOS) =====
HOST="tienda-tech-db.cp2c6g4g0bpf.us-east-1.rds.amazonaws.com"
PORT=3306
USER="admin"
# Reemplaza 'tu_password_aqui' por la contraseña real que pusiste en Terraform
PASS="db123456789"          
DBNAME="tienda_tecnologica"

CURRENT_CLASS="db.t4g.micro"
TARGET_CLASS="db.t4g.small"

# ===== Duración total (segundos) =====
TOTAL_SECONDS=70

# ===== Carga / parámetros =====
BASE_CONC=5
BASE_QUERIES=50

# HOG_CONN ajustado para forzar el límite de una db.t4g.micro
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
  log "max_connections: (no se pudo leer; verificando conectividad...)"
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
# [1] HOG: Saturación de conexiones
#############################################
HOG_SLEEP_SEC=$((END_EPOCH - $(date +%s)))
if (( HOG_SLEEP_SEC < 15 )); then HOG_SLEEP_SEC=15; fi

log "[1/3] HOG: abriendo $HOG_CONN conexiones sostenidas por ~${HOG_SLEEP_SEC}s"
log "TIP: intenta cargar la web ahora; debería fallar el listado de productos."
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
  log "✅ HOG activo (aún quedan conexiones libres)."
fi
log ""

#############################################
# [2] STORM: Carga de consultas masivas
#############################################
NOW_EPOCH="$(date +%s)"
STORM_WINDOW=$((END_EPOCH - NOW_EPOCH - 3))
if (( STORM_WINDOW < 10 )); then STORM_WINDOW=10; fi

log "[2/3] STORM: ejecutando mysqlslap por ~${STORM_WINDOW}s"
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
# [3] Finalización
#############################################
NOW_EPOCH="$(date +%s)"
if (( NOW_EPOCH < END_EPOCH )); then
  sleep $((END_EPOCH - NOW_EPOCH))
fi

cleanup

#############################################
# Análisis y Recomendación
#############################################
TOO_MANY_CONN="no"
if echo "${HOG_CHECK_OUT:-}" | grep -qi "too many connections"; then TOO_MANY_CONN="yes"; fi
if echo "${STORM_OUT:-}" | grep -qi "too many connections"; then TOO_MANY_CONN="yes"; fi

RECO_TITLE=""
RECO_BODY=""

if [[ "$TOO_MANY_CONN" == "yes" ]]; then
  RECO_TITLE="❌ HALLAZGO: Saturación de conexiones (Too many connections)"
  RECO_BODY=$(
    cat <<EOF
Se evidenció rechazo de conexiones. El backend no podrá obtener datos del RDS bajo esta carga.

RECOMENDACIÓN:
✅ Escalar verticalmente RDS de $CURRENT_CLASS a $TARGET_CLASS.
EOF
  )
else
  RECO_TITLE="⚠️ HALLAZGO: No se detectó saturación crítica"
  RECO_BODY="Aumenta el parámetro HOG_CONN en el script para forzar la caída."
fi

log "================ RECOMENDACIÓN FINAL ================"
log "$RECO_TITLE"
log "$RECO_BODY"
log "====================================================="
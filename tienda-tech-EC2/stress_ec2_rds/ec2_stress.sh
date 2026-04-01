#!/usr/bin/env bash
# ec2_stress_v14.sh
# Amazon Linux 2023 - Stress MEM -> CPU ramp + optional NET + LIVE + HTTP evidence (phase/step)
# FIX v14: evita "pegado al final" matando NET workers antes de wait y evitando wait global en cleanup.
set -Eeuo pipefail

# ---------------------------
# USER CONFIG (override via env vars)
# ---------------------------
URL="${URL:-http://127.0.0.1/}"

# Log naming (change this to rename output log)
LOG_PREFIX="${LOG_PREFIX:-ec2_stress_v14}"

# Phases duration
MEM_PHASE_SEC="${MEM_PHASE_SEC:-60}"
CPU_PHASE_SEC="${CPU_PHASE_SEC:-60}"

# Memory target
MEM_TARGET_PCT="${MEM_TARGET_PCT:-70}"      # target memory usage %
MEM_STEP_MB="${MEM_STEP_MB:-32}"            # allocation step MB
MEM_HEADROOM_MB="${MEM_HEADROOM_MB:-80}"    # keep at least this much "available" MB (best effort)

# CPU ramp by % via stress-ng
CPU_WORKERS="${CPU_WORKERS:-2}"             # t3.micro=2 vCPU (good default)
CPU_LOAD_1="${CPU_LOAD_1:-30}"              # %
CPU_LOAD_2="${CPU_LOAD_2:-60}"              # %
CPU_LOAD_3="${CPU_LOAD_3:-95}"              # %

# Network (curl workers hitting local HTTP)
NET_WORKERS="${NET_WORKERS:-0}"             # raise to 60/120/200 to try to break Nginx
NET_CURL_TIMEOUT="${NET_CURL_TIMEOUT:-2}"   # curl --max-time
NET_CURL_CONNECT_TIMEOUT="${NET_CURL_CONNECT_TIMEOUT:-1}"

# Live status
LIVE_INTERVAL="${LIVE_INTERVAL:-1}"         # seconds (console + for peak calculations)

# HTTP evidence monitor
HTTP_MONITOR_ENABLED="${HTTP_MONITOR_ENABLED:-1}"     # 1=on, 0=off
HTTP_MONITOR_INTERVAL="${HTTP_MONITOR_INTERVAL:-1}"   # seconds
HTTP_FAIL_TIMEOUT="${HTTP_FAIL_TIMEOUT:-2}"           # curl max-time for monitor
HTTP_FAIL_CODE_MIN="${HTTP_FAIL_CODE_MIN:-500}"       # >=500 is fail
HTTP_FAIL_LATENCY_SEC="${HTTP_FAIL_LATENCY_SEC:-2.0}" # >= this counts as "slow/degraded"

# Threshold refs for recommendation
THRESH_CPU_PCT="${THRESH_CPU_PCT:-70}"
THRESH_MEM_PCT="${THRESH_MEM_PCT:-70}"

# ---------------------------
# Internals
# ---------------------------
RUN_DIR="$(pwd)"
TS_START="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${RUN_DIR}/${LOG_PREFIX}_${TS_START}.log"

STATE_FILE="/tmp/${LOG_PREFIX}_state_$$.txt"
SAMPLE_FILE="/tmp/${LOG_PREFIX}_samples_$$.tsv"
HTTP_SAMPLE_FILE="/tmp/${LOG_PREFIX}_http_$$.tsv"
NET_PIDS_FILE="/tmp/${LOG_PREFIX}_netpids_$$.txt"

CURRENT_PHASE="INIT"
CURRENT_STEP="N/A"

# For reporting: when mem target first achieved
MEM_TARGET_REACHED="NO"
MEM_TARGET_TS="N/A"
MEM_TARGET_AT_PCT="N/A"

# ---------------------------
# Helpers
# ---------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  echo "[$(ts)] $*" | tee -a "$LOG_FILE"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing command '$1'. Install it and retry."
    exit 1
  }
}

write_state() {
  printf "PHASE=%s\nSTEP=%s\n" "$CURRENT_PHASE" "$CURRENT_STEP" > "$STATE_FILE"
}

read_state() {
  local p s
  p="$(awk -F= '/^PHASE=/{print $2}' "$STATE_FILE" 2>/dev/null || echo "N/A")"
  s="$(awk -F= '/^STEP=/{print $2}' "$STATE_FILE" 2>/dev/null || echo "N/A")"
  echo "$p" "$s"
}

primary_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true
}

mem_stats_mb() {
  # Returns: used_mb total_mb used_pct avail_mb swap_used_mb
  local used total avail swap
  read -r _ total used _ _ _ avail < <(free -m | awk '/^Mem:/ {print $1,$2,$3,$4,$5,$6,$7}')
  swap="$(free -m | awk '/^Swap:/ {print $3}')"
  local pct
  pct="$(awk -v u="$used" -v t="$total" 'BEGIN{ if(t>0) printf "%.2f", (u/t)*100; else print "0.00"}')"
  echo "$used" "$total" "$pct" "$avail" "$swap"
}

cpu_used_pct_mpstat() {
  local idle used
  idle="$(mpstat 1 1 | awk '/Average/ && $2=="all"{print $NF}' | tail -n1)"
  used="$(awk -v i="$idle" 'BEGIN{printf "%.2f", 100-i}')"
  echo "$used"
}

net_mbps() {
  local iface="$1"
  local rx_path="/sys/class/net/${iface}/statistics/rx_bytes"
  local tx_path="/sys/class/net/${iface}/statistics/tx_bytes"
  [[ -r "$rx_path" && -r "$tx_path" ]] || { echo "0.00 0.00"; return 0; }

  local rx1 tx1 rx2 tx2
  rx1="$(cat "$rx_path")"; tx1="$(cat "$tx_path")"
  sleep 1
  rx2="$(cat "$rx_path")"; tx2="$(cat "$tx_path")"

  local in_bps out_bps in_m out_m
  in_bps=$(( (rx2 - rx1) * 8 ))
  out_bps=$(( (tx2 - tx1) * 8 ))
  in_m="$(awk -v b="$in_bps" 'BEGIN{printf "%.2f", b/1000000}')"
  out_m="$(awk -v b="$out_bps" 'BEGIN{printf "%.2f", b/1000000}')"
  echo "$in_m" "$out_m"
}

stop_net_workers() {
  if [[ -f "$NET_PIDS_FILE" ]]; then
    while read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
    done < "$NET_PIDS_FILE"
  fi
}

cleanup() {
  set +e
  log "Cleanup: deteniendo procesos..."

  # stop net workers
  stop_net_workers

  # stop monitors
  [[ -n "${LIVE_PID:-}" ]] && kill "$LIVE_PID" >/dev/null 2>&1 || true
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" >/dev/null 2>&1 || true

  # stop mem consumer if running
  [[ -n "${MEM_PID:-}" ]] && kill "$MEM_PID" >/dev/null 2>&1 || true

  # FIX v14: NO wait global (evita quedar colgado)
  rm -f "$STATE_FILE" "$NET_PIDS_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------
# Checks
# ---------------------------
need_cmd awk
need_cmd free
need_cmd ip
need_cmd curl
need_cmd mpstat
need_cmd stress-ng
need_cmd python3

IFACE="$(primary_iface)"
IFACE="${IFACE:-eth0}"

# ---------------------------
# Banner
# ---------------------------
cat <<BANNER | tee -a "$LOG_FILE"
============================================================
[$(ts)] START EC2 Stress v14 (MEM -> CPU ramp by % via stress-ng) + NET + Live + HTTP evidence
Run dir: $RUN_DIR
Log file: $LOG_FILE
URL: $URL
MEM: ${MEM_PHASE_SEC}s | target ${MEM_TARGET_PCT}% | step ${MEM_STEP_MB}MB | headroom ${MEM_HEADROOM_MB}MB
CPU: ${CPU_PHASE_SEC}s | ramp steps 3 | workers=${CPU_WORKERS} | loads ${CPU_LOAD_1}% -> ${CPU_LOAD_2}% -> ${CPU_LOAD_3}%
NET_WORKERS: ${NET_WORKERS} (curl silent)
Live status every: ${LIVE_INTERVAL}s (CPU uses mpstat 1 1)
HTTP monitor: ${HTTP_MONITOR_ENABLED} (interval ${HTTP_MONITOR_INTERVAL}s, timeout ${HTTP_FAIL_TIMEOUT}s, slow>=${HTTP_FAIL_LATENCY_SEC}s)
Threshold refs: MEM=${THRESH_MEM_PCT}% | CPU=${THRESH_CPU_PCT}%
============================================================
BANNER

log "Interfaz primaria: $IFACE"

# ---------------------------
# NET workers (optional)
# ---------------------------
net_worker() {
  while true; do
    curl -sS -o /dev/null \
      --connect-timeout "$NET_CURL_CONNECT_TIMEOUT" \
      --max-time "$NET_CURL_TIMEOUT" \
      "$URL" >/dev/null 2>&1 || true
  done
}

if [[ "$NET_WORKERS" -gt 0 ]]; then
  log "NET: iniciando ${NET_WORKERS} workers (silencioso)..."
  : > "$NET_PIDS_FILE"
  for _ in $(seq 1 "$NET_WORKERS"); do
    net_worker &
    echo $! >> "$NET_PIDS_FILE"
  done
else
  log "NET: iniciando 0 workers (silencioso)..."
fi

# ---------------------------
# LIVE sampler (writes TSV + shows console)
# ---------------------------
: > "$SAMPLE_FILE"
live_sampler() {
  while true; do
    local phase step
    read -r phase step < <(read_state)

    local cpu mem_used mem_total mem_pct mem_avail swap_mb
    cpu="$(cpu_used_pct_mpstat)"
    read -r mem_used mem_total mem_pct mem_avail swap_mb < <(mem_stats_mb)

    local in_m out_m
    read -r in_m out_m < <(net_mbps "$IFACE")

    local now
    now="$(ts)"

    printf "%s\t%s\t%s\t%.2f\t%.2f\t%s\t%s\t%s\t%.2f\t%.2f\n" \
      "$now" "$phase" "$step" "$cpu" "$mem_pct" "$mem_used" "$mem_total" "$swap_mb" "$in_m" "$out_m" >> "$SAMPLE_FILE"

    echo "[$now] CPU-LIVE: CPU=${cpu}% | MEM=${mem_pct}% (${mem_used}/${mem_total}MB) | NET in/out=${in_m}/${out_m} Mbps | swap=${swap_mb}MB | phase=${phase} step=${step}" | tee -a "$LOG_FILE"
    sleep "$LIVE_INTERVAL"
  done
}

CURRENT_PHASE="BOOT"
CURRENT_STEP="N/A"
write_state
live_sampler &
LIVE_PID="$!"
log "LIVE sampler iniciado (PID=$LIVE_PID) -> $SAMPLE_FILE"

# ---------------------------
# HTTP evidence monitor (writes TSV + logs first fail with phase/step)
# ---------------------------
: > "$HTTP_SAMPLE_FILE"
http_monitor() {
  local first_fail_logged=0
  while true; do
    local now phase step
    now="$(ts)"
    read -r phase step < <(read_state)

    local out code ttotal
    out="$(curl -s -o /dev/null \
      --max-time "$HTTP_FAIL_TIMEOUT" \
      -w "%{http_code} %{time_total}" \
      "$URL" 2>/dev/null || echo "000 9.999")"
    code="$(awk '{print $1}' <<<"$out")"
    ttotal="$(awk '{print $2}' <<<"$out")"

    printf "%s\t%s\t%s\t%s\t%s\n" "$now" "$phase" "$step" "$code" "$ttotal" >> "$HTTP_SAMPLE_FILE"

    local is_slow=0
    awk -v a="$ttotal" -v b="$HTTP_FAIL_LATENCY_SEC" 'BEGIN{exit !(a>=b)}' && is_slow=1

    if [[ "$code" == "000" || "$code" -ge "$HTTP_FAIL_CODE_MIN" || "$is_slow" -eq 1 ]]; then
      if [[ "$first_fail_logged" -eq 0 ]]; then
        first_fail_logged=1
        log "HTTP-MON: ❌ PRIMER FALLO/DEGRADACIÓN => HTTP=${code} time_total=${ttotal}s (phase=${phase} step=${step})"
      fi
    fi

    sleep "$HTTP_MONITOR_INTERVAL"
  done
}

if [[ "$HTTP_MONITOR_ENABLED" -eq 1 ]]; then
  http_monitor &
  HTTP_PID="$!"
  log "HTTP monitor iniciado (PID=$HTTP_PID) -> $HTTP_SAMPLE_FILE"
else
  log "HTTP monitor deshabilitado (HTTP_MONITOR_ENABLED=0)"
fi

# ---------------------------
# PHASE 1: MEMORY (python allocator)
# ---------------------------
CURRENT_PHASE="MEM"
CURRENT_STEP="ALLOC"
write_state

log "PHASE 1: MEM (hasta ${MEM_PHASE_SEC}s o hasta alcanzar ${MEM_TARGET_PCT}%)"
read -r mu mt mp ma sw < <(mem_stats_mb)
log "MEM status: used=${mu}/${mt}MB (${mp}%) avail=${ma}MB swap=${sw}MB"

python3 - <<'PY' &
import os, time, subprocess

step_mb = int(os.environ.get("MEM_STEP_MB", "32"))
target_pct = float(os.environ.get("MEM_TARGET_PCT", "70"))
headroom_mb = int(os.environ.get("MEM_HEADROOM_MB", "80"))
max_sec = int(os.environ.get("MEM_PHASE_SEC", "60"))

chunks = []
allocated = 0
start = time.time()

def mem_stats():
    out = subprocess.check_output(["free","-m"], text=True).splitlines()
    mem = [l for l in out if l.startswith("Mem:")][0].split()
    total = int(mem[1]); used = int(mem[2]); avail = int(mem[6])
    pct = (used/total*100) if total else 0.0
    return used, total, pct, avail

def touch(b):
    page = 4096
    for i in range(0, len(b), page):
        b[i] = 1

print(f"[PY] mem-consumer v14 start: step={step_mb}MB target={target_pct}% headroom={headroom_mb}MB max={max_sec}s", flush=True)

while True:
    used, total, pct, avail = mem_stats()
    elapsed = time.time() - start

    if pct >= target_pct:
        print(f"[PY] TARGET reached: used={used}/{total}MB ({pct:.2f}%) avail={avail}MB", flush=True)
        break
    if elapsed >= max_sec:
        print(f"[PY] TIMEOUT: reached {elapsed:.0f}s, stop allocating (pct={pct:.2f}%)", flush=True)
        break
    if avail <= headroom_mb:
        print(f"[PY] HEADROOM stop: avail={avail}MB <= headroom={headroom_mb}MB (pct={pct:.2f}%)", flush=True)
        break

    try:
        b = bytearray(step_mb * 1024 * 1024)
        touch(b)
        chunks.append(b)
        allocated += step_mb
        used, total, pct, avail = mem_stats()
        print(f"[PY] allocated_total={allocated}MB | used={used}/{total}MB ({pct:.2f}%) avail={avail}MB", flush=True)
        time.sleep(1)
    except MemoryError:
        print("[PY] MemoryError reached", flush=True)
        break

while True:
    time.sleep(5)
PY
MEM_PID="$!"
log "MEM: proceso python PID=$MEM_PID"

mem_start="$(date +%s)"
while true; do
  read -r used total pct avail swap < <(mem_stats_mb)

  awk -v p="$pct" -v t="$MEM_TARGET_PCT" 'BEGIN{exit !(p>=t)}' && {
    if [[ "$MEM_TARGET_REACHED" == "NO" ]]; then
      MEM_TARGET_REACHED="YES"
      MEM_TARGET_TS="$(ts)"
      MEM_TARGET_AT_PCT="$pct"
      log "✅ MEM alcanzó umbral (${MEM_TARGET_PCT}%). Iniciando CPU..."
      break
    fi
  }

  now_s="$(date +%s)"
  if (( now_s - mem_start >= MEM_PHASE_SEC )); then
    log "⚠️ MEM: no se alcanzó target en ${MEM_PHASE_SEC}s, pero se mantiene memoria asignada."
    break
  fi

  sleep 1
done

# ---------------------------
# PHASE 2: CPU ramp by % (stress-ng)
# ---------------------------
CURRENT_PHASE="CPU"
CURRENT_STEP="STEP1"
write_state

log "PHASE 2: CPU (${CPU_PHASE_SEC}s) stress-ng ramp por % + estado en vivo"
log "CPU RAMP (%): ${CPU_LOAD_1}% -> ${CPU_LOAD_2}% -> ${CPU_LOAD_3}% (cada ~20s) workers=${CPU_WORKERS}"

step_len=$(( CPU_PHASE_SEC / 3 ))
[[ "$step_len" -lt 10 ]] && step_len=20

run_cpu_step() {
  local step_name="$1"
  local load="$2"
  local dur="$3"

  CURRENT_STEP="$step_name"
  write_state
  log "CPU ${step_name}: load=${load}% (${dur}s)"
  log "  stress-ng: cpu workers=${CPU_WORKERS} cpu-load=${load}% for ${dur}s"

  stress-ng --cpu "$CPU_WORKERS" --cpu-load "$load" --cpu-method all --timeout "${dur}s" --quiet || true
}

run_cpu_step "STEP1" "$CPU_LOAD_1" "$step_len"
run_cpu_step "STEP2" "$CPU_LOAD_2" "$step_len"
run_cpu_step "STEP3" "$CPU_LOAD_3" "$step_len"

log "PHASE 2 complete."

# Stop mem consumer now
[[ -n "${MEM_PID:-}" ]] && kill "$MEM_PID" >/dev/null 2>&1 || true

# Give monitors a moment
sleep 1

# FIX v14: detener NET workers ANTES del wait (si no, wait se queda esperando)
stop_net_workers

# Stop monitors
[[ -n "${LIVE_PID:-}" ]] && kill "$LIVE_PID" >/dev/null 2>&1 || true
[[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" >/dev/null 2>&1 || true

# FIX v14: wait solo por PIDs conocidos (best-effort)
wait "${LIVE_PID:-}" 2>/dev/null || true
wait "${HTTP_PID:-}" 2>/dev/null || true
wait "${MEM_PID:-}" 2>/dev/null || true

# ---------------------------
# REPORT: parse samples for peaks and HTTP evidence
# ---------------------------
peak_cpu="$(awk -F'\t' 'BEGIN{m=0} {if($4+0>m)m=$4} END{printf "%.2f", m}' "$SAMPLE_FILE")"
peak_cpu_row="$(awk -F'\t' 'BEGIN{m=0; r=""} {if($4+0>m){m=$4; r=$0}} END{print r}' "$SAMPLE_FILE")"
peak_cpu_ts="$(awk -F'\t' '{print $1}' <<<"$peak_cpu_row")"
peak_cpu_phase="$(awk -F'\t' '{print $2}' <<<"$peak_cpu_row")"
peak_cpu_step="$(awk -F'\t' '{print $3}' <<<"$peak_cpu_row")"

peak_mem="$(awk -F'\t' 'BEGIN{m=0} {if($5+0>m)m=$5} END{printf "%.2f", m}' "$SAMPLE_FILE")"
peak_mem_row="$(awk -F'\t' 'BEGIN{m=0; r=""} {if($5+0>m){m=$5; r=$0}} END{print r}' "$SAMPLE_FILE")"
peak_mem_ts="$(awk -F'\t' '{print $1}' <<<"$peak_mem_row")"
peak_mem_used="$(awk -F'\t' '{print $6}' <<<"$peak_mem_row")"
peak_mem_total="$(awk -F'\t' '{print $7}' <<<"$peak_mem_row")"

peak_in="$(awk -F'\t' 'BEGIN{m=0} {if($9+0>m)m=$9} END{printf "%.2f", m}' "$SAMPLE_FILE")"
peak_out="$(awk -F'\t' 'BEGIN{m=0} {if($10+0>m)m=$10} END{printf "%.2f", m}' "$SAMPLE_FILE")"

peak_swap="$(awk -F'\t' 'BEGIN{m=0} {if($8+0>m)m=$8} END{printf "%d", m}' "$SAMPLE_FILE")"

if [[ "$HTTP_MONITOR_ENABLED" -eq 1 && -s "$HTTP_SAMPLE_FILE" ]]; then
  http_total="$(wc -l < "$HTTP_SAMPLE_FILE" | tr -d ' ')"
  http_ok="$(awk -F'\t' '$4 ~ /^(200|301|302|304)$/ {c++} END{print c+0}' "$HTTP_SAMPLE_FILE")"
  http_fail="$(awk -F'\t' '
    function is_slow(t,thr){ return (t+0)>=thr }
    {code=$4; t=$5}
    (code=="000" || code+0>=min || is_slow(t,slow)) {c++}
    END{print c+0}
  ' min="$HTTP_FAIL_CODE_MIN" slow="$HTTP_FAIL_LATENCY_SEC" "$HTTP_SAMPLE_FILE")"

  http_000="$(awk -F'\t' '$4=="000"{c++} END{print c+0}' "$HTTP_SAMPLE_FILE")"
  http_5xx="$(awk -F'\t' -v m="$HTTP_FAIL_CODE_MIN" '$4+0>=m {c++} END{print c+0}' "$HTTP_SAMPLE_FILE")"
  http_slow="$(awk -F'\t' -v s="$HTTP_FAIL_LATENCY_SEC" '$5+0>=s {c++} END{print c+0}' "$HTTP_SAMPLE_FILE")"

  http_first_fail="$(awk -F'\t' -v m="$HTTP_FAIL_CODE_MIN" -v s="$HTTP_FAIL_LATENCY_SEC" '
    function is_slow(t,thr){ return (t+0)>=thr }
    {code=$4; t=$5}
    (code=="000" || code+0>=m || is_slow(t,s)) {print $0; exit}
  ' "$HTTP_SAMPLE_FILE")"

  http_first_fail_ts="$(awk -F'\t' '{print $1}' <<<"$http_first_fail")"
  http_first_fail_phase="$(awk -F'\t' '{print $2}' <<<"$http_first_fail")"
  http_first_fail_step="$(awk -F'\t' '{print $3}' <<<"$http_first_fail")"
  http_first_fail_code="$(awk -F'\t' '{print $4}' <<<"$http_first_fail")"
  http_first_fail_t="$(awk -F'\t' '{print $5}' <<<"$http_first_fail")"

  http_peak_latency="$(awk -F'\t' 'BEGIN{m=0} {if($5+0>m)m=$5} END{printf "%.3f", m}' "$HTTP_SAMPLE_FILE")"
  http_peak_row="$(awk -F'\t' 'BEGIN{m=0; r=""} {if($5+0>m){m=$5; r=$0}} END{print r}' "$HTTP_SAMPLE_FILE")"
  http_peak_ts="$(awk -F'\t' '{print $1}' <<<"$http_peak_row")"
  http_ok_pct="$(awk -v ok="$http_ok" -v tot="$http_total" 'BEGIN{ if(tot>0) printf "%.2f", (ok/tot)*100; else print "0.00"}')"
else
  http_total="N/A"; http_ok="N/A"; http_fail="N/A"; http_ok_pct="N/A"
  http_000="N/A"; http_5xx="N/A"; http_slow="N/A"
  http_first_fail_ts="N/A"; http_first_fail_phase="N/A"; http_first_fail_step="N/A"
  http_first_fail_code="N/A"; http_first_fail_t="N/A"
  http_peak_latency="N/A"; http_peak_ts="N/A"
fi

# ---------------------------
# FINAL REPORT
# ---------------------------
echo "============================================================" | tee -a "$LOG_FILE"
echo "[$(ts)] INFORME FINAL (peaks en base a LIVE + evidencia HTTP por fase/step)" | tee -a "$LOG_FILE"
echo "- Umbral MEM objetivo:       ${MEM_TARGET_PCT}% | Alcanzado: ${MEM_TARGET_REACHED} | Hora: ${MEM_TARGET_TS} | % al alcanzar: ${MEM_TARGET_AT_PCT}" | tee -a "$LOG_FILE"
echo "- Umbral CPU referencia:     ${THRESH_CPU_PCT}%" | tee -a "$LOG_FILE"
echo "------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "- Peak CPU Used (%):         ${peak_cpu}  (time: ${peak_cpu_ts}, phase: ${peak_cpu_phase}, step: ${peak_cpu_step})" | tee -a "$LOG_FILE"
echo "- Peak MEM Used (%):         ${peak_mem}  (MB: ${peak_mem_used}/${peak_mem_total})" | tee -a "$LOG_FILE"
echo "- Peak Swap Used (MB):       ${peak_swap}" | tee -a "$LOG_FILE"
echo "- Peak Net In (Mbps):        ${peak_in}" | tee -a "$LOG_FILE"
echo "- Peak Net Out (Mbps):       ${peak_out}" | tee -a "$LOG_FILE"
echo "------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "EVIDENCIA HTTP (durante el stress)" | tee -a "$LOG_FILE"
echo "- Requests totales:          ${http_total}" | tee -a "$LOG_FILE"
echo "- OK (2xx/3xx):              ${http_ok}  (${http_ok_pct}%)" | tee -a "$LOG_FILE"
echo "- Fallas/Degradación:        ${http_fail}" | tee -a "$LOG_FILE"
echo "  - Timeouts/conn (000):     ${http_000}" | tee -a "$LOG_FILE"
echo "  - Errores 5xx (>=${HTTP_FAIL_CODE_MIN}): ${http_5xx}" | tee -a "$LOG_FILE"
echo "  - Lentas (>=${HTTP_FAIL_LATENCY_SEC}s):  ${http_slow}" | tee -a "$LOG_FILE"
echo "- Primer fallo:              ${http_first_fail_ts} | phase=${http_first_fail_phase} step=${http_first_fail_step} | HTTP=${http_first_fail_code} t=${http_first_fail_t}s" | tee -a "$LOG_FILE"
echo "- Peak latencia:             ${http_peak_latency}s (hora: ${http_peak_ts})" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# ---------------------------
# RECOMMENDATION
# ---------------------------
echo "[$(ts)] RECOMENDACIÓN" | tee -a "$LOG_FILE"

mem_reach=0
awk -v p="$peak_mem" -v t="$THRESH_MEM_PCT" 'BEGIN{exit !(p>=t)}' && mem_reach=1

cpu_reach=0
awk -v p="$peak_cpu" -v t="$THRESH_CPU_PCT" 'BEGIN{exit !(p>=t)}' && cpu_reach=1

if [[ "$mem_reach" -eq 1 ]]; then
  echo "✅ MEMORIA: Se alcanzó el umbral crítico (${THRESH_MEM_PCT}%). Recomendar **Vertical Scaling t3.micro → t3.small** (más RAM)." | tee -a "$LOG_FILE"
else
  echo "ℹ️ MEMORIA: No superó umbral (${THRESH_MEM_PCT}%). Aun así, t3.small da holgura para picos/caché." | tee -a "$LOG_FILE"
fi

if [[ "$cpu_reach" -eq 1 ]]; then
  echo "✅ CPU: Picos >= ${THRESH_CPU_PCT}% → usar para alarmas de **Auto Scaling** por CPU (horizontal) en la siguiente etapa." | tee -a "$LOG_FILE"
else
  echo "ℹ️ CPU: No superó umbral (${THRESH_CPU_PCT}%). Sube CPU_LOAD_3 o aumenta CPU_WORKERS si necesitas más carga." | tee -a "$LOG_FILE"
fi

if [[ "$HTTP_MONITOR_ENABLED" -eq 1 && "$http_fail" != "N/A" ]]; then
  if [[ "$http_fail" -gt 0 ]]; then
    echo "������ DISPONIBILIDAD: Hubo fallas/degradación HTTP durante el stress (ver 'EVIDENCIA HTTP'). Útil para justificar incidentes por carga." | tee -a "$LOG_FILE"
  else
    echo "✅ DISPONIBILIDAD: No se detectaron fallas HTTP con estos parámetros. Sube NET_WORKERS o baja timeouts para forzar caída." | tee -a "$LOG_FILE"
  fi
fi

echo "============================================================" | tee -a "$LOG_FILE"
log "FIN. Log: $LOG_FILE"
log "Archivos de evidencia: samples=$SAMPLE_FILE | http=$HTTP_SAMPLE_FILE"

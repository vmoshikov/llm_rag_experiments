#!/usr/bin/env bash
set -euo pipefail

# Requirements: kubectl, jq, python3 (или GNU date), awk, sed
# Usage:
#   ./cluster_events_triage.sh [--since 10m] [--namespace ns1,ns2|--all-namespaces]
#                              [--context ctx] [--kubeconfig /path/kubeconfig]
#                              [--out ./outdir] [--logs-tail 300] [--limit 0]
#
# Examples:
#   ./cluster_events_triage.sh --since 10m --all-namespaces
#   ./cluster_events_triage.sh --since 2h --namespace default,kube-system --logs-tail 200
#
# Notes:
#  - --limit >0 ограничит количество обрабатываемых уникальных компонентов (для быстрой прогона)
#  - Для Pod'ов собираются логи всех контейнеров (обычных и init) с tail N строк.

SINCE="10m"
NS_MODE="--all-namespaces"
NS_LIST=""
KCTX=""
KCONF=""
OUT_DIR="./events_triage_$(date +%Y%m%d_%H%M%S)"
LOGS_TAIL=300
LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)         SINCE="$2"; shift 2 ;;
    --namespace)     NS_LIST="$2"; NS_MODE=""; shift 2 ;;
    --all-namespaces) NS_MODE="--all-namespaces"; NS_LIST=""; shift 1 ;;
    --context)       KCTX="--context=$2"; shift 2 ;;
    --kubeconfig)    KCONF="--kubeconfig=$2"; shift 2 ;;
    --out)           OUT_DIR="$2"; shift 2 ;;
    --logs-tail)     LOGS_TAIL="$2"; shift 2 ;;
    --limit)         LIMIT="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,80p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "${OUT_DIR}"

# -------- helpers --------

# RFC3339 -> epoch (seconds). Prefer GNU date; fallback to python3.
rfc3339_to_epoch() {
  local ts="$1"
  if command -v date >/dev/null 2>&1 && date --version >/dev/null 2>&1; then
    date -d "$ts" +%s
  else
    python3 - <<PY
import sys, datetime
from datetime import timezone
s=sys.argv[1]
try:
    # handle fractional seconds and Z
    dt = datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
except ValueError:
    # Fallback: strip subsecond if needed
    if "." in s:
        base=s.split(".")[0]
        tz="+00:00" if s.endswith("Z") else ""
        dt = datetime.datetime.fromisoformat(base+tz)
    else:
        dt = datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
print(int(dt.timestamp()))
PY
    "$ts"
  fi
}

# Compute cutoff epoch "now - SINCE"
compute_cutoff_epoch() {
  local since="$1"
  # since like 10m / 2h / 1d
  local num unit
  num="$(echo "$since" | sed -E 's/^([0-9]+).*/\1/')"
  unit="$(echo "$since" | sed -E 's/^[0-9]+([a-zA-Z]).*/\1/')"

  local seconds=0
  case "$unit" in
    m|M) seconds=$(( num*60 ));;
    h|H) seconds=$(( num*3600 ));;
    d|D) seconds=$(( num*86400 ));;
    s|S) seconds=$(( num ));;
    *)   # default minutes
         seconds=$(( num*60 ));;
  esac

  local now_epoch
  now_epoch=$(date +%s)
  echo $(( now_epoch - seconds ))
}

CUTOFF_EPOCH="$(compute_cutoff_epoch "$SINCE")"

# Compose namespace CLI
build_ns_args() {
  if [[ -n "$NS_MODE" ]]; then
    echo "$NS_MODE"
  else
    # build multiple -n args
    IFS=',' read -r -a arr <<< "$NS_LIST"
    local out=""
    for ns in "${arr[@]}"; do
      out="$out -n $ns"
    done
    echo "$out"
  fi
}

NS_ARGS="$(build_ns_args)"

# -------- fetch events (JSON) --------
echo "[*] Fetching events (Warning) $SINCE ..." | tee -a "${OUT_DIR}/_run.log"

# We take all events and post-filter by time.
# Time fields to consider (first non-empty): eventTime, series.lastObservedTime, lastTimestamp, firstTimestamp
EV_JSON_RAW="$(eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} ${NS_ARGS} get events -o json 2>/dev/null || true)"

if [[ -z "$EV_JSON_RAW" || "$EV_JSON_RAW" == "No resources found"* ]]; then
  echo "[!] No events fetched. Check permissions/namespace." | tee -a "${OUT_DIR}/_run.log"
  exit 0
fi

# Write raw snapshot
echo "$EV_JSON_RAW" > "${OUT_DIR}/events_raw.json"

# jq filter for Warning+time window
read -r -d '' JQ_FILTER <<'JQ'
  .items[]
  | select(.type=="Warning")
  | . as $e
  | ($e.eventTime // $e.series.lastObservedTime // $e.lastTimestamp // $e.firstTimestamp) as $t
  | select($t != null and $t != "")
  | {
      reason: (.reason // ""),
      message: (.message // ""),
      ns: (.involvedObject.namespace // "default"),
      kind: (.involvedObject.kind // ""),
      name: (.involvedObject.name // ""),
      component: .source.component,
      eventTime: $t,
      count: (.count // 1),
      reportingController: (.reportingController // ""),
      reportingInstance: (.reportingInstance // "")
    }
JQ

# Pre-extract Warning events with a timestamp
EV_WARN_JSON="$(jq -c "$JQ_FILTER" "${OUT_DIR}/events_raw.json" 2>/dev/null || true)"

if [[ -z "$EV_WARN_JSON" ]]; then
  echo "[*] No Warning events with timestamps." | tee -a "${OUT_DIR}/_run.log"
  exit 0
fi

# Time filter in bash using helper
echo "$EV_WARN_JSON" | while IFS= read -r line; do
  ts="$(echo "$line" | jq -r '.eventTime')"
  # Convert to epoch
  ep="$(rfc3339_to_epoch "$ts" 2>/dev/null || echo 0)"
  if [[ "$ep" -ge "$CUTOFF_EPOCH" ]]; then
    echo "$line"
  fi
done > "${OUT_DIR}/events_warning_since.jsonl"

if [[ ! -s "${OUT_DIR}/events_warning_since.jsonl" ]]; then
  echo "[*] No Warning events in the last ${SINCE}." | tee -a "${OUT_DIR}/_run.log"
  exit 0
fi

# -------- summary table --------
echo "[*] Writing summary..." | tee -a "${OUT_DIR}/_run.log"

# Pretty table
{
  echo "NAMESPACE,KIND,NAME,REASON,COUNT,LAST_TIME,COMPONENT"
  cat "${OUT_DIR}/events_warning_since.jsonl" \
    | jq -r '[.ns,.kind,.name,.reason, ( .count|tostring ), .eventTime, (.component//"")] | @csv' \
    | sed 's/\\"/"/g'
} > "${OUT_DIR}/events_summary.csv"

# Grouped by component key
cat > "${OUT_DIR}/events_grouped.txt" <<EOF
== Warning events (since ${SINCE}) grouped by component ==
EOF

jq -r '
  group_by(.ns + "|" + .kind + "|" + .name)[] |
  {
    key: (.[0].ns + "|" + .[0].kind + "|" + .[0].name),
    last_time: (max_by(.eventTime).eventTime),
    reasons: (map(.reason) | unique),
    count_sum: (map(.count)|add)
  } |
  "• \(.key)  last=\(.last_time)  reasons=\(.reasons|join("/"))  totalCount=\(.count_sum)"
' "${OUT_DIR}/events_warning_since.jsonl" \
  >> "${OUT_DIR}/events_grouped.txt"

# -------- enumerate unique components --------
mapfile -t COMPONENT_KEYS < <(jq -r '(.ns+"|"+.kind+"|"+.name)' "${OUT_DIR}/events_warning_since.jsonl" | sort -u)

TOTAL="${#COMPONENT_KEYS[@]}"
echo "[*] Unique components to collect: ${TOTAL}" | tee -a "${OUT_DIR}/_run.log"

if [[ "$LIMIT" -gt 0 && "$TOTAL" -gt "$LIMIT" ]]; then
  echo "[*] LIMIT active: processing first ${LIMIT} of ${TOTAL}" | tee -a "${OUT_DIR}/_run.log"
  COMPONENT_KEYS=("${COMPONENT_KEYS[@]:0:$LIMIT}")
fi

# -------- per-component collection --------
collect_for_kind_name() {
  local ns="$1" kind="$2" name="$3"
  local safe="${ns}__${kind}__${name}"
  local dir="${OUT_DIR}/components/${safe}"
  mkdir -p "$dir"

  # Describe
  eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" describe "$kind" "$name" > "${dir}/describe.txt" 2>&1 || true
  # YAML
  eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" get "$kind" "$name" -o yaml > "${dir}/resource.yaml" 2>&1 || true

  # If Pod -> logs for every container (including init)
  if [[ "$kind" == "Pod" ]]; then
    # list containers
    mapfile -t containers < <(eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" get pod "$name" -o json \
      | jq -r '[.spec.initContainers[]?.name, .spec.containers[]?.name] | .[]' 2>/dev/null || true)
    if [[ "${#containers[@]}" -gt 0 ]]; then
      for c in "${containers[@]}"; do
        eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" > "${dir}/logs_${c}.log" 2>&1 || true
        # previous if restarted
        eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" -p > "${dir}/logs_${c}_previous.log" 2>&1 || true
      done
    else
      # single-container shortcut
      eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" --tail="$LOGS_TAIL" > "${dir}/logs.log" 2>&1 || true
      eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" --tail="$LOGS_TAIL" -p > "${dir}/logs_previous.log" 2>&1 || true
    fi
  fi
}

idx=0
for key in "${COMPONENT_KEYS[@]}"; do
  idx=$((idx+1))
  ns="${key%%|*}"
  rest="${key#*|}"
  kind="${rest%%|*}"
  name="${rest#*|}"
  echo "[*] [$idx/${#COMPONENT_KEYS[@]}] Collect: ns=$ns kind=$kind name=$name" | tee -a "${OUT_DIR}/_run.log"
  collect_for_kind_name "$ns" "$kind" "$name"
done

# -------- write a quick README --------
cat > "${OUT_DIR}/README.txt" <<EOF
Cluster Events Triage
=====================
Generated: $(date -Is)
Window:    ${SINCE}

Files:
- events_raw.json                 : полный дамп событий
- events_warning_since.jsonl      : Warning события за окно (по времени)
- events_summary.csv              : таблица (namespace,kind,name,reason,count,last_time,component)
- events_grouped.txt              : агрегирование по компоненту
- components/*/                   : describe / yaml ресурса; для Pod'ов — логи контейнеров (tail ${LOGS_TAIL})

Tip:
- Открой events_summary.csv в табличнике и отсортируй по времени/причине.
- components/<ns>__<kind>__<name>/ содержит всё для быстрой диагностики.
EOF

echo
echo "[✓] Done. Output saved to: ${OUT_DIR}"
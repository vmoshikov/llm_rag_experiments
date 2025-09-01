#!/usr/bin/env bash
set -euo pipefail

# Reqs: kubectl, jq, python3 (или macOS date), awk, sed
# Usage:
#   ./cluster_events_triage_v2.sh [--since 10m] [--namespace ns1,ns2|--all-namespaces]
#                                 [--include-normal] [--context ctx] [--kubeconfig path]
#                                 [--out ./outdir] [--logs-tail 300] [--limit 0]
#
SINCE="10m"
NS_MODE="--all-namespaces"
NS_LIST=""
INCLUDE_NORMAL=0
KCTX=""
KCONF=""
OUT_DIR="./events_triage_$(date +%Y%m%d_%H%M%S)"
LOGS_TAIL=300
LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)          SINCE="$2"; shift 2 ;;
    --namespace)      NS_LIST="$2"; NS_MODE=""; shift 2 ;;
    --all-namespaces) NS_MODE="--all-namespaces"; NS_LIST=""; shift 1 ;;
    --include-normal) INCLUDE_NORMAL=1; shift 1 ;;
    --context)        KCTX="--context=$2"; shift 2 ;;
    --kubeconfig)     KCONF="--kubeconfig=$2"; shift 2 ;;
    --out)            OUT_DIR="$2"; shift 2 ;;
    --logs-tail)      LOGS_TAIL="$2"; shift 2 ;;
    --limit)          LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '1,120p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need kubectl; need jq

log() { echo "[$(date -Is)] $*" | tee -a "${OUT_DIR}/_run.log"; }

# RFC3339 -> epoch
rfc3339_to_epoch() {
  local ts="$1"
  # macOS date(1) без --version, GNU имеет --version
  if date -u +"%s" >/dev/null 2>&1; then
    # Попробуем portable вариант через python3
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$ts" <<'PY'
import sys, datetime
s=sys.argv[1]
if not s:
    print(0); sys.exit(0)
try:
    print(int(datetime.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()))
except Exception:
    try:
        # Усечь микросекунды
        base=s.split(".")[0]
        print(int(datetime.datetime.fromisoformat(base.replace("Z","+00:00")).timestamp()))
    except Exception:
        print(0)
PY
    else
      # Попытка через date (GNU/macOS форматы)
      if date -j -f "%Y-%m-%dT%H:%M:%S%z" 010101T000000+0000 +%s >/dev/null 2>&1; then
        # macOS: убрать дробную часть и Z
        local s="${ts/Z/+0000}"
        s="${s%%.*}"
        date -j -u -f "%Y-%m-%dT%H:%M:%S%z" "$s" +%s 2>/dev/null || echo 0
      else
        date -d "$ts" +%s 2>/dev/null || echo 0
      fi
    fi
  else
    echo 0
  fi
}

compute_cutoff_epoch() {
  local s="$1"; local n unit
  n="$(echo "$s" | sed -E 's/^([0-9]+).*/\1/')"
  unit="$(echo "$s" | sed -E 's/^[0-9]+([a-zA-Z]).*/\1/')"
  case "$unit" in
    s|S) echo $(( $(date +%s) - n ));;
    m|M|"") echo $(( $(date +%s) - n*60 ));;
    h|H) echo $(( $(date +%s) - n*3600 ));;
    d|D) echo $(( $(date +%s) - n*86400 ));;
    *)   echo $(( $(date +%s) - n*60 ));;
  esac
}
CUTOFF_EPOCH="$(compute_cutoff_epoch "$SINCE")"

build_ns_args() {
  if [[ -n "$NS_MODE" ]]; then
    echo "$NS_MODE"
  else
    IFS=',' read -r -a arr <<< "$NS_LIST"
    local out=""
    for ns in "${arr[@]}"; do out="$out -n $ns"; done
    echo "$out"
  fi
}
NS_ARGS="$(build_ns_args)"

log "Fetch events JSON…"
EV_JSON_RAW="$(eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} ${NS_ARGS} get events -o json 2>/dev/null || true)"
echo "$EV_JSON_RAW" > "${OUT_DIR}/events_raw.json"

if [[ -z "$EV_JSON_RAW" || "$EV_JSON_RAW" == "No resources found"* ]]; then
  log "No events fetched (check RBAC/ns)."
fi

# Типы событий к включению
if [[ "$INCLUDE_NORMAL" -eq 1 ]]; then
  TYPE_FILTER='select(.type=="Warning" or .type=="Normal")'
else
  TYPE_FILTER='select(.type=="Warning")'
fi

# Единый экстрактор времени с fallback к metadata.creationTimestamp
read -r -d '' JQ_EXTRACT <<'JQ'
  .items[]
  | . as $e
  | ($e.eventTime // $e.series.lastObservedTime // $e.lastTimestamp // $e.firstTimestamp // $e.metadata.creationTimestamp) as $t
  | select($t != null and $t != "")
  | {
      type: (.type // "Unknown"),
      reason: (.reason // ""),
      message: (.message // ""),
      ns: (.involvedObject.namespace // "default"),
      kind: (.involvedObject.kind // ""),
      name: (.involvedObject.name // ""),
      component: (.source.component // ""),
      reportingController: (.reportingController // ""),
      eventTime: $t,
      count: (.count // 1)
    }
JQ

# Предфильтр по типу
EV_ALL_JSONL="$(jq -c "$JQ_EXTRACT" "${OUT_DIR}/events_raw.json" 2>/dev/null | jq -c "$TYPE_FILTER" || true)"
if [[ -z "$EV_ALL_JSONL" ]]; then
  log "No events after type filter."
  : > "${OUT_DIR}/events_warning_since.jsonl"
else
  # Фильтр по времени
  echo "$EV_ALL_JSONL" | while IFS= read -r line; do
    ts="$(echo "$line" | jq -r '.eventTime')"
    ep="$(rfc3339_to_epoch "$ts" 2>/dev/null || echo 0)"
    if [[ "$ep" -ge "$CUTOFF_EPOCH" ]]; then echo "$line"; fi
  done > "${OUT_DIR}/events_warning_since.jsonl"
fi

if [[ ! -s "${OUT_DIR}/events_warning_since.jsonl" ]]; then
  log "No events in last ${SINCE}. Producing empty summary files."
fi

# Summary CSV (даже если пусто — будет только шапка)
{
  echo "NAMESPACE,KIND,NAME,TYPE,REASON,COUNT,LAST_TIME,COMPONENT"
  if [[ -s "${OUT_DIR}/events_warning_since.jsonl" ]]; then
    jq -r '[.ns,.kind,.name,.type,.reason,(.count|tostring),.eventTime, (.component//"")] | @csv' \
      "${OUT_DIR}/events_warning_since.jsonl" | sed 's/\\"/"/g'
  fi
} > "${OUT_DIR}/events_summary.csv"

# Grouped
{
  echo "== Events (since ${SINCE}) grouped by component =="
  if [[ -s "${OUT_DIR}/events_warning_since.jsonl" ]]; then
    jq -r '
      group_by(.ns + "|" + .kind + "|" + .name)[] |
      { key:(.[0].ns+"|"+.[0].kind+"|"+.[0].name),
        last_time:(max_by(.eventTime).eventTime),
        reasons:(map(.reason)|unique),
        types:(map(.type)|unique),
        count_sum:(map(.count)|add)
      } |
      "• \(.key)  last=\(.last_time)  types=\(.types|join("/"))  reasons=\(.reasons|join("/"))  totalCount=\(.count_sum)"
    ' "${OUT_DIR}/events_warning_since.jsonl"
  else
    echo "(empty)"
  fi
} > "${OUT_DIR}/events_grouped.txt"

# Собрать список компонентов
if [[ -s "${OUT_DIR}/events_warning_since.jsonl" ]]; then
  mapfile -t COMPONENT_KEYS < <(jq -r '(.ns+"|"+.kind+"|"+.name)' "${OUT_DIR}/events_warning_since.jsonl" | sort -u)
else
  COMPONENT_KEYS=()
fi

TOTAL="${#COMPONENT_KEYS[@]}"
log "Unique components to collect: ${TOTAL}"

if [[ "$LIMIT" -gt 0 && "$TOTAL" -gt "$LIMIT" ]]; then
  log "LIMIT active: ${LIMIT}/${TOTAL}"
  COMPONENT_KEYS=("${COMPONENT_KEYS[@]:0:$LIMIT}")
fi

collect() {
  local ns="$1" kind="$2" name="$3"
  local safe="${ns}__${kind}__${name}"
  local dir="${OUT_DIR}/components/${safe}"
  mkdir -p "$dir"
  # describe / yaml
  eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" describe "$kind" "$name" > "${dir}/describe.txt" 2>&1 || true
  eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" get "$kind" "$name" -o yaml > "${dir}/resource.yaml" 2>&1 || true

  if [[ "$kind" == "Pod" ]]; then
    mapfile -t containers < <(eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" get pod "$name" -o json \
      | jq -r '[.spec.initContainers[]?.name, .spec.containers[]?.name] | .[]' 2>/dev/null || true)
    if [[ "${#containers[@]}" -gt 0 ]]; then
      for c in "${containers[@]}"; do
        eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" > "${dir}/logs_${c}.log" 2>&1 || true
        eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" -p > "${dir}/logs_${c}_previous.log" 2>&1 || true
      done
    else
      eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" --tail="$LOGS_TAIL" > "${dir}/logs.log" 2>&1 || true
      eval kubectl ${KCONF:+$KCONF} ${KCTX:+$KCTX} -n "$ns" logs "$name" --tail="$LOGS_TAIL" -p > "${dir}/logs_previous.log" 2>&1 || true
    fi
  fi
}

idx=0
for key in "${COMPONENT_KEYS[@]}"; do
  idx=$((idx+1))
  ns="${key%%|*}"; rest="${key#*|}"; kind="${rest%%|*}"; name="${rest#*|}"
  log "[$idx/${#COMPONENT_KEYS[@]}] Collect: ns=$ns kind=$kind name=$name"
  collect "$ns" "$kind" "$name"
done

cat > "${OUT_DIR}/README.txt" <<EOF
Cluster Events Triage (v2)
Generated: $(date -Is)
Window: ${SINCE}
Include Normal: ${INCLUDE_NORMAL}

Files:
- events_raw.json
- events_warning_since.jsonl
- events_summary.csv
- events_grouped.txt
- components/*/: describe/yaml (+ logs for Pods, tail ${LOGS_TAIL})
EOF

log "Done. Output: ${OUT_DIR}"
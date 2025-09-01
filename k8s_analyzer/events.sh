#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./cluster_events_triage_v3.sh [--since 10m] [--ns default,kube-system|--all]
#                                 [--include-normal] [--ctx CONTEXT] [--kc KUBECONFIG]
#                                 [--out ./out] [--logs-tail 200] [--limit 0]
#
SINCE="10m"
NS_MODE="all"        # all|list
NS_LIST=""
INCLUDE_NORMAL=0
CTX=""
KCONF=""
OUT_DIR="./events_triage_$(date +%Y%m%d_%H%M%S)"
LOGS_TAIL=200
LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --ns) NS_MODE="list"; NS_LIST="$2"; shift 2;;
    --all) NS_MODE="all"; NS_LIST=""; shift 1;;
    --include-normal) INCLUDE_NORMAL=1; shift 1;;
    --ctx) CTX="$2"; shift 2;;
    --kc) KCONF="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    --logs-tail) LOGS_TAIL="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    -h|--help) sed -n '1,120p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

mkdir -p "$OUT_DIR"
log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$OUT_DIR/_run.log"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need kubectl; need jq

# Build kubectl base args as array (без eval)
KARGS=()
[[ -n "$CTX" ]] && KARGS+=(--context "$CTX")
[[ -n "$KCONF" ]] && KARGS+=(--kubeconfig "$KCONF")

# Namespaces
NSARGS_ALL=(-A)
NSARGS_LIST=()
if [[ "$NS_MODE" == "list" ]]; then
  IFS=',' read -r -a NSARR <<< "$NS_LIST"
  for ns in "${NSARR[@]}"; do NSARGS_LIST+=(-n "$ns"); done
fi

# Time cutoff (sec)
now=$(date +%s)
n=${SINCE//[!0-9]/}
u=${SINCE//[0-9]/}
case "${u,,}" in s) delta=$n;; m|"") delta=$((n*60));; h) delta=$((n*3600));; d) delta=$((n*86400));; *) delta=$((n*60));; esac
CUTOFF=$((now-delta))

to_epoch() {
  local ts="$1"
  # универсально через python3 если есть
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ts" <<'PY'
import sys,datetime
s=sys.argv[1] or ""
try:
  print(int(datetime.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()))
except Exception:
  try:
    base=s.split('.')[0]
    print(int(datetime.datetime.fromisoformat(base.replace("Z","+00:00")).timestamp()))
  except Exception:
    print(0)
PY
  else
    # грубый fallback
    date -d "$ts" +%s 2>/dev/null || echo 0
  fi
}

log "kubectl version: $(kubectl "${KARGS[@]}" version --client --short 2>&1 || true)"
log "Auth check: $(kubectl "${KARGS[@]}" auth can-i list events --all-namespaces 2>&1 || true)"

# --- fetch events core/v1
fetch_events() {
  local scope="$1" # all|list
  local api="$2"   # "core"|"events"
  local out_json="$3"

  local cmd=(kubectl "${KARGS[@]}")
  if [[ "$scope" == "all" ]]; then
    cmd+=("${NSARGS_ALL[@]}")
  else
    # если конкретные ns, дернём последовательно и сольём
    if ((${#NSARGS_LIST[@]}==0)); then
      echo '{"items":[]}'
      return
    fi
  fi

  if [[ "$api" == "core" ]]; then
    # core/v1 events
    if [[ "$scope" == "all" ]]; then
      "${cmd[@]}" get events -o json > "$out_json" 2>/dev/null || echo '{"items":[]}' > "$out_json"
    else
      # merge
      echo '{"items":[]}' > "$out_json"
      for ((i=0;i<${#NSARGS_LIST[@]};i+=2)); do
        ns="${NSARGS_LIST[i+1]}"
        tmp="$OUT_DIR/_core_${ns}.json"
        kubectl "${KARGS[@]}" -n "$ns" get events -o json > "$tmp" 2>/dev/null || echo '{"items":[]}' > "$tmp"
        jq -s '{"items": (.[0].items + .[1].items)}' "$out_json" "$tmp" > "$out_json.merge"
        mv "$out_json.merge" "$out_json"
      done
    fi
  else
    # events.k8s.io/v1
    if [[ "$scope" == "all" ]]; then
      "${cmd[@]}" get events.events.k8s.io -o json > "$out_json" 2>/dev/null || echo '{"items":[]}' > "$out_json"
    else
      echo '{"items":[]}' > "$out_json"
      for ((i=0;i<${#NSARGS_LIST[@]};i+=2)); do
        ns="${NSARGS_LIST[i+1]}"
        tmp="$OUT_DIR/_ek_${ns}.json"
        kubectl "${KARGS[@]}" -n "$ns" get events.events.k8s.io -o json > "$tmp" 2>/dev/null || echo '{"items":[]}' > "$tmp"
        jq -s '{"items": (.[0].items + .[1].items)}' "$out_json" "$tmp" > "$out_json.merge"
        mv "$out_json.merge" "$out_json"
      done
    fi
  fi
}

log "Fetch events JSON (core/v1)…"
fetch_events "$NS_MODE" core "$OUT_DIR/events_core.json"
log "Fetch events JSON (events.k8s.io/v1)…"
fetch_events "$NS_MODE" events "$OUT_DIR/events_eventsapi.json"

# выберем более «полный» источник
core_count=$(jq '.items|length' "$OUT_DIR/events_core.json" 2>/dev/null || echo 0)
evapi_count=$(jq '.items|length' "$OUT_DIR/events_eventsapi.json" 2>/dev/null || echo 0)
if (( evapi_count > core_count )); then
  cp "$OUT_DIR/events_eventsapi.json" "$OUT_DIR/events_raw.json"
  src="events.k8s.io/v1 (${evapi_count} items)"
else
  cp "$OUT_DIR/events_core.json" "$OUT_DIR/events_raw.json"
  src="core/v1 (${core_count} items)"
fi
log "Using source: $src"

# нормализуем время (первое непустое): eventTime/series.lastObservedTime/lastTimestamp/firstTimestamp/metadata.creationTimestamp
jq -c '
.items[] |
  . as $e |
  ($e.eventTime // $e.series.lastObservedTime // $e.lastTimestamp // $e.firstTimestamp // $e.metadata.creationTimestamp) as $t |
  select($t!=null and $t!="") |
  {
    type: (.type // "Unknown"),
    reason: (.reason // ""),
    message: (.note // .message // ""),
    ns: (.regarding.namespace // .involvedObject.namespace // "default"),
    kind: (.regarding.kind // .involvedObject.kind // ""),
    name: (.regarding.name // .involvedObject.name // ""),
    component: (.deprecatedSource.component // .source.component // ""),
    eventTime: $t,
    count: (.deprecatedCount // .count // 1)
  }
' "$OUT_DIR/events_raw.json" > "$OUT_DIR/events_flat.jsonl" || echo -n > "$OUT_DIR/events_flat.jsonl"

# типы событий
if (( INCLUDE_NORMAL == 1 )); then
  jq_filter='select(.type=="Warning" or .type=="Normal")'
else
  jq_filter='select(.type=="Warning")'
fi

# фильтр по времени
> "$OUT_DIR/events_since.jsonl"
while IFS= read -r line; do
  echo "$line" | jq -e "$jq_filter" >/dev/null 2>&1 || continue
  ts=$(echo "$line" | jq -r '.eventTime')
  ep=$(to_epoch "$ts")
  [[ "$ep" -ge "$CUTOFF" ]] && echo "$line" >> "$OUT_DIR/events_since.jsonl"
done < "$OUT_DIR/events_flat.jsonl"

# summary CSV
{
  echo "NAMESPACE,KIND,NAME,TYPE,REASON,COUNT,LAST_TIME,COMPONENT"
  if [[ -s "$OUT_DIR/events_since.jsonl" ]]; then
    jq -r '[.ns,.kind,.name,.type,.reason, (.count|tostring), .eventTime, (.component//"")] | @csv' "$OUT_DIR/events_since.jsonl" | sed 's/\\"/"/g'
  fi
} > "$OUT_DIR/events_summary.csv"

# grouped text
{
  echo "== Events (since ${SINCE}) grouped by component =="
  if [[ -s "$OUT_DIR/events_since.jsonl" ]]; then
    jq -r '
      group_by(.ns+"|"+.kind+"|"+.name)[] |
      { key:(.[0].ns+"|"+.[0].kind+"|"+.[0].name),
        last_time:(max_by(.eventTime).eventTime),
        reasons:(map(.reason)|unique|join("/")),
        types:(map(.type)|unique|join("/")),
        count_sum:(map(.count)|add)
      } |
      "• \(.key) last=\(.last_time) types=\(.types) reasons=\(.reasons) totalCount=\(.count_sum)"
    ' "$OUT_DIR/events_since.jsonl"
  else
    echo "(empty)"
  fi
} > "$OUT_DIR/events_grouped.txt"

# перечислить уникальные компоненты
mapfile -t KEYS < <( ( [[ -s "$OUT_DIR/events_since.jsonl" ]] && jq -r '(.ns+"|"+.kind+"|"+.name)' "$OUT_DIR/events_since.jsonl" | sort -u ) || true )
log "Unique components to collect: ${#KEYS[@]}"

if (( LIMIT>0 && ${#KEYS[@]}>LIMIT )); then
  KEYS=("${KEYS[@]:0:LIMIT}")
  log "LIMIT active: ${#KEYS[@]}"
fi

collect_one() {
  local ns="$1" kind="$2" name="$3"
  local dir="$OUT_DIR/components/${ns}__${kind}__${name}"
  mkdir -p "$dir"
  kubectl "${KARGS[@]}" -n "$ns" describe "$kind" "$name" > "$dir/describe.txt" 2>&1 || true
  kubectl "${KARGS[@]}" -n "$ns" get "$kind" "$name" -o yaml > "$dir/resource.yaml" 2>&1 || true
  if [[ "$kind" == "Pod" ]]; then
    # контенеры (init + app)
    local j tmp
    j=$(kubectl "${KARGS[@]}" -n "$ns" get pod "$name" -o json 2>/dev/null || echo '{}')
    echo "$j" | jq -r '[.spec.initContainers[]?.name,.spec.containers[]?.name]|.[]' | while read -r c; do
      [[ -z "$c" ]] && continue
      kubectl "${KARGS[@]}" -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" > "$dir/logs_${c}.log" 2>&1 || true
      kubectl "${KARGS[@]}" -n "$ns" logs "$name" -c "$c" --tail="$LOGS_TAIL" -p > "$dir/logs_${c}_previous.log" 2>&1 || true
    done
  fi
}

idx=0
for key in "${KEYS[@]}"; do
  idx=$((idx+1))
  ns="${key%%|*}"; rest="${key#*|}"; kind="${rest%%|*}"; name="${rest#*|}"
  log "[$idx/${#KEYS[@]}] Collect ns=$ns kind=$kind name=$name"
  collect_one "$ns" "$kind" "$name"
done

cat > "$OUT_DIR/README.txt" <<EOF
Events triage v3
Source: $src
Window: $SINCE
Include Normal: $INCLUDE_NORMAL
Out: $OUT_DIR

Files:
- events_core.json / events_eventsapi.json : сырые версии
- events_raw.json                          : выбранный источник
- events_flat.jsonl                        : нормализованные события
- events_since.jsonl                       : отфильтровано по времени и типу
- events_summary.csv                       : таблица для обзора
- events_grouped.txt                       : сгруппировано по объектам
- components/*                             : describe/yaml и логи (для Pod)
EOF

log "Done"
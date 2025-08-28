#!/usr/bin/env bash
set -euo pipefail

# Настройки окружения
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
NS_FILTER="${NAMESPACE:-}"          # если пусто — все ns
LABEL_SELECTOR="${LABEL_SELECTOR:-}"# если пусто — без селектора
OUTPUT_MODE="${OUTPUT_MODE:-ndjson}"# ndjson|table
KUBECONFIG_FLAG="${KUBECONFIG_FLAG:-}" # например: --kubeconfig=/path/kubeconfig

# Хелпер для построения field-selector по ns
ns_args() {
  if [[ -n "$NS_FILTER" ]]; then
    echo "-n ${NS_FILTER}"
  fi
}

# Хелпер для label-selector
ls_args() {
  if [[ -n "$LABEL_SELECTOR" ]]; then
    echo "--selector=${LABEL_SELECTOR}"
  fi
}

# Безопасная проверка существования ресурса
exists() {
  local kind="$1"; local ns="$2"; local name="$3"
  if [[ -n "$ns" ]]; then
    ${KUBECTL_BIN} ${KUBECONFIG_FLAG} get "$kind" "$name" -n "$ns" --no-headers >/dev/null 2>&1
  else
    ${KUBECTL_BIN} ${KUBECONFIG_FLAG} get "$kind" "$name" --no-headers >/dev/null 2>&1
  fi
}

# Печать NDJSON строки
emit_issue() {
  # args: kind ns name code message context_json
  local kind="$1"; shift
  local ns="$1"; shift
  local name="$1"; shift
  local code="$1"; shift
  local message="$1"; shift
  local ctx="${1:-{}}"

  jq -cn \
    --arg kind "$kind" \
    --arg ns "$ns" \
    --arg name "$name" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson ctx "$ctx" \
    '{kind:$kind, namespace:$ns, name:$name, issue:{code:$code, message:$message, context:$ctx}}'
}

# Примитивная маскировка (по аналогии с util.MaskString)
mask() {
  local s="$1"
  if (( ${#s} <= 4 )); then
    printf '***'
  else
    printf '%s***' "${s:0:2}"
  fi
}
#!/usr/bin/env bash
set -euo pipefail

# Параметры
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
NAMESPACE="${NAMESPACE:-}"
LABEL_SELECTOR="${LABEL_SELECTOR:-}"
OUTPUT="${OUTPUT:-ndjson}"  # ndjson|table
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LABEL_SELECTOR NAMESPACE
export KUBECONFIG_FLAG=""
[[ -n "$KUBECONFIG_PATH" ]] && export KUBECONFIG_FLAG="--kubeconfig=${KUBECONFIG_PATH}"

tmp_ndjson="$(mktemp)"
trap 'rm -f "$tmp_ndjson"' EXIT

# Запуск анализаторов (можно распараллелить & и wait)
"${BIN_DIR}/analyze_pods.sh"        >> "$tmp_ndjson"
"${BIN_DIR}/analyze_nodes.sh"       >> "$tmp_ndjson"
"${BIN_DIR}/analyze_ingress.sh"     >> "$tmp_ndjson"
"${BIN_DIR}/analyze_deployments.sh" >> "$tmp_ndjson"

if [[ "$OUTPUT" == "ndjson" ]]; then
  cat "$tmp_ndjson"
  exit 0
fi

# Табличное резюме
echo -e "KIND\tNAMESPACE\tNAME\tCODE\tMESSAGE"
jq -r '[.kind, .namespace, .name, .issue.code, (.issue.message|gsub("[\\r\\n\\t]";" "))] | @tsv' "$tmp_ndjson"
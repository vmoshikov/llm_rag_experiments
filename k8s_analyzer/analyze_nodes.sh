#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NODES_JSON="$(${KUBECTL_BIN} ${KUBECONFIG_FLAG} get nodes -o json)"
echo "$NODES_JSON" | jq -r '
  .items[]
  | {name:.metadata.name, conds:(.status.conditions // [])}
  | @base64' | while read -r row; do
  obj="$(echo "$row" | base64 --decode)"
  name=$(echo "$obj" | jq -r '.name')
  # Ready False/Unknown
  echo "$obj" | jq -r '
    .conds[]
    | select(.type=="Ready" and (.status=="False" or .status=="Unknown"))
    | {type:.type, status:.status, message:(.message // .reason // "not ready")}
    | @base64' | while read -r r2; do
    o2="$(echo "$r2" | base64 --decode)"
    msg=$(echo "$o2" | jq -r '.message')
    st=$(echo "$o2" | jq -r '.status')
    ctx=$(jq -cn --arg status "$st" '{status:$status}')
    emit_issue "Node" "" "$name" "NODE_NOT_READY" "$msg" "$ctx"
  done
  # Pressures + NetworkUnavailable True
  echo "$obj" | jq -r '
    .conds[]
    | select((.type=="DiskPressure" or .type=="MemoryPressure" or .type=="PIDPressure" or .type=="NetworkUnavailable") and .status=="True")
    | {type:.type, message:(.message // .reason // .type)}
    | @base64' | while read -r r3; do
    o3="$(echo "$r3" | base64 --decode)"
    typ=$(echo "$o3" | jq -r '.type'); msg=$(echo "$o3" | jq -r '.message')
    ctx=$(jq -cn --arg condition "$typ" '{condition:$condition}')
    emit_issue "Node" "" "$name" "NODE_CONDITION" "$msg" "$ctx"
  done
done
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEPS_JSON="$(${KUBECTL_BIN} ${KUBECONFIG_FLAG} get deploy $(ns_args) $(ls_args) -o json)"

# gap по репликам
echo "$DEPS_JSON" | jq -r '
  .items[]
  | {
      ns: .metadata.namespace,
      name: .metadata.name,
      desired: (.spec.replicas // 1),
      available: (.status.availableReplicas // 0),
      conditions: (.status.conditions // [])
    }
  | @base64' | while read -r row; do
  obj="$(echo "$row" | base64 --decode)"
  ns=$(echo "$obj" | jq -r '.ns'); name=$(echo "$obj" | jq -r '.name')
  desired=$(echo "$obj" | jq -r '.desired'); available=$(echo "$obj" | jq -r '.available')
  if (( available < desired )); then
    ctx=$(jq -cn --argjson desired "$desired" --argjson available "$available" '{desired:$desired, available:$available}')
    emit_issue "Deployment" "$ns" "$name" "DEPLOYMENT_REPLICA_GAP" "Available replicas less than desired" "$ctx"
  fi

  # Conditions
  echo "$obj" | jq -r '
    .conditions[]?
    | select((.type=="Progressing" and .status=="False" and .reason=="ProgressDeadlineExceeded")
             or (.type=="Available" and .status=="False"))
    | {type:.type, reason:.reason, message:(.message // .reason // .type)}
    | @base64' | while read -r r2; do
    o2="$(echo "$r2" | base64 --decode)"
    typ=$(echo "$o2" | jq -r '.type'); reason=$(echo "$o2" | jq -r '.reason'); msg=$(echo "$o2" | jq -r '.message')
    code="DEPLOYMENT_CONDITION"
    [[ "$typ" == "Progressing" && "$reason" == "ProgressDeadlineExceeded" ]] && code="DEPLOYMENT_PROGRESS_DEADLINE_EXCEEDED"
    ctx=$(jq -cn --arg type "$typ" --arg reason "$reason" '{type:$type, reason:$reason}')
    emit_issue "Deployment" "$ns" "$name" "$code" "$msg" "$ctx"
  done

  # Selector vs template labels (быстрый smoke)
  selKeys="$(echo "$DEPS_JSON" | jq -r --arg ns "$ns" --arg name "$name" \
    '.items[]|select(.metadata.namespace==$ns and .metadata.name==$name)|.spec.selector.matchLabels|keys[]?' 2>/dev/null || true)"
  if [[ -n "$selKeys" ]]; then
    mismatch="false"
    while read -r k; do
      [[ -z "$k" ]] && continue
      v_sel=$(echo "$DEPS_JSON" | jq -r --arg ns "$ns" --arg name "$name" --arg k "$k" \
        '.items[]|select(.metadata.namespace==$ns and .metadata.name==$name)|.spec.selector.matchLabels[$k]')
      v_tpl=$(echo "$DEPS_JSON" | jq -r --arg ns "$ns" --arg name "$name" --arg k "$k" \
        '.items[]|select(.metadata.namespace==$ns and .metadata.name==$name)|.spec.template.metadata.labels[$k]')
      if [[ "$v_sel" != "$v_tpl" ]]; then mismatch="true"; break; fi
    done <<< "$selKeys"
    if [[ "$mismatch" == "true" ]]; then
      emit_issue "Deployment" "$ns" "$name" "DEPLOYMENT_SELECTOR_MISMATCH" "spec.selector.matchLabels does not match template labels" '{}'
    fi
  fi
done
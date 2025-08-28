#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PODS_JSON="$(${KUBECTL_BIN} ${KUBECONFIG_FLAG} get pods $(ns_args) $(ls_args) -o json)"

# 1) Pending + Unschedulable
echo "$PODS_JSON" | jq -r '
  .items[]
  | select(.status.phase=="Pending")
  | {
      ns: .metadata.namespace,
      name: .metadata.name,
      conds: (.status.conditions // [])
    }
  | .conds[]
  | select(.type=="PodScheduled" and .reason=="Unschedulable")
  | @base64' | while read -r row; do
  obj="$(echo "$row" | base64 --decode)"
  ns=$(echo "$obj" | jq -r '.ns')
  name=$(echo "$obj" | jq -r '.name')
  msg=$(echo "$obj" | jq -r '.message // "Unschedulable"')
  emit_issue "Pod" "$ns" "$name" "POD_UNSCHEDULABLE" "$msg" '{}'
done

# 2) ContainerStatuses (init + app)
for STAT_PATH in '.status.initContainerStatuses' '.status.containerStatuses'; do
  echo "$PODS_JSON" | jq -r --arg sp "$STAT_PATH" '
    .items[]
    | {
        ns: .metadata.namespace,
        name: .metadata.name,
        phase: .status.phase,
        statuses: (getpath(($sp|split(".")|map(select(length>0)))) // [])
      }
    | @base64' | while read -r row; do
    obj="$(echo "$row" | base64 --decode)"
    ns=$(echo "$obj" | jq -r '.ns'); name=$(echo "$obj" | jq -r '.name'); phase=$(echo "$obj" | jq -r '.phase')

    # CrashLoopBackOff
    echo "$obj" | jq -r '
      .statuses[]?
      | select(.state.waiting.reason=="CrashLoopBackOff" and .lastTerminationState.terminated!=null)
      | {container:.name, reason:.lastTerminationState.terminated.reason, exit:.lastTerminationState.terminated.exitCode}
      | @base64' | while read -r r2; do
      o2="$(echo "$r2" | base64 --decode)"
      cont=$(echo "$o2" | jq -r '.container')
      reason=$(echo "$o2" | jq -r '.reason // "Unknown"')
      exitc=$(echo "$o2" | jq -r '.exit')
      ctx=$(jq -cn --arg container "$cont" --arg reason "$reason" --argjson exit "$exitc" '{container:$container, lastTerminationReason:$reason, exitCode:$exit}')
      emit_issue "Pod" "$ns" "$name" "POD_CRASH_LOOP" "Container CrashLoopBackOff" "$ctx"
    done

    # ImagePull / CreateContainer / InvalidImageName и т.п.
    echo "$obj" | jq -r '
      .statuses[]?
      | select(.state.waiting!=null)
      | {container:.name, reason:.state.waiting.reason, message:(.state.waiting.message // .state.waiting.reason)}
      | select(.reason|IN("ImagePullBackOff","ErrImagePull","CreateContainerError","CreateContainerConfigError","RunContainerError","InvalidImageName","ImageInspectError","ErrImageNeverPull"))
      | @base64' | while read -r r3; do
      o3="$(echo "$r3" | base64 --decode)"
      cont=$(echo "$o3" | jq -r '.container')
      reason=$(echo "$o3" | jq -r '.reason')
      msg=$(echo "$o3" | jq -r '.message')
      ctx=$(jq -cn --arg container "$cont" --arg reason "$reason" '{container:$container, reason:$reason}')
      emit_issue "Pod" "$ns" "$name" "POD_IMAGE_OR_CREATE_ERROR" "$msg" "$ctx"
    done

    # Terminated != 0
    echo "$obj" | jq -r '
      .statuses[]?
      | select(.state.terminated!=null and .state.terminated.exitCode!=0)
      | {container:.name, reason:(.state.terminated.reason // "Unknown"), exit:.state.terminated.exitCode}
      | @base64' | while read -r r4; do
      o4="$(echo "$r4" | base64 --decode)"
      cont=$(echo "$o4" | jq -r '.container')
      reason=$(echo "$o4" | jq -r '.reason')
      exitc=$(echo "$o4" | jq -r '.exit')
      ctx=$(jq -cn --arg container "$cont" --arg reason "$reason" --argjson exit "$exitc" '{container:$container, reason:$reason, exitCode:$exit}')
      emit_issue "Pod" "$ns" "$name" "POD_TERMINATED_ABNORMALLY" "Container terminated abnormally" "$ctx"
    done
  done
done
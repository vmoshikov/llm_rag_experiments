#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ING_JSON="$(${KUBECTL_BIN} ${KUBECONFIG_FLAG} get ingress $(ns_args) $(ls_args) -o json)"
echo "$ING_JSON" | jq -r '
  .items[]
  | {
      ns: .metadata.namespace,
      name: .metadata.name,
      iclass: (.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"] // ""),
      rules: (.spec.rules // []),
      tls:   (.spec.tls // [])
    }
  | @base64' | while read -r row; do
  obj="$(echo "$row" | base64 --decode)"
  ns=$(echo "$obj" | jq -r '.ns'); name=$(echo "$obj" | jq -r '.name')
  iclass=$(echo "$obj" | jq -r '.iclass')

  # IngressClass present?
  if [[ -z "$iclass" ]]; then
    emit_issue "Ingress" "$ns" "$name" "INGRESS_NO_CLASS" "IngressClass not specified" '{}'
  else
    if ! exists "ingressclass" "" "$iclass"; then
      ctx=$(jq -cn --arg ic "$iclass" '{ingressClassName:$ic}')
      emit_issue "Ingress" "$ns" "$name" "INGRESS_CLASS_NOT_FOUND" "IngressClass not found" "$ctx"
    }
  fi

  # Rules -> backends
  echo "$obj" | jq -r '
    .rules[]? | {host:.host, paths:(.http.paths // [])}
    | .paths[]?
    | {host:.host, svc:(.backend.service.name // ""), portName:(.backend.service.port.name // ""), portNumber:(.backend.service.port.number // 0)}
    | @base64' | while read -r r2; do
    o2="$(echo "$r2" | base64 --decode)"
    host=$(echo "$o2" | jq -r '.host // ""')
    svc=$(echo "$o2" | jq -r '.svc // ""')
    pName=$(echo "$o2" | jq -r '.portName // ""')
    pNum=$(echo "$o2" | jq -r '.portNumber // 0')

    if [[ -z "$svc" ]]; then
      ctx=$(jq -cn --arg host "$host" '{host:$host}')
      emit_issue "Ingress" "$ns" "$name" "INGRESS_BACKEND_MISSING" "Backend service not specified" "$ctx"
      continue
    fi
    if ! exists "service" "$ns" "$svc"; then
      ctx=$(jq -cn --arg host "$host" --arg svc "$svc" '{host:$host, service:$svc}')
      emit_issue "Ingress" "$ns" "$name" "INGRESS_SERVICE_NOT_FOUND" "Backend service does not exist" "$ctx"
      continue
    fi

    # Проверка порта сервиса
    SVC_JSON="$(${KUBECTL_BIN} ${KUBECONFIG_FLAG} get svc "$svc" -n "$ns" -o json)"
    port_ok="false"
    if [[ -n "$pName" ]]; then
      found=$(echo "$SVC_JSON" | jq -r --arg p "$pName" '[.spec.ports[]?|select(.name==$p)]|length')
      [[ "$found" -gt 0 ]] && port_ok="true"
    elif [[ "$pNum" -ne 0 ]]; then
      found=$(echo "$SVC_JSON" | jq -r --argjson n "$pNum" '[.spec.ports[]?|select(.port==$n)]|length')
      [[ "$found" -gt 0 ]] && port_ok="true"
    else
      # ни name, ни number
      :
    fi
    if [[ "$port_ok" != "true" ]]; then
      ctx=$(jq -cn --arg host "$host" --arg svc "$svc" --arg pName "$pName" --argjson pNum "$pNum" '{host:$host, service:$svc, portName:$pName, portNumber:$pNum}')
      emit_issue "Ingress" "$ns" "$name" "INGRESS_SERVICE_PORT_INVALID" "Service port referenced by Ingress not found" "$ctx"
    fi
  done

  # TLS -> secret presence
  echo "$obj" | jq -r '.tls[]? | {secret: .secretName} | select(.secret!=null) | @base64' | while read -r r3; do
    o3="$(echo "$r3" | base64 --decode)"
    sec=$(echo "$o3" | jq -r '.secret')
    if ! exists "secret" "$ns" "$sec"; then
      ctx=$(jq -cn --arg secret "$sec" '{secretName:$secret}')
      emit_issue "Ingress" "$ns" "$name" "INGRESS_TLS_SECRET_NOT_FOUND" "TLS secret not found" "$ctx"
    fi
  done
done
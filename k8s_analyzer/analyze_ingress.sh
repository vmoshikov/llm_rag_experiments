#!/usr/bin/env bash
# analyze_ingress.sh
# Проверка Ingress: ingressClass, backend service/port, TLS secret
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NS_FILTER="${NAMESPACE:-}"
LABEL_SELECTOR="${LABEL_SELECTOR:-}"

NS_ARGS=""
if [ -n "$NS_FILTER" ]; then
  NS_ARGS="-n $NS_FILTER"
else
  NS_ARGS="-A"
fi

SEL_ARGS=""
if [ -n "$LABEL_SELECTOR" ]; then
  SEL_ARGS="--selector=${LABEL_SELECTOR}"
fi

# Хелпер существования ресурса (kind ns name)
exists() {
  local kind="$1" ns="$2" name="$3"
  if [ -n "$ns" ]; then
    $KUBECTL get "$kind" "$name" -n "$ns" --no-headers >/dev/null 2>&1
  else
    $KUBECTL get "$kind" "$name" --no-headers >/dev/null 2>&1
  fi
}

# Получаем ingress’ы
ING_JSON="$($KUBECTL get ingress $NS_ARGS $SEL_ARGS -o json 2>/dev/null || echo '{"items": []}')"

COUNT="$(echo "$ING_JSON" | jq '.items | length')"
if [ "$COUNT" -eq 0 ]; then
  echo "[INGRESS] No Ingress resources found ($NS_ARGS $SEL_ARGS)"
  exit 0
fi

# === 1) Проверка наличия/существования ingressClass ===
echo "$ING_JSON" | jq -r '
  .items[] |
  select((.spec.ingressClassName // (.metadata.annotations["kubernetes.io/ingress.class"] // "")) == "") |
  "[INGRESS] \(.metadata.namespace)/\(.metadata.name) — Missing ingressClass"
' || true

echo "$ING_JSON" | jq -r '
  .items[] |
  . as $ing |
  (.spec.ingressClassName // ($ing.metadata.annotations["kubernetes.io/ingress.class"] // "")) as $ic |
  select($ic != "") |
  "\($ing.metadata.namespace)\t\($ing.metadata.name)\t\($ic)"
' | while IFS=$'\t' read -r ns name iclass; do
  if ! exists "ingressclass" "" "$iclass"; then
    echo "[INGRESS] ${ns}/${name} — IngressClass not found: ${iclass}"
  fi
done

# === 2) Backend service/port проверки ===
echo "$ING_JSON" | jq -r '
  .items[] as $ing
  | ($ing.spec.rules // [])[]
  | .http.paths // []
  | .[]
  | .backend.service as $svc
  | [$ing.metadata.namespace, $ing.metadata.name,
     ($svc.name // ""), ($svc.port.name // ""), (if ($svc.port.number // 0) then ($svc.port.number|tostring) else "" end)]
  | @tsv
' 2>/dev/null | while IFS=$'\t' read -r ns name svc portName portNum; do
  if [ -z "${svc:-}" ]; then
    echo "[INGRESS] ${ns}/${name} — Backend service not specified"
    continue
  fi
  if ! exists "service" "$ns" "$svc"; then
    echo "[INGRESS] ${ns}/${name} — Service not found: ${svc}"
    continue
  fi

  SVC_JSON="$($KUBECTL get svc "$svc" -n "$ns" -o json)"
  if [ -n "${portName:-}" ]; then
    found_name="$(echo "$SVC_JSON" | jq -r --arg pn "$portName" '[.spec.ports[]?|select(.name==$pn)]|length')"
    if [ "$found_name" = "0" ]; then
      echo "[INGRESS] ${ns}/${name} — Service port name not found: ${svc}.${portName}"
    fi
  elif [ -n "${portNum:-}" ]; then
    found_num="$(echo "$SVC_JSON" | jq -r --argjson pn "$(echo "${portNum:-0}" | sed 's/[^0-9]//g')" '[.spec.ports[]?|select(.port==$pn)]|length')"
    if [ "$found_num" = "0" ]; then
      echo "[INGRESS] ${ns}/${name} — Service port number not found: ${svc}:${portNum}"
    fi
  else
    echo "[INGRESS] ${ns}/${name} — Backend port is missing for service: ${svc}"
  fi
done

# === 3) TLS secret проверки ===
echo "$ING_JSON" | jq -r '
  .items[] as $ing
  | ($ing.spec.tls // [])[]
  | select(.secretName != null)
  | "\($ing.metadata.namespace)\t\($ing.metadata.name)\t\(.secretName)"
' 2>/dev/null | while IFS=$'\t' read -r ns name secret; do
  if ! exists "secret" "$ns" "$secret"; then
    echo "[INGRESS] ${ns}/${name} — TLS secret not found: ${secret}"
  fi
done
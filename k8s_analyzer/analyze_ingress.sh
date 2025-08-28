#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

# Хелпер: существует ли ресурс (kind ns name)
exists() {
  local kind="$1" ns="$2" name="$3"
  if [[ -n "$ns" ]]; then
    "$KUBECTL" get "$kind" "$name" -n "$ns" --no-headers >/dev/null 2>&1
  else
    "$KUBECTL" get "$kind" "$name" --no-headers >/dev/null 2>&1
  fi
}

# Снимок всех ingress’ов одним вызовом
ING_JSON="$("$KUBECTL" get ingress -A -o json)"

# 1) Простейшие проверки внутри jq (ingressClass, backend basic)
echo "$ING_JSON" | jq -r '
  .items[] as $ing
  | (
      if
        ($ing.spec.ingressClassName // ($ing.metadata.annotations["kubernetes.io/ingress.class"] // null)) == null
      then
        "[INGRESS] \($ing.metadata.namespace)/\($ing.metadata.name) — Missing ingressClass"
      else empty end
    ),
    (
      ($ing.spec.rules // [])
      | .[]?
      | .http.paths // []
      | .[]?
      | select(.backend.service != null)
      | "[INGRESS] \($ing.metadata.namespace)/\($ing.metadata.name) — backend service=\(.backend.service.name) port=\(.backend.service.port.number // .backend.service.port.name)"
    )
' | grep -v '^null$' || true

# 2) Глубокая валидация с обращением к API: existence service/port и tls secret
#    (делаем вне jq, чтобы избежать синтаксических ловушек)
# Разворачиваем список для последующих проверок
mapfile -t ITEMS < <(echo "$ING_JSON" | jq -r '
  .items[]
  | {
      ns: .metadata.namespace,
      name: .metadata.name,
      iclass: (.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"] // ""),
      rules: (.spec.rules // []),
      tls: (.spec.tls // [])
    }
  | @base64
')

for row in "${ITEMS[@]}"; do
  obj="$(echo "$row" | base64 --decode)"
  ns="$(echo "$obj" | jq -r '.ns')"
  name="$(echo "$obj" | jq -r '.name')"
  iclass="$(echo "$obj" | jq -r '.iclass')"

  # ingressClass exists?
  if [[ -n "$iclass" ]]; then
    if ! exists "ingressclass" "" "$iclass"; then
      echo "[INGRESS] ${ns}/${name} — IngressClass not found: ${iclass}"
    fi
  fi

  # Backend services & ports
  mapfile -t PATHS < <(echo "$obj" | jq -r '
    .rules[]? | .http.paths // [] | .[]?
    | {svc:(.backend.service.name // ""), portName:(.backend.service.port.name // ""), portNum:(.backend.service.port.number // 0)}
    | @base64
  ')
  for p in "${PATHS[@]:-}"; do
    [[ -z "${p:-}" ]] && continue
    o="$(echo "$p" | base64 --decode)"
    svc="$(echo "$o" | jq -r '.svc')"
    portName="$(echo "$o" | jq -r '.portName')"
    portNum="$(echo "$o" | jq -r '.portNum')"

    if [[ -z "$svc" ]]; then
      echo "[INGRESS] ${ns}/${name} — Backend service not specified"
      continue
    fi
    if ! exists "service" "$ns" "$svc"; then
      echo "[INGRESS] ${ns}/${name} — Service not found: ${svc}"
      continue
    fi
    # Проверка порта в сервисе
    SVC_JSON="$("$KUBECTL" get svc "$svc" -n "$ns" -o json)"
    if [[ -n "$portName" ]]; then
      found="$(echo "$SVC_JSON" | jq -r --arg pn "$portName" '[.spec.ports[]?|select(.name==$pn)]|length')"
      if [[ "$found" -eq 0 ]]; then
        echo "[INGRESS] ${ns}/${name} — Service port name not found: ${svc}.${portName}"
      fi
    elif [[ "$portNum" -ne 0 ]]; then
      found="$(echo "$SVC_JSON" | jq -r --argjson pn "$portNum" '[.spec.ports[]?|select(.port==$pn)]|length')"
      if [[ "$found" -eq 0 ]]; then
        echo "[INGRESS] ${ns}/${name} — Service port number not found: ${svc}:${portNum}"
      fi
    else
      echo "[INGRESS] ${ns}/${name} — Backend port is missing for service: ${svc}"
    fi
  done

  # TLS secrets
  mapfile -t TLS_ITEMS < <(echo "$obj" | jq -r '.tls[]? | select(.secretName!=null) | .secretName')
  for sec in "${TLS_ITEMS[@]:-}"; do
    [[ -z "${sec:-}" ]] && continue
    if ! exists "secret" "$ns" "$sec"; then
      echo "[INGRESS] ${ns}/${name} — TLS secret not found: ${sec}"
    fi
  done
done
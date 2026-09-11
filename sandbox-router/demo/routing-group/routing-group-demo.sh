#!/usr/bin/env bash
set -euo pipefail

KUBE_CLI="${KUBE_CLI:-oc}"
NAMESPACE="${NAMESPACE:-default}"
ROUTING_GROUP="${ROUTING_GROUP:-test-group}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8080}"
SANDBOX_PORT="${SANDBOX_PORT:-8080}"
REQUEST_PATH="${REQUEST_PATH:-/invoke-agent}"
REQUESTS="${REQUESTS:-12}"

list_eligible_group_pods() {
  "${KUBE_CLI}" -n "${NAMESPACE}" get pods \
    -l "sandbox.users.io/routing-group=${ROUTING_GROUP}" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{$pod := .}}{{range .status.conditions}}{{if and (eq .type "Ready") (eq .status "True")}}{{printf "%s\n" $pod.metadata.name}}{{end}}{{end}}{{end}}{{end}}' \
    2>/dev/null | sort
}

echo "Eligible Ready Pods in routing group ${ROUTING_GROUP}:"
list_eligible_group_pods | sed 's/^/  /'

echo
echo "Sending ${REQUESTS} requests using X-Sandbox-Group only:"
for ((i=1; i<=REQUESTS; i++)); do
  backend="$(
    curl --fail --silent --show-error \
      -H "X-Sandbox-Group: ${ROUTING_GROUP}" \
      -H "X-Sandbox-Namespace: ${NAMESPACE}" \
      -H "X-Sandbox-Port: ${SANDBOX_PORT}" \
      "${ROUTER_URL}${REQUEST_PATH}" | tr -d '\r\n'
  )"
  printf 'request %02d: %s\n' "${i}" "${backend}"
done

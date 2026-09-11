#!/usr/bin/env bash
set -euo pipefail

KUBE_CLI="${KUBE_CLI:-oc}"
NAMESPACE="${NAMESPACE:-default}"
ROUTER_NAMESPACE="${ROUTER_NAMESPACE:-agent-sandbox-system}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
ROUTER_URL="http://127.0.0.1:${LOCAL_PORT}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_LOG="${TMPDIR:-/tmp}/routing-group-port-forward.log"

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo '$ oc apply -f demo.yaml'
"${KUBE_CLI}" apply -f "${DIR}/demo.yaml"
echo

echo '$ oc wait --for=condition=Ready sandboxclaim/demo-a sandboxclaim/demo-b sandboxclaim/demo-c --timeout=60s'
"${KUBE_CLI}" -n "${NAMESPACE}" wait \
  --for=condition=Ready \
  sandboxclaim/demo-a sandboxclaim/demo-b sandboxclaim/demo-c \
  --timeout=60s
echo

: >"${PF_LOG}"
"${KUBE_CLI}" -n "${ROUTER_NAMESPACE}" port-forward \
  svc/sandbox-router-svc "${LOCAL_PORT}:8080" \
  >"${PF_LOG}" 2>&1 &
PF_PID=$!

for _ in $(seq 1 50); do
  if grep -q "Forwarding from" "${PF_LOG}"; then
    break
  fi
  if ! kill -0 "${PF_PID}" >/dev/null 2>&1; then
    echo "port-forward exited unexpectedly:" >&2
    cat "${PF_LOG}" >&2
    exit 1
  fi
  sleep 0.1
done

if ! grep -q "Forwarding from" "${PF_LOG}"; then
  echo "port-forward did not become ready" >&2
  cat "${PF_LOG}" >&2
  exit 1
fi

echo '$ oc get sandboxclaim'
"${KUBE_CLI}" -n "${NAMESPACE}" get sandboxclaim
echo

echo '$ ./routing-group-demo.sh'
ROUTER_URL="${ROUTER_URL}" REQUESTS=6 "${DIR}/routing-group-demo.sh"
echo

echo '$ ./routing-group-failover-test.sh demo-b'
ROUTER_URL="${ROUTER_URL}" VERIFY_REQUESTS=8 "${DIR}/routing-group-failover-test.sh" demo-b

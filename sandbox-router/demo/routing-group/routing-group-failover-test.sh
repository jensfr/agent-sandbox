#!/usr/bin/env bash
set -euo pipefail

CLAIM_TO_DELETE="${1:-}"
[[ -n "${CLAIM_TO_DELETE}" ]] || { echo "usage: $0 <claim-to-delete>" >&2; exit 2; }

KUBE_CLI="${KUBE_CLI:-oc}"
NAMESPACE="${NAMESPACE:-default}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8080}"
SANDBOX_PORT="${SANDBOX_PORT:-8080}"
REQUEST_PATH="${REQUEST_PATH:-/invoke-agent}"
INITIAL_REQUESTS="${INITIAL_REQUESTS:-12}"
VERIFY_REQUESTS="${VERIFY_REQUESTS:-30}"
FAILOVER_TIMEOUT_SECONDS="${FAILOVER_TIMEOUT_SECONDS:-8}"
FAILOVER_POLL_SECONDS="${FAILOVER_POLL_SECONDS:-0.10}"
LABEL_KEY="sandbox.users.io/routing-group"

contains_line() {
  local needle="$1"
  grep -Fxq -- "${needle}"
}

request() {
  curl --fail --silent --show-error \
    --connect-timeout 2 \
    --max-time 5 \
    -H "X-Sandbox-Group: ${ROUTING_GROUP}" \
    -H "X-Sandbox-Namespace: ${NAMESPACE}" \
    -H "X-Sandbox-Port: ${SANDBOX_PORT}" \
    "${ROUTER_URL}${REQUEST_PATH}" | tr -d '\r\n'
}

list_group_pods() {
  "${KUBE_CLI}" -n "${NAMESPACE}" get pods \
    -l "${LABEL_KEY}=${ROUTING_GROUP}" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{$pod := .}}{{range .status.conditions}}{{if and (eq .type "Ready") (eq .status "True")}}{{printf "%s\n" $pod.metadata.name}}{{end}}{{end}}{{end}}{{end}}' \
    2>/dev/null | sort
}

echo "== Routing-group failover test =="
echo "namespace:       ${NAMESPACE}"
echo "router:          ${ROUTER_URL}"
echo "claim to delete: ${CLAIM_TO_DELETE}"
echo

echo "1. Resolve claim -> sandbox"
TARGET_SANDBOX="$("${KUBE_CLI}" -n "${NAMESPACE}" get sandboxclaim "${CLAIM_TO_DELETE}" \
  -o jsonpath='{.status.sandbox.name}')"
[[ -n "${TARGET_SANDBOX}" ]] || { echo "FAIL: claim is not bound" >&2; exit 1; }
echo "   ${CLAIM_TO_DELETE} -> ${TARGET_SANDBOX}"

echo
echo "2. Discover routing group from claimed sandbox pod"
ROUTING_GROUP="$("${KUBE_CLI}" -n "${NAMESPACE}" get pod "${TARGET_SANDBOX}" \
  -o 'jsonpath={.metadata.labels.sandbox\.users\.io/routing-group}')"
[[ -n "${ROUTING_GROUP}" ]] || { echo "FAIL: no routing-group label" >&2; exit 1; }
echo "   routing group: ${ROUTING_GROUP}"

echo
echo "3. Current eligible group members"
mapfile -t INITIAL_MEMBERS < <(list_group_pods)
(( ${#INITIAL_MEMBERS[@]} >= 2 )) || { echo "FAIL: need at least two eligible members" >&2; exit 1; }
printf '   %s\n' "${INITIAL_MEMBERS[@]}"

mapfile -t EXPECTED_AFTER < <(printf '%s\n' "${INITIAL_MEMBERS[@]}" | grep -Fvx -- "${TARGET_SANDBOX}")

echo
echo "4. Pre-delete routing check (${INITIAL_REQUESTS} requests)"
for ((i=1; i<=INITIAL_REQUESTS; i++)); do
  backend="$(request)"
  printf '   request %02d: %s\n' "${i}" "${backend}"
  printf '%s\n' "${INITIAL_MEMBERS[@]}" | contains_line "${backend}" || {
    echo "FAIL: unexpected backend ${backend}" >&2
    exit 1
  }
done

echo
echo "5. Delete claim without waiting for garbage collection"
"${KUBE_CLI}" -n "${NAMESPACE}" delete sandboxclaim "${CLAIM_TO_DELETE}" --wait=false

echo
echo "6. Wait until backing pod is terminating or already gone"
deadline=$((SECONDS + FAILOVER_TIMEOUT_SECONDS))
while true; do
  if ! pod_state="$("${KUBE_CLI}" -n "${NAMESPACE}" get pod "${TARGET_SANDBOX}" \
      -o jsonpath='{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null)"; then
    echo "   pod ${TARGET_SANDBOX} is already gone"
    break
  fi

  deletion_timestamp="${pod_state%%|*}"
  ready="${pod_state#*|}"

  if [[ -n "${deletion_timestamp}" ]]; then
    echo "   deletionTimestamp=${deletion_timestamp}, Ready=${ready:-unknown}"
    break
  fi

  (( SECONDS < deadline )) || { echo "FAIL: pod did not start terminating" >&2; exit 1; }
  sleep "${FAILOVER_POLL_SECONDS}"
done

echo
echo "7. Wait for router cache convergence"
clean_streak=0
deadline=$((SECONDS + FAILOVER_TIMEOUT_SECONDS))
attempt=0
while (( clean_streak < 6 )); do
  ((attempt+=1))
  backend="$(request)"
  if [[ "${backend}" == "${TARGET_SANDBOX}" ]]; then
    clean_streak=0
    printf '   attempt %02d: %s  <-- still selected\n' "${attempt}" "${backend}"
  else
    ((clean_streak+=1))
    printf '   attempt %02d: %s\n' "${attempt}" "${backend}"
  fi
  (( SECONDS < deadline )) || { echo "FAIL: router did not converge" >&2; exit 1; }
  sleep "${FAILOVER_POLL_SECONDS}"
done

echo
echo "8. Steady-state verification (${VERIFY_REQUESTS} requests)"
declare -A SEEN_AFTER=()
for ((i=1; i<=VERIFY_REQUESTS; i++)); do
  backend="$(request)"
  printf '   request %02d: %s\n' "${i}" "${backend}"
  [[ "${backend}" != "${TARGET_SANDBOX}" ]] || {
    echo "FAIL: deleted sandbox selected again" >&2
    exit 1
  }
  printf '%s\n' "${EXPECTED_AFTER[@]}" | contains_line "${backend}" || {
    echo "FAIL: unexpected backend ${backend}" >&2
    exit 1
  }
  SEEN_AFTER["${backend}"]=1
done

echo
echo "9. Result"
echo "PASS: ${TARGET_SANDBOX} was removed from routing after claim ${CLAIM_TO_DELETE} was deleted."
echo "Remaining expected members:"
printf '   %s\n' "${EXPECTED_AFTER[@]}"

missing=0
for member in "${EXPECTED_AFTER[@]}"; do
  if [[ -z "${SEEN_AFTER[${member}]+x}" ]]; then
    echo "WARN: ${member} was not observed."
    missing=1
  fi
done
(( missing != 0 )) || echo "PASS: all remaining members were observed."

# Agent Sandbox routing latency comparison

## Goal

Compare the native OpenShift path with the Agent Sandbox router PoC while keeping the client, ingress router, workload, payload and backend set identical.

### Path A: native OpenShift

```text
client -> OpenShift HAProxy -> Service-selected Sandbox Pod
```

### Path B: sandbox-router PoC

```text
client -> OpenShift HAProxy -> sandbox-router -> Sandbox Pod
```

## Environment

| Item | Value |
|---|---|
| Date/time | 2026-09-15 ~06:00-08:30 UTC |
| Cluster | virtlab2400 (SNO) |
| OpenShift version | 4.22.13 (Kubernetes v1.35.6) |
| Node | virtlab2400, RHEL CoreOS 9.8, kernel 5.14.0-687.44.1.el9_8.x86_64, cri-o 1.35.6 |
| Agent Sandbox version | v1.0.2 (controller: `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.2`) |
| Agent Sandbox git base | `main` @ `020634d` |
| PoC branch/commit | `routing-group-poc` @ `1abd1a4` (fork: `jensfr`) |
| Sandbox router image | `quay.io/jensfr/sandbox-router:routing-group-v2` |
| Sandbox router replicas | 1 |
| Backend image | `registry.k8s.io/e2e-test-images/agnhost:2.54` |
| Backends | 3 claimed sandboxes (demo-a, demo-b, demo-c) |
| Routing group | `test-group` |
| Client location (primary) | Python pod inside cluster, connecting to `router-internal-default.openshift-ingress.svc.cluster.local:80` |
| Client location (cross-check) | local Mac via `oc port-forward` to same internal router |
| Protocol | HTTP/1.1 keep-alive |
| Requests per run | 2000 |
| Warmup requests | 200 |
| Paired rounds | 6 (alternating run order to cancel temporal bias) |

## Steady-state request latency

### Primary: in-cluster client (12,000 requests per path)

| Path | Mean | p50 | p95 | p99 | Requests/s |
|---|---:|---:|---:|---:|---:|
| Service + Route | 1.40 ms | 1.49 ms | 1.77 ms | 1.83 ms | 648 |
| Route + sandbox-router | 2.39 ms | 2.47 ms | 2.77 ms | 3.19 ms | 379 |
| **Added router cost** | **+0.99 ms** | **+0.98 ms** | **+1.00 ms** | **+1.36 ms** | **-269** |

### Cross-check: port-forward client (1,500 requests per path)

| Path | Mean | p50 | p95 | p99 | Requests/s |
|---|---:|---:|---:|---:|---:|
| Service + Route | 121.5 ms | 119.5 ms | 129.1 ms | 142.6 ms | 7.5 |
| Route + sandbox-router | 123.5 ms | 121.6 ms | 132.8 ms | 143.2 ms | 7.3 |
| **Added router cost** | **+2.0 ms** | **+2.1 ms** | **+3.8 ms** | **+0.6 ms** | **-0.2** |

Notes:

- The absolute port-forward latency (~120ms) is the SSH/VPN tunnel round-trip. It is not representative of in-cluster or production latency.
- The delta between paths is directionally consistent across both measurement methods: the sandbox-router hop adds ~1ms in-cluster, ~2ms via tunnel (the jitter is higher through the tunnel, widening the gap slightly).
- Both routes traverse the same OpenShift HAProxy ingress router and reach the same three backend sandboxes.
- The throughput difference (648 vs 379 rps) reflects single-connection serial measurement. With concurrent clients or connection pooling, throughput would scale differently.

## Membership convergence

### Claim delete

Target: `demo-pool-4dcmn` (claim `demo-b`). 4 members active before delete. Polling interval: 20ms.

| Metric | Service + Route | sandbox-router |
|---|---:|---:|
| Target seen before delete | yes | yes |
| Post-delete hits to target | 1 | 0 |
| Last hit to deleted pod after delete | 226 ms | n/a (never hit) |
| First probe after delete | 78 ms | 104 ms |

The sandbox-router evicts the pod from the routing group as soon as the informer delivers the DeletionTimestamp update. The native Service+Route path relies on the EndpointSlice controller, which took one additional probe cycle (~226ms) to reflect the change.

```text
Pod: Ready=True, DeletionTimestamp=<set>
EndpointSlice: ready=false, serving=true, terminating=true
sandbox-router cache: evicted on DeletionTimestamp
```

### Claim add

Target: `demo-pool-5h2hg` (claim `demo-d`). 3 members active before add. Polling interval: 20ms.

| Metric | Service + Route | sandbox-router |
|---|---:|---:|
| Claim create -> Claim Ready | 1,561 ms | 1,561 ms |
| Claim Ready -> first request routed to new sandbox | 936 ms | 790 ms |
| Claim create -> first request routed to new sandbox | 2,497 ms | 2,351 ms |

Both paths picked up the new member within ~1 second of the claim becoming Ready. The sandbox-router's informer-based pod watch resolved slightly faster than the EndpointSlice reconciliation.

## Result

### What is proven

- The sandbox-router PoC adds ~1ms of latency at p50/p95 for an in-cluster HTTP/1.1 request path. This is the cost of the additional Go reverse-proxy hop.
- The sandbox-router converges faster on member removal (0 stale hits) because it checks DeletionTimestamp directly, while the native EndpointSlice path has a brief window (~200ms) where a terminating pod can still receive traffic.
- The sandbox-router converges comparably on member addition (~790ms vs ~936ms from claim Ready to first traffic).
- All three routing-group capabilities (round-robin distribution, termination removal, dynamic member addition) work correctly through both the native OpenShift path and the sandbox-router path.
- A native OpenShift Service + Route with `roundrobin` balance and `disable_cookies` can serve as a viable alternative routing-group mechanism if the routing-group label is propagated to the pod (via `additionalPodMetadata`).

### What is not proven

- Production latency across a real external load balancer/TLS path.
- Large-group scalability (tested with 3-4 members only).
- High membership churn (rapid add/remove cycles).
- Multiple sandbox-router replicas with independent round-robin cursors.
- Behavior under concurrent client load (tested with single-connection serial requests).

## Reproducing this test

### Native Service + Route

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-routing-group
  namespace: default
spec:
  selector:
    sandbox.users.io/routing-group: test-group
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: demo-routing-group
  namespace: default
  annotations:
    haproxy.router.openshift.io/balance: roundrobin
    haproxy.router.openshift.io/disable_cookies: "true"
spec:
  to:
    kind: Service
    name: demo-routing-group
  port:
    targetPort: http
```

### Router Route

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: demo-via-sandbox-router
  namespace: agent-sandbox-system
spec:
  to:
    kind: Service
    name: sandbox-router-svc
  port:
    targetPort: proxy
```

### Test scripts

The measurement scripts are in the `routing-latency-study.zip` archive:
- `compare-routing-latency.py`: steady-state A/B latency comparison with configurable rounds, warmup, and concurrency.
- `measure-routing-convergence.py`: delete and add convergence measurement with per-path polling.

## Conclusion

The sandbox-router adds ~1ms per request for an in-cluster path. It converges faster on member removal than the native Kubernetes EndpointSlice path and comparably on member addition. A native OpenShift Service+Route with `additionalPodMetadata` label propagation provides the same routing-group functionality without the extra hop, at the cost of requiring OpenShift-specific annotations (`roundrobin`, `disable_cookies`) and losing the router's DeletionTimestamp-based fast eviction.

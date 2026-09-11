# Routing group proof of concept

This directory demonstrates a small proof of concept for routing one application endpoint across a group of equivalent, already claimed Agent Sandboxes.

The caller sends `X-Sandbox-Group` instead of a concrete `X-Sandbox-ID`. The router selects one Ready member of the group. The prototype uses a pod label to define membership:

```text
sandbox.users.io/routing-group: test-group
```

This is an experiment to make the routing discussion concrete. It is not a proposed final API.

## What the demo shows

The demo creates:

- one `SandboxTemplate`
- one `SandboxWarmPool` with three warm sandboxes
- three `SandboxClaim` objects
- the same routing-group label on all three claimed sandboxes

Each sandbox runs `agnhost serve-hostname`, so the HTTP response body is the name of the pod that handled the request.

With three claims, repeated requests through the router should look like:

```text
request 01: demo-pool-aaaaa
request 02: demo-pool-bbbbb
request 03: demo-pool-ccccc
request 04: demo-pool-aaaaa
...
```

Deleting one claim should remove its sandbox from routing even during the Kubernetes termination window where the pod can still report `Ready=True`.

## Prerequisites

You need:

- a Kubernetes/OpenShift cluster with Agent Sandbox core + extensions installed
- the PoC sandbox-router image deployed
- router pod cache enabled with `--cache-enabled=true`
- `oc` or `kubectl`
- `curl`

The upstream router manifests deploy `sandbox-router-svc` in `agent-sandbox-system`.

For a simple demo, use one router replica so the round-robin sequence is easy to see. Multiple router replicas each maintain their own local round-robin state.

## Deploy the demo workload

From this directory:

```bash
oc apply -f demo.yaml
```

Wait until all three claims are ready:

```bash
oc wait --for=condition=Ready \
  sandboxclaim/demo-a \
  sandboxclaim/demo-b \
  sandboxclaim/demo-c \
  --timeout=60s
```

Check the claims:

```bash
oc get sandboxclaim
```

The actual sandbox names will usually be warm-pool generated names such as `demo-pool-abcde`.

Verify that only claimed pods carry the routing-group label:

```bash
oc get pods -l sandbox.users.io/routing-group=test-group
```

Unclaimed warm-pool spares must not be routing-group members.

## Run the router

Port-forward the router in a second terminal:

```bash
oc -n agent-sandbox-system \
  port-forward svc/sandbox-router-svc 8080:8080
```

The `sandbox-router-svc` Service exposes the proxy port only. The router health probe listens separately on port 8081, so for this demo it is enough to confirm that `port-forward` reports `Forwarding from ...` and then send a routing request.

## Test group routing

Run:

```bash
./routing-group-demo.sh
```

Or send one request manually:

```bash
curl \
  -H 'X-Sandbox-Group: test-group' \
  -H 'X-Sandbox-Namespace: default' \
  -H 'X-Sandbox-Port: 8080' \
  http://127.0.0.1:8080/invoke-agent
```

The response is the backend pod name.

Run it repeatedly to see requests distributed across the three claimed sandboxes.

## Test removal during termination

Run:

```bash
./routing-group-failover-test.sh demo-b
```

The test:

1. resolves `demo-b` to its adopted sandbox
2. discovers the routing group from the pod label
3. verifies routing before deletion
4. deletes the claim with `--wait=false`
5. catches the pod while it may still be `Ready=True` but has a `DeletionTimestamp`
6. verifies that the router no longer selects that sandbox
7. sends additional requests to ensure traffic continues to the remaining members

A successful run ends with output similar to:

```text
deletionTimestamp=2026-09-11T09:42:03Z, Ready=True
...
PASS: demo-pool-xxxxx was removed from routing after claim demo-b was deleted.
PASS: all remaining members were observed.
```

## Record the demo

`record-demo.sh` runs the whole demo and starts its own router port-forward on local port `18080`:

```bash
./record-demo.sh
```

For an actual terminal recording, one simple workflow is:

```bash
asciinema rec -c './record-demo.sh' routing-group-demo.cast
agg routing-group-demo.cast routing-group-demo.gif
```

Then add `routing-group-demo.gif` to this directory and reference it from this README:

```markdown
![Routing group demo](routing-group-demo.gif)
```

Keep the recording short. The useful story is:

1. three claims are Ready
2. requests rotate across three sandboxes
3. `demo-b` is deleted
4. its pod enters termination
5. requests continue only across the two remaining sandboxes

## Notes and limitations

- This is a proof of concept, not a final routing API.
- Group membership is carried by pod metadata for the prototype.
- Unclaimed warm-pool pods are intentionally excluded.
- Terminating and NotReady pods are not eligible.
- Each router replica has its own local group state and round-robin counter.
- Large-group scalability and high membership churn have not yet been characterized.
- The caller currently supplies the namespace and port along with the group.

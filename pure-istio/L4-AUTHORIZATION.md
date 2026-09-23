# L4 authorization in the VKS Istio add-on

Response to the query: *is L4 authorization available, and how does it work
alongside NetworkPolicy and L7?*

## Available — yes

`AuthorizationPolicy` (`security.istio.io/v1`) is available and enforced at L4
by ztunnel on every connection in an ambient namespace. No waypoint, no sidecar,
and no configuration beyond the `istio.io/dataplane-mode: ambient` namespace
label is required.

At L4, ztunnel evaluates the peer's SPIFFE identity from the mTLS certificate,
its namespace and service account, and the destination port. Rules expressed in
those terms work immediately:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: server-callers
  namespace: payments
spec:
  selector:
    matchLabels:
      app: server
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/payments/sa/api"]
    to:
    - operation:
        ports: ["8080"]
```

Note the port is the **pod** port, not the Service port.

| Field | L4 (ztunnel) | L7 (needs a waypoint) |
|---|---|---|
| `source.principals` | yes | |
| `source.namespaces` | yes | |
| `source.serviceAccounts` | yes | |
| `destination.ports` | yes | |
| `operation.methods` / `paths` / `hosts` | | yes |
| `request.headers`, JWT claims | | yes |

Anything in the right-hand column needs a waypoint. ztunnel cannot parse HTTP,
and Istio denies such a policy's traffic outright rather than admit what it
cannot evaluate — it does not fail open.

## Alongside NetworkPolicy

These are complementary, not alternatives, and we would not recommend replacing
one with the other.

| | NetworkPolicy | L4 AuthorizationPolicy |
|---|---|---|
| Enforced by | CNI, on the packet path | ztunnel |
| Matches on | pod selector, namespace, CIDR | SPIFFE identity from the certificate |
| Covers non-mesh destinations | yes | no |
| Egress to arbitrary IPs | yes | no (needs an egress waypoint + ServiceEntry) |
| Survives IP reuse / relabelling | no | yes |
| Voided by removing one namespace label | no | yes |

The asymmetry that matters: Istio evaluates authorization at the *destination
workload's* ztunnel. Where the destination is not a meshed pod — external
addresses, node endpoints, the control plane — there is no ztunnel to evaluate
anything, and an AuthorizationPolicy constrains nothing. A pod under a strict
identity-based ALLOW policy, unable to reach a peer in its own namespace, can
still open connections to all of those.

It is also scoped entirely by the namespace label. Removing
`istio.io/dataplane-mode` silently voids every Istio policy in that namespace at
once; NetworkPolicy has no equivalent failure mode.

A reasonable division:

- **NetworkPolicy** — a coarse default-deny baseline per namespace, CIDR-based
  egress control, blocking node/metadata/control-plane endpoints, and any
  traffic involving non-meshed workloads.
- **AuthorizationPolicy** — service-to-service rules inside the mesh, where
  identity rather than IP is what you actually mean.

Identity is the stronger control where the two overlap: a workload cannot
acquire another workload's certificate by being relabelled or by reusing its IP.

## Alongside L7

Introducing a waypoint does not switch L4 enforcement off — both layers apply to
the same connection.

One consequence to plan for: once a Service routes through a waypoint, the
server sees the **waypoint's** identity as the peer, not the original client's.
A workload-level L4 policy must therefore include the waypoint's service account
(`cluster.local/ns/<namespace>/sa/<waypoint-name>`) or the L7 path fails with a
503 that presents as an application fault rather than a policy denial.

The failure shape is a useful first diagnostic:

- **connection reset** — refused at L4 by ztunnel; there is no HTTP response to
  carry a status code.
- **403** — refused at L7 by a waypoint.

## One operational note

The first ALLOW policy selecting a workload makes that workload default-deny:
everything not explicitly matched is refused, with no DENY policy present.
Enumerate every legitimate caller — including Prometheus and any health checkers
— before the first policy lands.

# Corrections to `istio-ambient-vks-evidence-brief.md`

Findings from a real Istio ambient build on VKS (`se-cluster-01`, Supervisor
`wld-sup`/wkld01), 2026-09-18 to 09-20. Everything below was observed, not
inferred, unless marked otherwise.

Apply these to the brief before running it. Item 1 stops the run at Phase 1.

---

## 1. BLOCKER: PodSecurity `restricted` breaks Phases 1 and 7

Phase 1 creates namespaces with `kubectl create ns`, which inherits the cluster
default. On VKS that default is **`restricted`**, enforced. Two consequences:

**The application pods are rejected.** `docker.io/kennethreitz/httpbin` runs as
root and binds `:80`. Observed rejection on this cluster:

```
pods "..." is forbidden: violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false, unrestricted capabilities,
  runAsNonRoot != true, seccompProfile
```

**The waypoint is rejected.** Istio's generated waypoint Deployment does not set
`seccompProfile` on its `istio-proxy` container:

```
pods "waypoint-..." is forbidden: violates PodSecurity "restricted:latest":
  seccompProfile (container "istio-proxy" must set
  securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The waypoint Deployment appears, stays at `0/1`, and the `Gateway` reports
`Programmed=False / AddressNotAssigned`. The real reason is only visible in
ReplicaSet events, not on the Gateway.

### Fix

Label the three namespaces at creation. `baseline` is the minimum that admits
the waypoint:

```bash
for ns in shop partner legacy; do
  kubectl create ns $ns
  kubectl label ns $ns \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted
done
```

`baseline` still blocks privileged containers, host namespaces and hostPath. It
simply does not mandate `seccompProfile` or `runAsNonRoot`.

For the workloads, either keep `baseline` (httpbin then runs as-is) or switch to
`nginxinc/nginx-unprivileged:1.27-alpine` (uid 101, listens on `:8080`) and add
`securityContext` blocks. `curlimages/curl` also needs a `securityContext` under
`restricted`.

**This is worth a section in the white paper**, not just a workaround. Any
customer following a CIS-style hardening guide hits it immediately, and the
symptom points at the Gateway rather than the cause.

---

## 2. Environment drift: the stated versions are not what is available

The brief states VKS 3.6.x, Supervisor `v1.33.9+vmware.3-fips`, Istio 1.28.2.
Observed on `wld-sup`:

| | Brief | Actual |
|---|---|---|
| ClusterClass | VKS 3.6.x | **`builtin-generic-v3.7.0`** (3.6.0 also present) |
| Guest Kubernetes | 1.35 | **`v1.35.6+vmware.2`** |
| Istio add-on | 1.28.2 | **1.30.0** available; 1.27.1, 1.27.4, 1.27.5, 1.28.2, 1.28.7 also |

Phase 0 greps for the literal string `1.28.2`:

```bash
PKG=$(kubectl get package -A -o name | grep -i istio | grep 1.28.2 | head -1)
```

This returns nothing if the cluster runs 1.30.0. Make the version a variable
discovered in Phase 0 rather than hard-coded, and record which version was used.

Istio 1.30.0 on Kubernetes 1.35.6 was installed and works: ztunnel 3/3, istiod
2/2, waypoints functional.

---

## 3. `istioctl` is not present and many phases depend on it

The brief assumes "istioctl 1.28.x on the path". It was not installed on the
jumpbox, and the VKS add-on does not provide it. Phases 0, 3, 5, 6, 7, 8 and 13
call it (`ztunnel-config`, `proxy-config`, `waypoint apply`, `analyze`,
`precheck`, `proxy-status`).

Either install it first (and note the version must match the mesh), or record
kubectl equivalents. Worked substitutes used here:

```bash
# instead of: istioctl ztunnel-config workloads
kubectl -n istio-system get ds ztunnel -o wide
kubectl get ns <ns> -o jsonpath='{.metadata.labels}'    # dataplane-mode, use-waypoint

# instead of: istioctl waypoint apply -n shop --enroll-namespace
#   (see item 4: this does TWO things)
```

---

## 4. `istioctl waypoint apply --enroll-namespace` does two separable things

Phase 7 uses it as one step. It both:

1. creates a `Gateway` with `gatewayClassName: istio-waypoint`, and
2. labels the namespace `istio.io/use-waypoint: <name>`

**These are independent, and step 2 is load-bearing.** Observed here: with the
Gateway created but the label missing, the waypoint was `Programmed=True`, the
`AuthorizationPolicy` reported `WaypointAccepted`, the waypoint pod was healthy
— and it was never in the data path. L7 policy was silently unenforced:

```
POST via the waypoint path  -> 405   (the application's own answer)
POST with use-waypoint set  -> RBAC: access denied   (Envoy, from the waypoint)
```

The white paper should make the point explicitly: **deploying a waypoint is not
the same as using one**, and the difference is invisible from resource status.

For a declarative run, apply both and show them separately:

```yaml
# Gateway
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  labels: { istio.io/waypoint-for: service }
spec:
  gatewayClassName: istio-waypoint
  listeners: [{ name: mesh, port: 15008, protocol: HBONE }]
```
```bash
kubectl label ns shop istio.io/use-waypoint=waypoint
```

---

## 5. Which ingress gateway? The add-on ships one that bypasses the waypoint

The brief says "Gateway API with GatewayClass `istio`". The VKS add-on can also
install a **classic** `istio-ingressgateway` via `gateways.ingress.enabled`.
They behave differently, and this matters for Phase 10.

The classic gateway ships with `istio.io/dataplane-mode: none` and
`sidecar.istio.io/inject: true`. It is a mesh member with a SPIFFE identity, so
it reaches backends over mTLS — but it **bypasses the waypoint**. Measured:

```
in-mesh client  POST -> RBAC: access denied     (waypoint enforcing)
via classic gw  POST -> 405                     (reached the app; waypoint skipped)
```

Phase 10 Path B already has the fix (`istio.io/ingress-use-waypoint=true`); the
brief should say explicitly that Path A without that label does **not** enforce
L7 policy, and that this is the expected result rather than a misconfiguration.

Worth stating the three tiers in the paper:

| Ingress | Has mesh identity | Waypoint in path |
|---|---|---|
| AKO / Avi Service Engine | no | no (blocked entirely under STRICT) |
| classic `istio-ingressgateway` | yes | **no**, unless `ingress-use-waypoint` |
| Gateway API `Gateway`, class `istio`, ambient ns | yes | yes |

---

## 6. CA: the add-on exposes nothing, but the plug-in CA works anyway

Phase 14 verifies a plug-in CA loaded via `cacerts`. Three findings:

**The add-on has no CA settings at all.** Searched all 191 schema properties and
every description across all six Istio versions (1.27.1 to 1.30.0) for
`cert-manager`, `istio-csr`, `caAddress`, `caCertificates`, `pluginCA`: zero
matches. Only `meshConfig.trustDomain` and `trustDomainAliases` exist.

**istiod honours `cacerts` regardless.** Creating the secret by hand and
restarting istiod worked with no add-on flag involved. The distributed root
changed from `O=cluster.local` to the supplied root. So plug-in CA is achievable
and supported by istiod, just not expressible through the add-on.

**`CA_TRUSTED_NODE_ACCOUNTS=istio-system/ztunnel` is already set** by the add-on
on istiod. The brief and the companion paper both flag this as an istio-csr
requirement; on VKS it is present by default.

Two things the paper should add:

- **istiod does not hot-reload `cacerts`.** Renewal has no effect until istiod
  restarts. This undercuts any "cert-manager rotates the intermediate" story.
- **A CA swap is disruptive.** Mid-rotation the mesh returned **503** until the
  ingress gateway was restarted: ztunnel had new-CA certs while the gateway
  still held old-CA ones. Every mesh component needs restarting, and there is a
  window where mTLS fails.

**cert-manager cannot populate `cacerts` directly.** A cert-manager `Certificate`
produces `tls.crt` / `tls.key` / `ca.crt`; istiod requires `ca-cert.pem` /
`ca-key.pem` / `root-cert.pem` / `cert-chain.pem`. The names do not match and
cert-manager cannot rename them. Bridging needs something like
`SecretTemplate` from secretgen-controller (present on VKS). Untested.

---

## 7. Phase 7 waypoint defaults ConfigMap: correct, with two refinements

The ConfigMap in the brief is **correct**; the same format was derived
independently from the Istio 1.30 docs and applied successfully. Observed
result: HPA `min 2 / max 5 @ 70%` and PDB `minAvailable 1` created by istiod,
and the waypoint scaled 1 -> 2 on its own.

Two refinements:

**The delete/re-apply is unnecessary.** The brief does
`istioctl waypoint delete` then `apply`. Changes to container resources were
picked up **in place** — istiod's mesh controller updated the generated
Deployment and the pod recreated itself. No istiod restart either.

**Resources have a second, supported owner.** `istio.meshConfig.waypoint.resources`
is an add-on value and sets the same fields declaratively. HPA and PDB have no
add-on equivalent. Cleanest split: resources via the add-on, HPA and PDB via the
ConfigMap. Do not set resources in both; precedence is untested.

`metrics-server` is installed by default on VKS, so the HPA populates. If it
shows `cpu: <unknown>/70%`, wait for the first scrape before concluding it is
missing.

---

## 8. Metrics (Phase 12): ztunnel has no shell

`kubectl exec` into ztunnel fails — it is a distroless Rust binary with no
shell, no `curl`, no `wget`. Use port-forward:

```bash
ZT=$(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl -n istio-system port-forward pod/$ZT 15020:15020 &
curl -s localhost:15020/stats/prometheus | grep istio_tcp_connections_opened_total
```

**Counters do not exist until traffic flows.** A freshly restarted ztunnel emits
only ~7 `istio_*` lines and no connection metrics at all. Generate traffic
first, and scrape the ztunnel **on the destination pod's node**:

```bash
NODE=$(kubectl -n shop get pod -l app=httpbin -o jsonpath='{.items[0].spec.nodeName}')
ZT=$(kubectl -n istio-system get pods -l app=ztunnel \
      -o jsonpath="{.items[?(@.spec.nodeName=='$NODE')].metadata.name}")
```

Confirmed label for the paper's mTLS-audit argument:

```
connection_security_policy="mutual_tls"
source_principal=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway-sa
destination_principal=spiffe://cluster.local/ns/nginx-ambient/sa/default
```

---

## 9. Add-on operations (Phase 13): three observed behaviours

**Supervisor status lags the workload cluster by minutes.** `ClusterAddon` shows
`ready=False` while ztunnel, istiod and the CNI are all Running and healthy. Do
not read it as failure; poll for 5+ minutes.

**Add-on reconciles take 2 to 5 minutes** after an `AddonConfig` change.

**`kubectl patch --type=merge` on an AddonConfig does not update
`last-applied-configuration`.** A later `kubectl apply` then cannot remove the
patched field, and the value persists silently. Use `apply` throughout, or
explicitly null the field.

For the canary-rollout question in the brief: the add-on installs `istio-cni` as
a DaemonSet wholesale. There is no staged-rollout knob, and `istioCNI` exposes
only `enabled` and `resources` — **no `excludeNamespaces`**, despite upstream
having it. Observed default in `istio-cni-config`: `EXCLUDE_NAMESPACES: "kube-system"`
(not `istio-system`), and `AMBIENT_DNS_CAPTURE: "true"`.

---

## 10. Worth adding: AKO L7 cannot front an ambient namespace

Not in the brief, but relevant on VKS where Avi is the default load balancer.

An AKO-backed L7 virtual service terminates on an NSX ALB **Service Engine** — a
VM outside the cluster with no SPIFFE identity and no HBONE support. Under
STRICT, ztunnel refuses its plaintext connection. Demonstrated by proxy: an
out-of-mesh pod calling an ambient pod directly under STRICT gives

```
exit code 56    (connection reset)
```

which is the same refusal an SE would receive. True for **all** AKO service
types — `ClusterIP`, `NodePort` and `NodePortLocal` alike, since the issue is
identity, not topology.

It works under PERMISSIVE, but that path carries no mTLS. Worth stating plainly,
because a checklist asking for both "leave PERMISSIVE" and "use AKO for L7"
contains a hidden dependency: flipping to STRICT later breaks the AKO path.

---

## 11. Smaller notes

- **Gateway API CRDs on VKS are owned by a separate `gateway-api` add-on**
  (v1.4.0, standard channel), not by Istio and not by Envoy Gateway. Istio ships
  only its own `networking.istio.io` CRDs. Standard channel means no `TCPRoute`,
  `TLSRoute` or `UDPRoute`.
- **All three GatewayClasses** (`istio`, `istio-remote`, `istio-waypoint`) are
  registered by the add-on. Phase 0's hedge is unnecessary.
- **Envoy Gateway is not in the VKS catalogue.** If the paper references it,
  note it is a customer-installed component.
- **Session tokens last 10 hours.** A 14-phase run will outlive one login; plan
  for a re-login mid-run.
- **Node-level checks** (Phase 13, and any file inspection) need a node shell.
  `kubectl debug node/` works if permitted; the Headlamp add-on's node shell
  also works and places a `hostPID` + `hostNetwork` pod with `hostPath: /` in
  the `headlamp` namespace, which the add-on labels
  `pod-security.kubernetes.io/enforce=privileged` for exactly this reason.

# Istio ambient on VKS: answers to the infra setup checklist

Every answer below is from a live cluster, not from documentation. Outputs are
copied verbatim.

**Tested on:** VKS guest cluster, Kubernetes `v1.35.6+vmware.2`, ClusterClass
`builtin-generic-v3.7.0`, Istio add-on
`istio.kubernetes.vmware.com.1.28.2-vmware.1-vks.1`, ambient mode, CNI Antrea.

**Legend:** **Yes** — supported and verified · **Yes, with an overlay** —
achievable, but not through add-on settings · **No** — not available ·
**Differs** — the intent is met, the specifics differ on this platform.

A `verify.sh` in this directory re-runs every check against a live cluster:

```sh
SUP=<supervisor-context> WL=<workload-cluster-context> ./verify.sh
```

`apply.sh` applies the add-on configuration and wires up the overlays:

```sh
SUP=<supervisor-context> WL=<workload-cluster-context> ./apply.sh
```

Both need the `PI` variable set if your PackageInstall is not named
`se-cluster-01-istio` — find it with
`kubectl -n vmware-system-tkg get packageinstall`.

---

## Install (one-time)

### Install Istio ambient profile — istiod + ztunnel DaemonSet (all nodes) + istio-cni — **Yes**

Set `istio.ambientMode.enabled: true` and `istio.istioCNI.enabled: true` in the
add-on values. See [`addon.yaml`](addon.yaml).

```
$ kubectl -n istio-system get ds ztunnel istio-cni-node
NAME             DESIRED   CURRENT   READY   AVAILABLE   NODE SELECTOR
ztunnel          3         3         3       3           kubernetes.io/os=linux
istio-cni-node   3         3         3       3           kubernetes.io/os=linux

$ kubectl -n istio-system get deploy istiod
NAME     READY   UP-TO-DATE   AVAILABLE
istiod   2/2     2            2
```

One ztunnel and one istio-cni pod per node across all three nodes (one control
plane, two workers). istiod runs 2 replicas via `istio.pilot.replicas`.

### Do not deploy sidecar-injection; no istio-injection labels anywhere — **Yes**

```
$ kubectl get ns -l istio-injection
No resources found
```

Two things to be aware of. Ambient mode does not inject sidecars into
workloads, so nothing is required to satisfy this for applications. However the
add-on **can** install a classic `istio-ingressgateway` via
`gateways.ingress.enabled`, and that component *is* sidecar-mode
(`sidecar.istio.io/inject: true`, `istio.io/dataplane-mode: none`). It is
disabled in [`addon.yaml`](addon.yaml) for exactly this reason. North-south
should use a Gateway API `Gateway` with `gatewayClassName: istio`, which
participates in ambient instead.

### Confirm Gateway API CRDs v1 exist and are owned by Envoy Gateway — **Differs**

The CRDs exist and have a single owner, so the intent is met. The owner is not
Envoy Gateway.

```
$ kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{" "}{...channel}'
v1.4.0 standard

$ kubectl -n vmware-system-tkg get packageinstall | grep gateway-api
se-cluster-01-gateway-api   gateway-api.tanzu.vmware.com   1.4.0+vmware.4-tkg.1
```

On VKS the Gateway API CRDs are installed by a **separate platform add-on**,
not by Istio and not by Envoy Gateway. Istio ships only its own
`networking.istio.io` CRDs, so there is no conflict to avoid.

Two consequences:

- **Envoy Gateway is not in the VKS add-on catalogue.** If you deploy it
  yourself, its Helm chart installs Gateway API CRDs by default and that
  **must be disabled** — otherwise it collides with the platform's copy. This
  is the ownership problem your checklist is guarding against, but the other
  party is the platform rather than Istio.
- **The version is a platform decision.** v1.4.0 is set by the add-on and
  cannot be upgraded independently.

The channel is `standard`, so the experimental route types are absent:

```
$ kubectl get crd | grep -cE 'tcproutes|tlsroutes|udproutes'
0
```

If your configuration uses `TCPRoute`, `TLSRoute` or `UDPRoute`, it will fail
on a missing CRD. Worth checking before you start.

### Ensure istio-waypoint GatewayClass is registered, and istiod's Gateway deployment controller is enabled — **Yes**

```
$ kubectl get gatewayclass
NAME             CONTROLLER                    ACCEPTED   DESCRIPTION
istio            istio.io/gateway-controller   True       The default Istio GatewayClass
istio-remote     istio.io/unmanaged-gateway    True       Remote to this cluster...
istio-waypoint   istio.io/mesh-controller      True       The default Istio waypoint GatewayClass
```

All three are registered automatically by the add-on; no configuration needed.
The deployment controller is active — creating a `Gateway` with
`gatewayClassName: istio-waypoint` causes istiod to generate the Deployment and
Service itself. Verified in this lab: the waypoint Deployment appeared and
became ready without any further action.

### Keep istio-cni excluded namespaces to only kube-system and istio-system — **Yes, with an overlay**

The add-on exposes **no setting for this**. `istioCNI` has only `enabled` and
`resources`; a search of the entire 76 KB values schema for `excludeNamespaces`
returns zero matches. As shipped, the value is `kube-system` only.

It can be changed with a ytt overlay, because `istio-cni-config` is part of the
package render. See [`overlays/02-istio-cni-excludes.yml`](overlays/02-istio-cni-excludes.yml)
and the setup instructions at the end of this document.

Result after applying:

```
$ kubectl -n istio-system get cm istio-cni-config -o jsonpath='{.data.EXCLUDE_NAMESPACES}'
kube-system,istio-system
```

### Leave ambient.dnsCapture: true (default) enabled — **Yes**

Not tunable through the add-on, and the default is what you want:

```
$ kubectl -n istio-system get cm istio-cni-config -o jsonpath='{.data.AMBIENT_DNS_CAPTURE}'
true
```

### Do not apply any cluster-wide AuthorizationPolicy, PeerAuthentication (leave PERMISSIVE), or root-namespace Telemetry — **Yes**

```
$ kubectl get peerauthentication -A            # 0
$ kubectl get authorizationpolicy -n istio-system   # 0
$ kubectl get telemetry -n istio-system        # 0
```

One thing to watch: the add-on has a value `istio.enableStrictMTLS` which, if
set to `true`, **creates a mesh-wide STRICT PeerAuthentication in
istio-system**. It is explicitly `false` in [`addon.yaml`](addon.yaml) to keep
the mesh PERMISSIVE. If anyone flips that value, this checklist item breaks
silently.

### Do not manage/overwrite the istio.io/dataplane-mode namespace label — **Yes**

Nothing in the add-on or in this configuration sets that label. It is yours.
The platform sets no namespace labels outside `istio-system` and the gateway
namespaces it creates.

---

## CA / identity

### State the CA mode, trust domain = cluster.local, workload cert lifetime = 24h — **Yes**

**CA mode: plug-in**, with cert-manager issuing and owning the intermediate.

```
$ kubectl -n istio-system get secret cacerts -o jsonpath='{.data}' | jq -r 'keys|join(", ")'
ca-cert.pem, ca-key.pem, cert-chain.pem, root-cert.pem

$ kubectl -n default get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' \
    | openssl x509 -noout -subject -dates
subject=CN=se-selfsigned-root-ca
notBefore=Sep 19 09:06:57 2026 GMT
notAfter=Dec 18 09:06:57 2026 GMT
```

**Trust domain:**

```
$ kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' | grep trustDomain
trustDomain: cluster.local
```

Settable via `istio.meshConfig.trustDomain`.

**Workload certificate lifetime: 24 hours.** Observed in ztunnel's own log when
it caches a workload certificate:

```
info cache returned workload certificate from cache ttl=23h59m59.137063503s
```

**How the plug-in CA is built.** The add-on exposes **no CA settings of any
kind** — a schema search for `caAddress`, `caCertificates`, `pluginCA`,
`cert-manager` and `istio-csr` returns zero matches across every available
Istio version (1.27.1 to 1.30.0). istiod nevertheless reads a Secret named
`cacerts` in `istio-system` directly, which is what makes this work.

Two manifests in [`ca/`](ca/) build it from platform components only:

1. [`ca/10-istio-ca-certificate.yaml`](ca/10-istio-ca-certificate.yaml) — a
   cert-manager `Certificate` with `isCA: true`, signed by a `ClusterIssuer`.
   In production, point `issuerRef` at your corporate PKI or Vault issuer;
   nothing else changes.
2. [`ca/20-cacerts-secrettemplate.yaml`](ca/20-cacerts-secrettemplate.yaml) —
   a `SecretTemplate` that renames the keys.

The second file exists because of a naming mismatch:

```
cert-manager writes : tls.crt      tls.key      ca.crt
istiod requires     : ca-cert.pem  ca-key.pem   root-cert.pem  cert-chain.pem
```

cert-manager cannot rename its output, so a plain `Certificate` **cannot**
populate `cacerts` — istiod would ignore it and silently fall back to
self-signed. `SecretTemplate` comes from secretgen-controller, a core VKS
component, and regenerates the Secret whenever cert-manager renews.

> **Rotation caveat.** istiod does **not** hot-reload `cacerts`. cert-manager
> will renew the intermediate on schedule and the Secret will update, but
> istiod continues using the old CA in memory until it restarts. Plan a
> restart into the renewal window. Workload certificates (the 24h ones) rotate
> normally and are unaffected.

### If using istio-csr: include istio-system/ztunnel in caTrustedNodeAccounts — **Yes, already set**

```
$ kubectl -n istio-system get deploy istiod \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CA_TRUSTED_NODE_ACCOUNTS")].value}'
istio-system/ztunnel
```

The add-on sets this by default, with no configuration required. It is needed
for ambient regardless of CA mode: ztunnel requests certificates on behalf of
the workloads on its node, so the CA must trust it to do so.

**On istio-csr itself.** It is an Istio capability, not a VKS one. It is not in
the add-on catalogue and the add-on cannot configure istiod for it. It remains
possible, at a cost:

- `cert-manager-istio-csr` is installed by Helm and owned by you.
- istiod must be reconfigured (disable its CA server, point at istio-csr, mount
  the serving certificate istio-csr issues) — which on VKS means a ytt overlay
  on the PackageInstall, outside your GitOps repo.
- **Ordering is a hard constraint.** cert-manager's documentation states Istio
  must not already be installed; istio-csr cannot be retrofitted to a running
  mesh.

If the requirement is *"our PKI roots the mesh"*, the plug-in CA above achieves
it today with supported components. If it is specifically *"cert-manager issues
every workload certificate"*, istio-csr is the only route.

### Confirm workload cert issuance + rotation is working and monitored — **Yes**

Issuance is observable in ztunnel's log (`returned workload certificate from
cache`, 24h TTL) and in its metrics. Every connection is labelled with both
identities and whether it was encrypted:

```
istio_tcp_connections_opened_total{
  connection_security_policy="mutual_tls",
  source_principal="spiffe://cluster.local/ns/<ns>/sa/<sa>",
  destination_principal="spiffe://cluster.local/ns/<ns>/sa/<sa>", ...}
```

`connection_security_policy` is the field to alert on: it reads `mutual_tls` or
`none`, so you can measure exactly what fraction of traffic is still plaintext
and which identity is sending it. That is also the metric to drive a
PERMISSIVE-to-STRICT migration with evidence rather than hope.

---

## Waypoint support

### Apply the istio-waypoint defaults ConfigMap: HPA min 2 / max 5 @ 70% CPU, PDB minAvailable 1, resources 300m/512Mi → 3/2Gi — **Yes, with an overlay**

The add-on can set waypoint **resources** (`istio.meshConfig.waypoint.resources`)
but has **no values for HPA or PDB**. A ytt overlay also cannot patch the
waypoint Deployment, because istiod generates it at runtime — it carries no
package label and is never part of the render.

What does work is adding the defaults ConfigMap to the package output, which
istiod then reads. See
[`overlays/01-waypoint-defaults.yml`](overlays/01-waypoint-defaults.yml). It
carries all three settings, exactly as your checklist specifies.

Verified against a real waypoint:

```
$ kubectl -n <ns> get hpa,pdb
NAME                     REFERENCE             TARGETS         MINPODS  MAXPODS
hpa/waypoint             Deployment/waypoint   cpu: <unknown>/70%   2    5

NAME                     MIN AVAILABLE   ALLOWED DISRUPTIONS
pdb/waypoint             1               1

$ kubectl -n <ns> get deploy waypoint -o jsonpath='{...resources}'
{"limits":{"cpu":"3","memory":"2Gi"},"requests":{"cpu":"300m","memory":"512Mi"}}
```

The HPA scaled the waypoint from 1 to 2 replicas on its own, which is the
availability outcome the `minReplicas: 2` is there for.

### Ensure metrics-server is installed (waypoint HPA needs it) — **Yes, by default**

```
$ kubectl -n kube-system get deploy metrics-server
NAME             READY   UP-TO-DATE   AVAILABLE
metrics-server   1/1     1            1

$ kubectl top nodes
se-cluster-01-...-fj2sd   53m   2%   ...
```

Installed automatically as a VKS add-on — you do not need to request it. If an
HPA shows `<unknown>` targets, wait for the first scrape before concluding
metrics-server is missing.

### Don't strip Prometheus scrape annotations from generated waypoint pods — **Yes**

Checked on a real waypoint pod, not on the template:

```
$ kubectl -n <ns> get pod <waypoint-pod> -o jsonpath='{.metadata.annotations}'
prometheus.io/path   = /stats/prometheus
prometheus.io/port   = 15020
prometheus.io/scrape = true
```

And the endpoint serves:

```
$ curl -s localhost:15020/stats/prometheus | grep -cE '^istio_|^envoy_'
422
```

Nothing in the add-on or in this configuration strips these.

---

## Telemetry

### Keep ztunnel :15020 metrics scrapeable — **Yes**

```
$ kubectl -n istio-system get ds ztunnel -o jsonpath='{.spec.template.metadata.annotations}'
{"prometheus.io/port":"15020","prometheus.io/scrape":"true"}
```

`istio.meshConfig.enablePrometheusMerge: true` is set in
[`addon.yaml`](addon.yaml), which keeps these annotations on generated pods.

Two operational notes for your SigNoz collector:

- **ztunnel is a distroless image** — no shell, no `curl`. You cannot
  `kubectl exec` into it to test the endpoint; use `kubectl port-forward`.
- **Counters do not exist until traffic flows.** A freshly restarted ztunnel
  emits only a handful of `istio_*` lines and no connection metrics at all.
  Scrape the ztunnel **on the destination pod's node**, and generate traffic
  before concluding the metrics are missing.

---

## RBAC

### In your app namespaces: create/update/delete AuthorizationPolicy, Telemetry, Gateway (class istio-waypoint); label namespaces — **Yes**

Ordinary Kubernetes RBAC. Nothing in the add-on restricts it. A `Role` in each
of your namespaces covering `authorizationpolicies` and `telemetries`
(`security.istio.io`, `telemetry.istio.io`), `gateways`
(`gateway.networking.k8s.io`), plus `patch` on `namespaces` for the two labels.

Note the namespace labels are cluster-scoped objects, so labelling a namespace
needs a ClusterRole with `patch` on `namespaces`, scoped by name if you want it
tight.

### In istio-system: read ztunnel metrics, create ServiceEntry later — **Yes**

Metrics are exposed on the pod at `:15020/stats/prometheus`; a Prometheus-style
scrape needs no Istio-specific permission beyond pod read access.
`ServiceEntry` is `networking.istio.io` and can be granted per namespace.

### Read access: pods, logs, events — **Yes**

Standard RBAC; the built-in `view` ClusterRole covers it.

---

## Operations

### Give us the add-on change/upgrade notice (we byte-compare pinned renders) — **Yes**

Upgrades are never automatic. The `AddonInstall` pins an exact release:

```
$ kubectl -n <supervisor-ns> get addoninstall se-cluster-01-istio \
    -o jsonpath='{.spec.releaseFilter.ref.name}'
istio.kubernetes.vmware.com.1.28.2-vmware.1-vks.1
```

Changing versions means changing that string, which is a reviewable commit in
[`addon.yaml`](addon.yaml). Nothing moves without one.

To see what is available before deciding:

```
kubectl -n vmware-system-vks-public get addonreleases | grep istio
```

### Roll out istio-cni to nodes canaried/progressively, not all-at-once — **Partly**

The DaemonSet already rolls **one node at a time**, not all at once:

```
$ kubectl -n istio-system get ds istio-cni-node -o jsonpath='{.spec.updateStrategy}'
{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}
```

So the blast radius is one node per step, which is the substance of the
request. What is **not** available is a way to control this through add-on
values — `updateStrategy` returns zero matches in the schema, so there is no
setting for a slower or gated rollout. Patching the DaemonSet directly would be
reverted by the add-on on its next reconcile; a ytt overlay could change it,
with the caveats described below.

---

## Setting up the overlays

Two checklist items are met with ytt overlays because the add-on has no values
for them. This section is how to apply them.

### What an overlay is here

The add-on generates a Carvel `PackageInstall` on the workload cluster. That
PackageInstall renders the Istio manifests with `ytt`. kapp-controller lets you
add extra files to that render through an annotation pointing at a Secret.

Two modes, one mechanism:

| Goal | File contents | ytt syntax |
|---|---|---|
| **Add** a new object | a plain Kubernetes manifest | none |
| **Patch** an existing object | `#@overlay/match` directives | yes |

[`overlays/01-waypoint-defaults.yml`](overlays/01-waypoint-defaults.yml) is the
first kind — it adds a ConfigMap.
[`overlays/02-istio-cni-excludes.yml`](overlays/02-istio-cni-excludes.yml) is
the second — it patches one the package already renders.

Only objects the package **renders** can be patched. The waypoint Deployment
cannot be, because istiod creates it at runtime.

### Applying them

[`apply.sh`](apply.sh) does this. The two commands it runs are:

```sh
# 1. a Secret holding the overlay files, in the SAME namespace as the
#    PackageInstall, on the WORKLOAD cluster
kubectl -n vmware-system-tkg create secret generic istio-overlays \
  --from-file=01-waypoint-defaults.yml=overlays/01-waypoint-defaults.yml \
  --from-file=02-istio-cni-excludes.yml=overlays/02-istio-cni-excludes.yml \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. the annotation that wires it in. The trailing .0 is an index;
#    use .1, .2 for further Secrets.
kubectl -n vmware-system-tkg annotate packageinstall se-cluster-01-istio \
  ext.packaging.carvel.dev/ytt-paths-from-secret-name.0=istio-overlays --overwrite
```

Reconcile takes **2 to 5 minutes**. Watch it with:

```sh
kubectl -n vmware-system-tkg get packageinstall se-cluster-01-istio \
  -o jsonpath='{.status.friendlyDescription}{"\n"}{.status.usefulErrorMessage}{"\n"}'
```

`usefulErrorMessage` is where render failures surface. A bad reference fails
loudly there — but **nowhere else**, which is the main operational hazard: the
ClusterAddon can keep reporting while the PackageInstall sits failed.

### Removing them

```sh
kubectl -n vmware-system-tkg annotate packageinstall se-cluster-01-istio \
  ext.packaging.carvel.dev/ytt-paths-from-secret-name.0-
kubectl -n vmware-system-tkg delete secret istio-overlays
```

Reconciliation recovers on the next cycle.

### Limitations you should know before relying on this

**The annotation cannot live in git.** The `AddonInstall` resource has no field
that carries it, and it does not propagate metadata to the generated
PackageInstall — both tested. So while the overlay *files* are version
controlled, the wiring is a manual step that must be re-applied after a cluster
rebuild.

**Survival across an add-on upgrade is unverified.** A configuration-change
reconcile preserves the annotation (tested). A version change is a different
code path and was not tested. If the annotation is lost, kapp prunes the
objects the overlay added — so HPA, PDB and the CNI exclusion would disappear
**silently**, with no error anywhere.

Canaries, worth putting in a monitoring check:

```sh
kubectl -n istio-system get cm istio-waypoint-defaults
kubectl -n istio-system get cm istio-cni-config -o jsonpath='{.data.EXCLUDE_NAMESPACES}'
```

---

## Summary

| Item | Answer |
|---|---|
| Ambient profile: istiod + ztunnel + istio-cni | Yes |
| No sidecar injection | Yes (disable the add-on's classic ingress gateway) |
| Gateway API CRDs, single owner | Differs — owned by a VKS add-on, not Envoy Gateway |
| istio-waypoint GatewayClass + deployment controller | Yes |
| istio-cni excludes kube-system + istio-system | Yes, with an overlay |
| ambient dnsCapture true | Yes (default) |
| No cluster-wide PeerAuth / AuthzPolicy / Telemetry | Yes |
| dataplane-mode label left alone | Yes |
| CA mode, trust domain, 24h cert lifetime | Yes — plug-in CA via cert-manager |
| caTrustedNodeAccounts includes ztunnel | Yes, set by default |
| cert-manager-istio-csr | Possible, not add-on supported; see notes |
| Waypoint HPA / PDB / resources | Yes, with an overlay |
| metrics-server | Yes, installed by default |
| Waypoint Prometheus annotations | Yes |
| ztunnel :15020 scrapeable | Yes |
| RBAC for app namespaces | Yes, ordinary Kubernetes RBAC |
| Pinned release, explicit upgrades | Yes |
| Canary istio-cni rollout | Partly — one node at a time already; not tunable |

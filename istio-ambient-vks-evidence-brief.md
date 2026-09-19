# Brief for Claude Code: Istio ambient on VKS, evidence run

## Purpose

This brief drives a lab run whose output feeds an internal white paper on Istio ambient mode on VKS (vSphere Kubernetes Service). The paper needs real evidence: exact commands, raw output, pod names, IPs, node placement, log lines and metric samples from this cluster. Nothing may be paraphrased or invented. Where a test cannot be run, record why and move on.

The run has 14 phases. Each phase produces one markdown file in an evidence directory. Work through them in order; later phases depend on earlier state.

## Environment (as known before the run; verify in Phase 0)

- Supervisor: v1.33.9+vmware.3-fips (VKS 3.6.x), Kubernetes 1.35 guest cluster
- Istio add-on: 1.28.2 via the VKS Carvel package, ambient mode enabled
- CNI: Antrea (istio-cni chained)
- Load balancer: Avi (NSX Advanced Load Balancer) in L4 mode, default for this cluster
- Ingress: Gateway API with GatewayClass `istio`
- CA: plug-in CA, intermediate certificate loaded via the `cacerts` Secret in `istio-system`
- Client access: `kubectl` context pointed at the guest cluster; `istioctl` 1.28.x on the path

## Output conventions

Create `./istio-evidence/` with this layout:

```
istio-evidence/
  00-inventory.md
  01-estate.md
  02-baseline.md
  03-enrol-and-mtls.md
  04-strict.md
  05-l4-authz.md
  06-l7-without-waypoint.md
  07-waypoint.md
  08-traffic-split.md
  09-networkpolicy.md
  10-north-south.md
  11-egress.md
  12-metrics.md
  13-operations.md
  14-ca.md
  SUMMARY.md
  manifests/        every YAML applied, named <phase>-<name>.yaml
  raw/              any output too long for the markdown (full logs, pcaps, metric dumps)
```

Each phase file has the same four sections:

1. **Purpose**: one or two sentences.
2. **Commands and output**: every command exactly as run, followed by its complete raw output in a fenced block. Prefix long outputs with `# saved to raw/<file>` and include the first 40 lines inline.
3. **Observations**: only what the output shows. Pod names, IPs, node names, timings, HTTP codes, error strings, log lines.
4. **Open questions**: anything that did not behave as this brief predicted, or could not be run.

Rules:

- Capture with `-o wide` wherever pods are listed, so node placement is recorded.
- Time every test call: `time curl ... --max-time 5`. The difference between a timeout and an instant reset is a finding.
- Never print private keys or service account tokens. When showing certificates, use `openssl x509 -noout -subject -issuer -dates` or `-text` with the key material excluded.
- Do not modify anything in `istio-system` except the waypoint defaults ConfigMap in Phase 7 and the read-only checks in Phase 14.
- Do not delete namespaces or restart anything outside the test namespaces without asking first. Phase 13 has explicit exceptions.
- Save every manifest before applying it.
- If a command needs a value discovered earlier (a node name, a VIP), show how it was obtained.

## Test estate

Five namespaces. The three application namespaces differ only in mesh status, so every test call is the same command from three places.

| Namespace | Mesh status | Contents | Role in tests |
|---|---|---|---|
| `shop` | ambient, with waypoint (from Phase 7) | httpbin, echo-v1, echo-v2, sleep | the protected target |
| `partner` | ambient, no waypoint | httpbin, sleep | the trusted caller |
| `legacy` | not enrolled | httpbin, sleep | the unknown, plaintext caller |
| `edge` | ambient | Gateway `public` (class `istio`) | north-south entry |
| `egress` | ambient | egress waypoint, ServiceEntry | governed exit |

Every workload has its own ServiceAccount: `httpbin`, `sleep`, `echo` in each namespace, plus whatever the Gateway controller creates for the gateway pod.

Images: `docker.io/kennethreitz/httpbin`, `curlimages/curl`, `hashicorp/http-echo`. If the cluster pulls through a private registry, rewrite the references and record the mapping in `01-estate.md`.

## The matrix script

Save as `istio-evidence/matrix.sh` and run it whenever a phase says so. It prints HTTP codes for the nine caller/target pairs and the wall time of each call.

```bash
#!/bin/bash
# rows = caller namespace, cols = target namespace; value = http_code/seconds
printf "%-10s" "from\\to"; for t in shop partner legacy; do printf "%-16s" $t; done; echo
for src in shop partner legacy; do
  printf "%-10s" $src
  for dst in shop partner legacy; do
    out=$(kubectl -n $src exec deploy/sleep -- \
      curl -s -o /dev/null -w '%{http_code}/%{time_total}' --max-time 5 \
      http://httpbin.$dst:8000/get 2>/dev/null)
    printf "%-16s" "${out:-fail}"
  done
  echo
done
```

---

## Phase 0: Inventory

Purpose: pin down exactly what the add-on installed and what it lets us configure. This becomes the paper's "platform facts" section.

Capture all of the following:

```bash
# cluster and supervisor
kubectl version
kubectl get nodes -o wide
kubectl get cluster -A 2>/dev/null                # from the supervisor context if available; else note skipped

# the add-on itself
kubectl get pkgi -A
kubectl get pkgi -A -o yaml | grep -B2 -A60 'istio'          # PackageInstall spec incl. values ref
kubectl get package -A | grep -i istio
# the values schema is the key artefact: what is configurable
PKG=$(kubectl get package -A -o name | grep -i istio | grep 1.28.2 | head -1)
NS=$(kubectl get package -A | grep -i istio | grep 1.28.2 | awk '{print $1}' | head -1)
kubectl get $PKG -n $NS -o jsonpath='{.spec.valuesSchema}' | python3 -m json.tool > raw/00-values-schema.json
# and the values actually in use
kubectl get secret -n $NS -o name | grep -i istio      # find the values secret referenced by the pkgi
# decode and save it as raw/00-values-in-use.yaml (it is config, not credentials; confirm before saving)

# what got installed
kubectl get all -n istio-system -o wide
kubectl get ds -n istio-system -o yaml | grep -A5 updateStrategy
kubectl get cm -n istio-system istio -o yaml               # meshConfig
kubectl get cm -n istio-system istio-cni-config -o yaml 2>/dev/null || kubectl get cm -n istio-system -o name
kubectl get deploy -n istio-system istiod -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool
kubectl get ns istio-system --show-labels                  # pod security labels
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration | grep -i istio

# gateway api
kubectl get gatewayclass -o wide
kubectl get crd | grep gateway.networking.k8s.io
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}' | python3 -m json.tool

# istioctl view
istioctl version
istioctl x precheck
istioctl proxy-status

# cni chaining on a node (best effort)
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$NODE -it --image=busybox -- sh -c 'ls /host/etc/cni/net.d/ && cat /host/etc/cni/net.d/*.conflist' 2>&1 | head -80
kubectl get cm -n kube-system antrea-config -o yaml | head -60
kubectl get pods -n kube-system -l app=antrea -o wide

# load balancer
kubectl get svc -A | grep LoadBalancer
kubectl get pods -A | grep -i -E 'ako|avi'
```

Observations to record explicitly: which values keys exist (list them), whether any of these appear: `ambient`, `cni.excludeNamespaces`, `dnsCapture`, `meshConfig`, `outboundTrafficPolicy`, `caAddress`, `pilot.env`, `ztunnel.updateStrategy`. The white paper's "what the add-on exposes" table comes from this.

## Phase 1: Build the estate

Apply, in order, saving each manifest to `manifests/`:

```bash
for ns in shop partner legacy; do
  kubectl create ns $ns
  kubectl -n $ns create sa httpbin
  kubectl -n $ns create sa sleep
done
```

Then in each of `shop`, `partner`, `legacy`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels: { app: httpbin }
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector: { app: httpbin }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector: { matchLabels: { app: httpbin } }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      serviceAccountName: httpbin
      containers:
      - name: httpbin
        image: docker.io/kennethreitz/httpbin
        ports: [{ containerPort: 80 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata:
      labels: { app: sleep }
    spec:
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "infinity"]
```

Also in `shop` only:

```bash
kubectl -n shop create sa echo
```

```yaml
# one Deployment + Service per version, v1 and v2
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo-v1 }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo, version: v1 } }
  template:
    metadata: { labels: { app: echo, version: v1 } }
    spec:
      serviceAccountName: echo
      containers:
      - name: echo
        image: hashicorp/http-echo
        args: ["-text=v1", "-listen=:8080"]
---
apiVersion: v1
kind: Service
metadata: { name: echo-v1 }
spec:
  selector: { app: echo, version: v1 }
  ports: [{ port: 8080 }]
---
# repeat for v2 with -text=v2
---
apiVersion: v1
kind: Service
metadata: { name: echo }
spec:
  selector: { app: echo }
  ports: [{ port: 8080 }]
```

Capture: `kubectl get pods,svc -n shop -n partner -n legacy -o wide` (run per namespace), so every pod's IP and node is on record. Note which pods share a node and which do not; later tests want at least one cross-node pair.

## Phase 2: Baseline

Run `matrix.sh`. Expected: nine `200` cells. Record the times; they are the plaintext baseline for comparison in Phase 3.

Also capture the on-the-wire evidence that this is plaintext. Pick the node where `shop/httpbin` runs and watch port 80 while `partner/sleep` calls it:

```bash
NODE=$(kubectl -n shop get pod -l app=httpbin -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$NODE -it --image=nicolaka/netshoot -- \
  timeout 15 tcpdump -i any -A -c 20 'tcp port 80 and host <shop httpbin pod IP>' 2>&1 | tee raw/02-tcpdump-plaintext.txt &
sleep 2
kubectl -n partner exec deploy/sleep -- curl -s http://httpbin.shop:8000/get > /dev/null
wait
```

Observation to record: the HTTP request line and headers are visible in the capture.

## Phase 3: Enrol and prove mTLS

```bash
kubectl label ns shop istio.io/dataplane-mode=ambient
kubectl label ns partner istio.io/dataplane-mode=ambient
sleep 5
istioctl ztunnel-config workloads
istioctl ztunnel-config workloads -o json > raw/03-ztunnel-workloads.json
istioctl ztunnel-config services
istioctl ztunnel-config certificates
```

Run `matrix.sh`. Expected: still nine `200`s.

Then three pieces of proof:

```bash
# 1. identity in the destination ztunnel log
NODE=$(kubectl -n shop get pod -l app=httpbin -o jsonpath='{.items[0].spec.nodeName}')
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$NODE -o name)
kubectl -n partner exec deploy/sleep -- curl -s http://httpbin.shop:8000/get > /dev/null
kubectl -n legacy  exec deploy/sleep -- curl -s http://httpbin.shop:8000/get > /dev/null
kubectl -n istio-system logs $ZT --since=1m | grep httpbin | tee raw/03-ztunnel-inbound.log
# expect src.identity on the partner line, absent on the legacy line

# 2. on the wire: port 15008 carries TLS, port 80 carries nothing between nodes
kubectl debug node/$NODE -it --image=nicolaka/netshoot -- \
  timeout 15 tcpdump -i any -c 30 'tcp port 15008 or tcp port 80' 2>&1 | tee raw/03-tcpdump-hbone.txt &
sleep 2
kubectl -n partner exec deploy/sleep -- curl -s http://httpbin.shop:8000/get > /dev/null
wait
# then a -A capture on 15008 only, to show the TLS handshake bytes rather than readable HTTP

# 3. the certificate chain ends at the enterprise root loaded via cacerts
istioctl ztunnel-config certificates -o json > raw/03-certs.json
# for one workload, extract the chain and show subject/issuer of each cert with openssl; no keys
```

Observations: which pairs went HBONE (same-node and cross-node both), the exact `src.identity` string, the issuer chain, and the cert `notAfter` (should be about 24h from issue).

## Phase 4: STRICT

```bash
kubectl -n shop apply -f manifests/04-peerauth-strict.yaml
```

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: shop }
spec: { mtls: { mode: STRICT } }
```

Run `matrix.sh`. Expected: `legacy → shop` fails, everything else `200`. Then capture the failure mode:

```bash
kubectl -n legacy exec deploy/sleep -- time curl -v --max-time 5 http://httpbin.shop:8000/get
kubectl -n istio-system logs $ZT --since=1m | grep -i -E 'legacy|reset|policy|error' | tail
```

Record the exact curl error string and elapsed time. Keep STRICT in place for Phases 5 to 9.

## Phase 5: L4 authorization by identity

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: httpbin-callers, namespace: shop }
spec:
  selector: { matchLabels: { app: httpbin } }
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/partner/sa/sleep"]
```

Run `matrix.sh` (column `shop` is what matters). Expected: `partner → shop` 200; `shop → shop` and `legacy → shop` fail.

Then the evaluation-order sequence, running the matrix and capturing the ztunnel log after each step:

1. Add `cluster.local/ns/shop/sa/sleep` to `principals`. Expect `shop → shop` 200.
2. Apply a second policy, `action: DENY`, `from.source.namespaces: ["partner"]`, same selector. Expect `partner → shop` fails despite the ALLOW.
3. Delete both policies. Expect everything STRICT permits to pass again.

```bash
istioctl ztunnel-config policies
kubectl -n istio-system logs $ZT --since=2m | grep -i policy | tee raw/05-ztunnel-policy.log
```

Record the log line format for a policy rejection; the paper quotes it.

## Phase 6: L7 rule without a waypoint

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: httpbin-get-only, namespace: shop }
spec:
  selector: { matchLabels: { app: httpbin } }
  action: ALLOW
  rules:
  - to:
    - operation: { methods: ["GET"] }
```

Run `matrix.sh`. Expected: every call to `shop/httpbin` fails, GETs included. Capture `istioctl analyze -n shop` (it may warn about this) and the ztunnel log. Delete the policy afterwards.

## Phase 7: Waypoint

```bash
istioctl waypoint apply -n shop --enroll-namespace
kubectl -n shop get gateway,deploy,svc,pods -l gateway.networking.k8s.io/gateway-name=waypoint -o wide
kubectl -n shop get gateway waypoint -o yaml
kubectl get ns shop --show-labels
istioctl ztunnel-config workloads | grep -E 'shop|WAYPOINT'
istioctl ztunnel-config services | grep shop
```

Re-apply the GET-only policy, now attached to the waypoint:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: httpbin-get-only, namespace: shop }
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  - to:
    - operation: { methods: ["GET"] }
```

```bash
kubectl -n partner exec deploy/sleep -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.shop:8000/get
kubectl -n partner exec deploy/sleep -- curl -s -w '\n%{http_code}\n' -X POST http://httpbin.shop:8000/post
kubectl -n shop logs deploy/waypoint --since=2m | tail -20 | tee raw/07-waypoint-access.log
istioctl proxy-config listeners deploy/waypoint -n shop
istioctl proxy-config routes deploy/waypoint -n shop
```

Expected: GET 200, POST 403 with body `RBAC: access denied`. Record the waypoint access-log line for the 403.

Then the waypoint defaults ConfigMap. Apply in `istio-system`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-waypoint-defaults
  namespace: istio-system
  labels: { gateway.istio.io/defaults-for-class: istio-waypoint }
data:
  horizontalPodAutoscaler: |
    spec:
      minReplicas: 2
      maxReplicas: 5
      metrics:
      - type: Resource
        resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  podDisruptionBudget: |
    spec: { minAvailable: 1 }
  deployment: |
    spec:
      template:
        spec:
          containers:
          - name: istio-proxy
            resources:
              requests: { cpu: 300m, memory: 512Mi }
              limits: { cpu: "3", memory: 2Gi }
```

```bash
istioctl waypoint delete -n shop waypoint
istioctl waypoint apply -n shop --enroll-namespace
sleep 20
kubectl -n shop get hpa,pdb,deploy -l gateway.networking.k8s.io/gateway-name=waypoint -o wide
kubectl -n shop get deploy waypoint -o jsonpath='{.spec.template.spec.containers[0].resources}' | python3 -m json.tool
kubectl -n shop describe hpa waypoint
kubectl get deploy -n kube-system metrics-server 2>&1
kubectl -n shop get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].metadata.annotations}' | python3 -m json.tool
```

Record: whether the HPA reads a CPU value or shows `<unknown>`; whether `prometheus.io/scrape`, `prometheus.io/port` and `prometheus.io/path` annotations are present on the waypoint pod; the PDB status.

## Phase 8: Traffic split

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: echo-split, namespace: shop }
spec:
  parentRefs:
  - { group: "", kind: Service, name: echo, port: 8080 }
  rules:
  - backendRefs:
    - { name: echo-v1, port: 8080, weight: 90 }
    - { name: echo-v2, port: 8080, weight: 10 }
```

```bash
kubectl -n shop get httproute echo-split -o yaml | grep -A20 status
kubectl -n partner exec deploy/sleep -- sh -c 'for i in $(seq 1 200); do curl -s http://echo.shop:8080; done | sort | uniq -c'
# change to 50/50, repeat; delete the route, repeat
```

Record the three distributions.

## Phase 9: NetworkPolicy and the mesh

Apply the "obvious" policy first:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: fence, namespace: shop }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: partner } }
    ports: [{ port: 80, protocol: TCP }]
```

Run `matrix.sh`. Expected: `partner → shop` fails with a timeout (about 5s), not a reset. Capture:

```bash
kubectl -n partner exec deploy/sleep -- time curl -v --max-time 5 http://httpbin.shop:8000/get
kubectl -n istio-system logs $ZT --since=1m | grep partner    # expect nothing: the packet never reached ztunnel
kubectl get networkpolicy -n shop -o yaml
```

Then change `port: 80` to `port: 15008`, re-run the matrix, expect `partner → shop` 200 again. Then add the same `port: 15008` allow from `edge` (needed in Phase 10) and an `Egress` section allowing UDP/TCP 53 to `kube-system` plus all traffic to `partner`, `shop`, `edge`, `egress`. Save the final policy; it stays for the rest of the run.

Also capture Antrea's view if `antctl` is available in the antrea-agent pod: `kubectl exec -n kube-system <antrea-agent on shop httpbin node> -- antctl get networkpolicy -n shop`.

## Phase 10: North-south, three paths

This phase reproduces the three paths in the team diagram and records where the waypoint is and is not in the path. Avi is the L4 load balancer.

```bash
kubectl create ns edge
kubectl label ns edge istio.io/dataplane-mode=ambient
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: public, namespace: edge }
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes: { namespaces: { from: All } }
```

```bash
kubectl -n edge get gateway public -o yaml                  # wait until status.addresses has the Avi VIP
kubectl -n edge get svc,deploy,pods -o wide                 # the auto-created public-istio Service and pod
kubectl -n edge get sa
VIP=$(kubectl -n edge get gateway public -o jsonpath='{.status.addresses[0].value}')
echo $VIP
# Avi side, if reachable: note the virtual service Avi created for this VIP and its pool members (node IPs and NodePort, or pod IPs if NodePortLocal)
kubectl -n edge get svc public-istio -o yaml | grep -A10 -E 'ports|externalTrafficPolicy'
```

Two routes into `shop`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: public-httpbin, namespace: shop }
spec:
  parentRefs:
  - { name: public, namespace: edge, kind: Gateway, group: gateway.networking.k8s.io }
  hostnames: ["httpbin.lab.local"]
  rules:
  - backendRefs: [{ name: httpbin, port: 8000 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: public-echo, namespace: shop }
spec:
  parentRefs:
  - { name: public, namespace: edge, kind: Gateway, group: gateway.networking.k8s.io }
  hostnames: ["echo.lab.local"]
  rules:
  - backendRefs: [{ name: echo, port: 8080 }]
```

**Path A: north-south, default.** The `httpbin-get-only` policy from Phase 7 is still attached to the shop waypoint. From outside the cluster (a shell on the jump host, not a pod):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: httpbin.lab.local' http://$VIP/get
curl -s -w '\n%{http_code}\n' -X POST -H 'Host: httpbin.lab.local' http://$VIP/post
kubectl -n edge logs deploy/public-istio --since=1m | tail -5
kubectl -n shop logs deploy/waypoint --since=1m | grep -c httpbin      # does the waypoint see it?
kubectl -n istio-system logs $ZT --since=1m | grep httpbin | tail -3   # what src.identity arrives at the pod
```

Record: whether POST returned 200 or 403 from outside, and whether the waypoint access log has entries for it. This is the diagram's claim that the waypoint is not in the north-south path by default.

**Path B: north-south with ingress-use-waypoint.**

```bash
kubectl -n shop label svc httpbin istio.io/ingress-use-waypoint=true
sleep 5
# repeat the two curls and the three log checks exactly as in Path A
```

Record whether POST now returns 403 and whether the waypoint log shows the request. Then note the source identity the pod's ztunnel sees in each path (gateway SA vs waypoint SA).

**Path C: east-west.** Already covered in Phase 7; reference it and add one cross-node call here with the ztunnel logs on both source and destination nodes, so the paper can show the same request from both ends:

```bash
SRC_NODE=$(kubectl -n partner get pod -l app=sleep -o jsonpath='{.items[0].spec.nodeName}')
ZT_SRC=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$SRC_NODE -o name)
kubectl -n partner exec deploy/sleep -- curl -s http://httpbin.shop:8000/get > /dev/null
kubectl -n istio-system logs $ZT_SRC --since=30s | grep httpbin
kubectl -n istio-system logs $ZT     --since=30s | grep httpbin
```

**TLS at the edge.** Add a `https` listener on 443 with a self-signed certificate in a Secret in `edge`, re-run Path B over `https://`, and capture the gateway log (TLS terminated) alongside the ztunnel log (HBONE from the gateway's identity). Record the two certificate issuers involved.

## Phase 11: Egress

Needs a target outside the cluster. Use a VM on the lab network running `python3 -m http.server 8080`, or any reachable HTTP endpoint. Record its IP and hostname; call it `ext.lab.local` below (use the IP directly in the ServiceEntry if there is no DNS).

```bash
# 1. unrestricted: passes
kubectl -n shop exec deploy/sleep -- time curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://ext.lab.local:8080/
kubectl -n istio-system logs <ztunnel on shop sleep node> --since=1m | grep -i ext   # what ztunnel logged for an unknown host

# 2. egress fence on shop (edit the Phase 9 policy: egress only to kube-system:53, shop, partner, edge, egress)
# repeat the curl: expect timeout

# 3. governed exit
kubectl create ns egress
kubectl label ns egress istio.io/dataplane-mode=ambient
istioctl waypoint apply -n egress --name egress-wp
```

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ext-lab
  namespace: egress
  labels: { istio.io/use-waypoint: egress-wp }
spec:
  hosts: ["ext.lab.local"]
  ports: [{ number: 8080, name: http, protocol: HTTP }]
  resolution: DNS            # or STATIC with endpoints if using an IP
  location: MESH_EXTERNAL
```

```bash
istioctl ztunnel-config services | grep ext
kubectl -n shop exec deploy/sleep -- time curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://ext.lab.local:8080/   # expect 200
kubectl -n egress logs deploy/egress-wp --since=1m | tail -5
# on the external target, record the source IP seen (node SNAT IP or pod IP; depends on Antrea egress config)
```

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: ext-callers, namespace: egress }
spec:
  targetRefs: [{ kind: ServiceEntry, group: networking.istio.io, name: ext-lab }]
  action: ALLOW
  rules:
  - from: [{ source: { principals: ["cluster.local/ns/shop/sa/sleep"] } }]
```

```bash
kubectl -n shop    exec deploy/sleep -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://ext.lab.local:8080/   # 200
kubectl -n partner exec deploy/sleep -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://ext.lab.local:8080/   # record what happens; partner has no egress fence
# apply the same egress fence to partner, repeat: expect 403
```

**REGISTRY_ONLY check.** If Phase 0 found `meshConfig.outboundTrafficPolicy` in the values schema, set it to `REGISTRY_ONLY`, reconcile, remove the egress NetworkPolicy from `shop`, and call an unregistered external host. Record whether ztunnel blocks it. If the schema does not expose it, record that and skip.

## Phase 12: Metrics

```bash
kubectl -n istio-system port-forward $ZT 15020:15020 &
sleep 2
curl -s localhost:15020/stats/prometheus > raw/12-ztunnel-metrics.txt
grep -E '^istio_tcp_connections_opened_total' raw/12-ztunnel-metrics.txt | grep shop | head
kill %1

kubectl -n shop port-forward deploy/waypoint 15020:15020 &
sleep 2
curl -s localhost:15020/stats/prometheus > raw/12-waypoint-metrics.txt
grep -E '^istio_requests_total' raw/12-waypoint-metrics.txt | head -20
grep -E '^istio_request_duration_milliseconds_bucket' raw/12-waypoint-metrics.txt | head -5
kill %1

kubectl -n shop get pod -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].metadata.annotations}'
kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.annotations}'
```

Record: one full `istio_tcp_connections_opened_total` line and one `istio_requests_total{response_code="403"...}` line with all labels, and the scrape annotations on both pod types.

If tracing was enabled in the add-on values, also capture the `Telemetry` resource and a sample span export config; otherwise record that tracing is off.

## Phase 13: Operations

These steps are disruptive to the test namespaces only. Ask before running anything that touches `istio-system` beyond the two named here.

```bash
# 1. ztunnel restart on one node: how long does traffic on that node fail?
kubectl -n partner exec deploy/sleep -- sh -c 'while true; do date +%T; curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 http://httpbin.shop:8000/get; sleep 0.5; done' > raw/13-ztunnel-restart-loop.txt &
kubectl -n istio-system delete pod $ZT
sleep 30; kill %1
# record the window of non-200 lines

# 2. namespace label removal
kubectl label ns partner istio.io/dataplane-mode-
./matrix.sh         # partner is now plaintext; under STRICT, shop refuses it
kubectl label ns partner istio.io/dataplane-mode=ambient

# 3. add-on reconcile behaviour (read-only unless a harmless value can be changed)
kubectl get ds -n istio-system ztunnel -o jsonpath='{.spec.updateStrategy}'
kubectl get ds -n istio-system istio-cni-node -o jsonpath='{.spec.updateStrategy}'
# if a harmless value exists (log level), change it in the values secret and:
kubectl get pods -n istio-system -w --output-watch-events | ts > raw/13-rollout.txt   # stop after pods settle
# record whether ztunnel/istio-cni rolled one node at a time or simultaneously

# 4. istiod off the data path
kubectl -n istio-system scale deploy istiod --replicas=0
./matrix.sh          # expect unchanged
istioctl proxy-status 2>&1 | head
kubectl -n istio-system scale deploy istiod --replicas=1
```

## Phase 14: CA (read-only verification of what was done manually)

```bash
kubectl -n istio-system get secret cacerts -o jsonpath='{.data}' | python3 -c 'import sys,json; print(list(json.load(sys.stdin).keys()))'   # key names only
kubectl -n istio-system get secret cacerts -o jsonpath='{.data.ca-cert\.pem}'   | base64 -d | openssl x509 -noout -subject -issuer -dates
kubectl -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -subject -issuer -dates
kubectl -n istio-system get secret cacerts -o jsonpath='{.data.cert-chain\.pem}'| base64 -d | openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout
kubectl -n shop get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' | openssl x509 -noout -subject -issuer
kubectl -n istio-system get secret cacerts -o yaml | grep -E 'kapp|packaging|annotations' -A3    # is it kapp-managed? expect no
kubectl get pkgi -A -o yaml | grep -i -E 'lastAttempt|friendlyDescription|usefulErrorMessage'
# one workload cert chain from ztunnel, subject/issuer per cert, no keys
istioctl ztunnel-config certificates -o json | python3 -c '
import sys,json
for w in json.load(sys.stdin):
    print(w.get("identity"))
    for c in w.get("certChain",[]):
        print("  ", c.get("validFrom"), "->", c.get("expirationTime"))
' | head -20
```

Record the issuer chain from workload cert up to the enterprise root, and confirm the `cacerts` Secret carries no kapp annotations (which is why reconcile leaves it alone).

## SUMMARY.md

At the end, write `SUMMARY.md` with:

1. The environment table from Phase 0 with actual values.
2. The values-schema keys that exist, and which of these were absent: `cni.excludeNamespaces`, `dnsCapture`, CA mode, `outboundTrafficPolicy`, istiod env, ztunnel `updateStrategy`.
3. The nine-cell matrix results after Phases 2, 3, 4, 5 (each variant), 6, 9 (both variants), in one table with the phase as the row.
4. The three north-south paths with: POST result from outside, waypoint log present or absent, `src.identity` seen at the pod's ztunnel.
5. The egress results: unrestricted, fenced, governed, and the partner bypass case.
6. Timings: plaintext vs HBONE call time from Phase 2 vs 3; the ztunnel restart outage window from Phase 13.
7. Every item from the "Open questions" sections, collected.

Do not editorialise in the summary. The paper draws conclusions; this run supplies facts.

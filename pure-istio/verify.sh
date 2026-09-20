#!/bin/sh
# Check the cluster against the application team's checklist.
# Read-only. Prints PASS / FAIL / N/A per item with the evidence.
set -u
# WL is the workload cluster kubectl context. SUP (the Supervisor context) is
# only needed for the release-pin check; that row is skipped if it is unset.
WL="${WL:-se-cluster-01}"
SUP="${SUP:-}"
K="kubectl --context=$WL"
pass() { printf '  PASS  %-46s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-46s %s\n' "$1" "$2"; }
na()   { printf '  N/A   %-46s %s\n' "$1" "$2"; }

echo "INSTALL"
z=$($K -n istio-system get ds ztunnel -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
c=$($K -n istio-system get ds istio-cni-node -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
d=$($K -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$z" ] && pass "ambient: ztunnel DaemonSet all nodes" "$z" || fail "ambient: ztunnel" "absent"
[ -n "$c" ] && pass "istio-cni DaemonSet" "$c" || fail "istio-cni" "absent"
[ -n "$d" ] && pass "istiod" "${d} ready" || fail "istiod" "absent"

inj=$($K get ns -l istio-injection --no-headers 2>/dev/null | wc -l)
[ "$inj" = "0" ] && pass "no istio-injection labels anywhere" "0 namespaces" || fail "istio-injection labels" "$inj namespaces"

gc=$($K get gatewayclass istio-waypoint -o jsonpath='{.spec.controllerName}' 2>/dev/null)
[ -n "$gc" ] && pass "istio-waypoint GatewayClass registered" "$gc" || fail "istio-waypoint GatewayClass" "absent"

bv=$($K get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null)
ow=$($K -n vmware-system-tkg get packageinstall --no-headers 2>/dev/null | awk '/gateway-api/{print $1}')
[ -n "$bv" ] && na "Gateway API CRDs owned by Envoy Gateway" "owned by VKS '${ow}' at ${bv}; Envoy Gateway not in catalogue"

ex=$($K -n istio-system get cm istio-cni-config -o jsonpath='{.data.EXCLUDE_NAMESPACES}' 2>/dev/null)
[ "$ex" = "kube-system,istio-system" ] && pass "istio-cni excludes kube-system+istio-system" "$ex" || fail "istio-cni excludes" "$ex"

dc=$($K -n istio-system get cm istio-cni-config -o jsonpath='{.data.AMBIENT_DNS_CAPTURE}' 2>/dev/null)
[ "$dc" = "true" ] && pass "ambient dnsCapture enabled" "$dc" || fail "ambient dnsCapture" "$dc"

pa=$($K get peerauthentication -A --no-headers 2>/dev/null | wc -l)
ap=$($K get authorizationpolicy -n istio-system --no-headers 2>/dev/null | wc -l)
[ "$pa" = "0" ] && pass "no cluster-wide PeerAuthentication (PERMISSIVE)" "0 found" || fail "PeerAuthentication" "$pa found"
[ "$ap" = "0" ] && pass "no root-namespace AuthorizationPolicy" "0 in istio-system" || fail "root AuthorizationPolicy" "$ap found"

echo
echo "CA / IDENTITY"
td=$($K -n istio-system get cm istio -o jsonpath='{.data.mesh}' 2>/dev/null | grep -o 'trustDomain: .*' | head -1)
[ -n "$td" ] && pass "trust domain" "$td" || fail "trust domain" "not found"
cacerts=$($K -n istio-system get secret cacerts --no-headers 2>/dev/null | awk '{print "present"}')
if [ -n "$cacerts" ]; then
  st=$($K -n istio-system get secrettemplate cacerts --no-headers 2>/dev/null | awk '{print "cert-manager + SecretTemplate"}')
  root=$($K -n default get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
  pass "CA mode" "plug-in via cacerts (${st:-manual}); root ${root}"
else
  pass "CA mode" "istiod self-signed (no cacerts secret)"
fi
ctna=$($K -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CA_TRUSTED_NODE_ACCOUNTS")].value}' 2>/dev/null)
[ -n "$ctna" ] && pass "caTrustedNodeAccounts includes ztunnel" "$ctna" || fail "caTrustedNodeAccounts" "not set"

echo
echo "WAYPOINT SUPPORT"
wc=$($K -n istio-system get cm istio-waypoint-defaults -o jsonpath='{.metadata.labels.gateway\.istio\.io/defaults-for-class}' 2>/dev/null)
[ "$wc" = "istio-waypoint" ] && pass "waypoint defaults ConfigMap" "labelled for $wc" || fail "waypoint defaults ConfigMap" "absent"
ms=$($K -n kube-system get deploy metrics-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$ms" ] && pass "metrics-server installed (HPA needs it)" "${ms} ready" || fail "metrics-server" "absent"

echo
echo "TELEMETRY"
sc=$($K -n istio-system get ds ztunnel -o jsonpath='{.spec.template.metadata.annotations.prometheus\.io/scrape}' 2>/dev/null)
po=$($K -n istio-system get ds ztunnel -o jsonpath='{.spec.template.metadata.annotations.prometheus\.io/port}' 2>/dev/null)
[ "$sc" = "true" ] && pass "ztunnel :15020 scrapeable" "scrape=$sc port=$po" || fail "ztunnel scrape annotations" "scrape=$sc"

echo
echo "OPERATIONS"
if [ -n "$SUP" ]; then
  rel=$(kubectl --context="$SUP" -n "${SUP_NS:-se-namespace}" get addoninstall "${AI:-se-cluster-01-istio}" -o jsonpath='{.spec.releaseFilter.ref.name}' 2>/dev/null)
  [ -n "$rel" ] && pass "release pinned (upgrades are explicit)" "$rel" || fail "release pin" "not found"
else
  na "release pinned (upgrades are explicit)" "set SUP=<supervisor context> to check"
fi
us=$($K -n istio-system get ds istio-cni-node -o jsonpath='{.spec.updateStrategy.rollingUpdate.maxUnavailable}' 2>/dev/null)
na "canary istio-cni rollout" "DaemonSet maxUnavailable=${us:-1}; no add-on setting for staged rollout"

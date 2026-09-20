#!/bin/sh
# Apply the Istio configuration for the application team's checklist.
#
#   ./apply.sh
#
# Two targets, because two API servers are involved:
#   addon.yaml   -> Supervisor       (AddonConfig + AddonInstall)
#   overlays/    -> workload cluster (Secret + annotation on the PackageInstall)
#
# The overlay step is imperative and cannot be declared in git: AddonInstall
# has no field that carries the annotation, and it does not propagate metadata
# to the generated PackageInstall. Re-run this after a cluster rebuild, and
# after any add-on version change.
set -eu
# Set these for your environment. SUP is the kubectl context for the
# Supervisor; WL the context for the workload cluster; PI the PackageInstall
# name the add-on generated (kubectl -n vmware-system-tkg get packageinstall).
: "${SUP:?set SUP to your Supervisor kubectl context}"
: "${WL:?set WL to your workload cluster kubectl context}"
PI="${PI:-se-cluster-01-istio}"
cd "$(dirname "$0")"

echo "==> Supervisor: AddonConfig + AddonInstall"
kubectl --context="$SUP" apply -f addon.yaml

echo "==> waiting for the PackageInstall to appear on the workload cluster"
for i in $(seq 1 30); do
  kubectl --context="$WL" -n vmware-system-tkg get packageinstall "$PI" >/dev/null 2>&1 && break
  sleep 10
done

echo "==> workload cluster: overlay Secret + annotation"
kubectl --context="$WL" -n vmware-system-tkg create secret generic istio-overlays \
  $(for f in overlays/*.yml; do printf ' --from-file=%s=%s' "$(basename "$f")" "$f"; done) \
  --dry-run=client -o yaml | kubectl --context="$WL" apply -f -

kubectl --context="$WL" -n vmware-system-tkg annotate packageinstall "$PI" \
  ext.packaging.carvel.dev/ytt-paths-from-secret-name.0=istio-overlays --overwrite

cat <<'TXT'

Applied. Reconcile takes 2-5 minutes. Verify with ./verify.sh

Canaries that the overlay wiring is still live:
  kubectl -n istio-system get cm istio-waypoint-defaults
  kubectl -n istio-system get cm istio-cni-config -o jsonpath='{.data.EXCLUDE_NAMESPACES}'
TXT

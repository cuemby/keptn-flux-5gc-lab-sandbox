#!/usr/bin/env bash
# Create the Kind cluster, bootstrap Flux against your fork, and create the two runtime
# Secrets that never live in Git.
#
# Usage:
#   scripts/bootstrap.sh            # cluster (if missing) + Flux + Secrets
#   scripts/bootstrap.sh cluster    # only the Kind cluster (and Cilium when CNI=cilium)
#
# Environment:
#   PROFILE=light|full     light (default): 1 control-plane + 1 worker; full: 1 + 2 workers
#   CNI=kindnet|cilium     both enforce NetworkPolicies; cilium is needed for SCTP tests
#   GITHUB_USER            your GitHub login                       (bootstrap only)
#   GITHUB_TOKEN           bootstrap-only fine-grained token       (bootstrap only)
#   KEPTN_DISPATCH_TOKEN   fine-grained token, Actions: write only (bootstrap only)
#   GITHUB_OWNER           owner of the fork (default: GITHUB_USER; set it for an organization)
#   REPO, BRANCH           fork name (default keptn-flux-5gc-lab) and branch (default main)
#   FLUX_VERSION           Flux controllers installed by bootstrap (default 2.10.0, the version
#                          whose CRD schemas `make validate` checks)
#   SKIP_MEMORY_CHECK=1    do not stop when a new cluster is about to be created and the host
#                          looks short on memory
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
PROFILE="${PROFILE:-light}"
CNI="${CNI:-kindnet}"
REPO="${REPO:-keptn-flux-5gc-lab}"
BRANCH="${BRANCH:-main}"
FLUX_VERSION="${FLUX_VERSION:-2.10.0}"   # renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.+)$
CLUSTER_NAME="keptn-5gc"                 # matches name: in kind/*.yaml
CILIUM_VERSION="1.20.4"                  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

case "$MODE" in
  all | cluster) ;;
  *) die "unknown mode '$MODE' (expected: cluster)" ;;
esac

case "$PROFILE" in
  light) config=kind/cluster; need_mib=6144 ;;
  full) config=kind/cluster-full; need_mib=12288 ;;
  *) die "PROFILE must be light or full, not '$PROFILE'" ;;
esac
case "$CNI" in
  kindnet) ;;
  cilium) config+=-cilium ;;
  *) die "CNI must be kindnet or cilium, not '$CNI'" ;;
esac
config+=.yaml

for t in kind kubectl; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
[[ "$CNI" == cilium ]] && { command -v helm >/dev/null 2>&1 || die "missing tool: helm (needed for CNI=cilium)"; }

if [[ "$MODE" == all ]]; then
  : "${GITHUB_USER:?set GITHUB_USER to your GitHub login}"
  : "${GITHUB_TOKEN:?set GITHUB_TOKEN to the bootstrap-only token (see README)}"
  : "${KEPTN_DISPATCH_TOKEN:?set KEPTN_DISPATCH_TOKEN to the Actions-write token (see README)}"
  command -v flux >/dev/null 2>&1 || die "missing tool: flux (Flux CLI 2.x)"
fi
GITHUB_OWNER="${GITHUB_OWNER:-${GITHUB_USER:-}}"

# 1. Kind cluster
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Kind cluster $CLUSTER_NAME already exists; reusing it"
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
else
  # Memory check (Linux only): the profile sizes assume this much memory is free for the cluster.
  if [[ -r /proc/meminfo && "${SKIP_MEMORY_CHECK:-0}" != 1 ]]; then
    avail_mib=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
    if (( avail_mib < need_mib )); then
      die "PROFILE=$PROFILE wants about ${need_mib} MiB free; only ${avail_mib} MiB available. Free memory or set SKIP_MEMORY_CHECK=1."
    fi
  fi
  log "Creating Kind cluster $CLUSTER_NAME from $config"
  kind create cluster --config "$config"
fi

if [[ "$CNI" == cilium ]]; then
  log "Installing Cilium $CILIUM_VERSION"
  helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
    --namespace kube-system --set sctp.enabled=true --set ipam.mode=kubernetes
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
fi

[[ "$MODE" == cluster ]] && { log "Cluster ready (Flux not bootstrapped)"; exit 0; }

# 2. Flux. bootstrap commits clusters/lab/flux-system/gotk-*.yaml to the fork and keeps
#    clusters/lab/flux-system/kustomization.yaml (the PSA label patch) as it is.
log "Bootstrapping Flux v$FLUX_VERSION from $GITHUB_OWNER/$REPO ($BRANCH, clusters/lab)"
flux check --pre
bootstrap_args=(--version="v$FLUX_VERSION" --owner="$GITHUB_OWNER" --repository="$REPO" --branch="$BRANCH" --path=clusters/lab)
[[ "$GITHUB_OWNER" == "$GITHUB_USER" ]] && bootstrap_args+=(--personal)
flux bootstrap github "${bootstrap_args[@]}"

# 3. Runtime Secrets. Values go through stdin so tokens never appear in process arguments.
log "Waiting for the lab namespaces"
# One name per call: with several names, kubectl 1.37 fails at once (NotFound) instead of waiting.
for ns in open5gs observability; do kubectl wait --for=create "ns/$ns" --timeout=5m; done
kubectl wait --for=jsonpath='{.status.phase}'=Active ns/open5gs ns/observability --timeout=5m

log "Creating Secret open5gs/github-dispatch"
printf '{"owner":"%s","repo":"%s","token":"%s"}' "$GITHUB_OWNER" "$REPO" "$KEPTN_DISPATCH_TOKEN" |
  kubectl -n open5gs create secret generic github-dispatch --from-file=SECURE_DATA=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
  log "Secret observability/grafana-admin exists; keeping the current password"
else
  log "Creating Secret observability/grafana-admin with a random password"
  password="$(openssl rand -base64 18)"
  printf '%s' "$password" |
    kubectl -n observability create secret generic grafana-admin --from-literal=admin-user=admin \
      --from-file=admin-password=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
  unset password
fi

log "Done. Flux now reconciles infrastructure -> observability -> platform -> apps."
echo "Follow progress with: flux get kustomizations -A --watch"
echo "Open the UIs with:    make ui"
echo "Revoke GITHUB_TOKEN now; it is only needed for bootstrap."

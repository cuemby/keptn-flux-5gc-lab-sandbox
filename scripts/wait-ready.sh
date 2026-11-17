#!/usr/bin/env bash
# Wait until the lab's Flux Kustomizations and HelmReleases exist and are all Ready.
#
# Usage: scripts/wait-ready.sh [timeout-seconds]   (default 1800)
#
# Environment:
#   EXPECT       space-separated <kind>/<namespace>/<name> objects that must exist
#                (default: the lab's Kustomizations and HelmReleases, Jaeger's "tracing" included)
#   INTERVAL     seconds between polls (default 15)
#
# Every Kustomization and HelmRelease found in the cluster must be Ready, not only the expected
# ones. Progress is printed once a minute, the full status on timeout.
set -euo pipefail

TIMEOUT="${1:-1800}"
INTERVAL="${INTERVAL:-15}"
EXPECT="${EXPECT:-ks/flux-system/flux-system ks/flux-system/infrastructure ks/flux-system/observability
  ks/flux-system/observability-monitors ks/flux-system/tracing ks/flux-system/platform
  ks/flux-system/platform-config ks/open5gs/apps hr/observability/kube-prometheus-stack
  hr/observability/otel-collector hr/keptn-system/keptn hr/open5gs/open5gs hr/open5gs/ueransim-gnb}"

for t in kubectl jq; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 1; }; done

# status: one line per object, "<kind>/<namespace>/<name> <Ready status> <reason>: <message>".
status() {
  local kind short
  for kind in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
    short=ks; [[ "$kind" == helmreleases.* ]] && short=hr
    kubectl get "$kind" -A -o json 2>/dev/null | jq -r --arg k "$short" '.items[] |
      (.status.conditions // [] | map(select(.type == "Ready")) | first) as $r |
      "\($k)/\(.metadata.namespace)/\(.metadata.name) \($r.status // "Unknown") \($r.reason // "-"): \(($r.message // "") | gsub("\n"; " ") | .[0:200])"'
  done
}

start=$SECONDS
last_report=-60
while :; do
  current="$(status)"
  missing=()
  for o in $EXPECT; do
    grep -q "^$o " <<<"$current" || missing+=("$o")
  done
  not_ready="$(grep -v '^[^ ]* True ' <<<"$current" || true)"
  elapsed=$(( SECONDS - start ))

  if (( ${#missing[@]} == 0 )) && [[ -z "$not_ready" ]]; then
    echo "All Flux Kustomizations and HelmReleases are Ready after ${elapsed}s:"
    echo "$current"
    exit 0
  fi
  if (( elapsed >= TIMEOUT )); then
    echo "error: not Ready after ${TIMEOUT}s" >&2
    (( ${#missing[@]} )) && echo "missing: ${missing[*]}" >&2
    echo "$current" >&2
    exit 1
  fi
  if (( elapsed - last_report >= 60 )); then
    last_report=$elapsed
    echo "--- ${elapsed}s: waiting for ${#missing[@]} missing and $(grep -c . <<<"$not_ready" || true) not-Ready objects"
    (( ${#missing[@]} )) && echo "missing: ${missing[*]}"
    [[ -n "$not_ready" ]] && echo "$not_ready"
  fi
  sleep "$INTERVAL"
done

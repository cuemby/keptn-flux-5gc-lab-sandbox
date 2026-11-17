#!/usr/bin/env bash
# Dump the lab state into a directory for troubleshooting (used by the e2e workflow on failure).
#
# Usage: scripts/collect-diagnostics.sh [out-dir]   (default: ./e2e-diagnostics)
#
# Collects: Flux objects and controller logs, Keptn CRs (apps, versions, tasks, evaluations,
# metrics, analyses) with describe output, task Job logs, pods and events of the lab namespaces,
# logs of every container in open5gs, the GitHub mock log (e2e only), node usage.
# Secrets are never dumped. Every command is best effort: a failing one is noted and skipped.
set -uo pipefail

OUT="${1:-e2e-diagnostics}"
mkdir -p "$OUT"
NAMESPACES="flux-system observability keptn-system open5gs e2e"

run() { # run <file> <command...>: write stdout+stderr of one command to $OUT/<file>
  local f="$OUT/$1"; shift
  { echo "\$ $*"; "$@"; } >"$f" 2>&1 || echo "(exit $?)" >>"$f"
}

command -v flux >/dev/null 2>&1 && run flux-get-all.txt flux get all -A
run flux-objects.yaml kubectl get gitrepositories,ocirepositories,helmrepositories,kustomizations,helmreleases -A -o yaml
for c in source-controller kustomize-controller helm-controller notification-controller; do
  run "logs-flux-$c.txt" kubectl -n flux-system logs "deploy/$c" --tail=500
done

run nodes.txt kubectl get nodes -o wide
run pods.txt kubectl get pods -A -o wide
run events.txt kubectl get events -A --sort-by=.lastTimestamp

KEPTN_KINDS="keptnapps,keptnappversions,keptnappcontexts,keptnworkloads,keptnworkloadversions,keptntasks,keptntaskdefinitions,keptnevaluations,keptnevaluationdefinitions"
run keptn-get.txt kubectl get "$KEPTN_KINDS" -A -o wide
run keptn-metrics.txt kubectl get keptnmetrics,analyses -A -o wide
run keptn-objects.yaml kubectl get "$KEPTN_KINDS,keptnmetrics,analyses" -A -o yaml
run keptn-describe.txt kubectl -n open5gs describe keptnappversions,keptnworkloadversions,keptntasks,keptnevaluations,keptnmetrics
for c in lifecycle-operator metrics-operator certificate-operator; do
  run "logs-keptn-$c.txt" kubectl -n keptn-system logs "deploy/$c" --all-containers --tail=500
done

for ns in $NAMESPACES; do
  run "describe-pods-$ns.txt" kubectl -n "$ns" describe pods
  run "jobs-$ns.txt" kubectl -n "$ns" get jobs,cronjobs -o wide
done

# Logs of every pod in open5gs (NFs, UERANSIM, Keptn task Jobs, traffic Jobs) and e2e.
mkdir -p "$OUT/logs"
for ns in open5gs e2e; do
  for pod in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
    name="${pod#pod/}"
    run "logs/$ns-$name.txt" kubectl -n "$ns" logs "$pod" --all-containers --tail=1000
    # Keptn task Jobs restart a failed container in place, which hides the first run's output.
    if kubectl -n "$ns" get "$pod" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null | grep -q '[1-9]'; then
      run "logs/$ns-$name.previous.txt" kubectl -n "$ns" logs "$pod" --all-containers --previous --tail=1000
    fi
  done
done

run helm-values-open5gs.txt kubectl -n open5gs get configmap open5gs-values -o yaml
echo "diagnostics written to $OUT"

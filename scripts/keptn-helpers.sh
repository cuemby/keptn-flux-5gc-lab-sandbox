# shellcheck shell=bash
# Keptn and Prometheus helpers shared by scripts/e2e.sh and scripts/live-github-check.sh.
# Source it after setting KUBECONFIG; needs kubectl, jq and curl. Uses NS (default open5gs) and
# VERSION_TIMEOUT (seconds, default 1800).
NS="${NS:-open5gs}"
VERSION_TIMEOUT="${VERSION_TIMEOUT:-1800}"

# appversion_for <release-id>: newest KeptnAppVersion of app open5gs in which the four tracked
# NFs (amf, smf, nssf, upf) carry that version.
appversion_for() {
  kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh -o json | jq -r --arg v "$1" '
    [.items[] | select(.spec.appName == "open5gs")
      | select([.spec.workloads[]? | select(.version == $v) | .name] as $n
               | ["amf", "smf", "nssf", "upf"] | all(. as $w | $n | index($w)))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

av_field() { kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh "$1" -o jsonpath="$2"; }

# wait_appversion <release-id>: wait for the app version to exist and to leave Pending/Progressing
# (promotion included); prints its name.
wait_appversion() {
  local rid=$1 deadline=$(( SECONDS + VERSION_TIMEOUT )) av="" st prom now last=""
  while (( SECONDS < deadline )); do
    [[ -z "$av" ]] && av="$(appversion_for "$rid")"
    if [[ -n "$av" ]]; then
      st="$(av_field "$av" '{.status.status}')"
      prom="$(av_field "$av" '{.status.promotionStatus}')"
      now="$st/$(av_field "$av" '{.status.currentPhase}')/post=$(av_field "$av" '{.status.postDeploymentStatus}')/eval=$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')/promotion=$prom"
      [[ "$now" != "$last" ]] && { echo "  $av: $now" >&2; last="$now"; }
      case "$st" in
        Succeeded) [[ "$prom" == Pending || "$prom" == Progressing || -z "$prom" ]] || { echo "$av"; return 0; } ;;
        Failed | Deprecated | Warning | Cancelled) echo "$av"; return 0 ;;
      esac
    fi
    sleep 15
  done
  echo "$av"
  return 1
}

# task_for <app-version> <task-definition>: newest KeptnTask of that definition owned by the app version.
task_for() {
  kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh -o json | jq -r --arg av "$1" --arg td "$2" '
    [.items[] | select(.spec.taskDefinition == $td and any(.metadata.ownerReferences[]?; .name == $av))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

wait_task() { # wait_task <task> [timeout-seconds]: wait for a KeptnTask to finish; prints its status
  local deadline=$(( SECONDS + ${2:-1200} )) st=""
  while (( SECONDS < deadline )); do
    st="$(kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh "$1" -o jsonpath='{.status.status}')"
    [[ "$st" == Succeeded || "$st" == Failed ]] && break
    sleep 10
  done
  echo "$st"
}

task_logs() { # task_logs <task>: logs of the pods of the Job behind a KeptnTask
  local job pod
  job="$(kubectl -n "$NS" get keptntasks.lifecycle.keptn.sh "$1" -o jsonpath='{.status.jobName}')"
  [[ -n "$job" ]] || return 0
  for pod in $(kubectl -n "$NS" get pods -l "job-name=$job" -o name 2>/dev/null); do
    # The Job restarts a failed container in place; the first run's output is in --previous.
    kubectl -n "$NS" logs "$pod" --all-containers --previous --tail=200 2>/dev/null || true
    kubectl -n "$NS" logs "$pod" --all-containers --tail=200 2>/dev/null || true
  done
}

evaluations_of() { # evaluations_of <app-version>: "<name> <overallStatus>" per KeptnEvaluation it owns
  kubectl -n "$NS" get keptnevaluations.lifecycle.keptn.sh -o json | jq -r --arg av "$1" '
    .items[] | select(any(.metadata.ownerReferences[]?; .name == $av))
    | "\(.metadata.name) \(.status.overallStatus // "none")"'
}

summarize() { # summarize <app-version>: status line and per-task results
  local av=$1
  echo "  app version $av: status=$(av_field "$av" '{.status.status}') post=$(av_field "$av" '{.status.postDeploymentStatus}') evaluation=$(av_field "$av" '{.status.postDeploymentEvaluationStatus}') promotion=$(av_field "$av" '{.status.promotionStatus}')"
  kubectl -n "$NS" get keptnappversions.lifecycle.keptn.sh "$av" -o json | jq -r '
    [.status.postDeploymentTaskStatus[]?, .status.postDeploymentEvaluationTaskStatus[]?, .status.promotionTaskStatus[]?]
    | .[] | "    \(.definitionName): \(.status) (\(.name))"'
  evaluations_of "$av" | sed 's/^/    evaluation /'
}

# prom_api <path>: GET from the Prometheus HTTP API through a short-lived port-forward to the
# Prometheus pod. The Prometheus image ships no wget/curl, and a port-forward reaches the pod's
# localhost, so the observability NetworkPolicies do not apply.
prom_api() {
  local pod pf rc=0
  pod="$(kubectl -n observability get pods -l app.kubernetes.io/name=prometheus -o name | head -n 1)"
  [[ -n "$pod" ]] || return 1
  kubectl -n observability port-forward --address 127.0.0.1 "$pod" 19090:9090 >/dev/null 2>&1 &
  pf=$!
  curl -fsS --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:19090$1" || rc=$?
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  return "$rc"
}

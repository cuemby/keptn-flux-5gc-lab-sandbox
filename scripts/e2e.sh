#!/usr/bin/env bash
# End-to-end test of the lab on Kind, with no GitHub token.
#
# How it differs from `make bootstrap`:
#   - Flux reconciles this working tree instead of a GitHub fork. The tree is copied into a
#     scratch Git repository, packed with `flux push artifact` and pushed to a local registry on
#     the Kind network. The generated clusters/lab/flux-system/gotk-sync.yaml declares an
#     OCIRepository "flux-system" (instead of the GitRepository that flux bootstrap creates),
#     and the sourceRefs of the Flux Kustomizations in the copy are switched to it.
#   - Scenario changes are made with the lab's own scripts (bump-release.sh and inject-fault.sh
#     with NO_PUSH=1) in the scratch repository, then pushed as a new artifact.
#   - The Keptn tasks call a GitHub API mock in namespace e2e (the optional "api" key of the
#     github-dispatch Secret). The mock logs every workflow_dispatch and answers 204, so a
#     rollback or promotion is asserted as "requested"; the GitHub workflows themselves do not run
#     (scripts/live-github-check.sh runs them against a real repository).
#
# Usage: scripts/e2e.sh <step>...
#   up          create the Kind cluster "kfl-e2e" (PROFILE, CNI) and the local registry; with
#               CNI=cilium, install Cilium (SCTP enabled) as scripts/bootstrap.sh does
#   flux        install Flux, push the tree, create the Secrets and the GitHub mock
#   wait        wait until every Flux Kustomization and HelmRelease is Ready
#   baseline    the first Keptn app version after the install succeeds (no rollback requested)
#               and Keptn manages only the four NFs (amf, smf, nssf, upf)
#   rbac        scenario 6: the RBAC check matrix and a real add-user.sh certificate
#               (scripts/rbac-check.sh)
#   netpol      scenario 7: NetworkPolicies deny the AMF metrics port, the alert relay and
#               Prometheus from namespace default, while Prometheus scrapes, Keptn metric queries
#               and Alertmanager -> alert-relay still work; with CNI=cilium also SCTP (Cilium
#               enable-sctp, NGAP over SCTP with registered UEs)
#   happy       scenario 1: bump RELEASE_ID; the app version succeeds, evaluation passes,
#               promotion dispatched; the UPF holds PDU sessions, UPFNoUserPlaneTraffic is not
#               firing; scenario 10: an open5gs-slo Analysis passes (overall and upf-sessions)
#   fault       scenario 2: faulty config (SMF DNN mismatch); kpi-guard fails and requests a
#               rollback, promotion skipped
#   slo         scenario 10, second half: an open5gs-slo Analysis during the fault fails, with the
#               smf-pdu-success and upf-sessions objectives failing (run after fault)
#   python      scenario 11: swap kpi-guard for kpi-guard-py and restore the good config (the
#               release passes under kpi-guard-py), then repeat scenario 2 (kpi-guard-py fails and
#               requests a rollback, promotion skipped)
#   diag [dir]  collect diagnostics (scripts/collect-diagnostics.sh)
#   memory      print the memory summary
#   down        delete the cluster and the registry
#   all         up flux wait baseline rbac [netpol] happy fault slo python, then down (diagnostics
#               on failure); netpol runs when CNI=cilium or E2E_NETPOL=1
#
# Environment:
#   E2E_DIR             state directory (default ${TMPDIR:-/tmp}/kfl-e2e): scratch repo,
#                       kubeconfig, memory log, results
#   PROFILE             light (default) or full
#   CNI                 kindnet (default) or cilium (kind/cluster*-cilium.yaml + Cilium with SCTP)
#   E2E_NETPOL=1        `all`: run the netpol step with kindnet too
#   REGISTRY_PORT       host port of the local registry (default 5001)
#   E2E_MIN_AVAIL_MIB   do not create the cluster below this much available memory (default 6144,
#                       the light-profile figure from scripts/bootstrap.sh); Linux only
#   E2E_MEM_FLOOR_MIB   stop the run when available memory falls below this (default 1024);
#                       `all` then deletes the cluster, single steps leave it for `down`; Linux only
#   E2E_KEEP=1          `all`: keep the cluster at the end
#   E2E_DIAG_DIR        `all`: where diagnostics go on failure (default $E2E_DIR/diagnostics)
#   READY_TIMEOUT       seconds for `wait` (default 1800)
#   VERSION_TIMEOUT     seconds for a Keptn app version to appear and finish (default 1800)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="${E2E_DIR:-${TMPDIR:-/tmp}/kfl-e2e}"
SRC="$E2E_DIR/src"
PROFILE="${PROFILE:-light}"
CNI="${CNI:-kindnet}"
CLUSTER="kfl-e2e"
REGISTRY_NAME="kfl-e2e-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_IMAGE="registry:3.1.1@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0"
MOCK_IMAGE="denoland/deno:2.9.8@sha256:a0d88a7fcbd44f062cba2748e19df67d30290ad12aa203c7c1e0b12462c483f0"
ARTIFACT="keptn-flux-5gc-lab"
FLUX_VERSION="${FLUX_VERSION:-2.10.0}"
E2E_MIN_AVAIL_MIB="${E2E_MIN_AVAIL_MIB:-6144}"
E2E_MEM_FLOOR_MIB="${E2E_MEM_FLOOR_MIB:-1024}"
READY_TIMEOUT="${READY_TIMEOUT:-1800}"
VERSION_TIMEOUT="${VERSION_TIMEOUT:-1800}"
NS=open5gs

export KUBECONFIG="$E2E_DIR/kubeconfig"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL|INFO <text>: record a scenario outcome
  local line="- **$1** $2"
  echo "$line" | tee -a "$E2E_DIR/results.md"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$line" >>"$GITHUB_STEP_SUMMARY"
  return 0
}
fail() { result FAIL "$*"; die "$*"; }

avail_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }

# --- memory guard -------------------------------------------------------------------------
# Samples host available memory and the memory of the Kind node containers every 15 s into
# $E2E_DIR/memory.log, and stops the run (SIGTERM to the main process) below E2E_MEM_FLOOR_MIB.
kind_mem_mib() {
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v c="$CLUSTER" '
    function mib(v) {
      if (v ~ /GiB$/) return v * 1024; if (v ~ /MiB$/) return v + 0
      if (v ~ /KiB$/) return v / 1024; return v / 1048576
    }
    index($1, c "-") == 1 { sum += mib($2) } END { printf "%d", sum }'
}

mem_guard() {
  local main=$1 a k
  while kill -0 "$main" 2>/dev/null; do
    k="$(kind_mem_mib)"
    if [[ -r /proc/meminfo ]]; then
      a="$(avail_mib)"
      echo "$(date -u +%FT%TZ) avail_mib=$a kind_mib=$k" >>"$E2E_DIR/memory.log"
      if (( a < E2E_MEM_FLOOR_MIB )); then
        echo "error: available memory ${a} MiB is below E2E_MEM_FLOOR_MIB=${E2E_MEM_FLOOR_MIB}; aborting" >&2
        echo "$(date -u +%FT%TZ) ABORT avail_mib=$a" >>"$E2E_DIR/memory.log"
        kill -TERM "$main" 2>/dev/null || true
        return
      fi
    else
      echo "$(date -u +%FT%TZ) kind_mib=$k" >>"$E2E_DIR/memory.log"
    fi
    sleep 15
  done
}

GUARD_PID=""
start_guard() {
  [[ -n "$GUARD_PID" ]] && return
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || return 0
  mem_guard $$ &
  GUARD_PID=$!
}
stop_guard() { [[ -n "$GUARD_PID" ]] && { kill "$GUARD_PID" 2>/dev/null || true; }; GUARD_PID=""; return 0; }

memory_summary() {
  [[ -s "$E2E_DIR/memory.log" ]] || { echo "no memory samples"; return 0; }
  awk '{ for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
         if (v["kind_mib"] > peak) peak = v["kind_mib"]
         if (v["avail_mib"] != "" && (min == "" || v["avail_mib"] < min)) min = v["avail_mib"] }
       END { printf "peak Kind node memory: %d MiB; lowest host available memory: %s MiB; samples: %d\n", peak, (min == "" ? "n/a" : min), NR }' \
    "$E2E_DIR/memory.log"
}

# --- steps --------------------------------------------------------------------------------
step_up() {
  for t in kind kubectl docker git; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
  mkdir -p "$E2E_DIR"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    die "Kind cluster $CLUSTER already exists; run 'scripts/e2e.sh down' first"
  fi
  [[ "$PROFILE" == light || "$PROFILE" == full ]] || die "PROFILE must be light or full"
  [[ "$CNI" == kindnet || "$CNI" == cilium ]] || die "CNI must be kindnet or cilium"
  local config=kind/cluster
  [[ "$PROFILE" == full ]] && config=kind/cluster-full
  [[ "$CNI" == cilium ]] && { config+=-cilium; command -v helm >/dev/null 2>&1 || die "missing tool: helm (CNI=cilium)"; }
  config+=.yaml
  if [[ -r /proc/meminfo ]]; then
    local a; a="$(avail_mib)"
    (( a >= E2E_MIN_AVAIL_MIB )) || die "only ${a} MiB available, E2E_MIN_AVAIL_MIB=${E2E_MIN_AVAIL_MIB}"
    log "Host memory available: ${a} MiB"
  fi
  : >"$E2E_DIR/memory.log"
  : >"$E2E_DIR/results.md"

  log "Creating Kind cluster $CLUSTER from $config"
  if [[ "$CNI" == cilium ]]; then
    # No CNI yet: the nodes only turn Ready once Cilium runs, so do not wait for them here.
    kind create cluster --name "$CLUSTER" --config "$REPO_ROOT/$config" --kubeconfig "$KUBECONFIG"
    start_guard
    install_cilium
  else
    kind create cluster --name "$CLUSTER" --config "$REPO_ROOT/$config" --kubeconfig "$KUBECONFIG" --wait 120s
    start_guard
  fi

  log "Starting local registry $REGISTRY_NAME on 127.0.0.1:$REGISTRY_PORT"
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REGISTRY_NAME" --network kind -p "127.0.0.1:$REGISTRY_PORT:5000" "$REGISTRY_IMAGE" >/dev/null
}

# install_cilium: the same chart, version and settings as scripts/bootstrap.sh (CNI=cilium).
install_cilium() {
  local version
  version="$(sed -nE 's/^CILIUM_VERSION="([^"]+)".*/\1/p' "$REPO_ROOT/scripts/bootstrap.sh")"
  [[ -n "$version" ]] || die "no CILIUM_VERSION in scripts/bootstrap.sh"
  log "Installing Cilium $version (SCTP enabled)"
  helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "$version" \
    --namespace kube-system --set sctp.enabled=true --set ipam.mode=kubernetes --wait --timeout 10m
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
  kubectl wait --for=condition=Ready node --all --timeout=5m
  result PASS "Cilium $version installed (sctp.enabled=true); all nodes Ready"
}

registry_ip() {
  docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$REGISTRY_NAME"
}

# push_tree <message>: commit the scratch repo and push it as the flux-system artifact.
push_tree() {
  git -C "$SRC" add -A
  git -C "$SRC" diff --cached --quiet || git -C "$SRC" commit -qm "$1"
  local rev; rev="$(git -C "$SRC" rev-parse HEAD)"
  flux push artifact "oci://127.0.0.1:$REGISTRY_PORT/$ARTIFACT:e2e" --path="$SRC" \
    --source="e2e" --revision="e2e@sha1:$rev" --insecure-registry >/dev/null
  echo "pushed $rev ($1)"
}

# reconcile: make Flux pick up the last pushed artifact now instead of at the next interval.
reconcile() {
  flux reconcile source oci flux-system -n flux-system --timeout=2m
  flux reconcile kustomization flux-system -n flux-system --timeout=5m
  flux reconcile kustomization apps -n "$NS" --timeout=5m
}

step_flux() {
  command -v flux >/dev/null 2>&1 || die "missing tool: flux"
  start_guard
  local ip; ip="$(registry_ip)"
  [[ -n "$ip" ]] || die "registry $REGISTRY_NAME has no address on the kind network"

  log "Copying the working tree to $SRC"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  # Tracked and untracked (not ignored) files as they are on disk, uncommitted edits included.
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done |
    tar --null -T - -cf -) | tar -xf - -C "$SRC"
  git -C "$SRC" init -q -b main
  git -C "$SRC" config user.name "kfl-e2e"
  git -C "$SRC" config user.email "kfl-e2e@localhost"

  log "Generating clusters/lab/flux-system (Flux v$FLUX_VERSION, OCI source $ip:5000)"
  flux install --version="v$FLUX_VERSION" --export >"$SRC/clusters/lab/flux-system/gotk-components.yaml"
  cat >"$SRC/clusters/lab/flux-system/gotk-sync.yaml" <<EOF
# Generated by scripts/e2e.sh: the e2e equivalent of what flux bootstrap writes.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: oci://$ip:5000/$ARTIFACT
  ref:
    tag: e2e
  insecure: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/lab
  prune: true
  sourceRef:
    kind: OCIRepository
    name: flux-system
EOF
  # The lab's Flux Kustomizations (nested ones included) point at the GitRepository that
  # flux bootstrap creates; in the scratch copy they point at the OCIRepository instead.
  # shellcheck disable=SC2016  # ${1}/${2} are perl capture groups
  grep -rlZ --include='*.yaml' 'kind: GitRepository' "$SRC" | xargs -0 -r perl -0pi -e \
    's/(sourceRef:[ \t]*\n[ \t]*kind:[ \t]*)GitRepository([ \t]*\n[ \t]*name:[ \t]*flux-system\b)/${1}OCIRepository${2}/g'
  push_tree "e2e: working tree"

  log "Installing Flux from clusters/lab/flux-system"
  kubectl kustomize "$SRC/clusters/lab/flux-system" >"$E2E_DIR/flux-system.yaml"
  kubectl apply --server-side -f "$E2E_DIR/flux-system.yaml" >/dev/null 2>&1 || true
  kubectl wait --for=condition=Established crd --all --timeout=2m >/dev/null
  kubectl apply --server-side -f "$E2E_DIR/flux-system.yaml"
  kubectl -n flux-system rollout status deploy --timeout=5m
  kubectl get ns flux-system -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -qx baseline ||
    fail "flux-system namespace is missing the PSA enforce=baseline label"
  result PASS "Flux v$FLUX_VERSION controllers run in flux-system under PSA enforce=baseline"

  log "Waiting for the lab namespaces"
  # One name per call: with several names, kubectl 1.37 fails at once (NotFound) instead of waiting.
  for ns in open5gs observability; do kubectl wait --for=create "ns/$ns" --timeout=5m; done
  kubectl wait --for=jsonpath='{.status.phase}'=Active ns/open5gs ns/observability --timeout=5m

  log "Creating the runtime Secrets (no real token)"
  # Same shape as scripts/bootstrap.sh, plus "api": the Keptn tasks send their dispatches to the mock.
  printf '{"owner":"e2e","repo":"%s","token":"e2e-placeholder","api":"http://github-mock.e2e.svc:8080"}' "$ARTIFACT" |
    kubectl -n "$NS" create secret generic github-dispatch --from-file=SECURE_DATA=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -
  openssl rand -base64 18 | tr -d '\n' |
    kubectl -n observability create secret generic grafana-admin --from-literal=admin-user=admin \
      --from-file=admin-password=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

  log "Deploying the GitHub API mock"
  deploy_mock
}

deploy_mock() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: e2e
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata: { name: github-mock, namespace: e2e }
data:
  main.ts: |
    // Logs every request as one JSON line and accepts workflow_dispatch calls (HTTP 204).
    Deno.serve({ hostname: "0.0.0.0", port: 8080 }, async (req) => {
      const { pathname } = new URL(req.url);
      if (pathname === "/healthz") return new Response("ok");
      const m = pathname.match(/^\/repos\/[^/]+\/[^/]+\/actions\/workflows\/([^/]+)\/dispatches\$/);
      const text = await req.text();
      let payload = null;
      try { payload = JSON.parse(text); } catch { payload = text; }
      console.log(JSON.stringify({
        time: new Date().toISOString(), method: req.method, path: pathname,
        workflow: m ? m[1] : null, authorization: req.headers.has("authorization"), payload,
      }));
      if (req.method === "POST" && m) return new Response(null, { status: 204 });
      return new Response("not found", { status: 404 });
    });
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: github-mock, namespace: e2e }
spec:
  replicas: 1
  selector: { matchLabels: { e2e: github-mock } }
  template:
    metadata: { labels: { e2e: github-mock } }
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1993
        runAsGroup: 1993
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: mock
          image: $MOCK_IMAGE
          command: [deno, run, --no-prompt, "--allow-net=0.0.0.0:8080", /app/main.ts]
          env:
            - { name: DENO_DIR, value: /deno-dir }
            - { name: DENO_NO_UPDATE_CHECK, value: "1" }
          ports: [{ name: http, containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 5 }
          volumeMounts:
            - { name: app, mountPath: /app, readOnly: true }
            - { name: deno-dir, mountPath: /deno-dir }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 5m, memory: 24Mi }
            limits: { memory: 64Mi }
      volumes:
        - { name: app, configMap: { name: github-mock } }
        - { name: deno-dir, emptyDir: { sizeLimit: 32Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: github-mock, namespace: e2e }
spec:
  selector: { e2e: github-mock }
  ports: [{ name: http, port: 8080, targetPort: http }]
EOF
  kubectl -n e2e rollout status deploy/github-mock --timeout=3m
}

step_wait() {
  start_guard
  log "Waiting for Flux (timeout ${READY_TIMEOUT}s)"
  if ! "$REPO_ROOT/scripts/wait-ready.sh" "$READY_TIMEOUT"; then
    fail "Flux Kustomizations and HelmReleases not Ready within ${READY_TIMEOUT}s"
  fi
  kubectl -n "$NS" rollout status deploy --timeout=10m
  result PASS "all Flux Kustomizations and HelmReleases Ready; Open5GS and UERANSIM rolled out"
}

# --- Keptn helpers ----------------------------------------------------------------------------
# appversion_for, av_field, wait_appversion, task_for, wait_task, task_logs, evaluations_of,
# summarize and prom_api.
# shellcheck source=scripts/keptn-helpers.sh
source "$REPO_ROOT/scripts/keptn-helpers.sh"

release_id() { sed -nE 's/^[[:space:]]*RELEASE_ID:[[:space:]]*"([^"]+)".*/\1/p' "$SRC/clusters/lab/apps.yaml"; }

# mock_dispatches <workflow>: workflow_dispatch requests the GitHub mock has received, one JSON per line.
mock_dispatches() {
  kubectl -n e2e logs deploy/github-mock --tail=-1 2>/dev/null |
    jq -Rc --arg wf "$1" 'fromjson? | select(.workflow == $wf and .method == "POST")'
}

# release <message> <command...>: run a lab script in the scratch repo, push, reconcile; prints RELEASE_ID.
release() {
  local msg=$1; shift
  (cd "$SRC" && NO_PUSH=1 "$@" >&2)
  push_tree "$msg" >&2
  reconcile >&2
  release_id
}

# run_analysis <label>: create a one-shot open5gs-slo Analysis (examples/analysis-run.yaml), wait
# for it to complete, print the overall and per-objective results (stderr) and print its
# status.raw JSON (stdout). On failure it records a FAIL line and exits.
run_analysis() {
  local an deadline state raw
  an="$(kubectl create -f "$REPO_ROOT/examples/analysis-run.yaml" -o name)" || fail "$1: could not create the open5gs-slo Analysis"
  deadline=$(( SECONDS + 300 ))
  until state="$(kubectl -n "$NS" get "$an" -o jsonpath='{.status.state}')"; [[ "$state" == Completed ]]; do
    (( SECONDS < deadline )) || fail "$1: $an not Completed after 300s (state ${state:-none})"
    sleep 10
  done
  raw="$(kubectl -n "$NS" get "$an" -o jsonpath='{.status.raw}')"
  jq -r '.objectiveResults[] | "    analysis \(.objective.analysisValueTemplateRef.name): value=\(.value) pass=\(.result.pass) warning=\(.result.warning) score=\(.score)"' <<<"$raw" >&2
  echo "    analysis ${an#*/}: pass=$(jq -r .pass <<<"$raw") warning=$(jq -r .warning <<<"$raw") score=$(jq -r '"\(.totalScore)/\(.maximumScore)"' <<<"$raw")" >&2
  printf '%s\n' "$raw"
}

# objective <raw> <template>: the objective result for one AnalysisValueTemplate, or empty.
objective() { jq -c --arg t "$2" '[.objectiveResults[] | select(.objective.analysisValueTemplateRef.name == $t)][0] // empty' <<<"$1"; }

# check_upf_kpis: the UPF user-plane KPIs read UPF PDU sessions (fivegs_upffunction_upf_sessionnbr),
# not the N3 GTP-U counter Open5GS 2.8.0 never increments. On a healthy lab: the UPF holds
# sessions, UPFNoUserPlaneTraffic is loaded on that metric and not firing, and a one-shot
# open5gs-slo Analysis (examples/analysis-run.yaml) passes, overall (scenario 10) and on its
# upf-sessions objective.
check_upf_kpis() {
  local q sessions rule raw upf
  q="$(jq -rn '"sum(fivegs_upffunction_upf_sessionnbr)" | @uri')"
  sessions="$(prom_api "/api/v1/query?query=$q" | jq -r '.data.result[0].value[1] // "none"')" ||
    fail "upf: Prometheus query failed"
  echo "    UPF PDU sessions: $sessions"
  awk -v s="$sessions" 'BEGIN { exit !(s + 0 >= 1) }' || fail "upf: sum(fivegs_upffunction_upf_sessionnbr)=$sessions (want >= 1)"

  rule="$(prom_api "/api/v1/rules?type=alert" |
    jq -c '[.data.groups[].rules[] | select(.name == "UPFNoUserPlaneTraffic")][0] // empty')" ||
    fail "upf: Prometheus rules query failed"
  [[ -n "$rule" ]] || fail "upf: alert UPFNoUserPlaneTraffic is not loaded in Prometheus"
  echo "    UPFNoUserPlaneTraffic: state=$(jq -r .state <<<"$rule") health=$(jq -r .health <<<"$rule")"
  jq -e '.query | contains("fivegs_upffunction_upf_sessionnbr")' <<<"$rule" >/dev/null ||
    fail "upf: UPFNoUserPlaneTraffic does not read fivegs_upffunction_upf_sessionnbr"
  jq -e '.health == "ok" and .state != "firing"' <<<"$rule" >/dev/null ||
    fail "upf: UPFNoUserPlaneTraffic is $(jq -r '"\(.state)/\(.health)"' <<<"$rule") on a healthy lab (want not firing, health ok)"

  raw="$(run_analysis upf)"
  upf="$(objective "$raw" upf-sessions)"
  [[ -n "$upf" ]] || fail "upf: the open5gs-slo Analysis has no upf-sessions objective"
  jq -e '.result.pass and .value >= 1' <<<"$upf" >/dev/null || fail "upf: upf-sessions objective failed: $upf"
  jq -e '.pass == true' <<<"$raw" >/dev/null ||
    fail "scenario 10: open5gs-slo Analysis on a healthy lab did not pass (score $(jq -r '"\(.totalScore)/\(.maximumScore)"' <<<"$raw"))"
  ANALYSIS_SCORE="$(jq -r '"\(.totalScore)/\(.maximumScore)"' <<<"$raw")"
}

# --- scenarios ---------------------------------------------------------------------------------
step_baseline() {
  start_guard
  local rid av st task apps wls
  rid="$(release_id)"
  log "Baseline: first Keptn app version (RELEASE_ID $rid)"
  av="$(wait_appversion "$rid")" || fail "baseline: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  task="$(task_for "$av" kpi-guard)"
  [[ -n "$task" ]] && task_logs "$task" | tail -n 5 | sed 's/^/    kpi-guard: /'
  # Keptn's pod webhook only selects pods labelled keptn.sh/workload: no auto-apps for MongoDB,
  # populate, the other NFs, UERANSIM or alert-relay, and no fifth workload in the open5gs app.
  apps="$(kubectl -n "$NS" get keptnapps.lifecycle.keptn.sh -o json | jq -r '[.items[].metadata.name] | sort | join(",")')"
  wls="$(kubectl -n "$NS" get keptnworkloads.lifecycle.keptn.sh -o json | jq -r '[.items[].metadata.name] | sort | join(",")')"
  echo "  Keptn apps: $apps; workloads: $wls"
  [[ "$apps" == open5gs ]] || fail "baseline: Keptn apps $apps (want only open5gs)"
  [[ "$wls" == open5gs-amf,open5gs-nssf,open5gs-smf,open5gs-upf ]] ||
    fail "baseline: Keptn workloads $wls (want the four NFs only)"
  (( $(mock_dispatches keptn-rollback.yaml | wc -l) == 0 )) || fail "baseline: a rollback was requested for the first release"
  [[ "$st" == Succeeded ]] || fail "baseline: first app version $av status=$st (want Succeeded)"
  result PASS "baseline: first app version $av for $rid Succeeded with no rollback request; Keptn manages only amf, smf, nssf, upf"
}

step_happy() {
  start_guard
  local before rid av st post ev prom n
  before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 1 (happy path): bump RELEASE_ID"
  rid="$(release "e2e: bump RELEASE_ID" bash -c 'scripts/bump-release.sh lab >/dev/null && git add -A && git commit -qm "Bump RELEASE_ID"')"
  echo "RELEASE_ID $rid"
  av="$(wait_appversion "$rid")" || fail "happy: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  post="$(av_field "$av" '{.status.postDeploymentStatus}')"
  ev="$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')"
  prom="$(av_field "$av" '{.status.promotionStatus}')"
  local task; task="$(task_for "$av" kpi-guard)"
  [[ -n "$task" ]] && task_logs "$task" | tail -n 5 | sed 's/^/    kpi-guard: /'
  [[ "$st" == Succeeded && "$post" == Succeeded && "$ev" == Succeeded ]] ||
    fail "happy: app version $av status=$st post=$post evaluation=$ev (want Succeeded)"
  evaluations_of "$av" | grep -qE ' (Pass|Succeeded)$' || fail "happy: no passing KeptnEvaluation for $av"
  [[ "$prom" == Succeeded ]] || fail "happy: promotion status $prom (want Succeeded)"
  n="$(mock_dispatches keptn-promote.yaml | wc -l)"
  (( n > before )) || fail "happy: promote task succeeded but the GitHub mock got no keptn-promote.yaml dispatch"
  mock_dispatches keptn-promote.yaml | tail -n 1 | sed 's/^/    mock: /'
  check_upf_kpis
  result PASS "scenario 1 (happy path): RELEASE_ID $rid -> app version $av Succeeded (tasks, evaluation open5gs-kpis), promotion dispatched (keptn-promote.yaml); UPF sessions > 0, UPFNoUserPlaneTraffic not firing, open5gs-slo upf-sessions objective passed"
  result PASS "scenario 10 (SLO analysis), healthy: open5gs-slo Analysis passed with score $ANALYSIS_SCORE"
}

step_fault() {
  start_guard
  local rb_before pr_before rid
  rb_before="$(mock_dispatches keptn-rollback.yaml | wc -l)"
  pr_before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 2 (fault): switch Open5GS to values/open5gs-fault-slice.yaml"
  rid="$(release "e2e: inject fault" scripts/inject-fault.sh lab)"
  echo "RELEASE_ID $rid"
  check_fault_release "scenario 2 (fault)" kpi-guard "$rid" "$rb_before" "$pr_before"
}

# check_fault_release <label> <kpi-guard task definition> <release-id> <rollback dispatches before>
# <promote dispatches before>: the faulty release's app version fails, the kpi-guard task fails
# with "rollback requested via Git", the GitHub mock gets one more keptn-rollback.yaml dispatch
# ({ref: main, stage: lab, source: keptn} with a token) and no promotion runs.
check_fault_release() {
  local label=$1 td=$2 rid=$3 rb_before=$4 pr_before=$5 av st prom task tst logs ev d
  av="$(wait_appversion "$rid")" || fail "$label: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  prom="$(av_field "$av" '{.status.promotionStatus}')"
  task="$(task_for "$av" "$td")"
  # The app version turns Failed as soon as any post-deployment task fails, possibly before
  # kpi-guard has finished; wait for kpi-guard itself.
  tst=""
  [[ -n "$task" ]] && tst="$(wait_task "$task")"
  logs="$( [[ -n "$task" ]] && task_logs "$task" || true)"
  printf '%s\n' "$logs" | tail -n 8 | sed "s/^/    $td: /"

  [[ "$st" == Failed ]] || fail "$label: app version $av status=$st (want Failed)"
  [[ "$tst" == Failed ]] || fail "$label: $td task ${task:-missing} ended ${tst:-unknown} (want Failed)"
  grep -q 'rollback requested via Git' <<<"$logs" || fail "$label: $td did not report 'rollback requested via Git'"
  (( $(mock_dispatches keptn-rollback.yaml | wc -l) > rb_before )) || fail "$label: the GitHub mock got no keptn-rollback.yaml dispatch"
  d="$(mock_dispatches keptn-rollback.yaml | tail -n 1)"
  echo "    mock: $d"
  jq -e '.payload.ref == "main" and .payload.inputs.stage == "lab" and .payload.inputs.source == "keptn" and .authorization' <<<"$d" >/dev/null ||
    fail "$label: rollback dispatch payload is not {ref: main, stage: lab, source: keptn} with a token"
  [[ "$prom" != Succeeded ]] || fail "$label: promotion ran for a failed release"
  (( $(mock_dispatches keptn-promote.yaml | wc -l) == pr_before )) || fail "$label: a keptn-promote.yaml dispatch was sent"
  ev="$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')"
  [[ "$ev" != Succeeded ]] || fail "$label: post-deployment evaluation passed on the faulty release"
  result PASS "$label: RELEASE_ID $rid -> app version $av Failed; $td breach, rollback dispatch requested (keptn-rollback.yaml, source keptn); evaluation $ev; promotion skipped"
}

# deploy_age <deployment>: seconds since the newest pod of a Deployment in open5gs started.
deploy_age() {
  local sel start
  sel="$(kubectl -n "$NS" get deploy "$1" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  start="$(kubectl -n "$NS" get pods -l "$sel" -o json | jq -r '[.items[].status.startTime // empty] | sort | last // empty')"
  [[ -n "$start" ]] || { echo 0; return; }
  echo $(( $(date -u +%s) - $(date -u -d "$start" +%s) ))
}

step_slo() {
  start_guard
  local age raw pdu upf amf
  log "Scenario 10 (SLO analysis) during the fault"
  # Keptn 0.11's Prometheus provider runs a range query over the Analysis timeframe (recent 10m)
  # and keeps only its first point, so the result describes the 5m window (args.window) that ended
  # 10m before the Analysis started. Wait until the faulty SMF has run 10m + 5m (+ margin), so
  # that window holds only the fault.
  age="$(deploy_age open5gs-smf)"
  if (( age < 960 )); then
    echo "  faulty SMF running for ${age}s; waiting $(( 960 - age ))s (Analysis timeframe 10m + window 5m)"
    sleep $(( 960 - age ))
  fi
  raw="$(run_analysis "scenario 10")"
  pdu="$(objective "$raw" smf-pdu-success)"
  upf="$(objective "$raw" upf-sessions)"
  amf="$(objective "$raw" amf-reg-success)"
  jq -e '.pass == false' <<<"$raw" >/dev/null ||
    fail "scenario 10: open5gs-slo Analysis passed during the fault (score $(jq -r '"\(.totalScore)/\(.maximumScore)"' <<<"$raw"))"
  jq -e '.result.pass == false' <<<"$pdu" >/dev/null 2>&1 || fail "scenario 10: smf-pdu-success objective did not fail during the fault: ${pdu:-missing}"
  jq -e '.result.pass == false' <<<"$upf" >/dev/null 2>&1 || fail "scenario 10: upf-sessions objective did not fail during the fault: ${upf:-missing}"
  result PASS "scenario 10 (SLO analysis), fault: open5gs-slo Analysis failed with score $(jq -r '"\(.totalScore)/\(.maximumScore)"' <<<"$raw"); smf-pdu-success value $(jq -r .value <<<"$pdu") failed, upf-sessions value $(jq -r .value <<<"$upf") failed, amf-reg-success value $(jq -r .value <<<"$amf") pass=$(jq -r .result.pass <<<"$amf")"
}

step_python() {
  start_guard
  local before rid av st post ev prom task tst logs rb_before pr_before
  before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 11 (Python runtime): swap kpi-guard for kpi-guard-py and restore the good config"
  # One artifact: Flux applies the KeptnAppContext change before helm-controller rolls the NFs.
  # shellcheck disable=SC2016  # expanded by the inner shell
  rid="$(release "e2e: kpi-guard-py + heal" bash -c '
    f=apps/open5gs/keptn/app-context.yaml
    sed -i "s/postDeploymentTasks: \[traffic-burst, kpi-guard\]/postDeploymentTasks: [traffic-burst, kpi-guard-py]/" "$f"
    grep -q "postDeploymentTasks: \[traffic-burst, kpi-guard-py\]" "$f" || { echo "could not swap kpi-guard in $f" >&2; exit 1; }
    scripts/heal.sh lab')"
  echo "RELEASE_ID $rid"
  av="$(wait_appversion "$rid")" || fail "python: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
  summarize "$av"
  st="$(av_field "$av" '{.status.status}')"
  post="$(av_field "$av" '{.status.postDeploymentStatus}')"
  ev="$(av_field "$av" '{.status.postDeploymentEvaluationStatus}')"
  prom="$(av_field "$av" '{.status.promotionStatus}')"
  task="$(task_for "$av" kpi-guard-py)"
  [[ -n "$task" ]] || fail "python: no kpi-guard-py task for $av"
  [[ -z "$(task_for "$av" kpi-guard)" ]] || fail "python: the Deno kpi-guard also ran for $av"
  tst="$(wait_task "$task")"
  logs="$(task_logs "$task")"
  printf '%s\n' "$logs" | tail -n 5 | sed 's/^/    kpi-guard-py: /'
  [[ "$st" == Succeeded && "$post" == Succeeded && "$ev" == Succeeded ]] ||
    fail "python: healed app version $av status=$st post=$post evaluation=$ev (want Succeeded)"
  [[ "$tst" == Succeeded ]] || fail "python: kpi-guard-py task $task ended ${tst:-unknown} (want Succeeded)"
  grep -q 'KPIs healthy for the full soak window' <<<"$logs" || fail "python: kpi-guard-py did not report healthy KPIs"
  [[ "$prom" == Succeeded ]] || fail "python: promotion status $prom (want Succeeded)"
  (( $(mock_dispatches keptn-promote.yaml | wc -l) > before )) || fail "python: no keptn-promote.yaml dispatch for the healed release"
  result PASS "scenario 11 (Python runtime), healthy: kpi-guard-py in the app context; RELEASE_ID $rid (good config) -> app version $av Succeeded, kpi-guard-py passed, promotion dispatched"

  rb_before="$(mock_dispatches keptn-rollback.yaml | wc -l)"
  pr_before="$(mock_dispatches keptn-promote.yaml | wc -l)"
  log "Scenario 11 (Python runtime): repeat scenario 2 under kpi-guard-py"
  rid="$(release "e2e: inject fault (kpi-guard-py)" scripts/inject-fault.sh lab)"
  echo "RELEASE_ID $rid"
  check_fault_release "scenario 11 (Python runtime), fault" kpi-guard-py "$rid" "$rb_before" "$pr_before"
}

step_rbac() {
  start_guard
  local out rc=0
  log "Scenario 6 (RBAC): check matrix and add-user.sh (scripts/rbac-check.sh)"
  # Run the copy in the scratch repo, so add-user.sh writes the test user's key and kubeconfig
  # to $SRC/users (git-ignored there too) and never into the checkout.
  out="$("$SRC/scripts/rbac-check.sh" all 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  (( rc == 0 )) || fail "scenario 6 (RBAC): $(grep -c '^FAIL' <<<"$out") check(s) failed: $(grep '^FAIL' <<<"$out" | head -n 3 | tr '\n' ';')"
  result PASS "scenario 6 (RBAC): $(tail -n 1 <<<"$out" | sed 's/^rbac-check: //') (persona matrix, workload identities, add-user.sh certificate for lab:keptn-authors)"
}

# --- scenario 7: NetworkPolicies -------------------------------------------------------------
# The probe image is the lab's own pinned kubectl + curl image (traffic-pulse).
probe_image() { grep -oE 'alpine/k8s:[^ @]+@sha256:[0-9a-f]{64}' "$REPO_ROOT/apps/open5gs/traffic/traffic-pulse.yaml" | head -n 1; }

# probe_pod <namespace>: start (once) a pod "e2e-netprobe" that sleeps, in the given namespace.
probe_pod() {
  kubectl -n "$1" get pod e2e-netprobe >/dev/null 2>&1 && return 0
  kubectl -n "$1" run e2e-netprobe --image="$(probe_image)" --restart=Never \
    --labels=e2e=netprobe --command -- sleep 3600 >/dev/null
  kubectl -n "$1" wait --for=condition=Ready pod/e2e-netprobe --timeout=3m >/dev/null
}

# http_from <namespace> <url>: HTTP status from the probe pod, or "blocked" when the connection
# does not complete within 5 s (a NetworkPolicy drops the packets).
http_from() {
  local code
  code="$(kubectl -n "$1" exec e2e-netprobe -- curl -sS -o /dev/null -m 5 -w '%{http_code}' "$2" 2>/dev/null)" || true
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && echo "$code" || echo blocked
}

# http_as_pod <namespace> <pod> <url>: HTTP status of a request made from inside an existing pod's
# network namespace (an ephemeral debug container), so NetworkPolicies see that pod's labels.
http_as_pod() {
  local c="netcheck-$RANDOM" code=""
  kubectl -n "$1" debug "pod/$2" --image="$(probe_image)" --profile=general -c "$c" --quiet -- \
    curl -sS -o /dev/null -m 5 -w '%{http_code}' "$3" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if [[ -n "$(kubectl -n "$1" get pod "$2" -o json | jq -r --arg c "$c" '.status.ephemeralContainerStatuses[]? | select(.name == $c) | .state.terminated.reason // empty')" ]]; then
      code="$(kubectl -n "$1" logs "$2" -c "$c" 2>/dev/null)"
      break
    fi
    sleep 2
  done
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && echo "$code" || echo blocked
}

step_netpol() {
  start_guard
  local amf relay prom got am targets down bad sctp ngap regs gnb
  amf="http://open5gs-amf-metrics.$NS.svc:9090/metrics"
  relay="http://alert-relay.$NS.svc:8080/healthz"
  prom="http://kube-prometheus-stack-prometheus.observability.svc:9090/-/ready"
  log "Scenario 7 (NetworkPolicy, CNI=$CNI)"
  probe_pod default
  probe_pod "$NS"

  # Denied: anything outside open5gs and observability reaching the 5G core or Prometheus.
  for u in "$amf" "$relay" "$prom"; do
    got="$(http_from default "$u")"
    echo "    default -> $u: $got"
    [[ "$got" == blocked ]] || fail "scenario 7: namespace default reached $u (HTTP $got); want blocked"
  done
  # Allowed (and a control that the services answer at all): from inside open5gs.
  for u in "$amf" "$prom"; do
    got="$(http_from "$NS" "$u")"
    echo "    $NS -> $u: $got"
    [[ "$got" == 200 ]] || fail "scenario 7: $NS could not reach $u ($got); want 200"
  done
  # Alertmanager -> alert-relay (mission control) is allowed.
  am="$(kubectl -n observability get pods -l app.kubernetes.io/name=alertmanager -o name | head -n 1)"
  [[ -n "$am" ]] || fail "scenario 7: no Alertmanager pod"
  got="$(http_as_pod observability "${am#pod/}" "$relay")"
  echo "    alertmanager -> $relay: $got"
  [[ "$got" == 200 ]] || fail "scenario 7: Alertmanager could not reach the alert relay ($got); want 200"
  # Prometheus still scrapes the AMF, SMF and UPF.
  targets="$(prom_api '/api/v1/targets?state=active' |
    jq -c --arg ns "$NS" '[.data.activeTargets[] | select(.labels.namespace == $ns) | {job: .labels.job, health}]')" ||
    fail "scenario 7: Prometheus targets query failed"
  echo "    Prometheus targets in $NS: $(jq -r 'map("\(.job)=\(.health)") | join(" ")' <<<"$targets")"
  down="$(jq '[.[] | select(.health != "up")] | length' <<<"$targets")"
  for nf in amf smf upf; do
    jq -e --arg nf "$nf" 'any(.[]; (.job | test($nf)) and .health == "up")' <<<"$targets" >/dev/null ||
      fail "scenario 7: no healthy Prometheus target for $nf in $NS"
  done
  (( down == 0 )) || fail "scenario 7: $down Prometheus target(s) in $NS not up"
  # Keptn metric queries (metrics operator in keptn-system -> Prometheus) still work.
  bad="$(kubectl -n "$NS" get keptnmetrics.metrics.keptn.sh -o json |
    jq -r '[.items[] | select((.status.value // "") == "" or (.status.errMsg // "") != "") | .metadata.name] | join(",")')"
  [[ -z "$bad" ]] || fail "scenario 7: KeptnMetrics without a value or with an error: $bad"
  echo "    KeptnMetrics: $(kubectl -n "$NS" get keptnmetrics.metrics.keptn.sh -o json | jq -r '[.items[] | "\(.metadata.name)=\(.status.value)"] | join(" ")')"

  sctp=""
  if [[ "$CNI" == cilium ]]; then
    # SCTP: Cilium runs with SCTP enabled, the AMF's NGAP Service is SCTP, and UEs are registered,
    # which needs the gNB's NG Setup over that SCTP association.
    [[ "$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-sctp}')" == true ]] ||
      fail "scenario 7: Cilium runs without enable-sctp=true"
    ngap="$(kubectl -n "$NS" get svc open5gs-amf-ngap -o jsonpath='{.spec.ports[0].protocol}/{.spec.ports[0].port}')"
    [[ "$ngap" == SCTP/38412 ]] || fail "scenario 7: Service open5gs-amf-ngap is $ngap (want SCTP/38412)"
    regs="$(prom_api "/api/v1/query?query=$(jq -rn '"sum(fivegs_amffunction_rm_registeredsubnbr)" | @uri')" |
      jq -r '.data.result[0].value[1] // "0"')" || fail "scenario 7: Prometheus query failed"
    gnb="$(kubectl -n "$NS" logs deploy/ueransim-gnb --tail=-1 2>/dev/null | grep -i 'NG Setup procedure is successful' | tail -n 1 || true)"
    echo "    cilium enable-sctp=true; open5gs-amf-ngap $ngap; registered UEs $regs; gNB: ${gnb:-no NG Setup line in the current log}"
    awk -v r="$regs" 'BEGIN { exit !(r + 0 >= 1) }' || fail "scenario 7: no registered UE over the SCTP NGAP association (fivegs_amffunction_rm_registeredsubnbr=$regs)"
    sctp="; SCTP: Cilium enable-sctp, NGAP SCTP/38412, $regs UE(s) registered"
  fi
  kubectl -n default delete pod e2e-netprobe --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pod e2e-netprobe --wait=false >/dev/null 2>&1 || true
  result PASS "scenario 7 (NetworkPolicy, CNI=$CNI): default -> AMF metrics, alert-relay, Prometheus blocked; open5gs -> AMF metrics, Prometheus allowed; Alertmanager -> alert-relay allowed; Prometheus targets up; KeptnMetrics updating$sctp"
}

step_diag() {
  "$REPO_ROOT/scripts/collect-diagnostics.sh" "${1:-${E2E_DIAG_DIR:-$E2E_DIR/diagnostics}}"
  cp "$E2E_DIR/memory.log" "$E2E_DIR/results.md" "${1:-${E2E_DIAG_DIR:-$E2E_DIR/diagnostics}}/" 2>/dev/null || true
}

step_down() {
  stop_guard
  log "Deleting Kind cluster $CLUSTER and registry $REGISTRY_NAME"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" 2>/dev/null || true
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
}

step_memory() {
  local s; s="$(memory_summary)"
  echo "$s"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "- $s" >>"$GITHUB_STEP_SUMMARY"
  return 0
}

step_all() {
  local rc=0
  trap 'rc=$?; stop_guard; if (( rc != 0 )); then step_diag || true; fi; step_memory; [[ "${E2E_KEEP:-0}" == 1 ]] || step_down; exit $rc' EXIT
  trap 'exit 143' TERM INT
  step_up
  step_flux
  step_wait
  step_baseline
  step_rbac
  [[ "$CNI" == cilium || "${E2E_NETPOL:-0}" == 1 ]] && step_netpol
  step_happy
  step_fault
  step_slo
  step_python
}

(( $# )) || { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
for t in kubectl jq; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
mkdir -p "$E2E_DIR"
trap 'stop_guard' EXIT
while (( $# )); do
  case "$1" in
    up | flux | wait | baseline | rbac | netpol | happy | fault | slo | python | down | memory | all) "step_$1" ;;
    diag) step_diag "${2:-}"; [[ $# -gt 1 ]] && shift ;;
    *) die "unknown step: $1" ;;
  esac
  shift
done

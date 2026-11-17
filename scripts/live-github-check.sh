#!/usr/bin/env bash
# Live check of the lab's GitHub side against a real repository: the scenarios that the Kind
# e2e (scripts/e2e.sh, GitHub API mock) cannot prove.
#
#   promote      the first release passes; the Keptn promote task's real workflow_dispatch runs
#                keptn-promote.yaml on GitHub (a no-op success: the lab has one stage)
#   rollback     scenario 2: a faulty release; kpi-guard's real dispatch runs keptn-rollback.yaml,
#                which pushes a [keptn-rollback] commit; Flux applies it and the next app version
#                passes
#   mission      scenario 9: a release with a config change passes; the UDM is then scaled to 0
#                with kubectl (outside Git); Keptn is no longer watching, so after 15 minutes
#                Open5GSDegradedAfterRelease fires, alert-relay dispatches keptn-rollback.yaml, the
#                rollback commit restores the release before, Flux applies it, the manual drift
#                (UDM replicas) is reverted and the next app version passes
#   loop-guard   scenario 3: the good config is made bad too, then a fault is released: one
#                rollback, then the rollback's own release fails and keptn-rollback.yaml stops in
#                "Needs a human" without a second rollback commit
#
# Usage: scripts/live-github-check.sh --creds <file> [owner/repo]
#   owner/repo   target repository (default cuemby/keptn-flux-5gc-lab-sandbox). Its main branch
#                receives the lab tree of this checkout's HEAD commit (without the e2e and validate
#                workflows) on top of its history, Flux bootstrap commits, scenario commits and the
#                workflows' rollback commits; when the run ends, main gets the starting lab tree
#                back, so the next run starts clean. Use a throwaway repository: only names ending
#                in "-sandbox" are accepted unless LIVE_ALLOW_ANY_REPO=1. The bootstrap token cannot
#                change workflow files, so the target's .github must already match this checkout's
#                (minus e2e.yaml and validate.yaml); the run stops before pushing anything if not.
#                .github/workflows/live-github-check.yaml runs this script inside the target itself.
#   --creds      file with GITHUB_TOKEN (bootstrap: Administration and Contents write on the
#                repository) and KEPTN_DISPATCH_TOKEN (Actions write), one KEY=value per line.
#                The file is read as data, never executed, and DELETED when the run ends, whatever
#                the outcome. Preflight refusals (tools, memory, another Kind cluster) happen
#                before it is read and leave it in place.
#
# Environment:
#   LIVE_DIR            state directory (default ${TMPDIR:-/tmp}/kfl-live): clone, kubeconfig,
#                       results.md, memory.log
#   LIVE_MIN_AVAIL_MIB  refuse to start below this much available memory (default 6144); Linux only
#   LIVE_MEM_FLOOR_MIB  stop the run below this much available memory (default 1024); Linux only
#   LIVE_SCENARIOS      scenarios to run, in this order (default "promote rollback mission loop-guard")
#   LIVE_DIAG_DIR       when set and the run fails, scripts/collect-diagnostics.sh writes the
#                       cluster state there before the cluster is deleted (no Secrets)
#
# Runs the light profile with kindnet (scripts/bootstrap.sh, cluster keptn-5gc) and refuses to start
# while any Kind cluster exists. On exit it deletes the Kind cluster, the Flux deploy key that
# bootstrap added to the repository, and the credentials file. Tokens never appear in process
# arguments or output: they reach curl and git through stdin and a credential helper, and only
# scripts/bootstrap.sh gets them in its environment. Lasts a few hours (several releases and a
# 15-minute degradation).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_DIR="${LIVE_DIR:-${TMPDIR:-/tmp}/kfl-live}"
LIVE_MIN_AVAIL_MIB="${LIVE_MIN_AVAIL_MIB:-6144}"
LIVE_MEM_FLOOR_MIB="${LIVE_MEM_FLOOR_MIB:-1024}"
LIVE_SCENARIOS="${LIVE_SCENARIOS:-promote rollback mission loop-guard}"
CLUSTER=keptn-5gc            # name: in kind/cluster.yaml, used by scripts/bootstrap.sh
CLONE="$LIVE_DIR/repo"
STAGE=lab
NS=open5gs
VERSION_TIMEOUT=1800
export KUBECONFIG="$LIVE_DIR/kubeconfig"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL|INFO <text>: record an outcome (also from command substitutions)
  echo "- **$1** $2" | tee -a "$LIVE_DIR/results.md" >&2
}

# --- arguments and preflight (the credentials file is not touched yet) --------------------------
CREDS=""
TARGET="cuemby/keptn-flux-5gc-lab-sandbox"
while (( $# )); do
  case "$1" in
    --creds) [[ $# -ge 2 ]] || usage; CREDS="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -n "$CREDS" ]] || { echo "missing --creds <file>" >&2; usage; }
[[ "$TARGET" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "owner/repo expected, got '$TARGET'"
OWNER="${TARGET%%/*}"
REPO="${TARGET#*/}"
[[ "$REPO" == *-sandbox || "${LIVE_ALLOW_ANY_REPO:-0}" == 1 ]] ||
  die "$TARGET does not end in -sandbox; the run pushes to its main branch (set LIVE_ALLOW_ANY_REPO=1 to override)"
for s in $LIVE_SCENARIOS; do
  case "$s" in promote | rollback | mission | loop-guard) ;; *) die "unknown scenario in LIVE_SCENARIOS: $s" ;; esac
done

for t in kind kubectl flux git curl jq docker openssl; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
[[ -f "$CREDS" && -r "$CREDS" ]] || die "credentials file $CREDS not found or not readable"
docker info >/dev/null 2>&1 || die "docker is not running"
clusters="$(kind get clusters 2>/dev/null || true)"
[[ -z "$clusters" ]] || die "Kind cluster(s) already running: $(tr '\n' ' ' <<<"$clusters"); never run two at once"
avail_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }
if [[ -r /proc/meminfo ]]; then
  a="$(avail_mib)"
  (( a >= LIVE_MIN_AVAIL_MIB )) || die "only ${a} MiB available, LIVE_MIN_AVAIL_MIB=${LIVE_MIN_AVAIL_MIB}"
fi

# --- the run starts: from here on the credentials file is deleted on exit -------------------------
BOOT_TOKEN=""
DISPATCH_TOKEN=""
GUARD_PID=""
CLUSTER_CREATED=0
START_SHA=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -n "$GUARD_PID" ]] && { kill "$GUARD_PID" 2>/dev/null || true; }
  if (( CLUSTER_CREATED )); then
    if [[ -n "${LIVE_DIAG_DIR:-}" ]] && { (( rc != 0 )) || grep -q '^- \*\*FAIL' "$LIVE_DIR/results.md" 2>/dev/null; }; then
      log "Collecting diagnostics into $LIVE_DIAG_DIR"
      "$REPO_ROOT/scripts/collect-diagnostics.sh" "$LIVE_DIAG_DIR" >/dev/null 2>&1 || true
      cp "$LIVE_DIR/results.md" "$LIVE_DIR/memory.log" "$LIVE_DIAG_DIR/" 2>/dev/null || true
    fi
    log "Deleting Kind cluster $CLUSTER"
    kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" 2>/dev/null || true
  fi
  if [[ -n "$BOOT_TOKEN" && -n "$START_SHA" ]]; then
    log "Restoring the starting lab tree on $TARGET main"
    restore_tree || echo "warning: could not restore the lab tree on $TARGET main" >&2
  fi
  if [[ -n "$BOOT_TOKEN" ]] && (( CLUSTER_CREATED )); then
    log "Removing the Flux deploy key from $TARGET"
    delete_deploy_keys || echo "warning: could not remove the Flux deploy key; remove it under Settings > Deploy keys" >&2
  fi
  BOOT_TOKEN=""
  DISPATCH_TOKEN=""
  if [[ -e "$CREDS" ]]; then
    if command -v shred >/dev/null 2>&1; then shred -u "$CREDS" 2>/dev/null || rm -f "$CREDS"; else rm -f "$CREDS"; fi
  fi
  if [[ -e "$CREDS" ]]; then
    echo "error: could not delete $CREDS; delete it by hand" >&2
    rc=1
  else
    echo "deleted $CREDS"
  fi
  if [[ -s "$LIVE_DIR/memory.log" ]]; then
    awk '{ for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "avail_mib" && (min == "" || kv[2] < min)) min = kv[2] } }
         END { if (min != "") printf "lowest host available memory: %s MiB\n", min }' "$LIVE_DIR/memory.log" | tee -a "$LIVE_DIR/results.md"
  fi
  (( rc == 0 )) && grep -q '^- \*\*FAIL' "$LIVE_DIR/results.md" 2>/dev/null && rc=1
  echo "results: $LIVE_DIR/results.md (exit $rc)"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' INT TERM

mkdir -p "$LIVE_DIR"
chmod 700 "$LIVE_DIR"
: >"$LIVE_DIR/results.md"
: >"$LIVE_DIR/memory.log"

# Read KEY=value lines (optional "export " and quotes) without executing the file.
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#export }"
  key="${line%%=*}"
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  case "$key" in
    GITHUB_TOKEN) BOOT_TOKEN="$val" ;;
    KEPTN_DISPATCH_TOKEN) DISPATCH_TOKEN="$val" ;;
  esac
done <"$CREDS"
unset line key val
[[ -n "$BOOT_TOKEN" && -n "$DISPATCH_TOKEN" ]] || die "$CREDS must set GITHUB_TOKEN and KEPTN_DISPATCH_TOKEN"

# --- memory guard ------------------------------------------------------------------------------
mem_guard() {
  local main=$1 a
  while kill -0 "$main" 2>/dev/null; do
    if [[ -r /proc/meminfo ]]; then
      a="$(avail_mib)"
      echo "$(date -u +%FT%TZ) avail_mib=$a" >>"$LIVE_DIR/memory.log"
      if (( a < LIVE_MEM_FLOOR_MIB )); then
        echo "error: available memory ${a} MiB is below LIVE_MEM_FLOOR_MIB=${LIVE_MEM_FLOOR_MIB}; aborting" >&2
        echo "$(date -u +%FT%TZ) ABORT avail_mib=$a" >>"$LIVE_DIR/memory.log"
        # Bash runs the TERM trap only after the current foreground child ends (wait-ready.sh can
        # take 30 min), so stop the children too; this guard is one of them and ends here.
        kill -TERM "$main" 2>/dev/null || true
        pkill -TERM -P "$main" 2>/dev/null || true
        return
      fi
    fi
    sleep 15
  done
}
mem_guard $$ &
GUARD_PID=$!

# --- GitHub ------------------------------------------------------------------------------------
# gh_api <boot|dispatch> <method> <path> [json body]: the response body on stdout; fails on
# HTTP >= 400 (body on stderr). The token goes to curl through a config file on stdin.
gh_api() {
  local tok out code
  case "$1" in boot) tok="$BOOT_TOKEN" ;; dispatch) tok="$DISPATCH_TOKEN" ;; *) return 2 ;; esac
  local args=(-sS -X "$2" -w '\n%{http_code}' -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28' --config -)
  [[ $# -ge 4 ]] && args+=(-H 'Content-Type: application/json' --data-binary "$4")
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl "${args[@]}" "https://api.github.com$3")" || return 1
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if (( code >= 400 )); then
    echo "GitHub API $2 $3: HTTP $code: $(head -c 300 <<<"$out")" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# git_remote <git args...>: a git command in the clone that authenticates with the bootstrap token
# through a credential helper reading it from the environment; other helpers are switched off,
# so the token is never stored.
git_remote() {
  # shellcheck disable=SC2016  # $LIVE_GIT_TOKEN is expanded by the helper's shell
  LIVE_GIT_TOKEN="$BOOT_TOKEN" git -C "$CLONE" -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$LIVE_GIT_TOKEN"; }; f' "$@"
}

# restore_tree: put the lab tree of START_SHA (pushed by setup) back on main, undoing the scenario
# and rollback commits, so the next run starts from a healthy lab.
restore_tree() {
  git_remote fetch -q origin main || return 1
  git -C "$CLONE" reset -q --hard origin/main || return 1
  git -C "$CLONE" read-tree -u --reset "$START_SHA" || return 1
  if git -C "$CLONE" diff --cached --quiet; then return 0; fi
  git -C "$CLONE" commit -qm "live-github-check: restore the lab tree of ${START_SHA:0:12}" || return 1
  push || return 1
  result INFO "repository $TARGET main restored to the lab tree of ${START_SHA:0:12} at $(git -C "$CLONE" rev-parse --short HEAD)"
}

delete_deploy_keys() {
  local ids id
  ids="$(gh_api boot GET "/repos/$OWNER/$REPO/keys?per_page=100" | jq -r '.[] | select(.title | startswith("flux-system-")) | .id')" || return 1
  for id in $ids; do gh_api boot DELETE "/repos/$OWNER/$REPO/keys/$id" >/dev/null || return 1; done
}

# runs_since <workflow file> <ISO time>: workflow_dispatch runs created at or after that time, oldest
# first, as JSON lines {id, status, conclusion, url, created}.
runs_since() {
  gh_api dispatch GET "/repos/$OWNER/$REPO/actions/workflows/$1/runs?event=workflow_dispatch&per_page=50&created=%3E%3D$2" |
    jq -c '.workflow_runs | sort_by(.created_at)[] | {id, status, conclusion, url: .html_url, created: .created_at}'
}

# wait_run <workflow file> <ISO time> <timeout s> [conclusion]: wait for the first run since that
# time that completed (with that conclusion, when given); prints its JSON line.
wait_run() {
  local wf=$1 since=$2 deadline=$(( SECONDS + $3 )) want=${4:-} r
  while (( SECONDS < deadline )); do
    r="$(runs_since "$wf" "$since" | jq -c --arg w "$want" 'select(.status == "completed" and ($w == "" or .conclusion == $w))' | head -n 1)" || true
    [[ -n "$r" ]] && { echo "$r"; return 0; }
    sleep 20
  done
  return 1
}

# run_steps <run id>: "<step name>=<conclusion>" for every step of every job of a run.
run_steps() {
  gh_api dispatch GET "/repos/$OWNER/$REPO/actions/runs/$1/jobs" | jq -r '.jobs[].steps[] | "\(.name)=\(.conclusion)"'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- the repository clone ------------------------------------------------------------------------
release_id() { sed -nE 's/^[[:space:]]*RELEASE_ID:[[:space:]]*"([^"]+)".*/\1/p' "$CLONE/clusters/$STAGE/apps.yaml"; }
pull() { git_remote pull -q --rebase origin main; }
push() { git_remote push -q origin HEAD:main; }
commit() { git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "$1"; }

# reconcile: make Flux fetch the repository now instead of at the next interval.
reconcile() {
  flux reconcile source git flux-system -n flux-system --timeout=3m >/dev/null || true
  flux reconcile kustomization flux-system -n flux-system --timeout=5m >/dev/null || true
  flux reconcile kustomization apps -n "$NS" --timeout=5m >/dev/null || true
}

# shellcheck source=scripts/keptn-helpers.sh
source "$REPO_ROOT/scripts/keptn-helpers.sh"

kpi_logs() { local t; t="$(task_for "$1" kpi-guard)"; [[ -n "$t" ]] && { wait_task "$t" >/dev/null; task_logs "$t"; }; }

# expect_release <label> <release-id> <Succeeded|Failed>: wait for that release's app version;
# prints its name. Records a FAIL and returns 1 when it ends otherwise.
expect_release() {
  local label=$1 rid=$2 want=$3 av st
  if ! av="$(wait_appversion "$rid")"; then
    result FAIL "$label: app version for $rid did not finish within ${VERSION_TIMEOUT}s (${av:-not created})"
    return 1
  fi
  summarize "$av" >&2
  st="$(av_field "$av" '{.status.status}')"
  if [[ "$st" != "$want" ]]; then
    result FAIL "$label: app version $av for $rid ended $st (want $want)"
    return 1
  fi
  echo "$av"
}

# rollback_alerts [since]: names and states of action=rollback alerts that are pending or firing
# (only those active since that ISO time, when given), one per line.
rollback_alerts() {
  prom_api /api/v1/alerts |
    jq -r --arg t "${1:-}" '.data.alerts[] | select(.labels.action == "rollback" and (.state == "pending" or .state == "firing") and ($t == "" or .activeAt >= $t)) | "\(.labels.alertname) \(.state)"'
}

# settle <label>: wait (up to 30 min) until no rollback alert is pending or firing. A fault keeps
# the alerts' 10-minute windows bad after Keptn rolled it back; the next scenario starts clean.
settle() {
  local start=$SECONDS a
  while (( SECONDS - start < 1800 )); do
    a="$(rollback_alerts 2>/dev/null)" || a="(Prometheus unreachable)"
    if [[ -z "$a" ]]; then
      (( SECONDS - start >= 60 )) && result INFO "$1: waited $(( (SECONDS - start) / 60 )) min for the rollback alerts of the previous scenario to clear"
      return 0
    fi
    sleep 30
  done
  result INFO "$1: rollback alerts still active after 30 min: $(tr '\n' ' ' <<<"$a")"
}

# --- setup ----------------------------------------------------------------------------------------
setup() {
  local sha type user
  sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  log "Checking the tokens against $TARGET"
  gh_api boot GET "/repos/$OWNER/$REPO" >/dev/null || die "GITHUB_TOKEN cannot read $TARGET"
  gh_api dispatch GET "/repos/$OWNER/$REPO/actions/workflows" >/dev/null || die "KEPTN_DISPATCH_TOKEN cannot read the Actions of $TARGET"

  log "Pushing the lab tree at ${sha:0:12} to $TARGET main"
  rm -rf "$CLONE"
  git_remote_clone
  git -C "$CLONE" config user.name "kfl-live-check"
  git -C "$CLONE" config user.email "kfl-live-check@users.noreply.github.com"
  git -C "$CLONE" rm -rq --ignore-unmatch -- .
  git -C "$REPO_ROOT" archive HEAD | tar -xf - -C "$CLONE"
  # The sandbox runs only the workflows under test.
  rm -f "$CLONE/.github/workflows/e2e.yaml" "$CLONE/.github/workflows/validate.yaml"
  commit "live-github-check: lab tree at ${sha:0:12}" || true
  # The bootstrap token has no Workflows permission: GitHub refuses pushes that change .github.
  if ! git -C "$CLONE" diff --quiet origin/main HEAD -- .github; then
    die "$TARGET .github differs from this checkout's (without e2e.yaml and validate.yaml): $(git -C "$CLONE" diff --name-only origin/main HEAD -- .github | tr '\n' ' ')- push the workflows under test first with a token that may change workflows"
  fi
  push
  START_SHA="$(git -C "$CLONE" rev-parse HEAD)"
  result INFO "repository $TARGET main at $(git -C "$CLONE" rev-parse --short HEAD): lab tree of ${sha:0:12}"

  # flux bootstrap needs --personal for a user's repository, not for an organization's.
  type="$(gh_api boot GET "/users/$OWNER" | jq -r .type)" || die "cannot look up $OWNER"
  user="$OWNER"
  [[ "$type" == Organization ]] && user="live-check"

  log "Bootstrapping the lab (light profile, kindnet) against $TARGET"
  CLUSTER_CREATED=1
  GITHUB_TOKEN="$BOOT_TOKEN" KEPTN_DISPATCH_TOKEN="$DISPATCH_TOKEN" GITHUB_USER="$user" \
    GITHUB_OWNER="$OWNER" REPO="$REPO" BRANCH=main PROFILE=light CNI=kindnet \
    "$REPO_ROOT/scripts/bootstrap.sh"
  log "Waiting for Flux"
  "$REPO_ROOT/scripts/wait-ready.sh" 1800 || die "Flux Kustomizations and HelmReleases not Ready within 1800s"
  kubectl -n "$NS" rollout status deploy --timeout=10m
  result PASS "bootstrap: Flux from $TARGET, every Kustomization and HelmRelease Ready"
  pull
}

git_remote_clone() {
  # shellcheck disable=SC2016  # $LIVE_GIT_TOKEN is expanded by the helper's shell
  LIVE_GIT_TOKEN="$BOOT_TOKEN" git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$LIVE_GIT_TOKEN"; }; f' \
    clone -q "https://github.com/$OWNER/$REPO.git" "$CLONE"
}

# --- scenarios ------------------------------------------------------------------------------------
SINCE_SETUP=""

scenario_promote() {
  local rid av r
  rid="$(release_id)"
  log "promote: first release $rid, real keptn-promote.yaml dispatch"
  av="$(expect_release promote "$rid" Succeeded)" || return 0
  [[ "$(av_field "$av" '{.status.promotionStatus}')" == Succeeded ]] ||
    { result FAIL "promote: promotion of $av is $(av_field "$av" '{.status.promotionStatus}')"; return 0; }
  if r="$(wait_run keptn-promote.yaml "$SINCE_SETUP" 900)"; then
    if [[ "$(jq -r .conclusion <<<"$r")" == success ]]; then
      result PASS "promote: app version $av Succeeded; keptn-promote.yaml ran on GitHub and succeeded (no next stage): $(jq -r .url <<<"$r")"
    else
      result FAIL "promote: keptn-promote.yaml concluded $(jq -r .conclusion <<<"$r"): $(jq -r .url <<<"$r")"
    fi
  else
    result FAIL "promote: no keptn-promote.yaml run on $TARGET within 15 min of the promotion"
  fi
}

scenario_rollback() {
  local t rid av logs r subj rid2 av2
  log "rollback (scenario 2): faulty release, real keptn-rollback.yaml dispatch"
  settle rollback
  pull
  t="$(now_iso)"
  (cd "$CLONE" && NO_PUSH=1 scripts/inject-fault.sh "$STAGE" >/dev/null)
  push
  rid="$(release_id)"
  reconcile
  av="$(expect_release rollback "$rid" Failed)" || return 0
  logs="$(kpi_logs "$av")"
  grep -q 'rollback requested via Git' <<<"$logs" ||
    { result FAIL "rollback: kpi-guard of $av did not report 'rollback requested via Git'"; return 0; }
  r="$(wait_run keptn-rollback.yaml "$t" 900 success)" ||
    { result FAIL "rollback: no successful keptn-rollback.yaml run within 15 min of $t"; return 0; }
  pull
  subj="$(git -C "$CLONE" log -1 --format=%s -- "clusters/$STAGE/apps.yaml")"
  [[ "$subj" == "[keptn-rollback]"*"(keptn)"* ]] ||
    { result FAIL "rollback: last release commit is '$subj', not a [keptn-rollback] commit from keptn"; return 0; }
  rid2="$(release_id)"
  result PASS "rollback: RELEASE_ID $rid -> $av Failed; kpi-guard dispatched keptn-rollback.yaml, which succeeded ($(jq -r .url <<<"$r")) and pushed '$subj'"
  reconcile
  t="$(now_iso)"
  av2="$(expect_release rollback "$rid2" Succeeded)" || return 0
  if r="$(wait_run keptn-promote.yaml "$t" 900)"; then
    result PASS "rollback: Flux applied the rollback; RELEASE_ID $rid2 -> $av2 Succeeded and was promoted ($(jq -r .conclusion <<<"$r"): $(jq -r .url <<<"$r"))"
  else
    result FAIL "rollback: RELEASE_ID $rid2 -> $av2 Succeeded but no keptn-promote.yaml run followed"
  fi
}

scenario_mission() {
  local rid av t_break fired_after r subj rid2 av2 relay replicas start
  log "mission control (scenario 9): release with a config change, then a manual break outside Git"
  settle mission
  pull
  # A release that changes a release input (a comment in the good values file), so the rollback
  # has a previous state to restore; a RELEASE_ID-only bump changes no input to roll back.
  printf '# live-github-check %s: release before the scenario 9 break\n' "$(now_iso)" >>"$CLONE/apps/open5gs/values/open5gs-good.yaml"
  (cd "$CLONE" && scripts/bump-release.sh "$STAGE" >/dev/null)
  commit "live-github-check: release before the scenario 9 break"
  push
  rid="$(release_id)"
  reconcile
  av="$(expect_release mission "$rid" Succeeded)" || return 0
  result PASS "mission: release $rid -> $av Succeeded (kpi-guard passed; Keptn stops watching)"

  t_break="$(now_iso)"
  start=$SECONDS
  log "mission: scaling Deployment open5gs-udm to 0 with kubectl (outside Git) at $t_break"
  kubectl -n "$NS" scale deploy/open5gs-udm --replicas=0
  # The alert needs registrations failing for 15 min (for: 15m) on a 10m window.
  fired_after=""
  while (( SECONDS - start < 2400 )); do
    if rollback_alerts "$t_break" 2>/dev/null | grep -qx 'Open5GSDegradedAfterRelease firing'; then
      fired_after=$(( (SECONDS - start) / 60 ))
      break
    fi
    sleep 30
  done
  if [[ -z "$fired_after" ]]; then
    result FAIL "mission: Open5GSDegradedAfterRelease did not fire within 40 min of the break"
    kubectl -n "$NS" scale deploy/open5gs-udm --replicas=1 >/dev/null || true
    return 0
  fi
  result PASS "mission: Open5GSDegradedAfterRelease firing ${fired_after} min after the break"

  if ! r="$(wait_run keptn-rollback.yaml "$t_break" 900 success)"; then
    result FAIL "mission: no successful keptn-rollback.yaml run within 15 min of the alert"
    kubectl -n "$NS" logs deploy/alert-relay --tail=20 2>/dev/null | sed 's/^/    alert-relay: /' >&2 || true
    kubectl -n "$NS" scale deploy/open5gs-udm --replicas=1 >/dev/null || true
    return 0
  fi
  relay="$(kubectl -n "$NS" logs deploy/alert-relay --tail=-1 2>/dev/null | grep 'rollback dispatch for Open5GSDegradedAfterRelease' | tail -n 1 || true)"
  pull
  subj="$(git -C "$CLONE" log -1 --format=%s -- "clusters/$STAGE/apps.yaml")"
  if [[ "$subj" != "[keptn-rollback]"*"(alertmanager)"* ]]; then
    result FAIL "mission: last release commit is '$subj', not a [keptn-rollback] commit from alertmanager"
    kubectl -n "$NS" scale deploy/open5gs-udm --replicas=1 >/dev/null || true
    return 0
  fi
  rid2="$(release_id)"
  result PASS "mission: alert-relay dispatched (${relay:-no relay log line}); keptn-rollback.yaml succeeded ($(jq -r .url <<<"$r")) and pushed '$subj'"
  reconcile
  av2="$(expect_release mission "$rid2" Succeeded)" || { kubectl -n "$NS" scale deploy/open5gs-udm --replicas=1 >/dev/null || true; return 0; }
  replicas="$(kubectl -n "$NS" get deploy open5gs-udm -o jsonpath='{.spec.replicas}/{.status.availableReplicas}')"
  if [[ "$replicas" == 1/1 ]]; then
    result PASS "mission: Flux applied the rollback (RELEASE_ID $rid2 -> $av2 Succeeded) and reverted the manual drift (open5gs-udm replicas 1, available 1)"
  else
    result FAIL "mission: RELEASE_ID $rid2 -> $av2 Succeeded but open5gs-udm replicas/available is $replicas (want 1/1)"
    kubectl -n "$NS" scale deploy/open5gs-udm --replicas=1 >/dev/null || true
  fi
}

scenario_loop_guard() {
  local t rid av r1 first rid2 av2 r steps commits
  log "loop guard (scenario 3): make the good config bad too, then release a fault"
  settle loop-guard
  pull
  first="$(git -C "$CLONE" rev-parse HEAD)"
  cp "$CLONE/apps/open5gs/values/open5gs-fault-slice.yaml" "$CLONE/apps/open5gs/values/open5gs-good.yaml"
  commit "live-github-check: make the good config bad too (scenario 3)"
  t="$(now_iso)"
  # Pushed together with the fault, so Flux never applies the bad "good" config on its own.
  (cd "$CLONE" && NO_PUSH=1 scripts/inject-fault.sh "$STAGE" >/dev/null)
  push
  rid="$(release_id)"
  reconcile
  av="$(expect_release loop-guard "$rid" Failed)" || return 0
  r1="$(wait_run keptn-rollback.yaml "$t" 900 success)" ||
    { result FAIL "loop-guard: no successful keptn-rollback.yaml run for the first failure"; return 0; }
  pull
  rid2="$(release_id)"
  result PASS "loop-guard: RELEASE_ID $rid -> $av Failed; one rollback ($(jq -r .url <<<"$r1")) restored the (now bad) good config as RELEASE_ID $rid2"
  reconcile
  av2="$(expect_release loop-guard "$rid2" Failed)" || return 0
  # The rollback's own release failed: kpi-guard asks again, and the workflow must stop.
  if ! r="$(wait_run keptn-rollback.yaml "$t" 1500 failure)"; then
    result FAIL "loop-guard: no keptn-rollback.yaml run stopped for a human within 25 min (runs since $t: $(runs_since keptn-rollback.yaml "$t" | jq -r '"\(.conclusion) \(.url)"' | tr '\n' ' '))"
    return 0
  fi
  steps="$(run_steps "$(jq -r .id <<<"$r")")"
  pull
  commits="$(git -C "$CLONE" log --format=%s "$first..HEAD" | grep -c '^\[keptn-rollback\]' || true)"
  if grep -qx 'Needs a human=failure' <<<"$steps" && [[ "$commits" == 1 ]]; then
    result PASS "loop-guard: $av2 (the rollback's release) Failed; keptn-rollback.yaml stopped in 'Needs a human' ($(jq -r .url <<<"$r")); one rollback commit in total"
  else
    result FAIL "loop-guard: failed run $(jq -r .url <<<"$r") steps: $(tr '\n' ' ' <<<"$steps"); rollback commits since the scenario began: $commits (want 'Needs a human=failure' and 1)"
  fi
}

# --- main ------------------------------------------------------------------------------------------
SINCE_SETUP="$(now_iso)"
setup
for s in $LIVE_SCENARIOS; do
  case "$s" in
    promote) scenario_promote ;;
    rollback) scenario_rollback ;;
    mission) scenario_mission ;;
    loop-guard) scenario_loop_guard ;;
  esac
done
log "Results"
cat "$LIVE_DIR/results.md"

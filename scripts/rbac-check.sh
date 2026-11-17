#!/usr/bin/env bash
# Scenario 6: the RBAC check matrix for the lab personas and workload identities.
#
# Usage: scripts/rbac-check.sh [matrix|add-user|all]   (default: all)
#   matrix     ask the API server (kubectl auth can-i, impersonating each subject) whether each
#              persona group and workload identity may do what the matrix below says, and compare
#              every answer with the expected one
#   add-user   issue a real 7-day client certificate with scripts/add-user.sh for the test user
#              RBAC_USER in lab:keptn-authors, then check as that user (auth whoami, can-i, real
#              requests, certificate lifetime) and delete the user's key and kubeconfig
#   all        both
#
# Environment:
#   RBAC_USER   test user for add-user (default rbac-check); refused if users/<name>.key exists,
#               so a real lab user's key is never reused or deleted
#
# Needs kubectl with cluster-admin on the current context (impersonation and CSR approval), jq
# and openssl, on a cluster where Flux has applied the lab (the RBAC, the open5gs and observability
# namespaces, and the Keptn, Flux and monitoring CRDs). Prints one PASS or FAIL line per check and
# exits 1 when any check fails.
set -euo pipefail

MODE="${1:-all}"
RBAC_USER="${RBAC_USER:-rbac-check}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$MODE" in
  matrix | add-user | all) ;;
  *) echo "usage: $0 [matrix|add-user|all]" >&2; exit 2 ;;
esac
for t in kubectl jq openssl; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 1; }; done

PASSED=0
FAILED=0
CLEANUP=()   # the test user's key and kubeconfig, removed on exit
trap 'rm -f "${CLEANUP[@]}"' EXIT
ok() { PASSED=$((PASSED + 1)); echo "PASS $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL $*"; }

# can_i <subject flags...> -- <can-i args...>: prints yes, no, or error: <message>.
can_i() {
  local subj=() out
  while [[ "$1" != -- ]]; do subj+=("$1"); shift; done
  shift
  if out="$(kubectl auth can-i "$@" "${subj[@]}" 2>&1)"; then :; fi
  # "no" exits 1. A resource type the server does not know (a missing CRD) still gets a yes/no
  # answer, with a warning; count it as an error, like anything that is not a plain yes/no line.
  if grep -q "doesn't have a resource type" <<<"$out"; then
    echo "error: $(tr '\n' ' ' <<<"$out")"
    return
  fi
  case "$(tail -n 1 <<<"$out")" in
    yes) echo yes ;;
    no | "no - "*) echo no ;;
    *) echo "error: $(tr '\n' ' ' <<<"$out")" ;;
  esac
}

# --- the matrix ---------------------------------------------------------------------------------
# Persona groups come from the client certificate's O (scripts/add-user.sh); the user names are
# arbitrary. Workload identities are the service accounts the lab runs as.
# Subjects are impersonation flags, split on spaces (no value contains one).
VIEWER="--as=rbac-viewer --as-group=lab:viewers"
AUTHOR="--as=alice --as-group=lab:keptn-authors"
OPERATOR="--as=kai --as-group=lab:5gc-operators"
ADMIN="--as=rbac-admin --as-group=lab:platform-admins"
NOBODY="--as=rbac-nobody"   # authenticated, in no lab group
TRAFFIC="--as=system:serviceaccount:open5gs:keptn-traffic"
RUNNER="--as=system:serviceaccount:open5gs:keptn-task-runner"
RELAY="--as=system:serviceaccount:open5gs:alert-relay"
FLUX="--as=system:serviceaccount:open5gs:flux-apps"

# row <yes|no> <subject label> <subject flags> <can-i args...>
row() {
  local want=$1 label=$2 who=$3 got
  shift 3
  # shellcheck disable=SC2086  # who is a list of flags
  got="$(can_i $who -- "$@")"
  if [[ "$got" == "$want" ]]; then
    ok "$label: can-i $* = $got"
  else
    bad "$label: can-i $* = $got (want $want)"
  fi
}

matrix() {
  # lab:viewers: read everywhere (view + the Keptn, Flux and monitoring CRDs), port-forward in
  # observability only, no Secrets.
  row yes lab:viewers "$VIEWER" get pods -n open5gs
  row yes lab:viewers "$VIEWER" list keptnappversions.lifecycle.keptn.sh -n open5gs
  row yes lab:viewers "$VIEWER" list helmreleases.helm.toolkit.fluxcd.io -n open5gs
  row yes lab:viewers "$VIEWER" get prometheusrules.monitoring.coreos.com -n observability
  row yes lab:viewers "$VIEWER" create pods --subresource=portforward -n observability
  row no lab:viewers "$VIEWER" create pods --subresource=portforward -n open5gs
  row no lab:viewers "$VIEWER" get secrets -n open5gs
  row no lab:viewers "$VIEWER" create analyses.metrics.keptn.sh -n open5gs
  row no lab:viewers "$VIEWER" patch deployments -n open5gs
  row no lab:viewers "$VIEWER" create pods --subresource=exec -n open5gs

  # lab:keptn-authors (participants): Keptn objects and SLO analyses in open5gs, monitoring
  # objects and dashboards in observability, task logs; nothing that changes the 5G core.
  row yes lab:keptn-authors "$AUTHOR" create analyses.metrics.keptn.sh -n open5gs
  row yes lab:keptn-authors "$AUTHOR" create keptntaskdefinitions.lifecycle.keptn.sh -n open5gs
  row yes lab:keptn-authors "$AUTHOR" patch keptnappcontexts.lifecycle.keptn.sh -n open5gs
  row yes lab:keptn-authors "$AUTHOR" delete keptnevaluationdefinitions.lifecycle.keptn.sh -n open5gs
  row yes lab:keptn-authors "$AUTHOR" get pods --subresource=log -n open5gs
  row yes lab:keptn-authors "$AUTHOR" create servicemonitors.monitoring.coreos.com -n observability
  row yes lab:keptn-authors "$AUTHOR" update prometheusrules.monitoring.coreos.com -n observability
  row yes lab:keptn-authors "$AUTHOR" create configmaps -n observability
  row yes lab:keptn-authors "$AUTHOR" create pods --subresource=portforward -n observability
  row no lab:keptn-authors "$AUTHOR" create analyses.metrics.keptn.sh -n observability
  row no lab:keptn-authors "$AUTHOR" delete keptnappversions.lifecycle.keptn.sh -n open5gs
  row no lab:keptn-authors "$AUTHOR" patch deployments -n open5gs
  row no lab:keptn-authors "$AUTHOR" patch helmreleases.helm.toolkit.fluxcd.io -n open5gs
  row no lab:keptn-authors "$AUTHOR" create configmaps -n open5gs
  row no lab:keptn-authors "$AUTHOR" get secrets -n open5gs
  row no lab:keptn-authors "$AUTHOR" get secrets -n observability
  row no lab:keptn-authors "$AUTHOR" create pods --subresource=exec -n open5gs

  # lab:5gc-operators (Kai): admin in open5gs (Secrets there included), author rights elsewhere.
  row yes lab:5gc-operators "$OPERATOR" patch deployments -n open5gs
  row yes lab:5gc-operators "$OPERATOR" get secrets -n open5gs
  row yes lab:5gc-operators "$OPERATOR" create pods --subresource=exec -n open5gs
  row yes lab:5gc-operators "$OPERATOR" create analyses.metrics.keptn.sh -n open5gs
  row yes lab:5gc-operators "$OPERATOR" create prometheusrules.monitoring.coreos.com -n observability
  row no lab:5gc-operators "$OPERATOR" get secrets -n observability
  row no lab:5gc-operators "$OPERATOR" patch deployments -n observability
  row no lab:5gc-operators "$OPERATOR" get secrets -n flux-system
  row no lab:5gc-operators "$OPERATOR" create clusterrolebindings

  # lab:platform-admins: cluster-admin.
  row yes lab:platform-admins "$ADMIN" get secrets -n flux-system
  row yes lab:platform-admins "$ADMIN" create clusterrolebindings
  row yes lab:platform-admins "$ADMIN" delete nodes

  # A user outside the lab groups gets nothing.
  row no "no lab group" "$NOBODY" get pods -n open5gs
  row no "no lab group" "$NOBODY" list keptnappversions.lifecycle.keptn.sh -n open5gs

  # keptn-traffic (traffic-burst task, traffic-pulse CronJob): patch only the two UERANSIM
  # Deployments, read and exec into pods, nothing else.
  row yes sa/keptn-traffic "$TRAFFIC" patch deployment/ueransim-gnb-ues -n open5gs
  row yes sa/keptn-traffic "$TRAFFIC" patch deployment/ueransim-gnb -n open5gs
  row no sa/keptn-traffic "$TRAFFIC" patch deployment/open5gs-amf -n open5gs
  row yes sa/keptn-traffic "$TRAFFIC" list pods -n open5gs
  row yes sa/keptn-traffic "$TRAFFIC" create pods --subresource=exec -n open5gs
  row no sa/keptn-traffic "$TRAFFIC" delete pods -n open5gs
  row no sa/keptn-traffic "$TRAFFIC" get secrets -n open5gs

  # keptn-task-runner (kpi-guard, kpi-guard-py, promote) and alert-relay: no API rights.
  row no sa/keptn-task-runner "$RUNNER" get pods -n open5gs
  row no sa/keptn-task-runner "$RUNNER" get secrets -n open5gs
  row no sa/keptn-task-runner "$RUNNER" list configmaps -n open5gs
  row no sa/alert-relay "$RELAY" get secrets -n open5gs
  row no sa/alert-relay "$RELAY" list pods -n open5gs

  # flux-apps (apps Kustomization, both HelmReleases): open5gs and nothing else.
  row yes sa/flux-apps "$FLUX" create deployments -n open5gs
  row yes sa/flux-apps "$FLUX" create helmreleases.helm.toolkit.fluxcd.io -n open5gs
  row yes sa/flux-apps "$FLUX" create prometheusrules.monitoring.coreos.com -n open5gs
  row no sa/flux-apps "$FLUX" create deployments -n observability
  row no sa/flux-apps "$FLUX" get secrets -n observability
  row no sa/flux-apps "$FLUX" create clusterroles
}

# --- add-user.sh ------------------------------------------------------------------------------------
add_user() {
  local dir="$REPO_ROOT/users" key kc who user groups end_s now days ns_out
  key="$dir/$RBAC_USER.key"
  kc="$dir/$RBAC_USER.kubeconfig"
  if [[ -e "$key" || -e "$kc" ]]; then
    bad "add-user: $key or $kc already exists; set RBAC_USER to an unused name"
    return
  fi
  CLEANUP+=("$key" "$kc")

  if ! "$REPO_ROOT/scripts/add-user.sh" "$RBAC_USER" lab:keptn-authors; then
    bad "add-user: scripts/add-user.sh $RBAC_USER lab:keptn-authors failed"
    return
  fi
  ok "add-user: scripts/add-user.sh $RBAC_USER lab:keptn-authors wrote $kc"

  # Same file mode as the script promises (umask 077): the key never becomes world-readable.
  if [[ "$(stat -c %a "$key" 2>/dev/null || stat -f %Lp "$key")" == 600 ]]; then
    ok "add-user: $RBAC_USER.key is mode 600"
  else
    bad "add-user: $RBAC_USER.key is not mode 600"
  fi

  who="$(KUBECONFIG="$kc" kubectl auth whoami -o json 2>&1)" || { bad "add-user: auth whoami failed: $who"; return; }
  user="$(jq -r '.status.userInfo.username' <<<"$who")"
  groups="$(jq -r '.status.userInfo.groups | join(",")' <<<"$who")"
  if [[ "$user" == "$RBAC_USER" && ",$groups," == *,lab:keptn-authors,* ]]; then
    ok "add-user: auth whoami = $user (groups $groups)"
  else
    bad "add-user: auth whoami = $user (groups $groups), want $RBAC_USER in lab:keptn-authors"
  fi

  # The API server answers for the real certificate as it did for the impersonated author.
  local want args got
  while IFS='|' read -r want args; do
    # shellcheck disable=SC2086  # args is a word list
    got="$(KUBECONFIG="$kc" can_i -- $args)"
    if [[ "$got" == "$want" ]]; then
      ok "add-user: $RBAC_USER can-i $args = $got"
    else
      bad "add-user: $RBAC_USER can-i $args = $got (want $want)"
    fi
  done <<'EOF'
yes|create analyses.metrics.keptn.sh -n open5gs
yes|get pods --subresource=log -n open5gs
no|get secrets -n open5gs
no|patch deployments -n open5gs
EOF

  # Real requests, not only access reviews.
  if KUBECONFIG="$kc" kubectl -n open5gs get keptnappversions.lifecycle.keptn.sh >/dev/null 2>&1; then
    ok "add-user: $RBAC_USER lists keptnappversions in open5gs"
  else
    bad "add-user: $RBAC_USER cannot list keptnappversions in open5gs"
  fi
  if ns_out="$(KUBECONFIG="$kc" kubectl -n open5gs get secrets 2>&1)"; then
    bad "add-user: $RBAC_USER listed Secrets in open5gs"
  elif grep -qi forbidden <<<"$ns_out"; then
    ok "add-user: $RBAC_USER is Forbidden to list Secrets in open5gs"
  else
    bad "add-user: listing Secrets failed for another reason: $ns_out"
  fi

  # The certificate is valid for about 7 days (expirationSeconds 604800 on the CSR).
  end_s="$(KUBECONFIG="$kc" kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' |
    base64 -d | openssl x509 -noout -enddate | sed 's/^notAfter=//')"
  end_s="$(date -d "$end_s" +%s 2>/dev/null || date -j -f '%b %e %T %Y %Z' "$end_s" +%s)"
  now="$(date +%s)"
  days="$(( (end_s - now) / 3600 ))"
  if (( end_s - now > 6 * 86400 && end_s - now <= 7 * 86400 + 3600 )); then
    ok "add-user: certificate expires in ${days}h (about 7 days)"
  else
    bad "add-user: certificate expires in ${days}h (want about 168h)"
  fi
}

[[ "$MODE" == matrix || "$MODE" == all ]] && matrix
[[ "$MODE" == add-user || "$MODE" == all ]] && add_user
echo "rbac-check: $PASSED passed, $FAILED failed"
(( FAILED == 0 ))

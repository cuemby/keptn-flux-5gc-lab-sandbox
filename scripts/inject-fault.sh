#!/usr/bin/env bash
# Scenario 2: ship a bad Open5GS config (the SMF serves DNN "ims" while the UEs use "internet").
# Points the open5gs-values ConfigMap at values/open5gs-fault-slice.yaml, bumps RELEASE_ID, then
# commits and pushes so Flux applies it and Keptn evaluates the new release.
# Usage: scripts/inject-fault.sh [stage]   (default: lab). Set NO_PUSH=1 to commit only.
set -euo pipefail

STAGE="${1:-lab}"
cd "$(git rev-parse --show-toplevel)"
KUST=apps/open5gs/kustomization.yaml
FROM="values.yaml=values/open5gs-good.yaml"
TO="values.yaml=values/open5gs-fault-slice.yaml"

SWAP=1
if grep -qF "$TO" "$KUST"; then
  echo "$KUST already uses values/open5gs-fault-slice.yaml; bumping RELEASE_ID only"
  SWAP=0
else
  grep -qF "$FROM" "$KUST" || { echo "$KUST does not reference values/open5gs-good.yaml" >&2; exit 1; }
fi

# Bump first: it validates the stage, so a bad stage leaves $KUST untouched.
RELEASE_ID="$(scripts/bump-release.sh "$STAGE")"
if [[ "$SWAP" == "1" ]]; then
  sed -i.bak "s|$FROM|$TO|" "$KUST"
  rm -f "$KUST.bak"
fi
git add "$KUST" "clusters/$STAGE/apps.yaml"
git commit -m "Inject slice fault on $STAGE (RELEASE_ID $RELEASE_ID)" -- "$KUST" "clusters/$STAGE/apps.yaml"
if [[ "${NO_PUSH:-0}" != "1" ]]; then
  git push
fi
echo "released $RELEASE_ID with values/open5gs-fault-slice.yaml"

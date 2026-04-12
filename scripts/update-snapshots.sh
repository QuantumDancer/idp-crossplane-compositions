#!/usr/bin/env bash
# Regenerates all render golden files. Run this after intentional composition
# changes, then commit the updated expected/rendered.yaml files.
#
# Requires the crossplane CLI at the version pinned in .gitlab-ci.yml
# (CROSSPLANE_VERSION). A version mismatch will silently produce a golden file
# that diverges from CI output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read the pinned version from CI config so there is a single source of truth.
REQUIRED_VERSION=$(grep 'CROSSPLANE_VERSION:' "$REPO_ROOT/.gitlab-ci.yml" \
  | awk -F'"' '{print $2}')
# crossplane version exits 1 when not connected to a cluster; pipefail would
# abort the script before we can compare versions, so we suppress that exit code.
ACTUAL_VERSION=$({ crossplane version 2>&1 || true; } | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [[ "$ACTUAL_VERSION" != "$REQUIRED_VERSION" ]]; then
  echo "ERROR: crossplane CLI is ${ACTUAL_VERSION:-not found}, but CI pins ${REQUIRED_VERSION}."
  echo "       Golden files generated with a different version will diverge from CI."
  echo "       Install the correct version and retry."
  exit 1
fi

for xrd_dir in "$REPO_ROOT"/tests/render/*/; do
  xrd=$(basename "$xrd_dir")
  echo "==> Updating snapshot for $xrd"

  mkdir -p "$xrd_dir/expected"

  helm template --show-only "templates/apis/$xrd/composition.yaml" "$REPO_ROOT" \
    > /tmp/composition.yaml

  crossplane render \
    "$REPO_ROOT/examples/$xrd/default.yaml" \
    /tmp/composition.yaml \
    "$xrd_dir/functions.yaml" \
    > "$xrd_dir/expected/rendered.yaml"

  echo "OK: wrote $xrd_dir/expected/rendered.yaml"
done

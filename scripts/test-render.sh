#!/usr/bin/env bash
# Runs crossplane render for each XRD and diffs the output against the committed
# golden file. Exits non-zero if any diff is found; copies actual output next to
# the golden file for easy inspection in CI artifacts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

for xrd_dir in "$REPO_ROOT"/tests/render/*; do
  xrd=$(basename "$xrd_dir")
  echo "==> Rendering $xrd"

  # Helm-render the composition so crossplane render gets plain YAML, not Helm templates.
  helm template --show-only "templates/apis/$xrd/composition.yaml" "$REPO_ROOT" \
    >/tmp/composition.yaml

  # crossplane render's Docker runtime expects a local Docker socket to start
  # function containers. Docker-in-Docker in GitLab CI is unreliable across
  # runners (remote daemon, privilege restrictions). Instead, the CI job uses
  # crane to extract the static function binaries from their OCI images and
  # runs them as native gRPC servers on localhost. functions.ci.yaml targets
  # those servers via the Development runtime — no Docker daemon required.
  # Locally, the default Docker runtime in functions.yaml is used as normal.
  functions_file="$xrd_dir/functions.yaml"
  if [[ "${CI:-}" == "true" && -f "$xrd_dir/functions.ci.yaml" ]]; then
    functions_file="$xrd_dir/functions.ci.yaml"
  fi

  crossplane render \
    "$REPO_ROOT/examples/$xrd/default.yaml" \
    /tmp/composition.yaml \
    "$functions_file" \
    >/tmp/actual.yaml

  if ! diff -u "$xrd_dir/expected/rendered.yaml" /tmp/actual.yaml; then
    echo "FAIL: $xrd render output differs from golden file"
    cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
    FAILED=1
  else
    echo "OK: $xrd"
  fi
done

exit $FAILED

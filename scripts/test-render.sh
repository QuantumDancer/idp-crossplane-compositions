#!/usr/bin/env bash
# Runs crossplane render for each XRD and diffs the output against the committed
# golden file. Exits non-zero if any diff is found; copies actual output next to
# the golden file for easy inspection in CI artifacts.
#
# Locally: requires Docker and the 'crank' binary (see update-snapshots.sh).
# Function gRPC servers are started/stopped automatically.
# CI: function servers are already running (started in before_script).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

# --- Resolve binaries ----------------------------------------------------
# CI installs the crank CLI as 'crossplane' and the controller binary is not
# needed (no --crossplane-binary required) because the CI image already has
# what it needs. Locally we need both:
#   crank  — the CLI that drives 'composition render'
#   crossplane-server — the controller binary providing 'internal render',
#                       passed via --crossplane-binary to avoid Docker
VERSION=$(grep 'CROSSPLANE_VERSION:' "$REPO_ROOT/.gitlab-ci.yml" | awk -F'"' '{print $2}')

if [[ "${CI:-}" == "true" ]]; then
  CRANK="crossplane"
  CROSSPLANE_SERVER_BIN=""   # not needed in CI
else
  # Locate crank
  if [[ -x "$REPO_ROOT/crank" ]]; then
    CRANK="$REPO_ROOT/crank"
  elif command -v crank &>/dev/null; then
    CRANK="crank"
  elif [[ -x "/tmp/crank" ]]; then
    CRANK="/tmp/crank"
  else
    echo "ERROR: 'crank' not found. Download it from:"
    echo "  https://releases.crossplane.io/stable/${VERSION}/bin/darwin_arm64/crank"
    exit 1
  fi

  # Locate the controller binary (provides 'internal render')
  if [[ -x "$REPO_ROOT/crossplane-server" ]]; then
    CROSSPLANE_SERVER_BIN="$REPO_ROOT/crossplane-server"
  elif [[ -x "/tmp/crossplane-server" ]]; then
    CROSSPLANE_SERVER_BIN="/tmp/crossplane-server"
  else
    echo "ERROR: 'crossplane-server' not found. Download it from:"
    echo "  https://releases.crossplane.io/stable/${VERSION}/bin/darwin_arm64/crossplane"
    exit 1
  fi
fi

# --- Start function gRPC servers (local only) ----------------------------
# Read the pinned function versions from a known render test directory so
# the script never drifts out of sync with the rest of the repo.
SAMPLE_FUNCTIONS="$REPO_ROOT/tests/render/postgresqldatabases.idp.rottler.io/functions.yaml"
FGT_VERSION=$(grep function-go-templating "$SAMPLE_FUNCTIONS" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
FAR_VERSION=$(grep function-auto-ready    "$SAMPLE_FUNCTIONS" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')

STARTED_SERVERS=0
if [[ "${CI:-}" != "true" ]]; then
  if ! nc -z localhost 9443 2>/dev/null || ! nc -z localhost 9444 2>/dev/null; then
    echo "==> Starting function gRPC servers (go-templating ${FGT_VERSION}, auto-ready ${FAR_VERSION})"
    docker rm -f fgt far 2>/dev/null || true
    docker run -d --name fgt -p 9443:9443 \
      "xpkg.crossplane.io/crossplane-contrib/function-go-templating:${FGT_VERSION}" \
      --insecure
    docker run -d --name far -p 9444:9444 \
      "xpkg.crossplane.io/crossplane-contrib/function-auto-ready:${FAR_VERSION}" \
      --insecure --address :9444
    until nc -z localhost 9443 && nc -z localhost 9444; do sleep 0.3; done
    STARTED_SERVERS=1
  fi
fi
# shellcheck disable=SC2064  # STARTED_SERVERS is intentionally evaluated now
trap "[[ \$STARTED_SERVERS -eq 1 ]] && docker rm -f fgt far >/dev/null" EXIT

# --- Normalize render output ---------------------------------------------
# crossplane v2.3.1 embeds the current timestamp in conditions and generates
# a random UID per render. Passwords are random per randAlphaNum call.
# Document ordering within a single render can also vary across runs.
# We strip these before diffing so golden files test structure and spec
# content, not ephemeral values.
normalize() {
  python3 - "$1" <<'EOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

content = re.sub(r'lastTransitionTime: "[^"]*"', 'lastTransitionTime: "TIMESTAMP"', content)
content = re.sub(r'\buid: [0-9a-f-]{36}\b', 'uid: UID', content)
content = re.sub(r'^  password: .*$', '  password: PASSWORD', content, flags=re.MULTILINE)
content = re.sub(r'^  uri: .*$', '  uri: URI', content, flags=re.MULTILINE)

docs = [d.strip() for d in re.split(r'\n---\n|^---\n', content, flags=re.MULTILINE) if d.strip()]
docs.sort()
print('\n---\n'.join(docs))
EOF
}

# --- Run render tests -----------------------------------------------------
for xrd_dir in "$REPO_ROOT"/tests/render/*; do
  xrd=$(basename "$xrd_dir")
  echo "==> Rendering $xrd"

  helm template --show-only "templates/apis/$xrd/composition.yaml" "$REPO_ROOT" \
    >/tmp/composition.yaml

  RENDER_ARGS=(
    "$REPO_ROOT/examples/$xrd/default.yaml"
    /tmp/composition.yaml
    "$xrd_dir/functions.ci.yaml"
  )
  [[ -n "${CROSSPLANE_SERVER_BIN:-}" ]] && RENDER_ARGS+=(--crossplane-binary "$CROSSPLANE_SERVER_BIN")

  "$CRANK" composition render "${RENDER_ARGS[@]}" >/tmp/actual.yaml

  if ! diff -u <(normalize "$xrd_dir/expected/rendered.yaml") <(normalize /tmp/actual.yaml); then
    echo "FAIL: $xrd render output differs from golden file"
    cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
    FAILED=1
  else
    echo "OK: $xrd"
  fi
done

exit $FAILED

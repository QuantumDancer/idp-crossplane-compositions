#!/usr/bin/env bash
# Regenerates all render golden files. Run this after intentional composition
# changes, then commit the updated expected/rendered.yaml files.
#
# Requires the 'crank' binary at $REPO_ROOT/crank, on PATH, or at /tmp/crank.
# Download the version pinned in .gitlab-ci.yml from:
#   https://releases.crossplane.io/stable/<VERSION>/bin/darwin_arm64/crank
#
# Function gRPC servers are started and stopped automatically via Docker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Resolve binaries ----------------------------------------------------
# Two binaries are required locally:
#   crank              — CLI that drives 'composition render'
#   crossplane-server  — controller binary providing 'internal render'
#                        (passed via --crossplane-binary to avoid Docker)
# Both are available from:
#   https://releases.crossplane.io/stable/<VERSION>/bin/darwin_arm64/{crank,crossplane}
REQUIRED_VERSION=$(grep 'CROSSPLANE_VERSION:' "$REPO_ROOT/.gitlab-ci.yml" | awk -F'"' '{print $2}')

if [[ -x "$REPO_ROOT/crank" ]]; then
  CRANK="$REPO_ROOT/crank"
elif command -v crank &>/dev/null; then
  CRANK="crank"
elif [[ -x "/tmp/crank" ]]; then
  CRANK="/tmp/crank"
else
  echo "ERROR: 'crank' not found. Download it from:"
  echo "  https://releases.crossplane.io/stable/${REQUIRED_VERSION}/bin/darwin_arm64/crank"
  exit 1
fi

if [[ -x "$REPO_ROOT/crossplane-server" ]]; then
  CROSSPLANE_SERVER_BIN="$REPO_ROOT/crossplane-server"
elif [[ -x "/tmp/crossplane-server" ]]; then
  CROSSPLANE_SERVER_BIN="/tmp/crossplane-server"
else
  echo "ERROR: 'crossplane-server' not found. Download it from:"
  echo "  https://releases.crossplane.io/stable/${REQUIRED_VERSION}/bin/darwin_arm64/crossplane"
  exit 1
fi

ACTUAL_VERSION=$("$CRANK" version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ "$ACTUAL_VERSION" != "$REQUIRED_VERSION" ]]; then
  echo "ERROR: crank is ${ACTUAL_VERSION:-not found}, but CI pins ${REQUIRED_VERSION}."
  echo "       Golden files generated with a different version will diverge from CI."
  echo "       Download the correct version and retry."
  exit 1
fi

# --- Start function gRPC servers -----------------------------------------
SAMPLE_FUNCTIONS="$REPO_ROOT/tests/render/postgresqldatabases.idp.rottler.io/functions.yaml"
FGT_VERSION=$(grep function-go-templating "$SAMPLE_FUNCTIONS" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
FAR_VERSION=$(grep function-auto-ready    "$SAMPLE_FUNCTIONS" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')

echo "==> Starting function gRPC servers (go-templating ${FGT_VERSION}, auto-ready ${FAR_VERSION})"
docker rm -f fgt far 2>/dev/null || true
docker run -d --name fgt -p 9443:9443 \
  "xpkg.crossplane.io/crossplane-contrib/function-go-templating:${FGT_VERSION}" \
  --insecure
docker run -d --name far -p 9444:9444 \
  "xpkg.crossplane.io/crossplane-contrib/function-auto-ready:${FAR_VERSION}" \
  --insecure --address :9444
until nc -z localhost 9443 && nc -z localhost 9444; do sleep 0.3; done
trap "docker rm -f fgt far >/dev/null" EXIT

# --- Normalize render output ---------------------------------------------
# Must mirror test-render.sh exactly: render embeds a fresh timestamp/UID per run
# and document ordering can vary, so goldens are written normalized. Otherwise
# every regeneration churns ephemeral values and re-orders docs, drowning real
# changes in review noise.
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

# --- Regenerate golden files ---------------------------------------------
for xrd_dir in "$REPO_ROOT"/tests/render/*/; do
  xrd=$(basename "$xrd_dir")
  echo "==> Updating snapshot for $xrd"

  mkdir -p "$xrd_dir/expected"

  helm template --show-only "templates/apis/$xrd/composition.yaml" "$REPO_ROOT" \
    --values "$REPO_ROOT/environments/homelab.yaml" \
    > /tmp/composition.yaml

  "$CRANK" composition render \
    "$REPO_ROOT/examples/$xrd/default.yaml" \
    /tmp/composition.yaml \
    "$xrd_dir/functions.ci.yaml" \
    --crossplane-binary "$CROSSPLANE_SERVER_BIN" \
    > /tmp/rendered.yaml

  normalize /tmp/rendered.yaml > "$xrd_dir/expected/rendered.yaml"

  echo "OK: wrote $xrd_dir/expected/rendered.yaml"
done

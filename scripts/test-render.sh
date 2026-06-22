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
# Both binaries are required in all environments:
#   crank (invoked as 'crossplane' in CI) — the CLI that drives 'composition render'
#   crossplane-server — the controller binary providing 'internal render',
#                       passed via --crossplane-binary; without it, crank falls
#                       back to Docker to run that step
VERSION=$(grep 'CROSSPLANE_VERSION:' "$REPO_ROOT/.gitlab-ci.yml" | awk -F'"' '{print $2}')

if [[ "${CI:-}" == "true" ]]; then
  CRANK="crossplane"
  CROSSPLANE_SERVER_BIN="/usr/local/bin/crossplane-server"
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
content = re.sub(r'^  url: .*$', '  url: URL', content, flags=re.MULTILINE)

docs = [d.strip() for d in re.split(r'\n---\n|^---\n', content, flags=re.MULTILINE) if d.strip()]
docs.sort()
print('\n---\n'.join(docs))
EOF
}

# --- Run render tests -----------------------------------------------------
for xrd_dir in "$REPO_ROOT"/tests/render/*; do
  test_name=$(basename "$xrd_dir")
  # A dir named "<xrd>__<variant>" is an extra scenario for an existing XRD: it
  # reuses that XRD's composition but supplies its own example/observed/asserts,
  # so a single composition can be tested under multiple inputs without
  # disturbing the default golden. The base name before "__" selects the
  # composition (and the default example, unless example.yaml overrides it).
  xrd=${test_name%%__*}
  echo "==> Rendering $test_name"

  helm template --show-only "templates/apis/$xrd/composition.yaml" "$REPO_ROOT" \
    --values "$REPO_ROOT/environments/homelab.yaml" \
    >/tmp/composition.yaml

  example="$REPO_ROOT/examples/$xrd/default.yaml"
  [[ -f "$xrd_dir/example.yaml" ]] && example="$xrd_dir/example.yaml"

  RENDER_ARGS=(
    "$example"
    /tmp/composition.yaml
    "$xrd_dir/functions.ci.yaml"
  )
  [[ -n "${CROSSPLANE_SERVER_BIN:-}" ]] && RENDER_ARGS+=(--crossplane-binary "$CROSSPLANE_SERVER_BIN")

  # An optional observed.yaml feeds mocked observed composed resources into the
  # pipeline via --observed-resources, exercising reconcile-time branches that a
  # first-apply render can't reach (e.g. reusing a password read back from the
  # already-applied connection Secret). See assert-contains.txt below.
  if [[ -f "$xrd_dir/observed.yaml" ]]; then
    RENDER_ARGS+=(--observed-resources "$xrd_dir/observed.yaml")
  fi

  "$CRANK" composition render "${RENDER_ARGS[@]}" >/tmp/actual.yaml

  # Catch Go fmt errors (e.g. %!s(MISSING)) that an over-eager printf can bake into
  # ESO directives meant to pass through verbatim. They render as valid YAML, so a
  # stale golden could hide them — fail loudly and independently of the diff.
  if grep -qF '%!' /tmp/actual.yaml; then
    echo "FAIL: $test_name render output contains a Go-template formatting error (e.g. %!s(MISSING))"
    grep -nF '%!' /tmp/actual.yaml
    cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
    FAILED=1
    continue
  fi

  if ! diff -u <(normalize "$xrd_dir/expected/rendered.yaml") <(normalize /tmp/actual.yaml); then
    echo "FAIL: $test_name render output differs from golden file"
    cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
    FAILED=1
    continue
  fi

  # Optional literal assertions against the RAW (pre-normalize) render output.
  # normalize() rubs out passwords/uris/uids, so it can't prove a value was
  # carried through verbatim. assert-contains.txt holds one literal-substring
  # expectation per line; every line must appear in the raw output. This is how
  # the password-reuse path is verified: the known password from observed.yaml's
  # connection Secret must survive into the freshly rendered Secret rather than
  # being regenerated by randAlphaNum.
  if [[ -f "$xrd_dir/assert-contains.txt" ]]; then
    missing=0
    while IFS= read -r expect; do
      [[ -z "$expect" || "$expect" == \#* ]] && continue
      if ! grep -qF -- "$expect" /tmp/actual.yaml; then
        echo "FAIL: $test_name render output is missing expected substring: $expect"
        missing=1
      fi
    done < "$xrd_dir/assert-contains.txt"
    if [[ $missing -eq 1 ]]; then
      cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
      FAILED=1
      continue
    fi
  fi

  # Optional negative assertions: each line is a literal substring that must NOT
  # appear in the raw output. Makes "this input composes no such resource" an
  # explicit, self-documenting check rather than relying on a reader noticing the
  # resource's absence from the golden (e.g. metrics.enabled:false → no ServiceMonitor).
  if [[ -f "$xrd_dir/assert-absent.txt" ]]; then
    present=0
    while IFS= read -r forbidden; do
      [[ -z "$forbidden" || "$forbidden" == \#* ]] && continue
      if grep -qF -- "$forbidden" /tmp/actual.yaml; then
        echo "FAIL: $test_name render output contains forbidden substring: $forbidden"
        present=1
      fi
    done < "$xrd_dir/assert-absent.txt"
    if [[ $present -eq 1 ]]; then
      cp /tmp/actual.yaml "$xrd_dir/actual.yaml"
      FAILED=1
      continue
    fi
  fi

  echo "OK: $test_name"
done

exit $FAILED

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Helm chart that packages Crossplane XRDs (CompositeResourceDefinitions) and Compositions for the IDP. Deploying the chart installs the Crossplane API types and their pipeline compositions onto a cluster.

## Common Commands

```bash
# Render templates locally (primary way to validate changes)
helm template . --debug

# Lint the chart
helm lint .

# Apply an example XR to test a composition
kubectl apply -f examples/applicationenvironments.idp.rottler.io/default.yaml

# Run render (snapshot) tests — no cluster required
scripts/test-render.sh

# Regenerate render golden files after intentional composition changes
scripts/update-snapshots.sh

# Run full E2E suite on a temporary k3d cluster (requires Docker)
scripts/run-e2e.sh
```

## Architecture

### Directory Layout

```
templates/
  apis/<xrd-name>/       # XRD definition, Composition, and Crossplane RBAC — Helm-templated
  functions/             # Crossplane Function package installs (one per function)
files/<xrd-name>/        # Go-template snippets embedded into the composition at render time
examples/<xrd-name>/     # Sample XR manifests for manual testing
```

### Composition Pattern

Compositions run in **Pipeline mode** with two steps:

1. `crossplane-contrib-function-go-templating` — renders all composed resources from the `files/<xrd-name>/` templates.
2. `crossplane-contrib-function-auto-ready` — sets `status.ready` based on composed resource health.

The `files/` directory is the working area for composition logic. Each XRD gets its own subdirectory there:

- `variables.yaml` — extracts XR spec fields into Go template variables (sourced first so later files can reference `$team`, `$system`, etc.)
- One file per composed resource kind (e.g. `namespace.yaml`, `argocd-application.yaml`)

`composition.yaml` stitches these together via `.Files.Get` inside the go-template inline block.

### Naming Conventions

- **Resource names**: `<team>-<system>-<component>` (all three fields from XR spec)
- **XRD file paths**: `<plural>.<group>` (e.g. `applicationenvironments.idp.rottler.io`)
- **Crossplane RBAC**: `rbac-crossplane.yaml` grants Crossplane the permissions it needs to manage the composed resource types; label `rbac.crossplane.io/aggregate-to-crossplane: "true"` wires it into the Crossplane ClusterRole aggregate.

### External Dependencies

- **ArgoCD** (`argoproj.io/v1alpha1 Application`) — deployment repo URL pattern: `https://gitlab.home.rottlr.de/idp/<team>/<system>-<component>-deployment.git`
- **External Secrets Operator** (`external-secrets.io/v1 ExternalSecret`) — reads from Vault via `ClusterSecretStore/vault-backend`; the ArgoCD repo pull-secret path is `idp/platform/argocd/idp-group-pull-secret`

### Testing

Two test layers; both run in CI via `.gitlab-ci.yml`.

**Render tests** (`scripts/test-render.sh`) — fast, no cluster required.
`crossplane render` executes the composition pipeline locally against the example XR and diffs the output against a committed golden file (`tests/render/<xrd>/expected/rendered.yaml`).
In CI the `crossplane render` Docker runtime is replaced by gRPC servers extracted from OCI images with `crane` (`tests/render/<xrd>/functions.ci.yaml`), avoiding the need for a Docker daemon.
After intentional composition changes, run `scripts/update-snapshots.sh` to regenerate golden files (it verifies the local `crossplane` CLI matches the pinned CI version first).

**E2E tests** (`scripts/run-e2e.sh`) — full integration, requires Docker.
Spins up a k3d cluster, installs Crossplane + the IDP chart, waits for Functions and XRDs to be ready, then runs [Kyverno Chainsaw](https://kyverno.github.io/chainsaw/) tests from `tests/chainsaw/`.
k3d is used instead of kind because kind requires a writable `/sys/fs/cgroup` (systemd as PID 1), which is unavailable in GitLab CI Docker executors.
CRD stubs for ArgoCD and External Secrets Operator live in `tests/crds/` so compositions can be exercised without those controllers installed.

```
tests/
  render/<xrd>/            # Render test artifacts
    functions.yaml         # Docker runtime (local)
    functions.ci.yaml      # Development/gRPC runtime (CI — no Docker daemon)
    expected/
      rendered.yaml        # Golden file — commit after intentional changes
  chainsaw/
    chainsaw.yaml          # Global Chainsaw configuration (timeouts)
    <xrd>/
      chainsaw-test.yaml   # Test steps: apply XR, assert composed resources
      xr.yaml              # Example XR applied by the test
      assert/              # Partial-match assertions for each composed resource
  crds/                    # Minimal CRD stubs for external API types (ArgoCD, ESO)
```

### Adding a New XRD

1. `templates/apis/<plural>.<group>/definition.yaml` — CompositeResourceDefinition
2. `templates/apis/<plural>.<group>/composition.yaml` — Composition (Pipeline mode, reference files via `.Files.Get`)
3. `templates/apis/<plural>.<group>/rbac-crossplane.yaml` — ClusterRole aggregated to Crossplane
4. `files/<plural>.<group>/variables.yaml` — extract spec fields into template vars
5. `files/<plural>.<group>/<resource>.yaml` — one file per composed resource
6. `examples/<plural>.<group>/default.yaml` — minimal sample XR
7. `docs/xrds/<kebab-name>.md` — TechDocs page (see [TechDocs](#techdocs) below)
8. Add a row to the XRD catalog in `README.md` and `docs/index.md`
9. Add a nav entry in `mkdocs.yml`

### TechDocs

Tech docs live in `docs/xrds/` and are published via MkDocs (config: `mkdocs.yml`). Every XRD must have a corresponding doc page; keep it in sync whenever the XRD spec changes.

A complete XRD doc page covers:

- One-paragraph summary of what the XRD does and when to use it
- **What It Creates** — table of every composed resource with name pattern and location
- **Spec Fields** — table with field name, type, required flag, default, and description (one table per nested object when the spec has depth)
- **Quick Start** — minimal working YAML example
- **Status Fields** — table of all `status.*` fields
- Any XRD-specific sections that matter (HA mode, secret management, relationship to sibling XRDs, etc.)

Follow the style of existing pages (`docs/xrds/postgresql-database.md`) for formatting.

## XRD API Conventions (from README)

- Prefer enums (t-shirt sizes) over raw values in XR specs.
- Keep required fields minimal; use sensible defaults for optional fields.
- `ApplicationEnvironment` and `TeamInfraEnvironment` are Cluster-scoped (they create namespaces); all other XRDs are Namespaced.
- Every XRD must expose `status.ready` (bool) and `status.phase` (string).
- All XRDs live under `idp.rottler.io`, starting at `v1alpha1`; prefer backward-compatible (additive) schema changes.

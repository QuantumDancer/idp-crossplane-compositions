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

### Adding a New XRD

1. `templates/apis/<plural>.<group>/definition.yaml` — CompositeResourceDefinition
2. `templates/apis/<plural>.<group>/composition.yaml` — Composition (Pipeline mode, reference files via `.Files.Get`)
3. `templates/apis/<plural>.<group>/rbac-crossplane.yaml` — ClusterRole aggregated to Crossplane
4. `files/<plural>.<group>/variables.yaml` — extract spec fields into template vars
5. `files/<plural>.<group>/<resource>.yaml` — one file per composed resource
6. `examples/<plural>.<group>/default.yaml` — minimal sample XR

## XRD API Conventions (from README)

- Prefer enums (t-shirt sizes) over raw values in XR specs.
- Keep required fields minimal; use sensible defaults for optional fields.
- `ApplicationEnvironment` is Cluster-scoped (creates the namespace); all other XRDs are Namespaced.
- Every XRD must expose `status.ready` (bool) and `status.phase` (string).
- All XRDs live under `idp.rottler.io`, starting at `v1alpha1`; prefer backward-compatible (additive) schema changes.

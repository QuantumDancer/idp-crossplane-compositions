# Crossplane Compositions for the IDP

This repository implements all Crossplane compositions for my IDP reference application.

## XRD Catalog

| XRD Kind                 | Group            | Purpose                                   | Scope     | Status      |
| ------------------------ | ---------------- | ----------------------------------------- | --------- | ----------- |
| `ApplicationEnvironment` | `idp.rottler.io` | Namespace + RBAC + Argo CD Application    | Cluster   | Implemented |
| `TeamInfraEnvironment`   | `idp.rottler.io` | Team infra namespace + ArgoCD Application | Cluster   | Implemented |
| `PostgreSQLDatabase`     | `idp.rottler.io` | CloudNativePG cluster + credentials       | Namespace | Implemented |
| `RabbitMQCluster`        | `idp.rottler.io` | Dedicated RabbitMQ broker per team        | Namespace | Implemented |
| `RabbitMQInstance`       | `idp.rottler.io` | Vhost, user, topology + connection secret | Namespace | Implemented |
| `RedisCache`             | `idp.rottler.io` | Redis instance                            | Namespace | Planned     |
| `SearchIndex`            | `idp.rottler.io` | Elasticsearch index                       | Namespace | Planned     |

## XRD API Conventions

- **T-shirt sizing over raw values**: Expose `compute: small | medium | large` enums.
  Compositions map these to environment-specific resource values (the homelab environment gets minimal resources, AWS gets production-grade).
  This follows Upbound's recommendation to prefer enums over raw numbers in the XRD API.
- **Sensible defaults for optional fields**: Storage size, software version, HA mode all have defaults. Only fields without a safe default (like compute tier) are required. Keep the required field set minimal.
- **Namespaced scope for application infrastructure**: All per-component XRDs use `scope: Namespaced` so developers create composite resources in their own namespace.
  `ApplicationEnvironment` is the only exception (`scope: Cluster`, because it creates the namespace and can compose resources across namespaces).
- **Status contract**: Every XRD exposes `status.ready` (boolean), `status.phase` (string), and resource-specific fields (endpoints, connection secret refs). This gives Backstage and developers a uniform way to check readiness.
- **Standard label propagation**: Compositions propagate common labels to all composed resources.
- **API group and versioning**: All XRDs live under `idp.rottler.io`, starting at `v1alpha1`. Prefer backward-compatible schema changes (adding optional fields) over proliferating API versions.

## Testing

There are two test layers, both can be run locally and via CI.

### Render tests (fast, no cluster)

`crossplane render` executes the composition pipeline against the example XR and diffs against a committed golden file.

```bash
scripts/test-render.sh        # run render tests
scripts/update-snapshots.sh   # regenerate golden files after intentional changes
```

Golden files live at `tests/render/<xrd>/expected/rendered.yaml`.
Commit updated files after any deliberate composition change.

In CI, function containers are replaced by gRPC servers extracted from OCI images with `crane` (no Docker daemon required).
The CI-specific runtime config is in `tests/render/<xrd>/functions.ci.yaml`.

### E2E tests (Chainsaw, real cluster)

Spins up a k3d cluster, installs Crossplane + the IDP chart, and runs [Kyverno Chainsaw](https://kyverno.github.io/chainsaw/) tests.

```bash
scripts/run-e2e.sh   # requires Docker
```

Each XRD has a test directory under `tests/chainsaw/<xrd>/`: it applies the example XR and asserts that every composed resource appears with the expected fields.
The test also asserts `status.conditions[Ready]=True` on the XR itself to catch pipeline errors that produce resources but leave the XR unready.

CRD stubs for ArgoCD and External Secrets Operator are in `tests/crds/` so compositions can be exercised without those controllers installed.

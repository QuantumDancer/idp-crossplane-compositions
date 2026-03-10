# Crossplane Compositions for the IDP

This repository implements all Crossplane compositions for my IDP reference application.

## XRD Catalog

| XRD Kind                 | Group            | Purpose                                | Scope     | Status               |
| ------------------------ | ---------------- | -------------------------------------- | --------- | -------------------- |
| `ApplicationEnvironment` | `idp.rottler.io` | Namespace + RBAC + Argo CD Application | Cluster   | Implemented          |
| `PostgreSQLDatabase`     | `idp.rottler.io` | CloudNativePG cluster + credentials    | Namespace | Migrate to this repo |
| `RedisCache`             | `idp.rottler.io` | Redis instance                         | Namespace | Planned              |
| `MessageQueue`           | `idp.rottler.io` | RabbitMQ or Kafka topic/queue          | Namespace | Planned              |
| `SearchIndex`            | `idp.rottler.io` | Elasticsearch index                    | Namespace | Planned              |

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

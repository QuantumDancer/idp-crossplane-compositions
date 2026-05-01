# IDP Crossplane Compositions

This repository implements the Crossplane XRDs (CompositeResourceDefinitions) and Compositions that back the IDP's self-service infrastructure capabilities.

Developers create instances of these resources in their application namespaces. The platform team maintains the compositions that map high-level specs to actual Kubernetes resources.

## XRD Catalog

| XRD Kind                                                  | Scope     | Purpose                                       | Status      |
| --------------------------------------------------------- | --------- | --------------------------------------------- | ----------- |
| [PostgreSQLDatabase](xrds/postgresql-database.md)         | Namespace | CloudNativePG cluster + credential management | Implemented |
| [ApplicationEnvironment](xrds/application-environment.md) | Cluster   | Namespace + RBAC + ArgoCD Application         | Implemented |
| RedisCache                                                | Namespace | Redis instance                                | Planned     |
| MessageQueue                                              | Namespace | RabbitMQ or Kafka topic/queue                 | Planned     |
| SearchIndex                                               | Namespace | Elasticsearch index                           | Planned     |

## API Conventions

All XRDs follow these conventions:

**T-shirt sizing over raw values.** Compute resources use `small | medium | large` enums. The composition maps these to environment-appropriate values — minimal resources on homelab, production-grade on AWS. This keeps the XR API stable across environments.

**Sensible defaults for optional fields.** Storage size, software version, and HA mode all have defaults. Only fields with no safe default (like compute tier) are required.

**Standard status contract.** Every XRD exposes `status.ready` (bool) and `status.phase` (string) so Backstage and `kubectl wait` have a uniform readiness signal.

**Namespaced scope for application infrastructure.** All per-component XRDs are namespace-scoped so developers create resources in their own namespace. `ApplicationEnvironment` is the only cluster-scoped exception — it creates the namespace itself.

**Stable API group.** All XRDs live under `idp.rottler.io`, starting at `v1alpha1`. Schema changes are additive (new optional fields only). Breaking changes bump the version.

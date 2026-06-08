# IDP Crossplane Compositions

This repository implements the Crossplane XRDs (CompositeResourceDefinitions) and Compositions that back the IDP's self-service infrastructure capabilities.

Developers create instances of these resources in their application namespaces. The platform team maintains the compositions that map high-level specs to actual Kubernetes resources.

## XRD Catalog

| XRD Kind                                                  | Scope     | Purpose                                       |
| --------------------------------------------------------- | --------- | --------------------------------------------- |
| [PostgreSQLDatabase](xrds/postgresql-database.md)         | Namespace | CloudNativePG cluster + credential management |
| [ApplicationEnvironment](xrds/application-environment.md) | Cluster   | Namespace + RBAC + ArgoCD Application         |
| [TeamInfraEnvironment](xrds/team-infra-environment.md)    | Cluster   | Team infra namespace + ArgoCD Application     |
| [RabbitMQCluster](xrds/rabbitmq-cluster.md)               | Namespace | Dedicated RabbitMQ broker per team            |
| [RabbitMQInstance](xrds/rabbitmq-instance.md)             | Namespace | Vhost, user, topology + connection secret     |

## API Conventions

All XRDs follow these conventions:

**T-shirt sizing over raw values.** Compute resources use `small | medium | large` enums. The composition maps these to environment-appropriate values — minimal resources on homelab, production-grade on AWS. This keeps the XR API stable across environments.

**Sensible defaults for optional fields.** Storage size, software version, and HA mode all have defaults. Only fields with no safe default (like compute tier) are required.

**Standard status contract.** Every XRD exposes `status.ready` (bool) and `status.phase` (string) so Backstage and `kubectl wait` have a uniform readiness signal.

**Namespaced scope for application infrastructure.** All per-component XRDs are namespace-scoped so developers create resources in their own namespace. `ApplicationEnvironment` and `TeamInfraEnvironment` are cluster-scoped — they create the namespaces themselves and are managed by the platform team, not developers.

**Stable API group.** All XRDs live under `idp.rottler.io`, starting at `v1alpha1`. Schema changes are additive (new optional fields only). Breaking changes bump the version.

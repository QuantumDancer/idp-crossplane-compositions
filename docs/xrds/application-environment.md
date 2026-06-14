# ApplicationEnvironment

Provisions the namespace, RBAC, and ArgoCD `Application` for a single deployable component. There is one `ApplicationEnvironment` per component per cluster.

This is a **platform-managed resource** — developers do not create it directly. The [Python FastAPI template](https://backstage.home.rottlr.de/create) creates it automatically as part of service scaffolding. It is documented here for operators and for developers who need to understand what gets provisioned.

## What It Creates

For a component `team-a / order-management / order-service`:

| Resource           | Name / Location                                        |
| ------------------ | ------------------------------------------------------ |
| Namespace          | `team-a-order-management-order-service`                |
| ArgoCD Application | `team-a-order-management-order-service` in `argocd` ns |
| ArgoCD Repo Secret | ExternalSecret pulling GitLab deploy token from Vault  |

The ArgoCD Application tracks the component's deployment repo (`idp/team-a/order-management-order-service-deployment`) and syncs automatically on commit.

## Spec Fields

| Field         | Type                                   | Required | Default   | Description                                                                                |
| ------------- | -------------------------------------- | -------- | --------- | ------------------------------------------------------------------------------------------ |
| `team`        | string                                 | **Yes**  | —         | GitLab group / Backstage Group (e.g. `team-a`). Drives namespace naming and RBAC bindings. |
| `system`      | string                                 | **Yes**  | —         | Backstage System the component belongs to (e.g. `order-management`)                        |
| `component`   | string                                 | **Yes**  | —         | Backstage Component name (e.g. `order-service`)                                            |
| `environment` | `homelab \| development \| production` | **Yes**  | —         | Target environment tier                                                                    |
| `targetNamespace` | string                             | No       | —         | Deploy into an existing namespace instead of creating `{team}-{system}-{component}`. See [Co-location](#co-location). |

## Example

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: ApplicationEnvironment
metadata:
  name: team-a-order-management-order-service
  labels:
    idp.rottler.io/team: team-a
    idp.rottler.io/system: order-management
    idp.rottler.io/component: order-service
spec:
  team: team-a
  system: order-management
  component: order-service
  environment: homelab
```

## Namespace Naming

Namespaces follow `{team}-{system}-{component}`. This enables wildcard RBAC bindings (e.g. a `RoleBinding` scoped to `team-a-*`) and ensures global uniqueness even when teams use the same component name.

## ArgoCD Sync Behaviour

The ArgoCD Application uses automated sync with pruning and self-heal enabled. Branch selection depends on environment:

| Environment   | Source Branch |
| ------------- | ------------- |
| `homelab`     | `development` |
| `development` | `development` |
| `production`  | `production`  |

Helm value overlays follow the pattern:

```yaml
valueFiles:
  - values.yaml
  - environments/{environment}.yaml
```

## Co-location

By default each component owns a namespace named `{team}-{system}-{component}`. Setting `targetNamespace` makes a component deploy into an existing namespace instead: the composition skips the `Namespace` resource and points the ArgoCD `Application` destination at the named namespace.

This exists for the **backend + worker pair**: a queue worker must share its backend's RabbitMQ vhost connection secret and KEDA `TriggerAuthentication`, both of which are namespace-local. The worker sets `targetNamespace` to the backend's namespace and the pair co-locates.

```yaml
spec:
  team: team-a
  system: order-management
  component: order-worker
  environment: homelab
  targetNamespace: team-a-order-management-order-service  # the backend's namespace
```

Safe because the `Application` name, repo secret, and all chart resource names stay component-prefixed — two apps syncing one namespace don't collide. The `Namespace` is the only resource coupled 1:1 to a component, and the co-located worker never composes it, so it never prunes the backend-owned namespace.

Trade-offs (see the gap 2 decision in `PLATFORM-ASSESSMENT.md`): the namespace is owned and lifecycled by the component that creates it — deleting the backend's `ApplicationEnvironment` removes the shared namespace and thus the worker's runtime. Namespace-level secret isolation between the pair is gone; credential scoping is enforced at the pod level instead.

## Decommissioning

Deleting the `ApplicationEnvironment` XR cascades to ArgoCD pruning, which removes all in-cluster resources including the namespace. The GitLab repositories are archived separately via Backstage.

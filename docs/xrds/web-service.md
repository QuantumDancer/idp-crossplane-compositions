# WebService

Runs a long-running HTTP workload. One `WebService` replaces the seven-manifest
golden-path Helm chart (Deployment, Service, HTTPRoute, HPA, PDB, image-pull
ExternalSecret, ServiceAccount): you describe *what* to run, the platform owns
*how* it runs (Gateway wiring, PodDisruptionBudgets, securityContext baseline,
label mechanics).

Use this for any service that serves HTTP. For headless queue/batch processes,
use [Worker](worker.md).

## Quick Start

Minimal example — everything except `image`, `port`, and `compute` is defaulted:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: WebService
metadata:
  name: my-service
  namespace: team-a-my-system-my-service
  labels:
    idp.rottler.io/team: team-a
    idp.rottler.io/environment: homelab
spec:
  image:
    repository: gitlab.home.rottlr.de:5050/idp/team-a/my-service
    tag: "1.0.0"
  port: 8000
  compute: small
  expose:
    hostname: my-service
```

The composition creates:

- A `Deployment` (1 replica) with the platform security baseline
- A `Service` (ClusterIP) targeting the container port
- An `HTTPRoute` on the platform Gateway (only when `expose` is set)
- An image-pull `ExternalSecret` (platform group registry credentials)
- A `ServiceMonitor` (metrics on by default)
- A `ServiceAccount` (token unmounted unless `kubernetesAccess.enabled`)

No HPA and no PodDisruptionBudget are created for a single-replica service.

## Spec Fields

| Field                       | Type                        | Required | Default                  | Description                                                            |
| --------------------------- | --------------------------- | -------- | ------------------------ | ---------------------------------------------------------------------- |
| `image.repository`          | string                      | **Yes**  | —                        | Image repository (without tag).                                        |
| `image.tag`                 | string                      | No       | `""`                     | Image tag. CI writes this on every push.                               |
| `backstageComponent`        | string                      | No       | XR name                  | `backstage.io/kubernetes-id` label value (see [Backstage discovery](#backstage-discovery)). |
| `port`                      | integer                     | **Yes**  | —                        | Container port. Service targets it and probes default to it.           |
| `compute`                   | `small \| medium \| large`  | **Yes**  | —                        | CPU/memory tier (see [Compute Tiers](#compute-tiers)).                 |
| `scaling.min`               | integer                     | No       | `1`                      | Minimum replicas (≥ 1). Equal to `max` (or `max` unset) means fixed.   |
| `scaling.max`               | integer                     | No       | —                        | When greater than `min`, a CPU HPA is created. Must be `>= min`.       |
| `scaling.targetCPUUtilization` | integer                  | No       | `80`                     | Target average CPU percentage for the HPA.                             |
| `expose.hostname`           | string                      | No\*     | —                        | Short hostname; the cluster base domain is appended.                   |
| `expose.host`               | string                      | No\*     | —                        | Escape hatch: a full FQDN used verbatim.                               |
| `healthChecks.liveness`     | string                      | No       | `/api/v1/health/live`    | HTTP liveness path (served on `port`).                                 |
| `healthChecks.readiness`    | string                      | No       | `/api/v1/health/ready`   | HTTP readiness path (served on `port`).                                |
| `healthChecks.startup.path` | string                      | No       | liveness path            | HTTP startup-probe path (see [Startup probe](#startup-probe)).         |
| `healthChecks.startup.periodSeconds` | integer            | No       | `2`                      | Seconds between startup-probe attempts.                                |
| `healthChecks.startup.failureThreshold` | integer         | No       | `30`                     | Failures tolerated before restart (default budget ≈ 60s).              |
| `env`                       | map[string]string           | No       | `{}`                     | Static, non-secret config rendered as env vars.                        |
| `envFrom[]`                 | list                        | No       | `[]`                     | Secret-backed config (see [Secret-backed config](#secret-backed-config)). |
| `metrics.enabled`           | boolean                     | No       | `true`                   | Compose a `ServiceMonitor`.                                            |
| `metrics.path`              | string                      | No       | `/metrics`               | Scrape path on the container port.                                     |
| `kubernetesAccess.enabled`  | boolean                     | No       | `false`                  | Grant the ServiceAccount a curated RBAC preset.                       |
| `kubernetesAccess.preset`   | `view-workloads`            | No       | `view-workloads`         | Curated permission set.                                               |
| `kubernetesAccess.serviceAccount` | string                | No       | —                        | Run as a pre-existing SA instead of a composition-managed one (requires `enabled`; see [Kubernetes access](#kubernetes-access)). |

\* `expose` is optional; omit it for an internal-only Service. When present, set
exactly one of `hostname` or `host`.

## Compute Tiers

No CPU limit is set — throttling hurts these workloads more than it protects.
Numbers are homelab values; other environments can differ.

| Tier     | CPU request | Memory request | Memory limit |
| -------- | ----------- | -------------- | ------------ |
| `small`  | 100m        | 256Mi          | 512Mi        |
| `medium` | 250m        | 512Mi          | 1Gi          |
| `large`  | 500m        | 1Gi            | 2Gi          |

## Exposure and the base domain

`expose.hostname` is a short name. The composition appends the cluster's base
domain, so the same CR yields the right URL everywhere. The base domain is owned
by the platform: it is set per cluster in the compositions chart's environment
values (`environments/<env>.yaml`) and injected into the composition at install
time — developers do not configure it on the CR.

| Environment   | `hostname: my-service` →            |
| ------------- | ----------------------------------- |
| `homelab`     | `my-service.k8s.home.rottlr.de`     |
| `development` | `my-service.dev.idp.rottlr.de`      |

Use `expose.host` with a full FQDN to bypass the base-domain logic entirely.

## Secret-backed config

Each `envFrom` item is exactly one of:

```yaml
spec:
  envFrom:
    - secretRef: my-service-db           # an existing in-namespace Secret
    - vaultPath: idp/team-a/my-system/my-service-config   # composition creates an ExternalSecret
      name: config                       # required with vaultPath — stable Secret suffix
```

A `secretRef` consumes an existing Secret directly (e.g. a `PostgreSQLDatabase`
connection secret). A `vaultPath` makes the composition create an
`ExternalSecret` that pulls every key at the path into a Secret, which is then
loaded via `envFrom`. All keys become environment variables.

For a `vaultPath` item, `name` is required: the composed Secret/ExternalSecret is
named `<workload>-<name>` (e.g. `my-service-config`). Because you own the suffix,
reordering `envFrom` never re-points env vars at a different Secret. `name` must
match `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` and is ignored for `secretRef` items.

## Scaling and availability

- `scaling.min` must be `>= 1` (a WebService serves HTTP, so scale-to-zero is not
  allowed — that is a [Worker](worker.md) behaviour).
- `scaling.max` must be `>= scaling.min`; `max < min` is rejected at admission.
- `scaling.min == scaling.max` (or `max` omitted) → fixed replicas, no HPA.
- `scaling.min < scaling.max` → a CPU-based `HorizontalPodAutoscaler`.
- `scaling.min >= 2` → a `PodDisruptionBudget` (`maxUnavailable: 1`) is added
  automatically.

## Startup probe

A `startupProbe` guards slow-booting apps: until it succeeds, the liveness and
readiness probes are suppressed, so a cold start cannot trip the restart loop.
It defaults to the liveness path with a ~60s budget (`periodSeconds: 2` ×
`failureThreshold: 30`) — enough for heavyweight apps (e.g. Backstage on a small
tier). Override `healthChecks.startup.{path,periodSeconds,failureThreshold}` for
apps that need longer or expose a dedicated startup endpoint.

## Backstage discovery

Every composed resource carries a `backstage.io/kubernetes-id` label so
Backstage's Kubernetes plugin can list this component's workloads. The value
defaults to the XR name; set `backstageComponent` only when the Backstage
catalog entity's id differs (the value must match the entity's
`backstage.io/kubernetes-id` annotation).

## Kubernetes access

Set `kubernetesAccess.enabled: true` to give the workload's ServiceAccount the
`view-workloads` preset (read access to pods, deployments, services, HPAs,
jobs, and pod metrics) via a namespaced `Role`/`RoleBinding`. The token is only
mounted into the pod when this is enabled. Cluster-scoped access is not
composed — grants stay within the workload's own namespace.

For workloads that genuinely need broader (e.g. cluster-wide) access — such as
the platform's own Backstage instance — set `kubernetesAccess.serviceAccount`
to the name of a ServiceAccount in the workload's namespace that the platform
team has provisioned out-of-band, along with its `Role`/`ClusterRole` bindings.
The composition then runs the workload as that SA and creates **no**
ServiceAccount or RBAC of its own, so no XR can mint cluster-scoped permissions.
This field requires `enabled: true`.

## Status Fields

| Field                       | Type    | Description                                            |
| --------------------------- | ------- | ----------------------------------------------------- |
| `status.ready`              | boolean | `true` when the Deployment is Available.              |
| `status.phase`              | string  | `Provisioning`, `Ready`, `Degraded`, or `Failed`.     |
| `status.availableReplicas`  | integer | Number of available pods.                             |
| `status.url`                | string  | External URL (only when exposed via HTTPRoute).       |

```bash
kubectl get webservice my-service -n team-a-my-system-my-service
kubectl wait webservice/my-service --for=condition=Ready -n team-a-my-system-my-service --timeout=5m
```

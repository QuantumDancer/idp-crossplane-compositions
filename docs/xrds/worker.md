# Worker

Runs a headless, long-running process — a queue consumer or batch loop with no
Service, port, or HTTP probes. With a queue trigger it scales on queue depth via
[KEDA](https://keda.sh/) (scale-to-zero by default); without one it runs a fixed
replica count.

`Worker` shares the `image` / `compute` / `env` / `envFrom` / `metrics` /
`kubernetesAccess` surface with [WebService](web-service.md), so the two are
learned once. For HTTP services, use `WebService`.

## Quick Start

A queue-scaled worker:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: Worker
metadata:
  name: my-worker
  namespace: team-a-my-system-my-worker
  labels:
    idp.rottler.io/team: team-a
    idp.rottler.io/environment: homelab
spec:
  image:
    repository: gitlab.home.rottlr.de:5050/idp/team-a/my-worker
    tag: "1.0.0"
  compute: small
  scaling:
    min: 0
    max: 10
    queue:
      name: jobs
      connectionSecretRef: my-worker-rabbitmq
  cache:
    mountPath: /cache
    sizeLimit: 2Gi
```

The composition creates:

- A `Deployment` (no Service, no probes, no HTTPRoute)
- A KEDA `ScaledObject` + `TriggerAuthentication` (only when `scaling.queue` is set)
- An image-pull `ExternalSecret`
- A `PodMonitor` (metrics on by default — a Worker has no Service to scrape)
- A `ServiceAccount`

## Spec Fields

| Field                            | Type                       | Required | Default      | Description                                                          |
| -------------------------------- | -------------------------- | -------- | ------------ | -------------------------------------------------------------------- |
| `image.repository`               | string                     | **Yes**  | —            | Image repository (without tag).                                      |
| `image.tag`                      | string                     | No       | `""`         | Image tag. CI writes this on every push.                             |
| `backstageComponent`             | string                     | No       | XR name      | `backstage.io/kubernetes-id` label value (see [WebService](web-service.md#backstage-discovery)). |
| `compute`                        | `small \| medium \| large` | **Yes**  | —            | CPU/memory tier (see [WebService](web-service.md#compute-tiers)).    |
| `scaling.min`                    | integer                    | No       | `1`          | Minimum replicas. `0` enables scale-to-zero (queue triggers only).   |
| `scaling.max`                    | integer                    | No       | `10`         | Maximum replicas when a queue trigger owns scaling.                  |
| `scaling.queue.name`            | string                     | No\*     | —            | Queue to watch.                                                      |
| `scaling.queue.connectionSecretRef` | string                 | No\*     | —            | RabbitMQ connection Secret; its `uri` key holds the AMQP URI.        |
| `scaling.queue.messagesPerReplica` | integer                 | No       | `5`          | Target queue length per replica (KEDA `queueLength`).               |
| `cache.mountPath`                | string                     | No\*\*   | —            | Mount path for the scratch volume.                                  |
| `cache.sizeLimit`                | string                     | No\*\*   | —            | `emptyDir` size limit (e.g. `2Gi`). Pattern: `^[0-9]+(Mi\|Gi)$`.    |
| `env`                            | map[string]string          | No       | `{}`         | Static, non-secret config rendered as env vars.                     |
| `envFrom[]`                      | list                       | No       | `[]`         | Secret-backed config (see [WebService](web-service.md#secret-backed-config)). |
| `metrics.enabled`                | boolean                    | No       | `true`       | Compose a `PodMonitor` (see [Metrics](#metrics)).                   |
| `metrics.path`                   | string                     | No       | `/metrics`   | Scrape path.                                                        |
| `metrics.port`                   | integer                    | No       | `9100`       | Container port the worker exposes metrics on.                      |
| `kubernetesAccess.*`             | object                     | No       | disabled     | Curated RBAC preset (see [WebService](web-service.md#kubernetes-access)). |

\* `scaling.queue` is optional; when present, both `name` and `connectionSecretRef` are required.
\*\* `cache` is optional; when present, both `mountPath` and `sizeLimit` are required.

## Scaling semantics

| Configuration                       | Result                                                |
| ----------------------------------- | ----------------------------------------------------- |
| `scaling` omitted                   | Fixed 1 replica.                                      |
| `scaling.min` set, no `queue`       | Fixed `min` replicas.                                 |
| `scaling.queue` set                 | KEDA owns replicas between `min` and `max`.           |

`queue` is the only trigger in v1. The nesting leaves room for other triggers
(e.g. `cron`) later without a breaking change.

### Queue scaling

The `connectionSecretRef` points at a RabbitMQ connection Secret — typically a
[RabbitMQInstance](rabbitmq-instance.md)'s `status.connectionSecretRef`, which
lives in the same namespace. The composition reads its `uri` key (the AMQP URI)
through a KEDA `TriggerAuthentication`.

## Cache volume

`cache` mounts an `emptyDir` scratch volume. It is node-local and lost on pod
restart — by design, for transient working data. Persistent state is a different
conversation (a future PVC-backed XRD), not this field.

## Metrics

Metrics are on by default (`metrics.enabled: true`): the composition creates a
`PodMonitor` that scrapes each pod on the `metrics` port (`metrics.port`,
default `9100`) at `metrics.path` (default `/metrics`). **A Worker is therefore
expected to expose a Prometheus endpoint on that port** — the worker template
scaffolds one. A worker that serves no metrics would accrue a permanently
failing scrape; such workers must set `metrics.enabled: false`.

## Status Fields

| Field                       | Type    | Description                                                  |
| --------------------------- | ------- | ------------------------------------------------------------ |
| `status.ready`              | boolean | `true` when the Deployment is Available.                     |
| `status.phase`              | string  | `Provisioning`, `Ready`, `Degraded`, or `Failed`.            |
| `status.availableReplicas`  | integer | Number of available pods (`0` is healthy when scaled to zero). |

`availableReplicas` makes scale-out visible on the XR itself — watching it move
`0 → N → 0` under load is the demo payoff:

```bash
kubectl get worker my-worker -n team-a-my-system-my-worker -w
```

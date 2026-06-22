# RabbitMQCluster

Provisions a dedicated RabbitMQ broker for a team. Lives in the team's shared infra namespace and is referenced by [`RabbitMQInstance`](rabbitmq-instance.md) resources in per-service namespaces.

One cluster per team is the intended model — deploy it in the team's shared infra namespace, and individual services point their `RabbitMQInstance` resources at it. Teams that need workload isolation may deploy additional clusters in individual service namespaces instead.

!!! warning "One cluster per namespace"
The RabbitMQ Cluster Operator only supports a single `RabbitmqCluster` per namespace. If your team needs more than one cluster, each must live in its own namespace.

## What It Creates

| Resource                               | Name / Location                               |
| -------------------------------------- | --------------------------------------------- |
| `rabbitmq.com/v1beta1 RabbitmqCluster` | `<team>-rabbitmq` in the team infra namespace |
| `monitoring.coreos.com/v1 PodMonitor`  | `<team>-rabbitmq` in the team infra namespace |

The RabbitmqCluster name follows `<team>-rabbitmq`. In HA mode, a `PodDisruptionBudget` and pod anti-affinity rules are applied automatically by the RabbitMQ Cluster Operator.

## Spec Fields

| Field               | Type                                   | Required | Default   | Description                                                                                                                          |
| ------------------- | -------------------------------------- | -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `team`              | string                                 | **Yes**  | —         | Owning team. Stamped as the `idp.rottler.io/team` label on every composed resource.                                                  |
| `environment`       | `homelab \| development \| production` | **Yes**  | —         | Cluster environment. Stamped as the `idp.rottler.io/environment` label.                                                              |
| `allowedNamespaces` | string[]                               | **Yes**  | —         | Namespaces permitted to create topology resources against this cluster. List every `RabbitMQInstance` namespace, or `["*"]` for all. |
| `ha`                | boolean                                | No       | `false`   | `false`: 1 replica. `true`: 3 replicas with pod anti-affinity across nodes. **Immutable after creation.**                            |
| `version`           | string                                 | No       | `"3.13"`  | RabbitMQ container image version (e.g. `"3.13"`).                                                                                    |
| `storageSize`       | enum                                   | No       | `"small"` | Persistent volume size: `small` (1 Gi), `medium` (10 Gi), `large` (20 Gi), `x-large` (50 Gi).                                        |

## Quick Start

Minimal example — HA disabled, default version:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: RabbitMQCluster
metadata:
  name: team-a-rabbitmq
  namespace: team-a-infra
spec:
  team: team-a
  environment: homelab
  allowedNamespaces:
    - team-a-order-service
    - team-a-payment-service
```

With HA enabled and production-sized storage:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: RabbitMQCluster
metadata:
  name: team-a-rabbitmq
  namespace: team-a-infra
spec:
  team: team-a
  environment: homelab
  ha: true
  version: "3.13"
  storageSize: large
  allowedNamespaces:
    - team-a-order-service
    - team-a-payment-service
```

## HA Mode

| Mode        | Replicas | Anti-affinity       | Quorum queues |
| ----------- | -------- | ------------------- | ------------- |
| `ha: false` | 1        | None                | No (classic)  |
| `ha: true`  | 3        | Spread across nodes | Yes           |

Use `ha: false` on homelab or in development. Use `ha: true` for production workloads where broker restarts must not cause message loss.

!!! warning "ha is immutable"
The RabbitMQ Cluster Operator does not support scaling down. Once `ha: true` is set, it cannot be changed to `false` — the API server will reject the update. To change HA mode, delete and recreate the cluster.

## Observability

A `PodMonitor` is composed alongside the broker so Prometheus scrapes the cluster's
`rabbitmq_prometheus` endpoint (port `prometheus` / `:15692`) from birth. It scrapes
two paths on every broker pod:

| Path                | Purpose                                                                     | Labels on series                                     |
| ------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------- |
| `/metrics`          | Node/global health: memory, disk-alarm, connections, publish/deliver rates. | Per-node only — values are summed across all queues. |
| `/metrics/detailed` | Per-queue depth and consumer counts.                                        | `{queue, vhost}` per queue.                          |

The detailed path is scoped to the `queue_coarse_metrics` and `queue_consumer_count`
metric families, which yields per-queue series **with** `queue`/`vhost` labels without
the cardinality blow-up of `/metrics/per-object` (which also fans out per-connection
and per-channel):

| Metric                                     | Meaning                        |
| ------------------------------------------ | ------------------------------ |
| `rabbitmq_detailed_queue_messages_ready`   | Messages ready for delivery.   |
| `rabbitmq_detailed_queue_messages_unacked` | Delivered but unacknowledged.  |
| `rabbitmq_detailed_queue_messages`         | Total depth (ready + unacked). |
| `rabbitmq_detailed_queue_consumers`        | Attached consumers.            |

Because these carry the `queue` label, dashboards can graph an individual queue's
depth — e.g. `rabbitmq_detailed_queue_messages_ready{queue="jobs"}` and a dedicated
DLQ panel on `{queue="jobs.dlq"}` — which the aggregated
`rabbitmq_queue_messages_ready` series cannot distinguish.

## Status Fields

| Field          | Type    | Description                                                      |
| -------------- | ------- | ---------------------------------------------------------------- |
| `status.ready` | boolean | `true` when all cluster replicas are ready.                      |
| `status.phase` | string  | Current lifecycle phase: `Provisioning`, `Running`, or `Failed`. |

Check readiness with:

```bash
kubectl get rabbitmqcluster team-a-rabbitmq -n team-a-infra
kubectl wait rabbitmqcluster/team-a-rabbitmq \
  --for=condition=Ready \
  -n team-a-infra \
  --timeout=5m
```

## Relationship to RabbitMQInstance

`RabbitMQCluster` is infrastructure — it owns the broker process. [`RabbitMQInstance`](rabbitmq-instance.md) is the per-service abstraction — it provisions vhosts, users, and topology on top of an existing cluster. Create the cluster first; services then reference it via `spec.clusterRef`.

# RabbitMQCluster

Provisions a dedicated RabbitMQ broker for a team. Lives in the team's shared infra namespace and is referenced by [`RabbitMQInstance`](rabbitmq-instance.md) resources in per-service namespaces.

One cluster per team is the intended model — deploy it in the team's shared infra namespace, and individual services point their `RabbitMQInstance` resources at it. Teams that need workload isolation may deploy additional clusters in individual service namespaces instead.

!!! warning "One cluster per namespace"
The RabbitMQ Cluster Operator only supports a single `RabbitmqCluster` per namespace. If your team needs more than one cluster, each must live in its own namespace.

## What It Creates

| Resource                               | Name / Location                               |
| -------------------------------------- | --------------------------------------------- |
| `rabbitmq.com/v1beta1 RabbitmqCluster` | `<team>-rabbitmq` in the team infra namespace |

The RabbitmqCluster name follows `<team>-rabbitmq`. In HA mode, a `PodDisruptionBudget` and pod anti-affinity rules are applied automatically by the RabbitMQ Cluster Operator.

## Spec Fields

| Field     | Type    | Required | Default  | Description                                                                                           |
| --------- | ------- | -------- | -------- | ----------------------------------------------------------------------------------------------------- |
| `team`    | string  | **Yes**  | —        | Team name. Must match the `idp.rottler.io/team` label.                                                |
| `ha`      | boolean | No       | `false`  | `false`: 1 replica. `true`: 3 replicas with pod anti-affinity across nodes and quorum queue defaults. |
| `version` | string  | No       | `"3.13"` | RabbitMQ container image version (e.g. `"3.13"`).                                                     |

## Quick Start

Minimal example — HA disabled, default version:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: RabbitMQCluster
metadata:
  name: team-a-rabbitmq
  namespace: team-a-infra
  labels:
    idp.rottler.io/team: team-a
spec:
  team: team-a
```

With HA enabled:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: RabbitMQCluster
metadata:
  name: team-a-rabbitmq
  namespace: team-a-infra
  labels:
    idp.rottler.io/team: team-a
spec:
  team: team-a
  ha: true
  version: "3.13"
```

## HA Mode

| Mode        | Replicas | Anti-affinity       | Quorum queues |
| ----------- | -------- | ------------------- | ------------- |
| `ha: false` | 1        | None                | No (classic)  |
| `ha: true`  | 3        | Spread across nodes | Yes           |

Use `ha: false` on homelab or in development. Use `ha: true` for production workloads where broker restarts must not cause message loss.

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

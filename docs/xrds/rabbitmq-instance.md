# RabbitMQInstance

Provisions all logical messaging resources for a single service on a team's [`RabbitMQCluster`](rabbitmq-cluster.md): a dedicated vhost, a scoped user, exchanges, queues, bindings, and a plain Kubernetes `Secret` with AMQP connection details.

Create one `RabbitMQInstance` per service that needs to produce or consume messages. The service mounts the connection `Secret` directly — no Vault or External Secrets Operator involved.

## What It Creates

For a service `order-service` with one exchange and two queues:

| Resource                            | Name / Location                            |
| ----------------------------------- | ------------------------------------------ |
| `rabbitmq.com/v1beta1 Vhost`        | `<xr-name>` vhost on the cluster           |
| `rabbitmq.com/v1beta1 User`         | `<xr-name>-user` on the cluster            |
| `rabbitmq.com/v1beta1 Permission`   | Full access for the user within the vhost  |
| `rabbitmq.com/v1beta1 Exchange` × n | One per entry in `spec.exchanges`          |
| `rabbitmq.com/v1beta1 Queue` × n    | One per entry in `spec.queues`             |
| `rabbitmq.com/v1beta1 Binding` × n  | One per queue with an `exchange` field set |
| `v1 Secret`                         | `<xr-name>-connection` in the XR namespace |

## Spec Fields

### Top-level

| Field        | Type                      | Required | Default      | Description                                                                                                |
| ------------ | ------------------------- | -------- | ------------ | ---------------------------------------------------------------------------------------------------------- |
| `clusterRef` | object                    | **Yes**  | —            | Reference to the team's `RabbitMQCluster` (see below).                                                     |
| `durability` | `persistent \| ephemeral` | No       | `persistent` | `persistent`: durable queues/exchanges, survive broker restart. `ephemeral`: non-durable, lost on restart. |
| `exchanges`  | array                     | No       | `[]`         | Exchanges to create. Only needed for topic/fanout routing patterns.                                        |
| `queues`     | array                     | No       | `[]`         | Queues to create in the vhost.                                                                             |

### `clusterRef`

| Field       | Type   | Required | Description                                               |
| ----------- | ------ | -------- | --------------------------------------------------------- |
| `name`      | string | **Yes**  | Name of the `RabbitMQCluster` resource.                   |
| `namespace` | string | **Yes**  | Namespace where the cluster lives (team infra namespace). |

### `exchanges[]`

| Field  | Type                        | Required | Default | Description                |
| ------ | --------------------------- | -------- | ------- | -------------------------- |
| `name` | string                      | **Yes**  | —       | Exchange name in RabbitMQ. |
| `type` | `topic \| fanout \| direct` | No       | `topic` | Exchange type.             |

### `queues[]`

| Field        | Type   | Required | Description                                                                                                      |
| ------------ | ------ | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `name`       | string | **Yes**  | Queue name in RabbitMQ.                                                                                          |
| `exchange`   | string | No       | Exchange to bind this queue to. If omitted, the queue is unbound and receives messages via the default exchange. |
| `routingKey` | string | No       | Routing key for the binding. Defaults to `#` (matches all) for topic exchanges.                                  |

## Quick Start

Minimal example — persistent durability, one topic exchange, two bound queues:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: RabbitMQInstance
metadata:
  name: order-service-mq
  namespace: team-a-order-management-order-service
  labels:
    idp.rottler.io/team: team-a
spec:
  clusterRef:
    name: team-a-rabbitmq
    namespace: team-a-infra
  exchanges:
    - name: orders
      type: topic
  queues:
    - name: order-created
      exchange: orders
      routingKey: "order.created"
    - name: order-processed
      exchange: orders
      routingKey: "order.processed"
```

## Connection Secret

The composition creates a `Secret` named `<xr-name>-connection` in the XR namespace with the following keys:

| Key        | Example value                                                                              | Description             |
| ---------- | ------------------------------------------------------------------------------------------ | ----------------------- |
| `username` | `order-service-mq`                                                                         | RabbitMQ username       |
| `password` | _(generated)_                                                                              | RabbitMQ password       |
| `host`     | `team-a-rabbitmq.team-a-infra.svc`                                                         | Broker service hostname |
| `port`     | `5672`                                                                                     | AMQP port               |
| `vhost`    | `team-a-order-management-order-service-order-service-mq`                                   | Virtual host name (`<namespace>-<xr-name>`) |
| `uri`      | `amqp://order-service-mq:<pw>@...:5672/team-a-order-management-order-service-order-service-mq` | Full AMQP URI |

The vhost name is `<namespace>-<xr-name>`, which guarantees isolation even when two instances share the same namespace. The password is generated on the first reconcile and stable thereafter — it is read from the observed secret state on subsequent reconciles. Mount the secret in your deployment:

```yaml
envFrom:
  - secretRef:
      name: order-service-mq-connection
```

Or as individual environment variables:

```yaml
env:
  - name: RABBITMQ_URI
    valueFrom:
      secretKeyRef:
        name: order-service-mq-connection
        key: uri
```

## Durability

| Mode         | Queue/exchange durability | Survives broker restart |
| ------------ | ------------------------- | ----------------------- |
| `persistent` | Durable                   | Yes                     |
| `ephemeral`  | Non-durable               | No                      |

Use `persistent` (the default) for production. Use `ephemeral` only for transient, high-throughput scenarios where replaying messages from before a restart is not required.

## Status Fields

| Field                        | Type    | Description                                                    |
| ---------------------------- | ------- | -------------------------------------------------------------- |
| `status.ready`               | boolean | `true` when the vhost and user are provisioned and ready.      |
| `status.phase`               | string  | Current lifecycle phase: `Provisioning`, `Ready`, or `Failed`. |
| `status.connectionSecretRef` | string  | Name of the `Secret` containing AMQP connection details.       |

Check readiness with:

```bash
kubectl get rabbitmqinstance order-service-mq -n team-a-order-management-order-service
kubectl wait rabbitmqinstance/order-service-mq \
  --for=condition=Ready \
  -n team-a-order-management-order-service \
  --timeout=5m
```

## Relationship to RabbitMQCluster

`RabbitMQInstance` assumes an existing [`RabbitMQCluster`](rabbitmq-cluster.md) in the team's infra namespace. The `spec.clusterRef` points to it. The vhost, user, and topology resources are owned by the instance and deleted when the XR is deleted.

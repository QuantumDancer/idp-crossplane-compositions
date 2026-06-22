# KeyValueStore

Provisions a Redis-compatible, in-memory key/value store for a single service and writes a plain Kubernetes `Secret` with connection details. Backed by the [Dragonfly operator](https://www.dragonflydb.io/docs/getting-started/kubernetes-operator) — a GA, single-CRD, Redis-wire-compatible engine — so any Redis client connects unchanged.

Create one `KeyValueStore` per service that needs shared mutable state: a cache, a rate-limiter, a coordination point between replicas, or short-lived job state with per-key TTL. The service's workloads mount the connection `Secret` directly — no Vault or External Secrets Operator involved, exactly like a [`RabbitMQInstance`](rabbitmq-instance.md) connection `Secret`.

Unlike RabbitMQ, there is no separate cluster/instance split: a KV store is lightweight and single-tenant, so each `KeyValueStore` provisions its own backing store rather than referencing a shared one.

## What It Creates

| Resource                            | Name / Location                            |
| ----------------------------------- | ------------------------------------------ |
| `dragonflydb.io/v1alpha1 Dragonfly` | `<xr-name>` in the XR namespace            |
| `v1 Secret`                         | `<xr-name>-connection` in the XR namespace |

The Dragonfly operator additionally creates a `Service` named `<xr-name>` (port `6379`) that always routes to the current master pod — that is the host the connection `Secret` points at.

## Spec Fields

| Field         | Type                                   | Required | Default | Description                                                                                                                                             |
| ------------- | -------------------------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `team`        | string                                 | **Yes**  | —       | Owning team. Stamped as the `idp.rottler.io/team` label on every composed resource.                                                                     |
| `environment` | `homelab \| development \| production` | **Yes**  | —       | Cluster environment. Stamped as the `idp.rottler.io/environment` label.                                                                                 |
| `size`        | `small \| medium \| large \| x-large`  | No       | `small` | Memory/CPU tier. See [Sizing](#sizing).                                                                                                                 |
| `ha`          | boolean                                | No       | `false` | `false`: 1 standalone pod. `true`: 2 pods (1 master + 1 replica) with operator-managed failover.                                                        |
| `auth`        | boolean                                | No       | `true`  | `true`: a random password is generated, stored in the connection `Secret`, and enforced. `false`: no password — only sensible for throwaway/dev stores. |
| `persistence` | boolean                                | No       | `false` | `false`: purely in-memory (lost on restart). `true`: periodic snapshot to a PVC sized by tier. See [Persistence](#persistence).                         |

## Quick Start

Minimal example — a small, password-protected, ephemeral store:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: KeyValueStore
metadata:
  name: jobs-state
  namespace: team-a-e2e-backstage-test-backend
spec:
  team: team-a
  environment: homelab
  size: small
  auth: true
  persistence: false
```

## Connection Secret

The composition creates a `Secret` named `<xr-name>-connection` in the XR namespace with the following keys:

| Key        | Example value                                                                | Description                             |
| ---------- | ---------------------------------------------------------------------------- | --------------------------------------- |
| `host`     | `jobs-state.team-a-e2e-backstage-test-backend.svc`                           | Store service hostname                  |
| `port`     | `6379`                                                                       | Redis port                              |
| `password` | _(generated)_                                                                | Only present when `auth: true`          |
| `url`      | `redis://default:<pw>@jobs-state.team-a-e2e-backstage-test-backend.svc:6379` | Full Redis URL (`REDIS_URL` convention) |
| `uri`      | _(identical to `url`)_                                                       | Alias for `url`                         |

The URL uses the explicit `default` username (Redis/Dragonfly's default ACL user); the password-only form `redis://:<pw>@host` is rejected by strict clients (`redis-cli -u`) as `WRONGPASS`. When `auth: false`, the `password` key is omitted and the URL has no credentials: `redis://<host>:6379`.

The password is generated on the first reconcile and stable thereafter — it is read back from the observed `Secret` state on subsequent reconciles so it never diverges from the password the store enforces. Mount the secret in your deployment:

```yaml
envFrom:
  - secretRef:
      name: jobs-state-connection
```

Or as an individual environment variable:

```yaml
env:
  - name: REDIS_URL
    valueFrom:
      secretKeyRef:
        name: jobs-state-connection
        key: url
```

### Sharing the store between workloads

A `Secret` is namespace-scoped, so **every workload that uses the store must run in the `KeyValueStore`'s namespace** — the network host (`<xr-name>.<ns>.svc`) resolves cluster-wide, but the credentials Secret does not. This is the same model as `jobs-mq-connection`: a single Secret in one namespace, consumed by co-located workloads via `envFrom.secretRef`.

Co-location is how a backend and its worker share one store. The worker is scaffolded with its `ApplicationEnvironment` `targetNamespace` pointed at the backend's namespace, so Argo CD deploys it alongside the backend and the `<xr-name>-connection` Secret is already present for both `Deployment`s to mount. Declare the `KeyValueStore` once in that namespace's deployment repo, alongside the [`RabbitMQInstance`](rabbitmq-instance.md).

A standalone consumer that genuinely runs in its own namespace cannot see this Secret. Co-locate it (via `targetNamespace`), or replicate the connection details through Vault using the push/pull pattern from [`PostgreSQLDatabase`](postgresql-database.md) — `KeyValueStore` does not push to Vault today, so that path would be an additive change to the XRD.

## Per-key TTL

Redis-compatible TTL (`SET key val EX <seconds>` / `EXPIRE`) is an application-level feature available out of the box — no XRD configuration is needed. Use it for "drop off after N minutes" semantics (e.g. completed job tiles expiring ~5 min after they finish). Because the store is in-memory and TTL-driven, leave `persistence: false` for these workloads.

## Sizing

Memory is the capacity lever: Dragonfly derives its `maxmemory` from the pod's cgroup memory limit, so the composition sets `requests == limits` on memory (Guaranteed QoS, stable cap).

| Tier      | Memory | CPU request | Snapshot PVC (`persistence: true`) |
| --------- | ------ | ----------- | ---------------------------------- |
| `small`   | 512Mi  | 100m        | 1Gi                                |
| `medium`  | 1Gi    | 250m        | 5Gi                                |
| `large`   | 2Gi    | 500m        | 10Gi                               |
| `x-large` | 4Gi    | 1           | 20Gi                               |

## Persistence

| Mode    | Behaviour                                                                                          |
| ------- | -------------------------------------------------------------------------------------------------- |
| `false` | Purely in-memory. Data is lost when the pod restarts. Correct for caches and TTL-driven state.     |
| `true`  | Dragonfly snapshots to a PVC (every 15 minutes) and restores on restart. Sized by the `size` tier. |

## High Availability

| Mode    | Pods                     | Failover                                                      |
| ------- | ------------------------ | ------------------------------------------------------------- |
| `false` | 1 standalone             | None — a pod restart drops data (unless `persistence: true`). |
| `true`  | 2 (1 master + 1 replica) | Operator promotes the replica and re-points the `Service`.    |

Dragonfly is single-master, so HA means one replica for failover — there is no quorum/odd-replica requirement like RabbitMQ.

## Status Fields

| Field                        | Type    | Description                                                      |
| ---------------------------- | ------- | ---------------------------------------------------------------- |
| `status.ready`               | boolean | `true` when the store's `phase` is `Ready`.                      |
| `status.phase`               | string  | Current lifecycle phase: `Provisioning`, `Running`, or `Failed`. |
| `status.connectionSecretRef` | string  | Name of the `Secret` containing connection details.              |

Readiness is derived from the Dragonfly resource's `status.phase` (the operator reports `Ready` rather than a standard `Ready` condition). Check it with:

```bash
kubectl get keyvaluestore jobs-state -n team-a-e2e-backstage-test-backend
kubectl wait keyvaluestore/jobs-state \
  --for=condition=Ready \
  -n team-a-e2e-backstage-test-backend \
  --timeout=5m
```

## Prerequisite: the Dragonfly operator

`KeyValueStore` composes a `Dragonfly` custom resource, so the [Dragonfly operator](https://github.com/dragonflydb/dragonfly-operator) must be installed cluster-wide (managed by `argocd-platform-apps`, the same way the RabbitMQ and CloudNativePG operators are). Without it, the `Dragonfly` resource is created but never reconciled and the XR stays `Provisioning`.

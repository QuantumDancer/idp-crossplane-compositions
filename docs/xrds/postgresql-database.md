# PostgreSQLDatabase

Provisions a [CloudNativePG](https://cloudnative-pg.io/) cluster with automatic credential management via External Secrets Operator and HashiCorp Vault.

Use this when your service needs a dedicated PostgreSQL database. For shared databases or read replicas, talk to the platform team.

## Quick Start

Minimal example — all optional fields use their defaults:

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: PostgreSQLDatabase
metadata:
  name: order-db
  namespace: team-a-order-management-order-service
spec:
  team: team-a
  environment: homelab
  compute: small
  storage: 2Gi
  version: "17"
```

The composition creates:

- A CloudNativePG `Cluster` in the same namespace
- An `ExternalSecret` (or `PushSecret` in push mode) to manage credentials in Vault
- A Kubernetes `Secret` your app can mount to get the connection string

## Spec Fields

| Field                        | Type                                           | Required | Default                                    | Description                                                              |
| ---------------------------- | ---------------------------------------------- | -------- | ------------------------------------------ | ------------------------------------------------------------------------ |
| `team`                       | string                                         | **Yes**  | —                                          | Owning team. Stamped as the `idp.rottler.io/team` label.                 |
| `environment`                | `homelab \| development \| production`         | **Yes**  | —                                          | Cluster environment. Stamped as the `idp.rottler.io/environment` label.  |
| `compute`                    | `small \| medium \| large`                     | **Yes**  | —                                          | CPU and memory tier (see [Compute Tiers](#compute-tiers))                |
| `storage`                    | string                                         | Yes      | `"2Gi"`                                    | Persistent volume size. Pattern: `^[0-9]+(Mi\|Gi)$`                      |
| `version`                    | `"13"` \| `"14"` \| `"15"` \| `"16"` \| `"17"` | Yes      | `"17"`                                     | PostgreSQL major version                                                 |
| `ha`                         | boolean                                        | No       | `false`                                    | High availability: 1 primary + 2 read replicas when `true`               |
| `databaseName`               | string                                         | No       | XR name                                    | Database to create. Pattern: `^[a-zA-Z_][a-zA-Z0-9_]*$`                  |
| `owner`                      | string                                         | No       | XR name                                    | Database owner username. Same pattern as `databaseName`                  |
| `connectionSecret.type`      | `pull \| push`                                 | No       | `pull`                                     | Credential management mode (see [Secret Management](#secret-management)) |
| `connectionSecret.vaultPath` | string                                         | No       | `idp/databases/{namespace}/{databaseName}` | Vault KV v2 path for credentials                                         |

!!! note "XR name and database identifiers"
PostgreSQL identifiers cannot contain hyphens. If your XR name uses hyphens (e.g. `order-db`), set `databaseName` and `owner` explicitly using underscores (e.g. `order_db`).

## Compute Tiers

Resources are environment-specific. The same `compute: small` value maps to different actual resources depending on where the cluster runs:

| Tier     | Homelab CPU | Homelab RAM | AWS CPU | AWS RAM |
| -------- | ----------- | ----------- | ------- | ------- |
| `small`  | 100m        | 512 MiB     | 2 vCPU  | 8 GiB   |
| `medium` | 500m        | 1 GiB       | 4 vCPU  | 16 GiB  |
| `large`  | 1000m       | 2 GiB       | 8 vCPU  | 32 GiB  |

Start with `small` for development and most production workloads. Upgrade via a spec change — CloudNativePG handles rolling restarts.

## Secret Management

Two modes control how database credentials flow through the system.

### Pull mode (recommended for production)

You provision the credentials in Vault first, then the composition creates an `ExternalSecret` that pulls them into the namespace.

```yaml
spec:
  connectionSecret:
    type: pull
    vaultPath: idp/databases/team-a-order-management-order-service/order-db
```

The `ExternalSecret` expects these keys at the Vault path:

| Key        | Description           |
| ---------- | --------------------- |
| `username` | Database username     |
| `password` | Database password     |
| `host`     | Service hostname      |
| `port`     | Port (usually `5432`) |
| `dbname`   | Database name         |

Use this mode when credentials are long-lived or managed externally.

### Push mode (convenient for dev/test)

The composition generates a random password, stores it in a Kubernetes `Secret`, and pushes it to Vault via a `PushSecret`. An `ExternalSecret` then pulls it back — this keeps Vault as the single source of truth.

```yaml
spec:
  connectionSecret:
    type: push
    vaultPath: idp/databases/team-a-order-management-order-service/order-db
```

Push mode is useful when you want the platform to own the credential lifecycle end-to-end. The generated credentials are rotatable by deleting and recreating the XR.

## Status Fields

| Field                               | Type    | Description                                             |
| ----------------------------------- | ------- | ------------------------------------------------------- |
| `status.ready`                      | boolean | `true` when the database accepts connections            |
| `status.phase`                      | string  | Current phase: `Provisioning`, `Ready`, or `Failed`     |
| `status.readyInstances`             | integer | Number of healthy instances (1 non-HA, up to 3 HA)      |
| `status.connectionDetailsSecretRef` | string  | Name of the Kubernetes `Secret` with connection details |
| `status.endpoint`                   | string  | Primary read-write service endpoint                     |
| `status.readOnlyEndpoint`           | string  | Read-only endpoint (HA only)                            |
| `status.currentPrimary`             | string  | Name of the current primary pod                         |

Check readiness with:

```bash
kubectl get postgresqldatabase order-db -n team-a-order-management-order-service
kubectl wait postgresqldatabase/order-db \
  --for=condition=Ready \
  -n team-a-order-management-order-service \
  --timeout=5m
```

## Full Example

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: PostgreSQLDatabase
metadata:
  name: order-db
  namespace: team-a-order-management-order-service
  labels:
    idp.rottler.io/tier: dev
spec:
  team: team-a
  environment: homelab
  compute: small
  storage: 5Gi
  version: "17"
  ha: false
  databaseName: order_db
  owner: order_db
  connectionSecret:
    type: push
    vaultPath: idp/databases/team-a-order-management-order-service/order-db
```

## Vault Path Convention

Default path when `connectionSecret.vaultPath` is omitted:

```
idp/databases/{namespace}/{databaseName}
```

This aligns with the broader IDP path convention:

```
secrets/idp/{group}/{system}/{resource-kind}/{resource-name}
```

Team Vault policies grant read access to `secrets/data/idp/{team}/*`, so databases under the team's systems are automatically accessible to that team's applications.

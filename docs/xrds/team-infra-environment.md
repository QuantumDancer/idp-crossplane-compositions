# TeamInfraEnvironment

Provisions the shared infrastructure namespace and ArgoCD `Application` for a team. One `TeamInfraEnvironment` per team per cluster.

The infra namespace (e.g. `team-a-infra`) is where team-scoped shared resources live — `RabbitMQCluster` XRs are created here so they are isolated from individual application namespaces.

This is a **platform-managed resource** — the platform team creates one instance per team during onboarding. It is documented here for operators and developers who need to understand what gets provisioned.

## What It Creates

For a team named `team-a`:

| Resource           | Name                | Location    |
| ------------------ | ------------------- | ----------- |
| Namespace          | `team-a-infra`      | cluster     |
| ArgoCD Application | `team-a-infra`      | `argocd` ns |
| ArgoCD Repo Secret | `repo-team-a-infra` | `argocd` ns |

The ArgoCD Application tracks the team's infra git repo (`idp/team-a/team-a-infra.git`) and syncs automatically on commit
The repo secret is an `ExternalSecret` that pulls the GitLab pull token from Vault at `idp/platform/argocd/idp-group-pull-secret`.

## Spec Fields

| Field         | Type                                   | Required | Default   | Description                                                    |
| ------------- | -------------------------------------- | -------- | --------- | -------------------------------------------------------------- |
| `team`        | string                                 | **Yes**  | —         | Team name (e.g. `team-a`). Drives namespace and repo naming.   |
| `environment` | `homelab \| development \| production` | No       | `homelab` | Target environment tier. Reserved for multi-cluster targeting. |

## Quick Start

```yaml
apiVersion: idp.rottler.io/v1alpha1
kind: TeamInfraEnvironment
metadata:
  name: team-a
spec:
  team: team-a
  environment: homelab
```

The XR name must match the `team` field — it is used as the cluster-scoped identifier for the team.

## Relationship to Other XRDs

`RabbitMQCluster` XRs are created in the `{team}-infra` namespace that this XRD provisions. A `TeamInfraEnvironment` must exist before any `RabbitMQCluster` can be created for that team.

```
TeamInfraEnvironment (team-a)
  └── Namespace: team-a-infra
        └── RabbitMQCluster: team-a-rabbitmq
```

## Status Fields

`TeamInfraEnvironment` exposes the standard Crossplane conditions. There are no XRD-specific status fields.

| Condition    | Description                                                                        |
| ------------ | ---------------------------------------------------------------------------------- |
| `Ready`      | `True` once all composed resources (namespace, ArgoCD app, repo secret) are synced |
| `Synced`     | `True` while Crossplane is reconciling the XR successfully                         |
| `Responsive` | `True` while the composition function pipeline is reachable                        |

Check readiness with:

```bash
kubectl get teaminfraenvironment team-a
kubectl wait teaminfraenvironment/team-a --for=condition=Ready --timeout=2m
```

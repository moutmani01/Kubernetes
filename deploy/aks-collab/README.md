# AKS collaboration stack

This deployment path uses an in-cluster PostgreSQL instance on AKS instead of Azure Database for PostgreSQL Flexible Server.

## PostgreSQL

The PostgreSQL deployment is managed with the Bitnami Helm chart and a small PowerShell bootstrap flow:

1. Install the PostgreSQL release and admin secret:
   - `deploy/aks-collab/scripts/install-postgresql.ps1`
2. Create application databases/users and Kubernetes secrets for app charts:
   - `deploy/aks-collab/scripts/bootstrap-postgresql-apps.ps1`

### What gets created

- Namespace: `collab-platform`
- Helm release: `collab-postgresql`
- Service hostname inside AKS: `collab-postgresql.collab-platform.svc.cluster.local`
- App DB users/databases:
  - `openproject`
  - `docmost`
  - `passbolt`

### Secrets created in-cluster

- `collab-postgresql-auth`
- `openproject-db`
- `docmost-db`
- `passbolt-db`

These secrets are generated/applied locally and are **not** meant to be committed to Git.

## Current stop point

This is where the deployment work was left:

- AKS cluster is up in Azure and reachable with `kubectl`
- `ingress-nginx` is installed and received public IP `20.237.115.224`
- Public hostnames currently targeted:
  - `openproject.20-237-115-224.nip.io`
  - `docmost.20-237-115-224.nip.io`
  - `passbolt.20-237-115-224.nip.io`
- Shared TLS secret `collab-wildcard-tls` was generated locally and applied in-cluster
- In-cluster PostgreSQL is installed and app databases/users were bootstrapped
- `deploy/aks-collab/scripts/deploy-apps.ps1` now generates local runtime values under `.local/` and attempts Helm installs for OpenProject, Docmost, and Passbolt
- OpenProject was partially installed but not fully stabilized yet on the current small single-node AKS size; the latest observed blockers were resource pressure on the node and incomplete app startup/migration flow during Helm `--wait`
- Docmost and Passbolt were not deployed yet because work paused while stabilizing OpenProject first

## Notes

- The existing Terraform stack in `terraform/demo-aks` still contains Azure Flexible Server resources from the earlier approach. Do not re-apply it expecting the in-cluster PostgreSQL path until that stack is refactored separately.
- The already-created Azure Flexible Server can be removed later once you confirm you no longer want it.
- Local generated secrets/state stay under `deploy/aks-collab/.local/` and are git-ignored on purpose.

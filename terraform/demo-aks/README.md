# Demo AKS + PostgreSQL Terraform

This Terraform stack prepares the Azure infrastructure for:
- one AKS cluster
- one Azure Database for PostgreSQL Flexible Server
- three PostgreSQL databases: `openproject`, `docmost`, `passbolt`
- three PostgreSQL users with generated passwords, one per app

> Status note: this Terraform stack reflects the original Azure-managed PostgreSQL path.
> The newer app deployment work later pivoted to an in-cluster PostgreSQL release under
> `deploy/aks-collab/` because that was simpler for the AKS app deployment flow.
> Keep that distinction in mind before re-running `terraform apply`.

## Inputs already baked in from Mahfoud's current request
- Subscription: `42c20bc6-0b17-4863-9dd7-36fb9fb16729`
- Region: `eastus`
- Resource group: `openclaw`
- Cluster name request: `infra collaboration tools`
- Cost target: cheap demo defaults

## Important naming note
Azure resource names cannot safely use spaces in every case.
This stack normalizes the cluster name to:

`infra-collaboration-tools`

## What this stack does not do yet
This stack only creates the Azure infrastructure.
The Kubernetes app deployment flow now lives separately under `deploy/aks-collab/`.
That second path handles:
- Helm install automation for OpenProject
- Helm install automation for Docmost
- Helm install automation for Passbolt
- Kubernetes secrets / generated values wiring
- ingress / TLS / `nip.io` hostname setup

## Suggested next commands
```powershell
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

If Terraform is not yet on PATH in the current shell, use the installed binary directly on Windows:

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe\terraform.exe" init
```

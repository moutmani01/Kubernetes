locals {
  # App list is only used for the Azure PostgreSQL path in this stack.
  # The newer AKS-local PostgreSQL deployment lives under deploy/aks-collab/.
  apps = {
    openproject = {}
    docmost     = {}
    passbolt    = {}
  }

  normalized_cluster_name = replace(lower(var.cluster_name), " ", "-")
  # Azure names have tighter length limits than the human-friendly cluster name.
  name_prefix = substr(local.normalized_cluster_name, 0, 24)

  default_tags = {
    project     = "collaboration-tools"
    environment = var.environment
    managed_by  = "terraform"
    repository  = "moutmani01/Kubernetes"
  }

  merged_tags                = merge(local.default_tags, var.tags)
  # Allows AKS to stay in one region while PostgreSQL Flexible Server uses another
  # when Azure restricts PostgreSQL offers in the AKS region.
  effective_postgres_location = coalesce(var.postgres_location, var.location)
}

data "http" "current_ip" {
  url = "https://api.ipify.org"

  request_headers = {
    Accept = "text/plain"
  }
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# Keep the PostgreSQL server suffix separate from the AKS suffix.
# This avoids name reuse/collision headaches when Azure holds onto old server names.
resource "random_string" "postgres_suffix" {
  length  = 7
  upper   = false
  special = false
}

resource "random_password" "postgres_admin" {
  length           = 24
  special          = true
  override_special = "!@#%^*-_"
}

resource "random_password" "app_passwords" {
  for_each         = local.apps
  length           = 24
  special          = true
  override_special = "!@#%^*-_"
}

# Reuse the existing resource group instead of trying to create/import it.
# Import was awkward here because the postgresql provider depends on apply-time values.
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = local.normalized_cluster_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = "${local.name_prefix}-${random_string.suffix.result}"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"
  tags                = local.merged_tags

  default_node_pool {
    name                         = "system"
    node_count                   = var.node_count
    vm_size                      = var.aks_vm_size
    os_disk_size_gb              = 64
    only_critical_addons_enabled = false
    temporary_name_for_rotation  = "systemtmp"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  lifecycle {
    # Azure/provider refresh can introduce noisy drift here; ignore it so Terraform
    # does not try to rotate the AKS default node pool for this field alone.
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
    ]
  }

  role_based_access_control_enabled = true
}

# NOTE: this Azure Flexible Server path still exists in Terraform because it was part
# of the original approach. The current Kubernetes app deployment flow was later
# switched to an in-cluster PostgreSQL release under deploy/aks-collab/.
resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "${local.name_prefix}-pg-${random_string.postgres_suffix.result}"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = local.effective_postgres_location
  version                       = var.postgres_version
  administrator_login           = var.postgres_admin_username
  administrator_password        = random_password.postgres_admin.result
  storage_mb                    = var.postgres_storage_mb
  sku_name                      = var.postgres_sku_name
  backup_retention_days         = 7
  public_network_access_enabled = true
  tags                          = local.merged_tags
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_current_client" {
  name      = "allow-current-client"
  server_id = azurerm_postgresql_flexible_server.main.id
  # Uses the public IP seen by Terraform at apply time so local provider operations
  # can connect to the server during provisioning.
  start_ip_address = trimspace(data.http.current_ip.response_body)
  end_ip_address   = trimspace(data.http.current_ip.response_body)
}

resource "postgresql_role" "app_users" {
  for_each = local.apps

  name     = each.key
  login    = true
  password = random_password.app_passwords[each.key].result

  depends_on = [
    azurerm_postgresql_flexible_server_firewall_rule.allow_current_client,
    azurerm_postgresql_flexible_server_firewall_rule.allow_azure_services,
  ]
}

resource "postgresql_database" "app_databases" {
  for_each = local.apps

  name              = each.key
  owner             = postgresql_role.app_users[each.key].name
  encoding          = "UTF8"
  lc_collate        = "en_US.utf8"
  lc_ctype          = "en_US.utf8"
  connection_limit  = -1
  allow_connections = true

  depends_on = [postgresql_role.app_users]
}

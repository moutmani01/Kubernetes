output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_cluster_fqdn" {
  value = azurerm_kubernetes_cluster.main.fqdn
}

output "postgres_server_name" {
  value = azurerm_postgresql_flexible_server.main.name
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_admin_username" {
  value = var.postgres_admin_username
}

output "app_databases" {
  value = {
    for app in keys(local.apps) : app => {
      database = postgresql_database.app_databases[app].name
      username = postgresql_role.app_users[app].name
    }
  }
}

output "postgres_admin_password" {
  value     = random_password.postgres_admin.result
  sensitive = true
}

output "app_passwords" {
  value = {
    for app in keys(local.apps) : app => random_password.app_passwords[app].result
  }
  sensitive = true
}

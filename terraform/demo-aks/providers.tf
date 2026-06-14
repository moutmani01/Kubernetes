provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "postgresql" {
  host            = azurerm_postgresql_flexible_server.main.fqdn
  port            = 5432
  database        = "postgres"
  username        = var.postgres_admin_username
  password        = random_password.postgres_admin.result
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}

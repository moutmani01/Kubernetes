variable "subscription_id" {
  description = "Azure subscription ID where the demo environment will be deployed."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Azure resource group name."
  type        = string
  default     = "openclaw"
}

variable "cluster_name" {
  description = "Logical AKS cluster name. Spaces will be normalized to dashes for Azure resource names."
  type        = string
  default     = "infra collaboration tools"
}

variable "environment" {
  description = "Environment label used in tags and naming."
  type        = string
  default     = "demo"
}

variable "kubernetes_version" {
  description = "Optional AKS version. Leave null to use Azure's default stable version."
  type        = string
  default     = null
}

variable "node_count" {
  description = "System node count for the AKS default pool."
  type        = number
  default     = 1
}

variable "aks_vm_size" {
  description = "VM size for the AKS system node pool. Cheap default chosen for demo use."
  type        = string
  default     = "Standard_B2s"
}

variable "postgres_location" {
  description = "Azure region for PostgreSQL Flexible Server. Defaults to the main location when null."
  type        = string
  default     = null
}

variable "postgres_sku_name" {
  description = "Azure Database for PostgreSQL Flexible Server SKU. Cheap burstable default for demo use."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "postgres_storage_mb" {
  description = "Allocated PostgreSQL storage in MB."
  type        = number
  default     = 32768
}

variable "postgres_admin_username" {
  description = "Administrator username for PostgreSQL Flexible Server."
  type        = string
  default     = "pgadmin"
}

variable "tags" {
  description = "Additional Azure tags to merge with the default set."
  type        = map(string)
  default     = {}
}

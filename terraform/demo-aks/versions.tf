terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }

    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
  }
}

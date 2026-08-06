terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # État distant : indispensable dès qu'on est plusieurs. En local, deux
  # `terraform apply` concurrents se marcheraient dessus et pourraient
  # détruire des ressources créées par l'autre. Azure Blob Storage fournit
  # le verrouillage nativement, via les baux de blob.
  #
  # Le compte de stockage doit exister AVANT le premier `terraform init` — il
  # ne peut pas se créer lui-même. Voir README.md, section « Amorçage ».
  backend "azurerm" {
    # resource_group_name, storage_account_name et container_name sont
    # fournis par -backend-config au moment du init (voir README).
    key = "assistant-financier.tfstate"
  }
}

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  # État distant : indispensable dès qu'on est plusieurs. En local, deux
  # `terraform apply` concurrents se marcheraient dessus et pourraient
  # détruire des ressources créées par l'autre. GCS fournit en plus le
  # verrouillage automatiquement, sans table de lock à provisionner.
  #
  # Le bucket doit exister AVANT le premier `terraform init` — il ne peut pas
  # se créer lui-même (l'œuf et la poule). Voir README.md, section « Amorçage ».
  backend "gcs" {
    # bucket = fourni par -backend-config au moment du init (voir README)
    prefix = "assistant-financier/etat"
  }
}

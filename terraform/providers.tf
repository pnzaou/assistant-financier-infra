provider "azurerm" {
  subscription_id = var.id_abonnement

  features {
    resource_group {
      # `false` : refuser de supprimer un groupe de ressources qui contient
      # encore des ressources non gérées par Terraform. Sans ce garde-fou,
      # un `destroy` emporterait aussi ce qui aurait été créé à la main.
      prevent_deletion_if_contains_resources = true
    }
  }
}

# ─────────────────────────────────────────────────────────────────
# Providers Kubernetes et Helm : ils s'authentifient auprès du cluster que
# Terraform vient lui-même de créer, via le kubeconfig administrateur qu'AKS
# expose en sortie.
#
# Pas de fichier kubeconfig sur le disque : ça évite d'exiger un
# `az aks get-credentials` avant chaque apply, et ça fonctionne tel quel sur
# un runner de CI.
# ─────────────────────────────────────────────────────────────────

locals {
  kube = azurerm_kubernetes_cluster.principal.kube_config[0]
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}

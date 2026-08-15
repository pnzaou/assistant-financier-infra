provider "azurerm" {
  subscription_id = var.id_abonnement

  features {
    resource_group {
      # Ce garde-fou refuse de supprimer un groupe qui contient encore des
      # ressources inconnues de Terraform. L'intention est bonne — éviter
      # qu'un `destroy` emporte du travail fait à la main — mais elle ne
      # s'applique pas ici, et elle a un coût réel.
      #
      # AKS crée lui-même des ressources dans ce groupe, notamment la solution
      # `ContainerInsights(...)` dès qu'on active l'agent de supervision.
      # Terraform ne la connaît pas, la voit encore présente et refuse alors
      # de supprimer le groupe :
      #
      #   Error: deleting Resource Group "assistant-financier-rg":
      #     the Resource Group still contains Resources.
      #
      # Le `destroy` s'arrête donc à la toute dernière étape, après avoir déjà
      # tout supprimé — il faut finir à la main. Or rien n'est créé à la main
      # dans ce groupe : l'état Terraform vit dans un groupe SÉPARÉ
      # (`assistant-financier-tfstate`), justement pour qu'il survive.
      #
      # `false` laisse donc Azure nettoyer les ressources imbriquées.
      prevent_deletion_if_contains_resources = false
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

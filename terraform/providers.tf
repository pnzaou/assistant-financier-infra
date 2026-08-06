provider "google" {
  project = var.projet_gcp
  region  = var.region
  zone    = var.zone
}

# ─────────────────────────────────────────────────────────────────
# Providers Kubernetes et Helm : ils s'authentifient auprès du cluster que
# Terraform vient lui-même de créer.
#
# On passe par un jeton OAuth du provider google plutôt que par un
# kubeconfig sur le disque : ça évite d'exiger `gcloud container
# clusters get-credentials` avant chaque apply, et ça fonctionne tel quel
# sur un runner de CI.
# ─────────────────────────────────────────────────────────────────

data "google_client_config" "courant" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.principal.endpoint}"
  token                  = data.google_client_config.courant.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.principal.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.principal.endpoint}"
    token                  = data.google_client_config.courant.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.principal.master_auth[0].cluster_ca_certificate)
  }
}

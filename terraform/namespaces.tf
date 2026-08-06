# Un namespace par environnement, sur le même cluster.
#
# Deux clusters seraient plus étanches, mais doubleraient la facture. Les
# namespaces suffisent tant que staging et prod n'ont pas d'exigences de
# conformité distinctes — et ils donnent déjà l'isolation des noms, des
# quotas et des NetworkPolicy.

resource "kubernetes_namespace" "environnements" {
  for_each = toset(["staging", "production"])

  metadata {
    name = each.value
    labels = {
      environnement                  = each.value
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Plafond de ressources par environnement : empêche qu'un HPA emballé en
# staging affame la production sur le même cluster.
resource "kubernetes_resource_quota" "environnements" {
  for_each = kubernetes_namespace.environnements

  metadata {
    name      = "quota-${each.key}"
    namespace = each.value.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.key == "production" ? "2" : "1"
      "requests.memory" = each.key == "production" ? "4Gi" : "2Gi"
      "limits.cpu"      = each.key == "production" ? "4" : "2"
      "limits.memory"   = each.key == "production" ? "6Gi" : "3Gi"
      "pods"            = "20"
    }
  }
}

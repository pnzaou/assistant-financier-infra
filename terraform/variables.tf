variable "id_abonnement" {
  description = "Identifiant de l'abonnement Azure (az account show --query id -o tsv)."
  type        = string
}

variable "groupe_ressources" {
  description = <<-EOT
    Nom du groupe de ressources. Notion propre à Azure, sans équivalent GCP :
    c'est un conteneur logique. Tout supprimer revient à supprimer le groupe,
    ce qui est le garde-fou le plus efficace contre les ressources oubliées
    qui continuent de consommer les crédits.
  EOT
  type        = string
  default     = "assistant-financier-rg"
}

variable "region" {
  description = "Région Azure. westeurope refuse les nouveaux abonnements (RequestDisallowedByAzure) ; francecentral est la plus proche de Dakar et accepte les inscriptions."
  type        = string
  default     = "francecentral"
}

variable "nom_cluster" {
  description = "Nom du cluster AKS."
  type        = string
  default     = "assistant-financier"
}

variable "version_kubernetes" {
  description = "Version de Kubernetes. Laisser vide pour prendre la version stable par défaut de la région."
  type        = string
  default     = null
}

# ─── Pool système ────────────────────────────────────────────────
# Azure IMPOSE que le pool par défaut (celui qui héberge les composants
# système : CoreDNS, metrics-server…) soit en priorité Regular. Un pool
# système en Spot est refusé à la création. D'où deux pools distincts.

variable "taille_noeud_systeme" {
  description = "Type de VM du pool système. Standard_D2ads_v7 = 2 vCPU / 8 Go, la plus petite qui accepte AKS."
  type        = string
  default     = "Standard_D2ads_v7"
}

variable "nb_noeuds_systeme" {
  description = "Nombre de nœuds système. 1 suffit hors production."
  type        = number
  default     = 1
}

# ─── Pool applicatif ─────────────────────────────────────────────

variable "taille_noeud_app" {
  description = "Type de VM du pool applicatif."
  type        = string
  default     = "Standard_D2ads_v7"
}

variable "nb_noeuds_app_min" {
  description = "Taille minimale du pool applicatif (autoscaling)."
  type        = number
  default     = 1
}

variable "nb_noeuds_app_max" {
  description = "Taille maximale du pool applicatif. Plafond volontairement bas : garde-fou contre une boucle de scaling qui viderait les crédits."
  type        = number
  default     = 3
}

variable "noeuds_spot" {
  description = <<-EOT
    Utiliser des VM Spot pour le pool applicatif, jusqu'à 90 % moins chères.
    Contrepartie : Azure peut les récupérer avec 30 s de préavis, et elles
    portent un taint `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`
    que les pods doivent tolérer (le chart s'en charge).
    À passer à false pour une vraie production.
  EOT
  type        = bool
  default     = true
}

variable "activer_observabilite" {
  description = "Installer kube-prometheus-stack (Prometheus + Grafana + Alertmanager). Compte pour ~1,5 Go de RAM."
  type        = bool
  default     = true
}

variable "mot_de_passe_grafana" {
  description = "Mot de passe admin de Grafana. À passer par TF_VAR_mot_de_passe_grafana, jamais en clair dans un .tfvars commité."
  type        = string
  sensitive   = true
}

variable "plages_autorisees_api" {
  description = <<-EOT
    Plages CIDR autorisées à joindre l'API Kubernetes.
    Liste vide = ouvert à tous : pratique pour une démo depuis n'importe où,
    à restreindre à l'IP de sortie de l'équipe dès que possible.
  EOT
  type        = list(string)
  default     = []
}

variable "etiquettes" {
  description = "Étiquettes appliquées aux ressources — indispensables pour lire la facturation par poste."
  type        = map(string)
  default = {
    projet      = "assistant-financier"
    gere_par    = "terraform"
    environment = "staging"
  }
}

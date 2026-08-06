variable "projet_gcp" {
  description = "Identifiant du projet GCP (pas son nom d'affichage)."
  type        = string
}

variable "region" {
  description = "Région GCP. europe-west1 (Belgique) est la moins chère des régions européennes et la plus proche de Dakar en latence."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = <<-EOT
    Zone du cluster. Le cluster est ZONAL et non régional, délibérément :
    un cluster régional réplique le control plane sur trois zones et
    triple le nombre de nœuds. Pour un projet d'école c'est trois fois
    la facture sans bénéfice — et GKE offre la gestion d'UN cluster
    zonal par compte de facturation.
  EOT
  type        = string
  default     = "europe-west1-b"
}

variable "nom_cluster" {
  description = "Nom du cluster GKE."
  type        = string
  default     = "assistant-financier"
}

variable "type_machine" {
  description = "Type de machine des nœuds. e2-medium = 2 vCPU / 4 Go, le minimum viable pour faire tenir l'API, le front, Postgres et la stack d'observabilité."
  type        = string
  default     = "e2-medium"
}

variable "nb_noeuds_min" {
  description = "Taille minimale du pool (autoscaling)."
  type        = number
  default     = 2
}

variable "nb_noeuds_max" {
  description = "Taille maximale du pool (autoscaling). Plafond volontairement bas : c'est le garde-fou contre une boucle de scaling qui viderait les crédits."
  type        = number
  default     = 4
}

variable "noeuds_spot" {
  description = <<-EOT
    Utiliser des VM Spot (préemptibles), 60 à 91 % moins chères.
    Contrepartie : Google peut les récupérer avec 30 s de préavis.
    Acceptable ici — les Deployments ont plusieurs replicas et
    redémarrent ailleurs. À passer à false pour une vraie prod.
  EOT
  type        = bool
  default     = true
}

variable "reseaux_autorises_api" {
  description = <<-EOT
    Plages CIDR autorisées à joindre l'API Kubernetes.
    0.0.0.0/0 laisse le control plane ouvert au monde : pratique pour
    une démo depuis n'importe où, mais à restreindre à l'IP de sortie de
    l'équipe et à celle des runners GitHub dès que possible.
  EOT
  type = list(object({
    cidr        = string
    description = string
  }))
  default = [
    {
      cidr        = "0.0.0.0/0"
      description = "Ouvert — à restreindre"
    }
  ]
}

variable "activer_observabilite" {
  description = "Installer kube-prometheus-stack (Prometheus + Grafana + Alertmanager) dans le cluster. Compte pour ~1,5 Go de RAM."
  type        = bool
  default     = true
}

variable "mot_de_passe_grafana" {
  description = "Mot de passe de l'utilisateur admin de Grafana. À passer par TF_VAR_mot_de_passe_grafana, jamais en clair dans un .tfvars commité."
  type        = string
  sensitive   = true
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

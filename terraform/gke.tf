# ─────────────────────────────────────────────────────────────────
# Cluster GKE Standard, zonal, avec un pool de nœuds Spot.
#
# Pourquoi Standard et pas Autopilot : Autopilot facture à la ressource
# demandée par pod et refuse certaines charges (DaemonSets privilégiés,
# dont l'agent node-exporter de Prometheus). Standard + Spot revient
# nettement moins cher ici et laisse installer la stack d'observabilité
# telle quelle.
# ─────────────────────────────────────────────────────────────────

resource "google_container_cluster" "principal" {
  name     = var.nom_cluster
  project  = var.projet_gcp
  location = var.zone # zone (et non région) → cluster zonal

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.noeuds.id

  # GKE impose de créer un pool par défaut ; on le supprime aussitôt pour
  # gérer le nôtre séparément (google_container_node_pool ci-dessous).
  # Sans ça, changer le type de machine recréerait tout le cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Un projet d'école se détruit et se recrée : la protection empêcherait
  # `terraform destroy` et laisserait le cluster tourner — donc facturer.
  deletion_protection = false

  # Cluster VPC-natif : indispensable pour Workload Identity et pour que
  # l'Ingress GCE puisse cibler directement les pods (NEG).
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.noeuds.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.noeuds.secondary_ip_range[1].range_name
  }

  # Permet à un ServiceAccount Kubernetes d'emprunter l'identité d'un compte
  # de service GCP, sans clé JSON à stocker en Secret. C'est le mécanisme à
  # utiliser dès qu'un pod devra parler à une API Google.
  workload_identity_config {
    workload_pool = "${var.projet_gcp}.svc.id.goog"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.reseaux_autorises_api
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.description
      }
    }
  }

  release_channel {
    # REGULAR : mises à jour testées, sans être à la traîne de plusieurs
    # versions mineures comme le canal STABLE.
    channel = "REGULAR"
  }

  # Fenêtre de maintenance de nuit (UTC) : évite qu'une mise à jour de nœuds
  # tombe pendant une démo.
  maintenance_policy {
    daily_maintenance_window {
      start_time = "02:00"
    }
  }

  # Prometheus est installé dans le cluster (voir observabilite.tf) : le
  # service managé ferait doublon et serait facturé à l'échantillon.
  monitoring_config {
    managed_prometheus {
      enabled = false
    }
  }

  # Les logs partent quand même vers Cloud Logging : c'est le seul endroit
  # où lire ce qui s'est passé sur un nœud Spot déjà préempté.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  addons_config {
    http_load_balancing {
      disabled = false # requis par l'Ingress GCE
    }
    horizontal_pod_autoscaling {
      disabled = false # requis par les HPA du chart
    }
  }

  resource_labels = var.etiquettes
}

resource "google_container_node_pool" "principal" {
  name     = "${var.nom_cluster}-pool"
  project  = var.projet_gcp
  location = var.zone
  cluster  = google_container_cluster.principal.name

  initial_node_count = var.nb_noeuds_min

  autoscaling {
    min_node_count = var.nb_noeuds_min
    max_node_count = var.nb_noeuds_max
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Sur des nœuds Spot, la préemption est la norme, pas l'exception :
  # on remplace au plus un nœud à la fois et on tolère un nœud absent,
  # pour qu'une mise à jour ne vide jamais le cluster.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.type_machine
    disk_size_gb = 30
    disk_type    = "pd-standard" # pd-ssd coûte 4x plus cher pour rien ici

    spot = var.noeuds_spot

    # Compte de service dédié, au lieu du compte Compute par défaut qui a
    # le rôle Editor sur tout le projet.
    service_account = google_service_account.noeuds.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Ciblée par la règle pare-feu des sondes de load balancer.
    tags = ["gke-${var.nom_cluster}"]

    labels = var.etiquettes

    workload_metadata_config {
      # Empêche un pod de lire le serveur de métadonnées du nœud et donc
      # d'emprunter l'identité du compte de service des nœuds.
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    # Le nombre de nœuds est piloté par l'autoscaler : sans ça, chaque
    # `terraform apply` ramènerait le cluster à sa taille initiale.
    ignore_changes = [initial_node_count]
  }
}

# ─── Identité des nœuds ──────────────────────────────────────────

resource "google_service_account" "noeuds" {
  account_id   = "${var.nom_cluster}-noeuds"
  project      = var.projet_gcp
  display_name = "Nœuds GKE — ${var.nom_cluster}"
  description  = "Compte de service des nœuds. Droits minimaux : écrire logs et métriques, lire les images."
}

# Le strict nécessaire pour qu'un nœud fonctionne, et rien de plus.
resource "google_project_iam_member" "noeuds" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.projet_gcp
  role    = each.value
  member  = "serviceAccount:${google_service_account.noeuds.email}"
}

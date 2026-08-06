# ─────────────────────────────────────────────────────────────────
# Réseau : un VPC dédié plutôt que le réseau « default » de GCP.
#
# Le réseau default arrive avec des règles pare-feu permissives (SSH ouvert
# au monde, entre autres) et un sous-réseau dans chaque région. On repart
# d'un VPC vide dont on maîtrise chaque règle.
# ─────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name    = "${var.nom_cluster}-vpc"
  project = var.projet_gcp

  # Les sous-réseaux sont déclarés explicitement ci-dessous : sans ça GCP en
  # crée un par région, dont on n'utilisera jamais 99 %.
  auto_create_subnetworks = false

  # Les nœuds ont des IP publiques (voir gke.tf) : sans Cloud NAT, un MTU
  # non standard casserait certains flux TLS sortants.
  mtu = 1460
}

resource "google_compute_subnetwork" "noeuds" {
  name          = "${var.nom_cluster}-noeuds"
  project       = var.projet_gcp
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/20" # 4 094 adresses de nœuds

  # Cluster VPC-natif : les pods reçoivent de vraies IP routables du VPC
  # (alias IP) au lieu de passer par un overlay. C'est le mode par défaut
  # depuis GKE 1.21 et le prérequis de Workload Identity.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16" # 65 534 IP de pods
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20" # 4 094 IP de Services
  }

  # Journalise les flux réseau — utile pour comprendre a posteriori qui parle
  # à qui. Échantillonné à 50 % pour ne pas gonfler la facture Cloud Logging.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─── Règles pare-feu ─────────────────────────────────────────────
# Le trafic HTTP/HTTPS entrant n'a PAS besoin de règle : il arrive par le
# load balancer géré par l'Ingress, qui ouvre ses propres règles. On se
# limite donc au strict nécessaire.

resource "google_compute_firewall" "sante_load_balancer" {
  name    = "${var.nom_cluster}-sondes-lb"
  project = var.projet_gcp
  network = google_compute_network.vpc.name

  description = "Autorise les sondes de santé des load balancers Google vers les nœuds."

  allow {
    protocol = "tcp"
  }

  # Plages fixes et documentées des sondes Google. Sans elles, le load
  # balancer déclarerait tous les backends en échec et renverrait des 502.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["gke-${var.nom_cluster}"]
}

resource "google_compute_firewall" "interne" {
  name    = "${var.nom_cluster}-interne"
  project = var.projet_gcp
  network = google_compute_network.vpc.name

  description = "Trafic entre nœuds et pods du cluster."

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    google_compute_subnetwork.noeuds.ip_cidr_range,
    "10.20.0.0/16", # pods
  ]
}

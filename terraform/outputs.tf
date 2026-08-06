output "nom_cluster" {
  description = "Nom du cluster GKE."
  value       = google_container_cluster.principal.name
}

output "endpoint_cluster" {
  description = "Adresse de l'API Kubernetes."
  value       = google_container_cluster.principal.endpoint
  sensitive   = true
}

output "commande_kubeconfig" {
  description = "À exécuter pour configurer kubectl sur ce cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.principal.name} --zone ${var.zone} --project ${var.projet_gcp}"
}

output "commande_grafana" {
  description = "Ouvre Grafana sur http://localhost:3000 (utilisateur : admin)."
  value = var.activer_observabilite ? (
    "kubectl port-forward -n observabilite svc/observabilite-grafana 3000:80"
  ) : "Observabilité désactivée (activer_observabilite = false)"
}

output "compte_service_noeuds" {
  description = "Compte de service porté par les nœuds GKE."
  value       = google_service_account.noeuds.email
}

output "reseau" {
  description = "VPC et sous-réseau du cluster."
  value = {
    vpc         = google_compute_network.vpc.name
    sous_reseau = google_compute_subnetwork.noeuds.name
    plage_pods  = google_compute_subnetwork.noeuds.secondary_ip_range[0].ip_cidr_range
  }
}

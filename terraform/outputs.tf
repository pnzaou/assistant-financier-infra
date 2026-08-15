output "nom_cluster" {
  description = "Nom du cluster AKS."
  value       = azurerm_kubernetes_cluster.principal.name
}

output "groupe_ressources" {
  description = "Groupe de ressources. Le supprimer supprime TOUT ce qu'il contient."
  value       = azurerm_resource_group.principal.name
}

output "commande_kubeconfig" {
  description = "À exécuter pour configurer kubectl sur ce cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.principal.name} --name ${azurerm_kubernetes_cluster.principal.name} --overwrite-existing"
}

output "commande_grafana" {
  description = "Ouvre Grafana sur http://localhost:3000 (utilisateur : admin)."
  value = var.activer_observabilite ? (
    "kubectl port-forward -n observabilite svc/observabilite-grafana 3000:80"
  ) : "Observabilité désactivée (activer_observabilite = false)"
}

output "ip_ingress" {
  description = "Commande pour relever l'IP publique du contrôleur d'entrée nginx géré par AKS."
  value       = "kubectl get svc -n app-routing-system nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "classe_ingress" {
  description = "Valeur à mettre dans ingress.className du chart Helm."
  value       = "webapprouting.kubernetes.azure.com"
}

output "classe_stockage" {
  description = "Valeur à mettre dans postgres.stockage.classe du chart Helm."
  value       = local.classe_stockage
}

output "reseau" {
  description = "VNet et sous-réseau du cluster."
  value = {
    vnet         = azurerm_virtual_network.vnet.name
    sous_reseau  = azurerm_subnet.noeuds.name
    plage_noeuds = azurerm_subnet.noeuds.address_prefixes[0]
    plage_pods   = azurerm_kubernetes_cluster.principal.network_profile[0].pod_cidr
  }
}

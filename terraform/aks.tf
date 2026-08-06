# ─────────────────────────────────────────────────────────────────
# Cluster AKS.
#
# `sku_tier = "Free"` : contrairement à EKS (0,10 $/h) ou GKE (0,10 $/h au-delà
# du premier cluster zonal), le control plane AKS est gratuit. On ne paie que
# les nœuds. En contrepartie, aucun SLA sur la disponibilité de l'API — sans
# importance ici.
#
# Deux pools de nœuds, et ce n'est pas un choix esthétique : Azure REFUSE
# qu'un pool système soit en priorité Spot. Le pool par défaut héberge les
# composants système (CoreDNS, metrics-server) et reste donc en Regular ;
# les charges applicatives vont sur un pool Spot séparé.
# ─────────────────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "principal" {
  name                = var.nom_cluster
  location            = azurerm_resource_group.principal.location
  resource_group_name = azurerm_resource_group.principal.name
  dns_prefix          = "${var.nom_cluster}-${random_string.suffixe.result}"
  kubernetes_version  = var.version_kubernetes

  sku_tier = "Free"

  # Groupe de ressources créé automatiquement par AKS pour les nœuds, disques
  # et load balancers. Le nommer explicitement évite le « MC_xxx_yyy_zzz »
  # illisible par défaut.
  node_resource_group = "${var.groupe_ressources}-noeuds"

  default_node_pool {
    name           = "systeme"
    vm_size        = var.taille_noeud_systeme
    node_count     = var.nb_noeuds_systeme
    vnet_subnet_id = azurerm_subnet.noeuds.id

    # Réserve ce pool aux composants système : les pods applicatifs iront
    # sur le pool Spot, moins cher.
    only_critical_addons_enabled = true

    os_disk_size_gb = 30
    # Disque éphémère : plus rapide et surtout GRATUIT (inclus dans la VM),
    # là où un disque managé est facturé à part. Le contenu est perdu si le
    # nœud est recréé — sans importance pour un disque système.
    os_disk_type = "Ephemeral"

    upgrade_settings {
      max_surge = "1"
    }

    tags = var.etiquettes
  }

  # Identité gérée : pas de secret client à stocker ni à faire tourner.
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    # Mode overlay : les pods reçoivent leurs IP d'un espace privé distinct
    # du VNet. Sans lui, chaque pod consommerait une adresse du sous-réseau,
    # et un /20 serait épuisé bien avant la limite de nœuds.
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"

    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  # Contrôleur d'entrée nginx géré par Azure. L'alternative, Application
  # Gateway (AGIC), coûte ~125 $/mois à elle seule : hors de question ici.
  web_app_routing {
    dns_zone_ids = []
  }

  # L'autoscaler doit réagir vite : sur des nœuds Spot, une préemption doit
  # être compensée sans attendre.
  auto_scaler_profile {
    scale_down_unneeded        = "5m"
    scale_down_delay_after_add = "5m"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.plages_autorisees_api) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.plages_autorisees_api
    }
  }

  # Envoie les journaux du control plane vers Log Analytics. Sans ça, un pod
  # qui ne démarre pas ne laisse aucune trace consultable après coup.
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.principal.id
  }

  tags = var.etiquettes

  lifecycle {
    ignore_changes = [
      # Piloté par l'autoscaler du pool, pas par Terraform.
      default_node_pool[0].node_count,
    ]
  }
}

# ─── Pool applicatif (Spot) ──────────────────────────────────────

resource "azurerm_kubernetes_cluster_node_pool" "applicatif" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.principal.id
  vm_size               = var.taille_noeud_app
  vnet_subnet_id        = azurerm_subnet.noeuds.id

  auto_scaling_enabled = true
  min_count            = var.nb_noeuds_app_min
  max_count            = var.nb_noeuds_app_max

  os_disk_size_gb = 30
  os_disk_type    = "Ephemeral"

  # `priority = Spot` place automatiquement un taint
  # kubernetes.azure.com/scalesetpriority=spot:NoSchedule sur les nœuds.
  # Les pods doivent le tolérer — c'est le rôle des tolerations du chart.
  priority        = var.noeuds_spot ? "Spot" : "Regular"
  eviction_policy = var.noeuds_spot ? "Delete" : null
  # -1 : accepter le prix Spot courant, quel qu'il soit, plutôt que de fixer
  # un plafond qui empêcherait le provisionnement quand la demande monte.
  spot_max_price = var.noeuds_spot ? -1 : null

  node_labels = var.noeuds_spot ? {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  } : {}

  tags = var.etiquettes

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ─── Journalisation ──────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "principal" {
  name                = "${var.nom_cluster}-logs-${random_string.suffixe.result}"
  location            = azurerm_resource_group.principal.location
  resource_group_name = azurerm_resource_group.principal.name
  sku                 = "PerGB2018"
  # 30 jours est le minimum facturable ; au-delà, l'ingestion des logs
  # devient vite le premier poste de dépense d'un petit cluster.
  retention_in_days = 30
  tags              = var.etiquettes
}

# ─── Autorisations ───────────────────────────────────────────────
# Le kubelet doit pouvoir tirer les images. Ici elles viennent de GHCR
# (public), donc aucun rôle Azure n'est requis. Ce bloc sert d'amorce si
# vous basculez un jour sur Azure Container Registry :
#
# resource "azurerm_role_assignment" "acr_pull" {
#   scope                = azurerm_container_registry.principal.id
#   role_definition_name = "AcrPull"
#   principal_id         = azurerm_kubernetes_cluster.principal.kubelet_identity[0].object_id
# }

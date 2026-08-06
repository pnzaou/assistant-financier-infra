# ─────────────────────────────────────────────────────────────────
# Groupe de ressources et réseau.
#
# Le groupe de ressources est la brique de base d'Azure : toutes les
# ressources y appartiennent, et le supprimer supprime tout ce qu'il
# contient. C'est le filet de sécurité le plus fiable contre les
# ressources oubliées qui continuent d'être facturées.
# ─────────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "principal" {
  name     = var.groupe_ressources
  location = var.region
  tags     = var.etiquettes
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.nom_cluster}-vnet"
  location            = azurerm_resource_group.principal.location
  resource_group_name = azurerm_resource_group.principal.name
  address_space       = ["10.10.0.0/16"]
  tags                = var.etiquettes
}

resource "azurerm_subnet" "noeuds" {
  name                 = "${var.nom_cluster}-noeuds"
  resource_group_name  = azurerm_resource_group.principal.name
  virtual_network_name = azurerm_virtual_network.vnet.name

  # /20 = 4 091 adresses utilisables (Azure en réserve 5 par sous-réseau).
  # En mode overlay, seuls les NŒUDS consomment ces adresses : les pods
  # vivent sur un réseau séparé, ce qui évite d'épuiser le VNet.
  address_prefixes = ["10.10.0.0/20"]
}

# ─────────────────────────────────────────────────────────────────
# Suffixe aléatoire pour les noms devant être uniques à l'échelle mondiale
# (DNS des IP publiques). Sans lui, deux déploiements du projet entreraient
# en collision.
# ─────────────────────────────────────────────────────────────────
resource "random_string" "suffixe" {
  length  = 6
  special = false
  upper   = false
}

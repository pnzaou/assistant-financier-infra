# ─────────────────────────────────────────────────────────────────
# Point 4i — Observabilité : Prometheus + Grafana + Alertmanager.
#
# kube-prometheus-stack apporte d'un bloc l'opérateur Prometheus, Grafana avec
# ses tableaux de bord Kubernetes préchargés, Alertmanager, node-exporter et
# kube-state-metrics. Les valeurs par défaut du chart visent un cluster de
# production : sur des VM Standard_B2s elles ne tiendraient pas, d'où les
# ajustements ci-dessous.
#
# TOLÉRATIONS — le point à ne pas rater sur AKS. Les deux pools sont taintés :
#   pool système      → CriticalAddonsOnly=true:NoSchedule (only_critical_addons_enabled)
#   pool applicatif   → kubernetes.azure.com/scalesetpriority=spot:NoSchedule (priorité Spot)
# Sans tolérer l'un des deux, aucun pod de la stack ne trouverait de nœud et
# tout resterait indéfiniment en Pending.
# ─────────────────────────────────────────────────────────────────

locals {
  # Les charges d'observabilité vont sur le pool Spot : leur interruption
  # ponctuelle est acceptable, et ça laisse le pool système aux composants
  # Kubernetes.
  toleration_spot = [{
    key      = "kubernetes.azure.com/scalesetpriority"
    operator = "Equal"
    value    = "spot"
    effect   = "NoSchedule"
  }]

  # node-exporter est un DaemonSet : il doit tourner sur TOUS les nœuds, y
  # compris système, sinon ces nœuds n'auraient aucune métrique.
  toleration_tous_noeuds = [
    {
      key      = "kubernetes.azure.com/scalesetpriority"
      operator = "Equal"
      value    = "spot"
      effect   = "NoSchedule"
    },
    {
      key      = "CriticalAddonsOnly"
      operator = "Equal"
      value    = "true"
      effect   = "NoSchedule"
    },
  ]

  # Classe de stockage Azure. `managed-csi` = SSD Standard, le meilleur
  # rapport prix/performance ici. `managed-csi-premium` serait 3x plus cher
  # pour un gain nul sur ces volumes.
  classe_stockage = "managed-csi"
}

resource "kubernetes_namespace" "observabilite" {
  count = var.activer_observabilite ? 1 : 0

  metadata {
    name = "observabilite"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.activer_observabilite ? 1 : 0

  name       = "observabilite"
  namespace  = kubernetes_namespace.observabilite[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "66.2.1"

  # L'opérateur installe ses CRD puis les objets qui en dépendent : sans
  # marge, l'apply échoue sur « no matches for kind ServiceMonitor ».
  timeout = 900

  values = [yamlencode({
    # ─── Prometheus ───────────────────────────────────────────────
    prometheus = {
      prometheusSpec = {
        # 7 jours suffisent pour une démo et bornent le disque.
        retention     = "7d"
        retentionSize = "8GB"

        tolerations = local.toleration_spot

        resources = {
          requests = { cpu = "150m", memory = "512Mi" }
          limits   = { memory = "1Gi" }
        }

        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              accessModes      = ["ReadWriteOnce"]
              storageClassName = local.classe_stockage
              resources        = { requests = { storage = "10Gi" } }
            }
          }
        }

        # Sans ça, Prometheus ne découvre que les ServiceMonitor portant les
        # labels du chart — donc pas ceux de l'application.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }

    # ─── Grafana ──────────────────────────────────────────────────
    grafana = {
      adminPassword = var.mot_de_passe_grafana
      tolerations   = local.toleration_spot

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }

      # Pas d'Ingress : l'exposer publiquement demanderait TLS et une vraie
      # authentification. On y accède par port-forward (voir README).
      service = { type = "ClusterIP" }

      persistence = {
        enabled          = true
        size             = "2Gi"
        storageClassName = local.classe_stockage
      }

      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "defaut"
            orgId           = 1
            folder          = "Assistant Financier"
            type            = "file"
            disableDeletion = false
            options         = { path = "/var/lib/grafana/dashboards/defaut" }
          }]
        }
      }
      dashboards = {
        defaut = {
          # Latence, trafic, erreurs et saturation d'une app Node.js.
          "nodejs-application" = { gnetId = 11159, revision = 1, datasource = "Prometheus" }
          # Vue par namespace : CPU, mémoire, réseau des workloads.
          "kubernetes-namespace" = { gnetId = 15758, revision = 39, datasource = "Prometheus" }
        }
      }
    }

    # ─── Alertmanager ─────────────────────────────────────────────
    alertmanager = {
      alertmanagerSpec = {
        tolerations = local.toleration_spot
        resources = {
          requests = { cpu = "20m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
        storage = {
          volumeClaimTemplate = {
            spec = {
              accessModes      = ["ReadWriteOnce"]
              storageClassName = local.classe_stockage
              resources        = { requests = { storage = "2Gi" } }
            }
          }
        }
      }
    }

    # ─── Opérateur ────────────────────────────────────────────────
    prometheusOperator = {
      tolerations = local.toleration_spot
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    # ─── Agents ───────────────────────────────────────────────────
    nodeExporter = { enabled = true }
    "prometheus-node-exporter" = {
      # DaemonSet : doit couvrir TOUS les nœuds, système compris.
      tolerations = local.toleration_tous_noeuds
      resources = {
        requests = { cpu = "20m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }

    kubeStateMetrics = { enabled = true }
    "kube-state-metrics" = {
      tolerations = local.toleration_spot
      resources = {
        requests = { cpu = "20m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }
    }

    # AKS ne donne pas accès aux composants du control plane : ces exporters
    # resteraient éternellement « down » et pollueraient les alertes.
    kubeApiServer         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
  })]

  depends_on = [azurerm_kubernetes_cluster_node_pool.applicatif]
}

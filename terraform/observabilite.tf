# ─────────────────────────────────────────────────────────────────
# Point 4i — Observabilité : Prometheus + Grafana + Alertmanager.
#
# kube-prometheus-stack apporte d'un bloc l'opérateur Prometheus, Grafana
# avec ses tableaux de bord Kubernetes préchargés, Alertmanager, node-exporter
# et kube-state-metrics. Les valeurs par défaut du chart visent un cluster de
# production : sur des nœuds e2-medium elles ne tiendraient pas, d'où les
# ajustements ci-dessous.
# ─────────────────────────────────────────────────────────────────

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

        resources = {
          requests = { cpu = "150m", memory = "512Mi" }
          limits   = { memory = "1Gi" }
        }

        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              accessModes = ["ReadWriteOnce"]
              # pd-standard : le débit d'un SSD n'apporte rien à ce volume.
              storageClassName = "standard-rwo"
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
        storageClassName = "standard-rwo"
      }

      # Tableaux de bord communautaires, tirés automatiquement de grafana.com.
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
        resources = {
          requests = { cpu = "20m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
        storage = {
          volumeClaimTemplate = {
            spec = {
              accessModes      = ["ReadWriteOnce"]
              storageClassName = "standard-rwo"
              resources        = { requests = { storage = "2Gi" } }
            }
          }
        }
      }
    }

    # ─── Agents ───────────────────────────────────────────────────
    nodeExporter = {
      enabled = true
    }
    prometheus-node-exporter = {
      resources = {
        requests = { cpu = "20m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }
    kubeStateMetrics = { enabled = true }
    kube-state-metrics = {
      resources = {
        requests = { cpu = "20m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }
    }

    # GKE ne donne pas accès aux composants du control plane : ces exporters
    # resteraient éternellement « down » et pollueraient les alertes.
    kubeApiServer         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
  })]

  depends_on = [google_container_node_pool.principal]
}

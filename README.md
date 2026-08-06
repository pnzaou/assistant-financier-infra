# Assistant Financier — Infrastructure

Provisionnement GCP, déploiement Kubernetes et observabilité.
Couvre les points **4g, 4h et 4i** du TODO.

| Dossier | Contenu |
|---|---|
| `terraform/` | VPC, cluster GKE, namespaces, stack Prometheus/Grafana |
| `helm/assistant-financier/` | Chart de l'application (API, front, PostgreSQL) |
| `.github/workflows/` | `terraform.yml` (plan/apply), `deploiement.yml` (helm upgrade) |

Les images déployées viennent de GHCR, publiées par la CI des repos
[client](https://github.com/pnzaou/assistant-financier-client) et
[serveur](https://github.com/pnzaou/assistant-financier-server).

---

## Choix structurants

**GKE Standard zonal, pas Autopilot ni régional.** Autopilot facture à la
ressource demandée et refuse les DaemonSets privilégiés — dont `node-exporter`,
nécessaire à l'observabilité. Un cluster régional triple le control plane et
les nœuds. Le zonal Standard est le seul à tenir dans les crédits gratuits.

**Nœuds Spot.** 60 à 91 % moins chers, préemptibles avec 30 s de préavis. Les
Deployments ont plusieurs replicas, des `topologySpreadConstraints` et un
PodDisruptionBudget : une préemption ne coupe pas le service. À passer à
`noeuds_spot = false` pour une vraie production.

**PostgreSQL dans le cluster.** La plus petite instance Cloud SQL coûte
~10 $/mois. Un StatefulSet mono-replica suffit pour staging et la démo — mais
**sans sauvegarde ni réplication** : si le disque est perdu, les données le
sont. Pour la production, basculer sur Cloud SQL (`postgres.active = false` et
`secrets.databaseUrl` renseigné).

**Images sur GHCR, pas Artifact Registry.** Gratuit et illimité sur dépôt
public, déjà lié à GitHub, aucun secret supplémentaire à gérer.

---

## Coût estimé

Sur `europe-west1`, avec les valeurs par défaut :

| Poste | ~ /mois |
|---|---|
| Control plane GKE (1er cluster zonal) | **0 $** — offert par compte de facturation |
| 2 × e2-medium Spot | 10–16 $ |
| Disques des nœuds (2 × 30 Go pd-standard) | 2–3 $ |
| Volumes persistants (Prometheus, Grafana, Alertmanager, Postgres) | 2–3 $ |
| Load balancer HTTP(S) de l'Ingress | **~18 $** |
| **Total** | **~35–45 $** |

Les 300 $ de crédits couvrent donc largement les 90 jours d'essai.

Le load balancer est le poste le plus lourd. Pour une démo courte, mettre
`ingress.active: false` et passer par `kubectl port-forward` économise cette
ligne entière.

> **Détruire l'infrastructure quand elle ne sert pas** : `terraform destroy`.
> Un cluster oublié consomme les crédits jour et nuit.

---

## Amorçage (une seule fois)

Terraform ne peut pas créer le bucket qui contient son propre état : il faut
l'amorcer à la main.

```bash
# 1. Projet et facturation
gcloud auth login
gcloud projects create assistant-financier-XXXXXX --name="Assistant Financier"
gcloud config set project assistant-financier-XXXXXX
# Lier le compte de facturation (indispensable, même avec des crédits) :
gcloud billing projects link assistant-financier-XXXXXX --billing-account=XXXXXX-XXXXXX-XXXXXX

# 2. Activer les API utilisées
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com

# 3. Bucket de l'état Terraform (le versioning permet de revenir en arrière
#    après un apply malheureux)
gsutil mb -p assistant-financier-XXXXXX -l europe-west1 gs://assistant-financier-tfstate
gsutil versioning set on gs://assistant-financier-tfstate
```

## Provisionner

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # renseigner projet_gcp

export TF_VAR_mot_de_passe_grafana='…'         # jamais dans un .tfvars

terraform init -backend-config="bucket=assistant-financier-tfstate"
terraform plan      # TOUJOURS relire avant d'appliquer
terraform apply
```

Comptez 10 à 15 minutes : la création du cluster et l'installation de
kube-prometheus-stack sont les étapes longues.

```bash
# Configurer kubectl (la commande exacte est aussi en sortie de terraform)
gcloud container clusters get-credentials assistant-financier \
  --zone europe-west1-b --project assistant-financier-XXXXXX

kubectl get nodes
```

## Déployer l'application

```bash
# Clés JWT — les mêmes que celles attendues par l'API
node ../server/scripts/generer-cles.js > /tmp/cles.env
source /tmp/cles.env

helm upgrade --install assistant-financier ./helm/assistant-financier \
  --namespace staging \
  --values ./helm/assistant-financier/values-staging.yaml \
  --set serveur.image.tag=sha-<commit> \
  --set client.image.tag=sha-<commit> \
  --set secrets.jwtClePrivee="$JWT_PRIVATE_KEY" \
  --set secrets.jwtClePublique="$JWT_PUBLIC_KEY" \
  --set secrets.cookieSecret="$(openssl rand -hex 32)" \
  --set postgres.motDePasse="$(openssl rand -hex 16)" \
  --atomic --wait --timeout 10m
```

**Épingler un `sha-<commit>`, pas `develop`.** Un tag mouvant rend le
déploiement non reproductible : deux `helm upgrade` identiques peuvent
installer deux versions différentes, et le rollback ne veut plus rien dire.

L'Ingress GCE met **5 à 10 minutes** à provisionner son IP au premier
déploiement. `kubectl get ingress -n staging -w` pour la voir apparaître.
Reporter ensuite le nom d'hôte réel dans `config.urlApiPubliqueClient` et
`config.urlsClient`.

### Rollback

```bash
helm history assistant-financier -n staging
helm rollback assistant-financier <révision> -n staging --wait
```

Attention : Helm restaure les manifests, **pas la base**. Une migration qui a
supprimé une colonne ne se défait pas toute seule.

## Observabilité

```bash
kubectl port-forward -n observabilite svc/observabilite-grafana 3000:80
# http://localhost:3000 — utilisateur admin, mot de passe = TF_VAR_mot_de_passe_grafana
```

Grafana arrive avec les tableaux de bord Kubernetes du chart, plus deux
importés depuis grafana.com (application Node.js, vue par namespace).

Prometheus : `kubectl port-forward -n observabilite svc/observabilite-kube-prometheus-prometheus 9090:9090`

---

## Ce qui reste à faire côté serveur

Le chart crée un `ServiceMonitor` qui demande à Prometheus de scruter
`/metrics` sur l'API. **Cet endpoint n'existe pas encore** : tant qu'il n'est
pas ajouté, la cible apparaîtra `down` dans Prometheus et les tableaux de bord
applicatifs resteront vides. Le reste (métriques du cluster, des nœuds, des
pods) fonctionne indépendamment.

Il manque, dans le repo serveur :

1. **`prom-client`** — exposer `/metrics` : métriques par défaut du process
   Node, plus un histogramme de latence et un compteur de requêtes par route
   et par code de statut. C'est ce qui alimente les quatre signaux d'or
   (latence, trafic, erreurs, saturation).
2. **Logs structurés** — remplacer `morgan` par `pino`. Une ligne de log en
   texte libre n'est pas requêtable ; en JSON, elle devient filtrable par
   `requestId`, `userId` ou `statusCode` dans Cloud Logging.
3. **Arrêt propre** — intercepter `SIGTERM`, cesser d'accepter de nouvelles
   connexions, laisser les requêtes en cours se terminer. Sans ça, chaque
   préemption d'un nœud Spot coupe des requêtes au milieu.

---

## Sécurité — état actuel

Volontairement laissé ouvert pour la démo, à resserrer avant tout usage réel :

- `reseaux_autorises_api = 0.0.0.0/0` — l'API Kubernetes est joignable depuis
  n'importe où. À restreindre à l'IP de sortie de l'équipe.
- Les nœuds ont des IP publiques (pas de Cloud NAT, qui coûterait ~30 $/mois).
- Grafana n'est pas exposé : accès par `port-forward` uniquement. C'est
  délibéré — l'exposer demanderait TLS et une vraie authentification.
- Aucune `NetworkPolicy` : tous les pods peuvent se parler. GKE Dataplane V2
  serait à activer pour les appliquer.

## Secrets attendus par la CI

| Secret | Usage |
|---|---|
| `WIF_PROVIDER`, `WIF_SERVICE_ACCOUNT` | Workload Identity Federation — évite de stocker une clé JSON |
| `BUCKET_ETAT_TF` | Bucket GCS de l'état Terraform |
| `PROJET_GCP`, `ZONE_GCP`, `NOM_CLUSTER` | Cible du déploiement |
| `MOT_DE_PASSE_GRAFANA` | Compte admin Grafana |
| `JWT_CLE_PRIVEE`, `JWT_CLE_PUBLIQUE`, `COOKIE_SECRET` | Secrets applicatifs |
| `POSTGRES_MOT_DE_PASSE` | Base dans le cluster |
| `RESEND_API_KEY` | Envoi d'emails (optionnel) |

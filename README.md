# Assistant Financier — Infrastructure

Provisionnement Azure, déploiement Kubernetes et observabilité.
Couvre les points **4g, 4h et 4i** du TODO.

| Dossier | Contenu |
|---|---|
| `terraform/` | Groupe de ressources, VNet, cluster AKS, namespaces, stack Prometheus/Grafana |
| `helm/assistant-financier/` | Chart de l'application (API, front, PostgreSQL) |
| `.github/workflows/` | `terraform.yml` (plan/apply), `deploiement.yml` (helm upgrade) |

Les images déployées viennent de GHCR, publiées par la CI des repos
[client](https://github.com/pnzaou/assistant-financier-client) et
[serveur](https://github.com/pnzaou/assistant-financier-server).

---

## Choix structurants

**AKS avec `sku_tier = "Free"`.** Contrairement à EKS (0,10 $/h) et GKE
(0,10 $/h au-delà du premier cluster zonal), le control plane AKS est gratuit.
On ne paie que les nœuds. En contrepartie : aucun SLA sur la disponibilité de
l'API Kubernetes, sans importance ici.

**Deux pools de nœuds, et ce n'est pas cosmétique.** Azure **refuse** qu'un
pool système soit en priorité Spot. Le pool par défaut héberge les composants
système (CoreDNS, metrics-server) et reste en Regular ; les charges
applicatives vont sur un pool Spot séparé, jusqu'à 90 % moins cher.

**Conséquence directe : les tolérations sont obligatoires.** Le pool système
porte le taint `CriticalAddonsOnly=true:NoSchedule`, le pool applicatif
`kubernetes.azure.com/scalesetpriority=spot:NoSchedule`. Un pod qui ne tolère
ni l'un ni l'autre reste **indéfiniment en Pending** — c'est l'erreur la plus
fréquente sur un cluster AKS mixte. Le chart et la stack d'observabilité
déclarent les tolérations qu'il faut.

**Réseau en mode overlay.** Les pods reçoivent leurs IP d'un espace privé
distinct du VNet. Sans ça, chaque pod consommerait une adresse du sous-réseau
et un `/20` serait épuisé bien avant la limite de nœuds.

**Disques OS éphémères.** Inclus dans le prix de la VM, là où un disque managé
est facturé à part. Le contenu est perdu si le nœud est recréé — sans
importance pour un disque système.

**PostgreSQL dans le cluster.** Azure Database for PostgreSQL démarre autour de
15 $/mois. Un StatefulSet mono-replica suffit pour staging et la démo, mais
**sans sauvegarde ni réplication** : si le disque est perdu, les données le
sont. Pour une vraie production, basculer sur le service managé
(`postgres.active = false` et `secrets.databaseUrl` renseigné).

**Images sur GHCR, pas Azure Container Registry.** Gratuit et illimité sur
dépôt public, déjà lié à GitHub, aucun secret supplémentaire à gérer.

---

## Coût estimé

Sur `westeurope`, avec les valeurs par défaut :

| Poste | ~ /mois |
|---|---|
| Control plane AKS (tier Free) | **0 $** |
| 1 × Standard_B2s système (Regular — imposé par Azure) | ~30 $ |
| 1 × Standard_B2s applicatif (Regular — Spot indisponible sur l'essai) | ~30 $ |
| Disques OS éphémères | 0 $ |
| Volumes persistants (Prometheus, Grafana, Alertmanager, Postgres) | 2–3 $ |
| Load balancer Standard + IP publique | ~22 $ |
| Log Analytics (ingestion des journaux) | 5–15 $ |
| **Total** | **~85–95 $** |

Les 200 $ de l'essai gratuit couvrent donc confortablement les 30 jours, mais
**pas beaucoup plus**. Deux leviers si ça devient juste :

- `ingress.active: false` + `kubectl port-forward` → **−22 $/mois**
- Retirer le bloc `oms_agent` de `aks.tf` → jusqu'à **−15 $/mois** (au prix de
  la perte des journaux du control plane)

> **Détruire l'infrastructure quand elle ne sert pas** : `terraform destroy`,
> ou supprimer le groupe de ressources. Un cluster oublié consomme jour et
> nuit, et l'essai Azure ne dure que 30 jours.

---

## Deux limites de l'essai gratuit à connaître avant de commencer

**Les VM Spot ne sont pas disponibles.** Azure les refuse aux abonnements Free
Trial, Azure for Students et MSDN. Il faut `noeuds_spot = false`, sinon la
création du pool applicatif échoue après plusieurs minutes d'attente, sur une
erreur peu explicite (`SkuNotAvailable`, `OperationNotAllowed`). Conséquence
directe sur la facture : le nœud applicatif passe de ~6 $ à ~30 $/mois.

**Le quota est de 4 vCPU par région.** Deux `Standard_B2s` (2 vCPU chacune) le
consomment exactement — d'où `nb_noeuds_app_max = 1`. Un autoscaling au-delà
échouerait silencieusement, l'autoscaler ne pouvant pas provisionner. À
vérifier avant l'apply :

```bash
az vm list-usage --location westeurope -o table | grep -i "Total Regional vCPUs"
```

Une demande d'augmentation de quota est possible depuis le portail
(Aide + support → Nouvelle demande de support → Limites de service), mais elle
est souvent refusée sur un abonnement d'essai.

Coût réel dans cette configuration : **~85–95 $/mois**. Les 200 $ couvrent
donc les 30 jours de l'essai, sans marge pour un oubli.

## Amorçage (une seule fois)

Terraform ne peut pas créer le compte de stockage qui contient son propre
état : il faut l'amorcer à la main.

> **« Une seule fois » tant que le compte de stockage existe.** S'il
> disparaît, l'état disparaît avec lui : Terraform ne sait plus ce qu'il
> gère et échoue sur un 404 au premier `init`. C'est déjà arrivé sur ce
> projet. Refaire cette section suffit à repartir — mais sur une
> infrastructure encore debout, Terraform la croirait alors inexistante et
> tenterait de tout recréer. Vérifiez donc l'état réel côté Azure avant
> tout `apply` : `az resource list --query "length(@)" -o tsv`.

```bash
az login
az account set --subscription "<nom ou id de l'abonnement>"
az account show --query id -o tsv     # → id_abonnement du terraform.tfvars

# Groupe de ressources dédié à l'état, séparé de celui du cluster : il ne doit
# pas disparaître avec un `terraform destroy`.
az group create --name assistant-financier-tfstate --location westeurope

# Le nom du compte de stockage doit être unique dans tout Azure, en
# minuscules, sans tiret. Ajoutez un suffixe aléatoire.
az storage account create \
  --name afitfstateXXXXXX \
  --resource-group assistant-financier-tfstate \
  --location westeurope \
  --sku Standard_LRS \
  --encryption-services blob

az storage container create \
  --name tfstate \
  --account-name afitfstateXXXXXX

# Versioning : permet de revenir en arrière après un apply malheureux.
az storage account blob-service-properties update \
  --account-name afitfstateXXXXXX \
  --resource-group assistant-financier-tfstate \
  --enable-versioning true
```

## Provisionner

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # renseigner id_abonnement

export TF_VAR_mot_de_passe_grafana='…'         # jamais dans un .tfvars

terraform init \
  -backend-config="resource_group_name=assistant-financier-tfstate" \
  -backend-config="storage_account_name=afitfstateXXXXXX" \
  -backend-config="container_name=tfstate"

terraform plan      # TOUJOURS relire avant d'appliquer
terraform apply
```

Comptez 10 à 15 minutes : la création du cluster et l'installation de
kube-prometheus-stack sont les étapes longues.

```bash
az aks get-credentials \
  --resource-group assistant-financier-rg \
  --name assistant-financier \
  --overwrite-existing

kubectl get nodes
```

Deux nœuds doivent apparaître, l'un du pool `systeme`, l'autre du pool `app`.

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

Relever l'IP publique du contrôleur d'entrée :

```bash
kubectl get svc -n app-routing-system nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Reporter ensuite le nom d'hôte réel (ou l'IP) dans
`config.urlApiPubliqueClient` et `config.urlsClient` de
`values-staging.yaml`, puis redéployer. Ces deux valeurs doivent être des
**origines complètes** (`https://hôte`) : le client résout son URL d'API avec
`||`, donc une chaîne vide retomberait sur `localhost:5000`.

### Rollback

```bash
helm history assistant-financier -n staging
helm rollback assistant-financier <révision> -n staging --wait
```

Attention : Helm restaure les manifests, **pas la base**. Une migration qui a
supprimé une colonne ne se défait pas toute seule.

## Détruire

```bash
cd terraform
terraform destroy
```

Comptez une dizaine de minutes. La suppression du groupe de ressources est
la dernière étape et, à elle seule, la plus longue.

**Vérifiez toujours le résultat** — un `destroy` peut s'arrêter en cours de
route en laissant des ressources facturées :

```bash
az resource list --query "length(@)" -o tsv     # doit renvoyer 0
az group list --query "[].name" -o tsv
```

Doivent subsister uniquement `assistant-financier-tfstate` (l'état) et
`NetworkWatcherRG` (recréé automatiquement par Azure). Les deux sont vides
et gratuits.

Si un groupe résiste alors qu'il est vide :

```bash
az group delete -n assistant-financier-rg --yes
```

### Ce qui a déjà mal tourné ici

**Le garde-fou sur les ressources imbriquées.** AKS crée lui-même une
solution `ContainerInsights(...)` que Terraform ne connaît pas ; le provider
refusait alors de supprimer le groupe, après avoir pourtant déjà tout
détruit. Réglé en passant `prevent_deletion_if_contains_resources` à `false`
dans `providers.tf` — voir le commentaire qui y détaille l'arbitrage.

**La perte du compte de stockage de l'état.** Si `terraform destroy` échoue
sur un 404 du type :

```
Error: retrieving Storage Account … unexpected status 404 (404 Not Found)
```

c'est que le backend a disparu : Terraform ne peut plus lire son état, et ne
sait donc plus ce qu'il gère. Vérifiez avec `az storage account list`. Dans
ce cas, le plus simple est de **finir le nettoyage à la main** avec
`az group delete`, puis de refaire l'[amorçage](#amorçage-une-seule-fois)
avant le prochain `apply` — Terraform repartira d'un état vierge, ce qui est
correct dès lors que plus rien n'existe côté Azure.

### Remonter l'environnement ensuite

1. Refaire l'amorçage si le compte de stockage n'existe plus.
2. `terraform init -backend-config=…` puis `terraform apply`.
3. Relever la nouvelle IP publique de l'Ingress — **elle change à chaque
   recréation** :

   ```bash
   kubectl get svc -n app-routing-system nginx \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

4. Reporter cette IP dans `helm/assistant-financier/values-staging.yaml`
   (`urlApiPubliqueClient` **et** `urlsClient`), les deux la contenant en dur.
5. Relancer le workflow **Déploiement**, en laissant les champs de tags vides.

## Observabilité

```bash
kubectl port-forward -n observabilite svc/observabilite-grafana 3000:80
# http://localhost:3000 — utilisateur admin, mot de passe = TF_VAR_mot_de_passe_grafana
```

Prometheus : `kubectl port-forward -n observabilite svc/observabilite-kube-prometheus-prometheus 9090:9090`

---

## Instrumentation de l'API

Le chart crée un `ServiceMonitor` qui demande à Prometheus de scruter
`/metrics` sur l'API. L'endpoint existe depuis la branche `feat/observabilite`
du repo serveur, avec :

- les métriques du process Node (mémoire, boucle d'événements, GC), un
  histogramme de latence et des compteurs de requêtes et d'erreurs ;
- des journaux JSON (`pino`) filtrables par `requestId`, `statut` ou durée,
  avec masquage des en-têtes `Authorization` et `Cookie` ;
- un arrêt en douceur sur `SIGTERM` : `/health` bascule en 503, cinq secondes
  d'attente que Kubernetes cesse de router, puis fermeture du serveur et du
  pool PostgreSQL.

Ce dernier point compte particulièrement ici : les nœuds Spot sont évincés
avec 30 secondes de préavis, et sans ce drainage chaque éviction couperait des
requêtes en vol.

## Sécurité — état actuel

Volontairement laissé ouvert pour la démo, à resserrer avant tout usage réel :

- `plages_autorisees_api = []` — l'API Kubernetes est joignable depuis
  n'importe où. À restreindre à l'IP de sortie de l'équipe.
- Grafana n'est pas exposé : accès par `port-forward` uniquement. C'est
  délibéré — l'exposer demanderait TLS et une vraie authentification.
- Aucune `NetworkPolicy` : tous les pods peuvent se parler.
- Pas de TLS sur l'Ingress en staging. En production, `ingress.tls.nomSecret`
  attend un Secret créé au préalable (cert-manager, ou `kubectl create secret
  tls`) — AKS n'a pas d'équivalent au ManagedCertificate de GKE.

## Secrets attendus par la CI

| Secret | Usage |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | Authentification OIDC — aucun secret client stocké |
| `GROUPE_RESSOURCES_ETAT`, `COMPTE_STOCKAGE_ETAT` | Backend Terraform |
| `GROUPE_RESSOURCES`, `NOM_CLUSTER` | Cible du déploiement |
| `MOT_DE_PASSE_GRAFANA` | Compte admin Grafana |
| `JWT_CLE_PRIVEE`, `JWT_CLE_PUBLIQUE`, `COOKIE_SECRET` | Secrets applicatifs |
| `POSTGRES_MOT_DE_PASSE` | Base dans le cluster |
| `RESEND_API_KEY` | Envoi d'emails (optionnel) |

L'authentification OIDC demande de créer une application Entra ID avec une
*federated credential* pointant sur ce dépôt. Voir la documentation
`azure/login` — c'est la partie la moins évidente de la mise en place.
